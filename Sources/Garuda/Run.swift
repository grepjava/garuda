//===----------------------------------------------------------------------===//
// Serving: the command line, then shards.
//
//     let app = Application()
//     app.get("/") { Text("hello") }
//     app.run()
//
// `run` reads the command line, checks the routes, and hands the process to
// Vega's sharded runtime: K shard processes, each a work-stealing runtime on
// its own CPUs, under a supervisor that starts a crashed shard again. With
// `--shards 0` (the default on macOS and Windows) it serves in this process.
//
// Under an exec launch every shard runs `main` again up to `run`, so the
// routes an application registers must be the same every time: no clock, no
// random numbers, no reading of files that may change in between.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Vega
import VegaIO
import GarudaWire

extension Application {
    /// Serves with the configuration on the command line, and never returns:
    /// the process exits when the server stops, 2 when the command line or the
    /// routes are wrong.
    public func run(arguments: [String] = CommandLine.arguments) -> Never {
        switch ServerConfig.parse(arguments) {
        case .exit(let status):
            exit(status)
        case .run(let config):
            run(config: config)
        }
    }

    /// Serves with `config`, and never returns.
    public func run(config: ServerConfig) -> Never {
        let problems = problems()
        if !problems.isEmpty {
            for problem in problems { Log.error(problem) }
            exit(2)
        }
        if let level = config.logLevel { Log.level = level }
        AppLogOutput.json = config.logJSON
        #if !os(Windows)
        // Idle workers spin briefly before they sleep (Vega's default;
        // VEGA_SPIN_NS sets it, 0 to sleep at once). On cores of its own a
        // server gains from it: 35.7k against 30.3k new connections a second
        // on the bench box. Where clients or another server share the cores,
        // the spin takes their CPU and 0 is better.
        if let io = config.io { setenv("VEGA_DRIVER", io, 1) }
        #endif
        let app = compile()
        let limits = ConnectionLimits(config)
        // A certificate that cannot be served is found here, once, rather
        // than by every shard as it starts.
        if !config.tlsCertificates.isEmpty {
            do {
                _ = try CertificateStore(files: config.tlsCertificates, protocols: Application.alpn(for: config),
                                         ticketKey: nil)
            } catch {
                Log.error("TLS: \(error)")
                exit(2)
            }
        }

        #if os(Linux) || os(macOS)
        var options = ShardOptions(shards: config.shards ?? Application.defaultShards,
                                   workersPerShard: config.threads)
        options.pinThreads = config.pinThreads
        options.shutdownGracePeriod = config.gracefulShutdown + .seconds(5)
        options.listeners = [.tcp(host: config.host, port: config.port, backlog: config.backlog)]
        if let redirect = config.redirectHTTPPort {
            options.listeners.append(.tcp(host: config.host, port: redirect, backlog: config.backlog))
        }
        // The session-ticket key every shard shares (TLS.swift).
        if !config.tlsCertificates.isEmpty { options.sharedRegions = [TicketKey.regionSize] }
        options.name = "garuda-s"
        Runtime.sharded(options) { shard in
            let info = ShardInfo(index: shard.index, count: shard.count, threads: shard.runtime.workerCount)
            let main: @Sendable () throws(IOError) -> TCPListener = { () throws(IOError) -> TCPListener in
                try shard.listener()
            }
            var redirect: (@Sendable () throws(IOError) -> TCPListener)? = nil
            if config.redirectHTTPPort != nil {
                redirect = { () throws(IOError) -> TCPListener in try shard.listener(1) }
            }
            var ticketKey: [UInt8]? = nil
            if !config.tlsCertificates.isEmpty { ticketKey = TicketKey.shared(in: shard.sharedRegion(0)) }
            let listening = Listening(main: main, redirect: redirect, ticketKey: ticketKey)
            Application.serve(shard.runtime, app: app, shard: info, limits: limits, config: config, listening: listening)
        }
        #else
        let runtime = Runtime(workers: config.threads)
        let info = ShardInfo(index: 0, count: 1, threads: runtime.workerCount)
        let main: @Sendable () throws(IOError) -> TCPListener = { () throws(IOError) -> TCPListener in
            try TCPListener.bind(host: config.host, port: config.port, backlog: config.backlog)
        }
        var redirect: (@Sendable () throws(IOError) -> TCPListener)? = nil
        if let port = config.redirectHTTPPort {
            redirect = { () throws(IOError) -> TCPListener in
                try TCPListener.bind(host: config.host, port: port, backlog: config.backlog)
            }
        }
        let listening = Listening(main: main, redirect: redirect,
                                  ticketKey: config.tlsCertificates.isEmpty ? nil : TicketKey.ownKey())
        Application.serve(runtime, app: app, shard: info, limits: limits, config: config, listening: listening)
        exit(0)
        #endif
    }

