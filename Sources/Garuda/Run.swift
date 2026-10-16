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
        for flag in config.ignoredFlags { Log.warning("\(flag) has no effect in Garuda 2") }
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
                try CertificateStore(files: config.tlsCertificates, protocols: Application.alpn(for: config),
                                     ticketKey: nil, ciphers: config.tlsCiphers).logNames()
            } catch {
                Log.error("TLS: \(error)")
                exit(2)
            }
        }

        #if os(Linux) || os(macOS)
        var options = ShardOptions(shards: config.shards ?? Application.defaultShards,
                                   workersPerShard: config.threads)
        options.pinThreads = config.pinThreads
        options.idleSpin = Application.idleSpin
        if let threads = config.blockingThreads { options.blockingThreads = threads }
        options.blockingQueue = config.blockingQueue
        switch config.balance {
        case .reusePort?: options.listenerMode = .perShard
        case .shared?: options.listenerMode = .shared
        case nil: break
        }
        options.shutdownGracePeriod = config.drainDelay + config.gracefulShutdown + .seconds(5)
        options.listeners = [config.unixPath.map { .unix(path: $0, backlog: config.backlog) }
                             ?? .tcp(host: config.host, port: config.port, backlog: config.backlog)]
        if let path = config.unixPath { UnixSocketRemoval.atExit(path) }
        if let redirect = config.redirectHTTPPort {
            options.listeners.append(.tcp(host: config.host, port: redirect, backlog: config.backlog))
        }
        if let port = config.metricsPort {
            options.listeners.append(.tcp(host: config.metricsHost ?? config.host, port: port, backlog: 128))
        }
        // The session-ticket key, the rate-limit table and the metrics
        // every shard shares (SharedMemory.swift).
        let layout = SharedLayout(config)
        options.sharedRegions = layout.sizes
        options.name = "garuda-s"
        let reload = ReloadLog()
        options.onEvent = { event in reload.saw(event) }
        if config.reload { ReloadWatcher.install(config, into: &options) }
        Runtime.sharded(options) { shard in
            let info = ShardInfo(index: shard.index, count: shard.count, threads: shard.runtime.workerCount)
            MemoryStores.warnIfSharded(info)
            let main: @Sendable () throws(IOError) -> TCPListener = { () throws(IOError) -> TCPListener in
                try shard.listener()
            }
            var redirect: (@Sendable () throws(IOError) -> TCPListener)? = nil
            if config.redirectHTTPPort != nil {
                redirect = { () throws(IOError) -> TCPListener in try shard.listener(1) }
            }
            var metrics: (@Sendable () throws(IOError) -> TCPListener)? = nil
            if config.metricsPort != nil {
                let index = config.redirectHTTPPort != nil ? 2 : 1
                metrics = { () throws(IOError) -> TCPListener in try shard.listener(index) }
            }
            let shared = ServerShared(layout, config: config, shard: shard.index) { shard.sharedRegion($0) }
            shared.shardStarted(of: shard.count)
            let listening = Listening(main: main, redirect: redirect, metrics: metrics, shared: shared)
            Application.serve(shard.runtime, app: app, shard: info, limits: limits, config: config, listening: listening)
        }
        #else
        // One process, as Runtime.sharded and the memory shards share are
        // POSIX only; and Vega's one I/O driver here, AFD polling.
        if let shards = config.shards, shards > 0 {
            Log.error("--shards \(shards): shards are not supported on this platform; --shards 0 serves in this process")
            exit(2)
        }
        if config.balance != nil { Log.warning("--balance is ignored: there are no shards on this platform") }
        if config.io != nil { Log.warning("--io is ignored: there is one I/O driver on this platform") }
        if config.acceptors.map({ $0 > 1 }) == true {
            Log.warning("--acceptors is ignored: one accept loop on this platform")
        }
        if config.reload {
            Log.warning("--reload is ignored: restarting on a rebuilt executable needs the shard supervisor")
        }
        let runtime = Runtime(workers: config.threads, blockingThreads: config.blockingThreads ?? 512,
                              blockingQueue: config.blockingQueue, idleSpin: Application.idleSpin)
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
        var metrics: (@Sendable () throws(IOError) -> TCPListener)? = nil
        if let port = config.metricsPort {
            metrics = { () throws(IOError) -> TCPListener in
                try TCPListener.bind(host: config.metricsHost ?? config.host, port: port, backlog: 128)
            }
        }
        let listening = Listening(main: main, redirect: redirect, metrics: metrics,
                                  shared: ServerShared(SharedLayout(config), config: config))
        Application.serve(runtime, app: app, shard: info, limits: limits, config: config, listening: listening)
        exit(0)
        #endif
    }

    /// The first of `streams` to deliver a signal, or nil after `delay`.
    @discardableResult
    static func firstSignal(_ streams: [SignalStream], orAfter delay: Duration? = nil) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            for stream in streams {
                group.addTask {
                    var stream = stream
                    return await stream.recv() ? stream.signal : nil
                }
            }
            if let delay {
                group.addTask {
                    try? await Runtime.sleep(for: delay)
                    return nil
                }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The protocols offered by ALPN, most wanted first.
    static let alpn = ["h2", "http/1.1"]

    /// How long an idle worker spins before it sleeps: not at all, as Garuda
    /// 1's workers slept in epoll at once. On the bench box a spin bought
    /// no throughput on any workload with the load on cores of its own, and
    /// cost CPU on every one: 121 us a request against 91 on churn, 94
    /// against 86 on stream. Where the load shares the cores it cost the
    /// load's own CPU: vs-axum's ramp, 4 workers unpinned, did 146-150k
    /// with the spin and 192-196k without. `VEGA_SPIN_NS` still sets one.
    static let idleSpin: Duration = .zero

    /// What `config` offers: no "h2" without HTTP/2, nothing else with
    /// --http2-only.
    static func alpn(for config: ServerConfig) -> [String] {
        if config.http2Only { return ["h2"] }
        return config.http2Enabled ? alpn : ["http/1.1"]
    }

    /// Where a shard listens, and what it shares with the others.
    struct Listening: Sendable {
        let main: @Sendable () throws(IOError) -> TCPListener
        /// The --redirect-http port's.
        let redirect: (@Sendable () throws(IOError) -> TCPListener)?
        /// The --metrics-port's.
        let metrics: (@Sendable () throws(IOError) -> TCPListener)?
        let shared: ServerShared
        var ticketKey: [UInt8]? { shared.ticketKey }
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
        app.runtime = runtime
        app.rateLimiter = listening.shared.rateLimiter
        app.metrics = listening.shared.metrics
        app.cache = listening.shared.cache
        TopicBus.install(listening.shared.bus)
        if config.cacheSizeMiB > 0 && app.cache == nil {
            Log.error("--cache-size \(config.cacheSizeMiB) is too little for a response of --cache-max-object")
            exit(2)
        }
        app.connections.metrics = listening.shared.metrics
        app.healthPath = config.healthCheckPath.map { Array($0.utf8) }
        app.rootPath = config.rootPath.isEmpty ? nil : Array(config.rootPath.utf8)
        app.screened = app.rateLimiter != nil || app.healthPath != nil
        var certificates: CertificateStore? = nil
        if !config.tlsCertificates.isEmpty {
            do {
                certificates = try CertificateStore(files: config.tlsCertificates,
                                                    protocols: Application.alpn(for: config),
                                                    ticketKey: listening.ticketKey, ciphers: config.tlsCiphers)
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
        // HTTP/3's endpoints and the pool their requests run in (HTTP3.swift).
        var http3: HTTP3Service? = nil
        if let tls, limits.http3.enabled {
            http3 = HTTP3Service(runtime: runtime, app: app, limits: limits,
                                 certificates: { tls.certificateKeys() })
        }
        let quic = http3
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
                #if os(Windows)
                // No SO_REUSEPORT, and one process: a socket bound once,
                // and one accept loop on it.
                let acceptors = 1
                #else
                let acceptors = max(1, config.acceptors ?? runtime.workerCount)
                #endif
                let accepting = config.serverConfiguration(acceptors: acceptors)
                var servers: [TCPServer] = []
                for _ in 0..<acceptors {
                    let listener = try listening.main()
                    if limits.requestStart && tls == nil {
                        // The kernel stamps what arrives, and the connections
                        // accepted inherit it, so the read that begins a
                        // request can say when it arrived (HTTP1.swift's
                        // readArrival). Over TLS the reads are of decrypted
                        // bytes, which carry no stamp.
                        try? listener.setOption(.receiveTimestamps, to: true)
                    }
                    servers.append(try TCPServer.serve(listener, configuration: accepting) { stream in
                        guard let tls else {
                            return await serveTCP(stream, app: app, limits: limits, http2: http2)
                        }
                        await serveTLSConnection(stream, tls, handshakeTimeout: handshakeTimeout, app: app,
                                                 limits: limits, http2: http2)
                    })
                }
                Log.info("serving \(tls == nil ? "http" : "https") on \(config.listeningName(port: servers[0].port))")
                if let quic {
                    // A socket per thread, as there is an accept loop per
                    // thread: the kernel spreads clients across them.
                    let port = config.quicPort ?? servers[0].port
                    do {
                        try quic.start(host: config.host, port: port, count: runtime.workerCount)
                    } catch {
                        Log.error("cannot serve HTTP/3 on udp \(config.host):\(port): \(error)")
                        exit(1)
                    }
                    Log.info("serving h3 on udp \(config.host):\(port)")
                }
                if let redirect = listening.redirect, let httpsPort = servers.first?.port {
                    let redirector = httpsRedirectApplication(httpsPort: httpsPort,
                                                              acmeWebroot: config.acmeWebroot).compile()
                    let server = try TCPServer.serve(try redirect()) { stream in
                        let peer = socketPeer(stream)
                        await serveHTTP1(stream, app: redirector, limits: limits, peer: peer)
                    }
                    Log.info("redirecting http on \(config.host):\(server.port) to https")
                    servers.append(server)
                }
                if let metrics = listening.metrics, let page = listening.shared.metrics {
                    // A server of its own, never through the application.
                    // Shards, which are Garuda 1's worker processes.
                    let scraped = metricsApplication(page, workers: shard.count,
                                                     cache: config.cacheSizeMiB > 0).compile()
                    let server = try TCPServer.serve(try metrics()) { stream in
                        let peer = socketPeer(stream)
                        await serveHTTP1(stream, app: scraped, limits: limits, peer: peer)
                    }
                    Log.info("metrics on \(config.metricsHost ?? config.host):\(server.port)/metrics")
                    servers.append(server)
                }
                if let tls, let interval = config.tlsReloadInterval {
                    runtime.spawn { await watchCertificates(tls, every: interval) }
                }
                let all = servers
                let grace = config.gracefulShutdown
                let delay = config.drainDelay
                runtime.spawn {
                    // SIGTERM may put the stop off; SIGINT and SIGQUIT do
                    // not. Under a supervisor, SIGQUIT arrives as SIGINT,
                    // and so does a rolling restart's stop.
                    let terms = try? Runtime.signals(SIGTERM)
                    #if os(Windows)
                    // Vega's console handler: Ctrl-C as SIGINT, Ctrl-Break
                    // as SIGBREAK; closing the console, logging off or
                    // shutting down as SIGTERM.
                    let nows = [SIGINT, SIGBREAK].compactMap { try? Runtime.signals($0) }
                    #else
                    let nows = [SIGINT, SIGQUIT].compactMap { try? Runtime.signals($0) }
                    #endif
                    let first = await firstSignal(terms.map { [$0] + nows } ?? nows)
                    if first == SIGTERM && delay > .zero {
                        app.unready.store(true, ordering: .relaxed)
                        Log.info("failing the health check; draining in \(delay)")
                        // A second SIGTERM -- from the supervisor and from
                        // an init system signalling the process group -- is
                        // not a reason to cut it short.
                        await firstSignal(nows, orAfter: delay)
                    }
                    app.unready.store(true, ordering: .relaxed)
                    // WebSockets are sent 1001. HTTP/2 connections are sent
                    // GOAWAY -- once their WebSockets have closed -- and
                    // finish the streams they have, as HTTP/1 ones finish
                    // their request.
                    app.webSockets.shutdown()
                    http2?.shutdown()
                    quic?.shutdown(grace: grace)
                    await withTaskGroup(of: Void.self) { group in
                        for server in all { group.addTask { await server.shutdown(gracePeriod: grace) } }
                    }
                }
                for server in all { await server.wait() }
                await quic?.wait()
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
          --unix PATH          listen on a unix socket instead, which every
                               shard accepts on; removed at exit
          --backlog N          listen backlog (default 2048)
          --shards N|auto      shard processes; 0 serves in this process
                               (default: auto on Linux, 0 elsewhere)
          --balance MODE       how shards share the port: reuseport (a socket
                               each, hashed by the kernel), shared (one socket,
                               taken by whichever is waiting), or auto
                               (default auto)
          --threads N          worker threads per shard (default: its CPUs)
          --no-pin             do not pin shard threads to their CPUs
          --io uring|epoll     the I/O driver (default: io_uring where the
                               kernel has it)
          --heavy-threshold US a route holding a thread longer than this many
                               microseconds runs in the heavy lane (default 500)
          --no-heavy-lane      let every route use every thread
          --blocking-threads N threads per shard app.offload routes run on
                               (default: Vega's, 512)
          --blocking-queue N   blocking work per shard that may wait for a
                               thread, past which it is refused with 503
                               (default: no limit)
          --acceptors N        accept loops per shard (default: one a thread)
          --log-level LEVEL    debug, info, warning, error or silent
          --max-body BYTES     largest request body (default 16 MiB)
          --max-header-size BYTES
                               largest request head (default 32 KiB)
          --max-connections N  connections a shard has open at once; more
                               wait in the backlog (default: no limit)
          --keep-alive MS      idle keep-alive timeout (default 5000)
          --request-timeout MS how long a request may stall mid-message,
                               head or body, or its answer go unread
                               (default 30000)
          --sse-keep-alive SECS
                               a comment to an event stream quiet this long
                               (default 15; 0 for none)
          --rate-limit N/s|m|h requests each client may make, counted across
                               every shard; 429 past it
          --rate-limit-burst N requests a client may make at once (default:
                               the rate's count)
          --health-check-path P
                               answer GET P with 200 before routing and
                               before --rate-limit
          --metrics-port PORT  serve Prometheus metrics at /metrics on PORT
          --metrics-host HOST  the interface for it (default: --host's)
          --cache-size MIB     keep responses the application marks fresh in
                               MIB of memory every shard shares
          --cache-max-object KIB
                               the largest body kept (default 1024)
          --cache-ttl-max SECS the longest a response is kept (default 300)
          --broadcast-size MIB the ring a Topic's messages cross shards in, and
                               how far back a reconnecting client can catch up
                               (default 4; 0 turns topics off)
          --broadcast-queue N  messages a subscriber may fall behind by before
                               the rest are replaced by one .missed (default 1024)
          --compress           compress text responses for clients that accept
                               it (see BREACH before turning this on)
          --compress-static    serve file.br, file.zst or file.gz beside a
                               --static-dir file to clients that accept them
          --compress-min-size BYTES
                               leave bodies smaller than this alone (default 1024)
          --static-dir PREFIX=DIR
                               answer GET and HEAD under PREFIX from the files
                               in DIR; a path naming no file falls through
          --static-index       answer a --static-dir directory with its
                               index.html
          --static-listing     and list one that has no index
          --static-listing-limit N
                               entries a listing shows (default 10000; 0 for all)
          --spa-fallback PREFIX=FILE
                               answer browser navigations under PREFIX that
                               nothing else answers with FILE
          --tls-cert PATH      a PEM certificate chain to serve HTTPS with;
                               give one --tls-key for each, in order. With
                               several, SNI picks the one covering the name
          --tls-key PATH       the PEM private key of the --tls-cert before it
          --tls-ciphers LIST   the TLS 1.2 cipher suites, as an OpenSSL cipher
                               list (TLS 1.3's are fixed)
          --tls-reload SECS    look at the certificate files every SECS and
                               serve them again when they change
          --redirect-http PORT also listen for plain HTTP on PORT and redirect
                               every request to https
          --acme-webroot DIR   on the --redirect-http port, answer
                               /.well-known/acme-challenge/ from DIR, the
                               webroot an ACME client such as certbot writes
                               its HTTP-01 challenges into
          --forwarded-allow-ips L
                               proxies whose forwarded headers are trusted:
                               addresses, CIDR blocks, unix, or *
          --root-path PATH     a mount prefix a proxy leaves on the path, taken
                               off before routing
          --scheme http|https  the scheme a request without TLS arrived by,
                               behind a proxy that terminates TLS and does not
                               say so (default http)
          --no-http2           refuse HTTP/2 and answer HTTP/1.1 only
          --graceful-timeout MS
                               how long requests, streams and WebSockets in
                               progress have to finish at shutdown (10000)
          --drain-delay MS     on SIGTERM, serve this long with the health
                               check failing before draining (0); SIGINT and
                               SIGQUIT do not wait
          --no-websockets      refuse WebSocket upgrades with 501
          --ws-max-message BYTES
                               the largest WebSocket message taken (16 MiB)
          --ws-ping-interval MS
                               ping a quiet WebSocket this often; 0 for never
                               (20000)
          --ws-ping-timeout MS how long a ping, or a close, may go unanswered
                               (20000)
          --ws-max-queue N     messages held for a handler not reading (32)
          --ws-max-queue-bytes BYTES
                               and bytes (4 MiB)
          --ws-compress        permessage-deflate with clients that offer it
          --websocket-protocols LIST
                               which of http1, http2 and http3 carry
                               WebSockets (all three)
          --http2-only         serve only HTTP/2 (h2c), with no HTTP/1 fallback
          --http3              also serve HTTP/3 over QUIC (needs --tls-cert),
                               advertised to TCP clients by Alt-Svc
          --quic-port PORT     the UDP port for HTTP/3 (default: --port's)
          --hsts SECS          send Strict-Transport-Security: max-age=SECS
                               on every answer over TLS
          --reload             restart on the executable when it is rebuilt,
                               and replace the shards when a --tls-cert or
                               --tls-key file changes; for development
          --reload-interval MS how often --reload looks, where the kernel
                               sends no notification (default 500)
          --request-start-header
                               give handlers request.requestStart, when the
                               request arrived, for APM agents that report
                               queue time
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
          --ktls, --no-ktls, --sched-slice US, --slow-handler-ms MS
                               Garuda 1's, accepted so its command lines
                               start; they have no effect here
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
            case "--unix":
                guard let v = value(), !v.isEmpty else { return fail("--unix needs a path") }
                config.unixPath = v
            case "--backlog":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--backlog must be a positive count")
                }
                config.backlog = n
            case "--max-connections":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--max-connections must be a positive count")
                }
                config.maxConnections = n
            case "--max-header-size":
                guard let n = value().flatMap({ Int($0) }), n >= 1024 else {
                    return fail("--max-header-size must be a byte count of at least 1024")
                }
                config.maxHeadSize = n
            case "--request-timeout":
                // Garuda 1's: one bound on a client that stops part-way
                // through a request, head or body, or stops reading the
                // answer.
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--request-timeout must be milliseconds")
                }
                config.requestHeadTimeout = .milliseconds(n)
                config.bodyTimeout = .milliseconds(n)
                config.writeTimeout = .milliseconds(n)
            case "--request-start-header":
                config.requestStartHeader = true
            case "--blocking-threads":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--blocking-threads must be a positive count")
                }
                config.blockingThreads = n
            case "--blocking-queue":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--blocking-queue must be a count")
                }
                config.blockingQueue = n
            case "--root-path":
                guard var v = value(), v.isEmpty || v.hasPrefix("/") else {
                    return fail("--root-path must start with /")
                }
                // "/app/" and "/app" are one mount.
                while v.hasSuffix("/") { v.removeLast() }
                config.rootPath = v
            case "--scheme":
                switch value() {
                case "http": config.assumeHTTPS = false
                case "https": config.assumeHTTPS = true
                default: return fail("--scheme must be http or https")
                }
            case "--tls-ciphers":
                guard let v = value(), !v.isEmpty else { return fail("--tls-ciphers needs an OpenSSL cipher list") }
                config.tlsCiphers = v
            case "--reload":
                config.reload = true
            case "--reload-interval":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--reload-interval must be milliseconds")
                }
                // Garuda 1's floor: looking more often only costs.
                config.reloadInterval = .milliseconds(max(50, n))
            case "--ktls":
                // Garuda 1 could have the kernel encrypt; Vega's TLS is in
                // the process, always.
                config.ignoredFlags.append("--ktls")
            case "--no-ktls":
                // Encrypting in the process is what it asks for, and all
                // there is here.
                break
            case "--sched-slice":
                guard let n = value().flatMap({ Int($0) }), n == 0 || (100...100_000).contains(n) else {
                    return fail("--sched-slice must be 0, or 100 to 100000 microseconds")
                }
                // Garuda 1 asked the kernel for a time slice per worker
                // process; a work-stealing runtime has no such request.
                config.ignoredFlags.append("--sched-slice")
            case "--slow-handler-ms":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--slow-handler-ms must be 0 or more")
                }
                // Garuda 1 warned of a handler holding its worker. Here a
                // route that holds a thread is moved to the heavy lane
                // instead (--heavy-threshold), which is not a warning.
                config.ignoredFlags.append("--slow-handler-ms")
            case "--shards":
                guard let v = value() else { return fail("--shards needs a count or auto") }
                if v == "auto" {
                    config.shards = nil
                } else if let n = Int(v), n >= 0 {
                    config.shards = n
                } else {
                    return fail("--shards must be a count or auto")
                }
            case "--balance":
                switch value() {
                case "reuseport": config.balance = .reusePort
                case "accept", "shared": config.balance = .shared
                case "adaptive", "auto": config.balance = nil
                default: return fail("--balance must be reuseport, shared or auto")
                }
            case "--workers":
                // Garuda 1's name for its processes, which are shards here.
                // Its processes were single-threaded, so N of them are N
                // shards of one thread each unless --threads says otherwise;
                // N shards of a CPU share each would oversubscribe the CPUs.
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--workers must be a count")
                }
                config.shards = n
                if n > 0 && config.threads == nil { config.threads = 1 }
            case "--static-dir":
                guard let v = value(), let eq = v.firstIndex(of: "="), eq != v.startIndex,
                      v.index(after: eq) != v.endIndex else {
                    return fail("--static-dir takes PREFIX=DIRECTORY, as in /static=/var/www/static")
                }
                let prefix = String(v[..<eq])
                guard prefix.hasPrefix("/") else { return fail("--static-dir prefix must start with /") }
                config.staticDirectories.append((prefix, String(v[v.index(after: eq)...])))
            case "--spa-fallback":
                guard let v = value(), let eq = v.firstIndex(of: "="), eq != v.startIndex,
                      v.hasPrefix("/"), v.index(after: eq) != v.endIndex else {
                    return fail("--spa-fallback takes PREFIX=FILE, as in /=/srv/app/index.html")
                }
                let path = String(v[v.index(after: eq)...])
                guard isReadable(path) else { return fail("--spa-fallback: cannot read \(path)") }
                let slash = path.lastIndex(of: "/")
                let directory = slash.map { $0 == path.startIndex ? "/" : String(path[..<$0]) } ?? "."
                let file = slash.map { String(path[$0...]) } ?? "/" + path
                config.spaFallbacks.append((String(v[..<eq]), directory, file))
            case "--rate-limit":
                guard let v = value(), let slash = v.firstIndex(of: "/"), let count = Int(v[..<slash]),
                      count > 0, count <= 100_000_000 else {
                    return fail("--rate-limit takes requests per second, minute or hour, as in 100/s or 600/m")
                }
                let period: UInt64
                switch v[v.index(after: slash)...] {
                case "s": period = 1000
                case "m": period = 60_000
                case "h": period = 3_600_000
                default: return fail("--rate-limit takes requests per second, minute or hour, as in 100/s or 600/m")
                }
                guard period * 1000 / UInt64(count) > 0 else {
                    return fail("--rate-limit is more than a request a microsecond")
                }
                config.rateLimitCount = count
                config.rateLimitPeriodMs = period
            case "--rate-limit-burst":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--rate-limit-burst must be a positive count")
                }
                config.rateLimitBurst = n
            case "--health-check-path":
                guard let v = value(), v.hasPrefix("/") else {
                    return fail("--health-check-path must start with /")
                }
                config.healthCheckPath = v
            case "--metrics-port":
                guard let v = value().flatMap({ Int($0) }), (1...65535).contains(v) else {
                    return fail("--metrics-port must be between 1 and 65535")
                }
                config.metricsPort = v
            case "--metrics-host":
                guard let v = value() else { return fail("--metrics-host needs a value") }
                config.metricsHost = v
            case "--cache-size":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--cache-size must be a number of mebibytes")
                }
                config.cacheSizeMiB = n
            case "--cache-max-object":
                guard let n = value().flatMap({ Int($0) }), n > 0, n <= 64 * 1024 else {
                    return fail("--cache-max-object must be a number of kibibytes, at most 65536")
                }
                config.cacheMaxObject = n * 1024
            case "--broadcast-size":
                guard let n = value().flatMap({ Int($0) }), n >= 0, n <= 1 << 20 else {
                    return fail("--broadcast-size must be a number of MiB")
                }
                config.broadcastSizeMiB = n
            case "--broadcast-queue":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--broadcast-queue must be a count above 0")
                }
                config.broadcastQueue = n
            case "--cache-ttl-max":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--cache-ttl-max must be a number of seconds")
                }
                config.cacheTTLMaxSeconds = n
            case "--compress":
                config.compress = true
            case "--compress-static":
                config.compressStatic = true
            case "--compress-min-size":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--compress-min-size must be a byte count")
                }
                config.compressMinimumLength = n
            case "--static-index":
                config.staticIndex = true
            case "--static-listing":
                config.staticListing = true
                config.staticIndex = true
            case "--static-listing-limit":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--static-listing-limit must be a count")
                }
                config.staticListingLimit = n
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
                    return fail("--keep-alive must be milliseconds")
                }
                config.keepAliveTimeout = .milliseconds(n)
            case "--sse-keep-alive":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--sse-keep-alive must be a number of seconds")
                }
                config.eventKeepAlive = .seconds(n)
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
            case "--acme-webroot":
                guard let v = value() else { return fail("--acme-webroot needs a directory") }
                config.acmeWebroot = v
            case "--forwarded-allow-ips":
                guard let v = value() else { return fail("--forwarded-allow-ips needs a list") }
                guard v.withCString({ config.trust.parse($0) }) else {
                    return fail("--forwarded-allow-ips contains an address that is not valid")
                }
            case "--drain-delay":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--drain-delay must be milliseconds")
                }
                config.drainDelay = .milliseconds(n)
            case "--graceful-timeout":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--graceful-timeout must be milliseconds")
                }
                config.gracefulShutdown = .milliseconds(n)
            case "--no-websockets":
                config.websocketsEnabled = false
            case "--ws-max-message":
                guard let n = value().flatMap({ Int($0) }), n >= 125 else {
                    return fail("--ws-max-message must be a byte count of at least 125")
                }
                config.maxWebsocketMessageSize = n
            case "--ws-ping-interval":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--ws-ping-interval must be milliseconds, or 0 for none")
                }
                config.websocketPingInterval = .milliseconds(n)
            case "--ws-ping-timeout":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--ws-ping-timeout must be milliseconds")
                }
                config.websocketPingTimeout = .milliseconds(n)
            case "--ws-max-queue":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--ws-max-queue must be a count above 0")
                }
                config.maxWebsocketQueue = n
            case "--ws-max-queue-bytes":
                guard let n = value().flatMap({ Int($0) }), n > 0 else {
                    return fail("--ws-max-queue-bytes must be a byte count")
                }
                config.maxWebsocketQueueBytes = n
            case "--ws-compress":
                config.websocketCompress = true
            case "--websocket-protocols":
                guard let list = value().flatMap({ WebSocketProtocols(parsing: $0) }) else {
                    return fail("--websocket-protocols takes a list of http1, http2 and http3")
                }
                config.websocketProtocols = list
            case "--no-http2":
                config.http2Enabled = false
                config.http2Only = false
            case "--http2-only":
                config.http2Only = true
                config.http2Enabled = true
            case "--http3":
                config.http3Enabled = true
            case "--quic-port":
                guard let v = value().flatMap({ Int($0) }), (1...65535).contains(v) else {
                    return fail("--quic-port must be between 1 and 65535")
                }
                config.quicPort = v
            case "--hsts":
                guard let n = value().flatMap({ Int($0) }), n >= 0 else {
                    return fail("--hsts must be a number of seconds")
                }
                config.hstsMaxAge = n
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
        if config.acmeWebroot != nil && config.redirectHTTPPort == nil {
            return fail("--acme-webroot answers challenges on the --redirect-http port; it needs --redirect-http")
        }
        if config.tlsReloadInterval != nil && config.tlsCertificates.isEmpty {
            return fail("--tls-reload has no certificates to watch; it needs --tls-cert")
        }
        // QUIC has no cleartext form.
        if config.http3Enabled && config.tlsCertificates.isEmpty {
            return fail("--http3 needs --tls-cert and --tls-key")
        }
        if config.quicPort != nil && !config.http3Enabled {
            return fail("--quic-port is the port of HTTP/3; it needs --http3")
        }
        if config.hstsMaxAge != nil && config.tlsCertificates.isEmpty {
            return fail("--hsts is only ever sent over TLS; it needs --tls-cert")
        }
        if config.tlsCiphers != nil && config.tlsCertificates.isEmpty {
            return fail("--tls-ciphers chooses among TLS's ciphers; it needs --tls-cert")
        }
        if config.unixPath != nil {
            #if os(Windows)
            return fail("--unix is not available on Windows")
            #else
            if config.http3Enabled { return fail("--http3 cannot be served over a unix socket") }
            if config.redirectHTTPPort != nil {
                return fail("--redirect-http has no https port to send clients to on a unix socket")
            }
            #endif
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

/// Whether the process can read the file at `path`.
func isReadable(_ path: String) -> Bool {
    #if os(Windows)
    return _access(path, 4) == 0
    #else
    return access(path, R_OK) == 0
    #endif
}

#if os(Linux) || os(macOS)
/// The supervisor's log of a rolling restart (SIGHUP): when it begins, and
/// when every shard running then has started again.
final class ReloadLog: @unchecked Sendable {
    // The supervisor is one thread, and calls `saw` from it alone.
    private var running: Set<Int> = []
    private var waiting: Set<Int>?

    func saw(_ event: ShardEvent) {
        switch event {
        case .started(let shard, _):
            running.insert(shard)
            guard var left = waiting else { return }
            left.remove(shard)
            waiting = left.isEmpty ? nil : left
            if left.isEmpty { Log.info("workers reloaded") }
        case .exited(let shard, _, _, _):
            running.remove(shard)
        case .reloading:
            Log.info("reloading workers")
            waiting = running.isEmpty ? nil : running
        default:
            break
        }
    }
}
#endif
