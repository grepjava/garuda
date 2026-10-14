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
        #if !os(Windows)
        if let io = config.io { setenv("VEGA_DRIVER", io, 1) }
        // Idle workers sleep at once rather than spin first. A spin saves a
        // wake-up only when work arrives within it, and on a machine whose
        // cores also run the clients, or another server, it takes their CPU:
        // 117k against 143k requests a second on the bench box, 26 against
        // 40 us of CPU each. VEGA_SPIN_NS still sets it.
        setenv("VEGA_SPIN_NS", "0", 0)
        #endif
        let app = compile()
        let limits = ConnectionLimits(config)

        #if os(Linux) || os(macOS)
        var options = ShardOptions(shards: config.shards ?? Application.defaultShards,
                                   workersPerShard: config.threads)
        options.pinThreads = config.pinThreads
        options.shutdownGracePeriod = config.gracefulShutdown + .seconds(5)
        options.listeners = [.tcp(host: config.host, port: config.port, backlog: config.backlog)]
        options.name = "garuda-s"
        Runtime.sharded(options) { shard in
            Application.serve(shard.runtime, app: app, limits: limits, config: config) {
                () throws(IOError) -> TCPListener in try shard.listener()
            }
        }
        #else
        let runtime = Runtime(workers: config.threads)
        Application.serve(runtime, app: app, limits: limits, config: config) {
            () throws(IOError) -> TCPListener in
            try TCPListener.bind(host: config.host, port: config.port, backlog: config.backlog)
        }
        exit(0)
        #endif
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

    /// One shard's serving: accept until SIGTERM or SIGINT, then let the
    /// requests in progress finish.
    static func serve(_ runtime: Runtime, app: CompiledApplication, limits: ConnectionLimits,
                      config: ServerConfig, listener: @escaping @Sendable () throws(IOError) -> TCPListener) {
        app.costs.configure(config, threads: runtime.workerCount)
        do {
            try runtime.block { () async throws(IOError) -> Void in
                var options = TCPServer.Configuration()
                options.connectionOptions[.noDelay] = 1
                let server = try TCPServer.serve(try listener(), configuration: options) { stream in
                    let peer = (try? stream.peerAddress).map {
                        SocketPeer(address: $0.host, port: $0.port ?? 0)
                    } ?? .none
                    await serveHTTP1(stream, app: app, limits: limits, peer: peer)
                }
                Log.info("serving on \(config.host):\(server.port)")
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
                    await server.shutdown(gracePeriod: grace)
                }
                #endif
                await server.wait()
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
          --log-level LEVEL    debug, info, warning, error or silent
          --max-body BYTES     largest request body (default 16 MiB)
          --keep-alive SECS    idle keep-alive timeout (default 5)
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
            default:
                return fail("unknown option \(arg) (garuda --help lists them)")
            }
        }
        return .run(config)
    }
}

func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}