    /// The protocols offered by ALPN, most wanted first.
    static let alpn = ["h2", "http/1.1"]

    /// What `config` offers: no "h2" without HTTP/2, nothing else with
    /// --http2-only.
    static func alpn(for config: ServerConfig) -> [String] {
        if config.http2Only { return ["h2"] }
        return config.http2Enabled ? alpn : ["http/1.1"]
    }

    /// Where a shard listens, and its session-ticket key under TLS.
    struct Listening: Sendable {
        let main: @Sendable () throws(IOError) -> TCPListener
        /// The --redirect-http port's.
        let redirect: (@Sendable () throws(IOError) -> TCPListener)?
        let ticketKey: [UInt8]?
    }

    /// Shards when `--shards` is not given: Vega's choice from the machine's
    /// cache domains on Linux, and none elsewhere -- a development machine
    /// wants one process to attach a debugger to.
    static var defaultShards: Int? {
        #if os(Linux)
        nil
        #else
        0
        #endif
    }

    /// One shard's serving: build its state and run its start hooks, accept
    /// until SIGTERM or SIGINT, let the requests in progress finish, then run
    /// its stop hooks and shut its state down.
    static func serve(_ runtime: Runtime, app: CompiledApplication, shard: ShardInfo, limits: ConnectionLimits,
                      config: ServerConfig, listening: Listening) {
        app.costs.configure(config, threads: runtime.workerCount)
        var certificates: CertificateStore? = nil
        if !config.tlsCertificates.isEmpty {
            do {
                certificates = try CertificateStore(files: config.tlsCertificates,
                                                    protocols: Application.alpn(for: config),
                                                    ticketKey: listening.ticketKey)
            } catch {
                Log.error("TLS: \(error)")
                exit(2)
            }
        }
        let tls = certificates
        let handshakeTimeout = config.tlsHandshakeTimeout
        // The pool HTTP/2 streams run in, and the connections shutdown
        // sends GOAWAY to (HTTP2.swift).
        let http2 = limits.http2.enabled ? HTTP2Service(runtime: runtime) : nil
        do {
            try runtime.block { () async throws(IOError) -> Void in
                do {
                    try await app.startShard(shard)
                } catch {
                    Log.error("shard \(shard.index) cannot start: \(error)")
                    exit(1)
                }
                // Vega sets TCP_NODELAY on every accepted socket. One accept
                // loop per thread: a connection then usually starts on the
                // thread that accepted it, rather than one woken to steal it.
                let acceptors = max(1, config.acceptors ?? runtime.workerCount)
                var servers: [TCPServer] = []
                for _ in 0..<acceptors {
                    servers.append(try TCPServer.serve(try listening.main()) { stream in
                        guard let tls else {
                            return await serveTCP(stream, app: app, limits: limits, http2: http2)
                        }
                        await serveTLSConnection(stream, tls, handshakeTimeout: handshakeTimeout, app: app,
                                                 limits: limits, http2: http2)
                    })
                }
                Log.info("serving \(tls == nil ? "http" : "https") on \(config.host):\(servers[0].port)")
                if let redirect = listening.redirect, let httpsPort = servers.first?.port {
                    let redirector = httpsRedirectApplication(httpsPort: httpsPort).compile()
                    let server = try TCPServer.serve(try redirect()) { stream in
                        await serveHTTP1(stream, app: redirector, limits: limits, peer: socketPeer(stream))
                    }
                    Log.info("redirecting http on \(config.host):\(server.port) to https")
                    servers.append(server)
                }
                if let tls, let interval = config.tlsReloadInterval {
                    runtime.spawn { await watchCertificates(tls, every: interval) }
                }
                let all = servers
                #if !os(Windows)
                let grace = config.gracefulShutdown
                runtime.spawn {
                    let terms = try? Runtime.signals(SIGTERM)
                    let ints = try? Runtime.signals(SIGINT)
                    // Whichever comes first.
                    await withTaskGroup(of: Void.self) { group in
                        for stream in [terms, ints] {
                            guard var stream else { continue }
                            group.addTask { _ = await stream.recv() }
                        }
                        await group.next()
                        group.cancelAll()
                    }
                    // HTTP/2 connections are sent GOAWAY and finish the streams
                    // they have, as HTTP/1 ones finish their request.
                    http2?.shutdown()
                    await withTaskGroup(of: Void.self) { group in
                        for server in all { group.addTask { await server.shutdown(gracePeriod: grace) } }
                    }
                }
                #endif
                for server in all { await server.wait() }
                await app.stopShard(shard)
            }
        } catch {
            Log.error("cannot serve on \(config.host):\(config.port): \(error)")
            exit(1)
        }
    }
}

// MARK: - The command line

extension ServerConfig {
    enum Parsed {
        case run(ServerConfig)
        /// --help, --version, or a mistake already reported.
        case exit(Int32)
    }

    static let usage = """
        garuda -- a Swift web server on Vega

        usage: garuda [options]

          --host HOST          interface to bind (default 127.0.0.1)
          --port PORT          port to bind (default 8000)
          --shards N|auto      shard processes; 0 serves in this process
                               (default: auto on Linux, 0 elsewhere)
          --threads N          worker threads per shard (default: its CPUs)
          --no-pin             do not pin shard threads to their CPUs
          --io uring|epoll     the I/O driver (default: io_uring where the
                               kernel has it)
          --heavy-threshold US a route holding a thread longer than this many
                               microseconds runs in the heavy lane (default 500)
          --no-heavy-lane      let every route use every thread
          --acceptors N        accept loops per shard (default: one a thread)
          --log-level LEVEL    debug, info, warning, error or silent
          --max-body BYTES     largest request body (default 16 MiB)
          --keep-alive SECS    idle keep-alive timeout (default 5)
          --tls-cert PATH      a PEM certificate chain to serve HTTPS with;
                               give one --tls-key for each, in order. With
                               several, SNI picks the one covering the name
          --tls-key PATH       the PEM private key of the --tls-cert before it
          --tls-reload SECS    look at the certificate files every SECS and
                               serve them again when they change
          --redirect-http PORT also listen for plain HTTP on PORT and redirect
                               every request to https
          --forwarded-allow-ips L
                               proxies whose forwarded headers are trusted:
                               addresses, CIDR blocks, unix, or *
          --no-http2           refuse HTTP/2 and answer HTTP/1.1 only
          --http2-only         serve only HTTP/2 (h2c), with no HTTP/1 fallback
          --request-id         give every request an X-Request-ID, echoed on
                               the response and logged; one a
                               --forwarded-allow-ips proxy sent is kept
          --trace-context      record a request's W3C traceparent, its trace
                               and parent span, in the logs
          --access-log         log one line per request
          --access-log-format F
                               text (default) or json; implies --access-log
          --log-format F       text (default) or json, for request.log and
                               AppLog; the access log follows it unless
                               --access-log-format says otherwise
          --version            print the version
          -h, --help           print this


        """

    static let version = "garuda 2.0.0-dev"

    /// The configuration `arguments` (argv, with the program first) describe.
    /// SERVER_HOSTNAME and SERVER_PORT, which the-benchmarker sets, are read
    /// first; the command line wins over them.
    static func parse(_ arguments: [String]) -> Parsed {
        var config = ServerConfig()
        if let host = environment("SERVER_HOSTNAME") { config.host = host }
        if let port = environment("SERVER_PORT").flatMap({ Int($0) }) { config.port = port }

        var args = arguments.dropFirst()
        var accessLogFormatGiven = false
        var certificates: [String] = [], keys: [String] = []
        func fail(_ message: String) -> Parsed {
            Log.error(message)
            return .exit(2)
        }
        while let arg = args.popFirst() {
            func value() -> String? { args.popFirst() }
            switch arg {
            case "-h", "--help":
                print(usage, terminator: "")
                return .exit(0)
            case "--version":
                print(version)
                return .exit(0)
            case "--host":
                guard let v = value() else { return fail("--host needs a value") }
                config.host = v
            case "--port":
                guard let v = value().flatMap({ Int($0) }), (0...65535).contains(v) else {
                    return fail("--port must be between 0 and 65535")
                }
                config.port = v
            case "--shards":
                guard let v = value() else { return fail("--shards needs a count or auto") }
                if v == "auto" {
                    config.shards = nil
                } else if let n = Int(v), n >= 0 {
                    config.shards = n
                } else {
                    return fail("--shards must be a count or auto")
                }
            case "--threads":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--threads must be a positive count")
                }
                config.threads = n
            case "--acceptors":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--acceptors must be a positive count")
                }
                config.acceptors = n
            case "--no-pin":
                config.pinThreads = false
            case "--io":
                guard let v = value(), v == "uring" || v == "epoll" else {
                    return fail("--io must be uring or epoll")
                }
                config.io = v
            case "--heavy-threshold":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--heavy-threshold must be a number of microseconds")
                }
                config.heavyThreshold = .microseconds(n)
            case "--no-heavy-lane":
                config.heavyLane = false
            case "--log-level":
                guard let level = value().flatMap({ LogLevel(name: $0) }) else {
                    return fail("--log-level must be debug, info, warning, error or silent")
                }
                config.logLevel = level
            case "--max-body":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--max-body must be a byte count")
                }
                config.maxBodySize = n
            case "--keep-alive":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--keep-alive must be a number of seconds")
                }
                config.keepAliveTimeout = .seconds(n)
            case "--tls-cert":
                guard let v = value() else { return fail("--tls-cert needs a path") }
                certificates.append(v)
            case "--tls-key":
                guard let v = value() else { return fail("--tls-key needs a path") }
                keys.append(v)
            case "--tls-reload":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--tls-reload must be a number of seconds")
                }
                config.tlsReloadInterval = .seconds(n)
            case "--redirect-http":
                guard let v = value().flatMap({ Int($0) }), (1...65535).contains(v) else {
                    return fail("--redirect-http must be a port between 1 and 65535")
                }
                config.redirectHTTPPort = v
            case "--forwarded-allow-ips":
                guard let v = value() else { return fail("--forwarded-allow-ips needs a list") }
                guard v.withCString({ config.trust.parse($0) }) else {
                    return fail("--forwarded-allow-ips contains an address that is not valid")
                }
            case "--no-http2":
                config.http2Enabled = false
                config.http2Only = false
            case "--http2-only":
                config.http2Only = true
                config.http2Enabled = true
            case "--request-id":
                config.requestID = true
            case "--trace-context":
                config.traceContext = true
            case "--access-log":
                config.accessLog = true
            case "--access-log-format":
                guard let v = value(), v == "text" || v == "json" else {
                    return fail("--access-log-format must be text or json")
                }
                config.accessLog = true
                config.accessLogJSON = v == "json"
                accessLogFormatGiven = true
            case "--log-format":
                guard let v = value(), v == "text" || v == "json" else {
                    return fail("--log-format must be text or json")
                }
                config.logJSON = v == "json"
            default:
                return fail("unknown option \(arg) (garuda --help lists them)")
            }
        }
        if !accessLogFormatGiven { config.accessLogJSON = config.logJSON }
        guard certificates.count == keys.count else {
            return fail("--tls-cert and --tls-key go together, one key for each certificate")
        }
        config.tlsCertificates = zip(certificates, keys).map { TLSCertificateFiles(chain: $0, key: $1) }
        if let redirect = config.redirectHTTPPort {
            guard !config.tlsCertificates.isEmpty else {
                return fail("--redirect-http sends clients to https; it needs --tls-cert")
            }
            guard redirect != config.port else {
                return fail("--redirect-http needs a port of its own, not the TLS port")
            }
        }
        if config.tlsReloadInterval != nil && config.tlsCertificates.isEmpty {
            return fail("--tls-reload has no certificates to watch; it needs --tls-cert")
        }
        return .run(config)
    }
}

/// The address and port of the peer of socket `fd`, or nil.
func peerName(of fd: Int32) -> (String, Int)? {
    #if os(Windows)
    return nil
    #else
    guard fd >= 0 else { return nil }
    var storage = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let rc = withUnsafeMutablePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
    }
    guard rc == 0 else { return nil }
    var text = [CChar](repeating: 0, count: 64)
    switch Int32(storage.ss_family) {
    case AF_INET:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { a in
                var addr = a.pointee.sin_addr
                guard inet_ntop(AF_INET, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                return (String(cString: text), Int(UInt16(bigEndian: a.pointee.sin_port)))
            }
        }
    case AF_INET6:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { a in
                var addr = a.pointee.sin6_addr
                guard inet_ntop(AF_INET6, &addr, &text, socklen_t(text.count)) != nil else { return nil }
                return (String(cString: text), Int(UInt16(bigEndian: a.pointee.sin6_port)))
            }
        }
    case AF_UNIX:
        return ("unix", 0)
    default:
        return nil
    }
    #endif
}

func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}
