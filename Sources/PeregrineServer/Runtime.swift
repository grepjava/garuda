//===----------------------------------------------------------------------===//
// Process model and worker start-up.
//
// One process per worker, each with its own interpreter and its own poller.
//
// How the listening socket is shared depends on the address family, because
// the two families have opposite constraints:
//
//   * TCP: every worker opens its own socket with SO_REUSEPORT, so each gets an
//     independent accept queue in the kernel. There is no shared accept lock,
//     no thundering herd, and the kernel spreads connections by hashing the
//     four-tuple.
//   * Unix: a path can only be bound once. The supervisor therefore creates the
//     listener and the workers inherit the descriptor across fork. Letting each
//     worker bind for itself would have every worker unlink and replace the
//     socket the previous one had just published, leaving only the last worker
//     reachable.
//
// Threads are not used for request handling in ASGI mode: with an event loop
// and a GIL there is nothing for a second thread to do. WSGI is different --
// see WSGIPool -- because a synchronous application blocks on its own I/O.
//
// `--free-threaded` changes that premise rather than that conclusion. On a
// CPython built without the GIL (PEP 703) the workers become threads of one
// process instead of processes, each still owning its own poller, connection
// slab and event loop -- so nothing above the transport learns that it has
// company. See FreeThreaded.swift.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrineQUIC
import PeregrinePython
import PeregrineWSGI

public enum Peregrine {

    /// Boots the server. Returns a process exit code.
    public static func run(config: ServerConfig) -> Int32 {
        Log.level = config.logLevel
        Log.pid = Int(pg_getpid())
        pg_ignore_sigpipe()
        let limit = pg_raise_nofile_limit()
        if limit > 0 && limit < Int(config.maxConnections) + 32 {
            Log.warn { line in
                line.str("file descriptor limit ")
                line.int(Int(limit))
                line.str(" is below max-connections; lower --max-connections or raise ulimit -n")
            }
        }

        // Certificates are checked once, here, rather than discovered to be
        // unreadable inside each worker after the sockets are already open.
        if config.tlsEnabled {
            if pg_tls_available() == 0 {
                Log.error("this build has no TLS support; rebuild against OpenSSL")
                return 1
            }
            guard makeTLSContext(config) != nil else { return 1 }
        }

        let workerCount = config.resolvedWorkers

        // Before any fork: children inherit the mapping, and a page mapped
        // after one would be private to whoever mapped it.
        if config.metricsPort != 0 {
            if pg_metrics_init(Int32(max(1, workerCount))) != 0 {
                Log.error("cannot map the shared metrics page")
                return 1
            }
        }

        // Workers as threads. --reload still wants a process to restart into,
        // so the two compose: the supervisor forks one child and that child
        // runs every worker as a thread of itself.
        if config.freeThreaded && !config.reload {
            return runFreeThreaded(config, workers: workerCount, inherited: -1) ? 0 : 1
        }

        // --reload needs a supervisor to restart into, even with one worker.
        if workerCount <= 1 && !config.reload {
            guard let fd = openListener(config, reusePort: false, unlinkStale: true) else {
                return 1
            }
            let ok = runWorker(config, listenFD: fd)
            removeUnixPath(config)
            return ok ? 0 : 1
        }
        // Under --free-threaded the supervisor has exactly one child to watch,
        // because the child holds all the workers itself.
        return runSupervisor(config, workers: config.freeThreaded ? 1 : max(1, workerCount))
    }

    /// Builds the TLS context, with the ALPN list the rest of the
    /// configuration implies. ALPN is the only way a browser will speak
    /// HTTP/2, so it follows --no-http2 and --http2-only exactly.
    static func makeTLSContext(_ config: ServerConfig) -> TLSContext? {
        guard let cert = config.tlsCertPath, let key = config.tlsKeyPath else { return nil }
        let alpn: UnsafePointer<CChar>
        if !config.http2Enabled {
            alpn = staticCString("http/1.1")
        } else if config.http2Only {
            alpn = staticCString("h2")
        } else {
            alpn = staticCString("h2,http/1.1")
        }
        return TLSContext.make(certPath: cert, keyPath: key,
                               alpn: alpn, ciphers: config.tlsCiphers)
    }

    /// Builds the QUIC listener. QUIC cannot borrow the SSL_CTX the TCP listener
    /// uses: it needs the primitives underneath, not the record layer on top, so
    /// the certificate is loaded again here. The loaded key is owned by the
    /// `QUICServerConfig` the listener carries, one per worker.
    static func makeQUICListener(_ config: ServerConfig) -> QUICListener? {
        guard let cert = config.tlsCertPath, let key = config.tlsKeyPath else {
            Log.error("--http3 needs --tls-cert and --tls-key: QUIC has no cleartext form")
            return nil
        }
        var error = [CChar](repeating: 0, count: 256)
        let loaded: OpaquePointer? = error.withUnsafeMutableBufferPointer {
            pg_certkey_load(cert, key, $0.baseAddress, 256)
        }
        guard let certKey = loaded else {
            error.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var n = 0
                while n < 256 && base[n] != 0 { n += 1 }
                Log.error { line in
                    line.str("http3: ")
                    base.withMemoryRebound(to: UInt8.self, capacity: n) { line.bytes($0, n) }
                }
            }
            return nil
        }

        let port = config.quicPort != 0 ? config.quicPort : config.port
        let fd = pg_bind_udp(config.host, port, 1, config.ipv6Only ? 1 : 0)
        if fd < 0 {
            let e = pg_errno()
            Log.error { line in
                line.str("cannot bind the QUIC socket: ")
                line.cstr(pg_strerror(e))
            }
            return nil
        }

        var quicConfig = QUICServerConfig(certKey: certKey, alpn: [Array("h3".utf8)])
        quicConfig.maxIdleTimeoutMs = UInt64(config.keepAliveTimeoutMs)
        quicConfig.initialMaxStreamData = UInt64(config.bodyHighWaterMark)
        quicConfig.initialMaxData = UInt64(config.bodyHighWaterMark) * 8
        quicConfig.initialMaxStreamsBidi = UInt64(config.h2MaxConcurrentStreams)
        let listener = QUICListener(fd: fd, config: quicConfig)
        listener.maxConnections = config.maxConnections
        return listener
    }

    // MARK: - Listening socket

    static func openListener(_ config: ServerConfig,
                             reusePort: Bool,
                             unlinkStale: Bool) -> Int32? {
        let fd: Int32
        if let path = config.unixPath {
            fd = pg_listen_unix(path, config.backlog, unlinkStale ? 1 : 0)
        } else {
            fd = pg_listen_tcp(config.host, config.port, config.backlog,
                               reusePort ? 1 : 0, config.ipv6Only ? 1 : 0)
        }
        if fd < 0 {
            let e = pg_errno()
            Log.error { line in
                line.str("cannot listen: ")
                line.cstr(pg_strerror(e))
            }
            return nil
        }
        return fd
    }

    static func removeUnixPath(_ config: ServerConfig) {
        if let path = config.unixPath { _ = pg_unlink(path) }
    }

    // MARK: - Supervisor

    static func runSupervisor(_ config: ServerConfig, workers: Int) -> Int32 {
        // A unix listener is created once here and inherited; a TCP listener is
        // only probed, so that a bad bind is one clear error rather than N
        // identical ones from children.
        var inherited: Int32 = -1
        if config.unixPath != nil {
            guard let fd = openListener(config, reusePort: false, unlinkStale: true) else {
                return 1
            }
            inherited = fd
        } else {
            guard let probe = openListener(config, reusePort: true, unlinkStale: false) else {
                return 1
            }
            _ = pg_close(probe)
        }
        defer { removeUnixPath(config) }

        let signalFD = pg_signal_pipe_init()
        let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: workers)
        defer { pids.deallocate() }
        pids.initialize(repeating: 0, count: workers)

        Log.info { line in
            line.str("peregrine starting with ")
            line.int(workers)
            line.str(" workers")
        }

        for i in 0..<workers {
            pids[i] = spawnWorker(config, inherited: inherited, index: i)
            if pids[i] < 0 { return 1 }
        }

        let watcher = config.reload ? ReloadWatcher(config: config) : nil
        if watcher != nil { Log.info("watching for source changes (--reload)") }

        var shuttingDown = false
        var killDeadline: UInt64 = 0
        var alive = workers
        var restarting = false

        /// Signals every live worker and, past the grace period, kills it.
        func signalAll(_ sig: Int32) {
            for k in 0..<workers where pids[k] > 0 { _ = pg_kill(pids[k], sig) }
        }

        while alive > 0 {
            var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
            let n = withUnsafeMutableBytes(of: &buf) { raw -> Int in
                let r = pg_poll_single(signalFD, 0, 250)
                if r <= 0 { return 0 }
                return pg_read(signalFD, raw.baseAddress!, 8)
            }
            if n > 0 {
                withUnsafeBytes(of: &buf) { raw in
                    let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<n {
                        switch Int32(p[i]) {
                        case SIGTERM, SIGINT, SIGQUIT:
                            if !shuttingDown {
                                shuttingDown = true
                                Log.info("shutting down; signalling workers")
                                signalAll(SIGTERM)
                                // Workers get the same grace period they give
                                // their own requests, plus a moment to exit.
                                killDeadline = pg_monotonic_ms()
                                    &+ config.gracefulShutdownMs &+ 2_000
                            }
                        case SIGHUP:
                            if !shuttingDown {
                                Log.info("SIGHUP: restarting workers")
                                restarting = true
                                signalAll(SIGTERM)
                            }
                        default:
                            break
                        }
                    }
                }
            }

            // Past the grace period a worker is no longer draining, it is
            // stuck; the deadline is what makes shutdown bounded.
            if shuttingDown && killDeadline > 0 && pg_monotonic_ms() > killDeadline {
                Log.warn("workers did not exit within the shutdown grace period; killing")
                signalAll(SIGKILL)
                killDeadline = 0
            }

            if let watcher, !shuttingDown, watcher.changed() {
                Log.info("source change detected; restarting workers")
                restarting = true
                signalAll(SIGTERM)
            }

            // Reap whatever has exited.
            while true {
                var status: Int32 = 0
                let pid = pg_waitpid(-1, &status, 1)
                if pid <= 0 { break }
                var index = -1
                for k in 0..<workers where pids[k] == pid { index = k }
                if index >= 0 { pids[index] = 0 }
                alive -= 1
                if !shuttingDown {
                    if !restarting {
                        Log.warn { line in
                            line.str("worker ")
                            line.int(Int(pid))
                            line.str(" exited; restarting")
                        }
                    }
                    if index >= 0 {
                        pids[index] = spawnWorker(config, inherited: inherited, index: index)
                        if pids[index] > 0 { alive += 1 }
                    }
                }
            }
            if restarting && alive == workers { restarting = false }
        }
        if inherited >= 0 { _ = pg_close(inherited) }
        Log.info("peregrine stopped")
        return 0
    }

    static func spawnWorker(_ config: ServerConfig, inherited: Int32,
                            index: Int = 0) -> pid_t {
        let pid = pg_fork()
        if pid < 0 {
            Log.error("fork failed")
            return -1
        }
        if pid > 0 { return pid }

        // --- child ---
        Log.pid = Int(pg_getpid())
        // A fresh signal pipe: the inherited one belongs to the supervisor.
        pg_signal_pipe_reset()
        // A free-threaded child opens one listener per worker thread, so it is
        // handed the inherited descriptor as-is and works the rest out itself.
        if config.freeThreaded {
            let ok = runFreeThreaded(config, workers: config.resolvedWorkers,
                                     inherited: inherited)
            exitProcess(ok ? 0 : 1)
        }
        var fd = inherited
        if fd < 0 {
            guard let opened = openListener(config, reusePort: true, unlinkStale: false) else {
                exitProcess(1)
            }
            fd = opened
        }
        let ok = runWorker(config, listenFD: fd, metricsSlot: index)
        exitProcess(ok ? 0 : 1)
    }

    static func exitProcess(_ code: Int32) -> Never {
        exit(code)
    }

    // MARK: - Worker

    /// The application, once the interpreter is up and it has been imported.
    struct LoadedApplication {
        let app: PyObj
        let proto: AppProtocol
    }

    /// Everything that happens once per process: the interpreter, the search
    /// path, the internal Python types, and the application itself.
    ///
    /// With workers as processes this runs once per worker, because a worker is
    /// a process. Under `--free-threaded` it runs exactly once and every worker
    /// thread shares what it produced -- which is the whole point: one import of
    /// the application, one set of module-level caches, one connection pool.
    static func bootInterpreter(_ config: ServerConfig) -> LoadedApplication? {
        guard Interpreter.initialize(program: staticCString("peregrine"),
                                     home: config.pythonHome,
                                     isolated: false) else {
            return nil
        }
        // Order matters, and each of these prepends, so they are applied
        // back to front. What comes out is: the directories the user named,
        // in the order they named them, then the working directory, then the
        // virtualenv. `--python-path` is the user saying "look here first",
        // and a package installed in the environment must not silently win
        // over one they pointed at -- which is the same rule PYTHONPATH
        // follows against site-packages in an ordinary interpreter.
        if !activateVirtualenv(config) { return nil }
        Interpreter.addSysPath(staticCString("."))
        for extra in config.pythonPaths.reversed() { Interpreter.addSysPath(extra) }

        // Internal Python types. Registered once per interpreter.
        guard PyTrampoline.register(),
              PyImmediate.register(),
              WSGIInputStream.register(),
              WSGIStartResponse.register() else {
            Log.error("failed to register internal Python types")
            return nil
        }

        var appRef = Interpreter.loadApplication(config.appSpec)
        guard var app = appRef.optional else {
            Log.error("could not load the application")
            return nil
        }
        if pg_is_callable(app) == 0 {
            Log.error("the application object is not callable")
            return nil
        }
        if config.appIsFactory {
            guard let produced = pg_call0(app) else {
                PyError.logPending("calling the application factory")
                return nil
            }
            if pg_is_callable(produced) == 0 {
                Log.error("the application factory did not return a callable")
                pg_decref(produced)
                return nil
            }
            _ = appRef.take()
            appRef = PyRef(stealing: produced)
            app = produced
        }
        let proto = config.appProtocol ?? Interpreter.detectProtocol(app)

        // The application object is deliberately leaked: it lives as long as
        // the process and releasing it during finalisation is a hazard.
        _ = appRef.take()
        return LoadedApplication(app: app, proto: proto)
    }

    /// Builds one worker: poller, connection slab, TLS, QUIC listener, and the
    /// WSGI runtime when that is the protocol.
    ///
    /// The ASGI event loop is deliberately not set up here. How the loop and
    /// the lifespan are arranged is precisely what differs between the process
    /// model and the free-threaded one -- a process has one of each, a
    /// free-threaded worker has a loop of its own and shares one lifespan with
    /// its siblings -- so each caller does that part itself.
    ///
    /// `controlFD` is the descriptor the worker learns about shutdown through:
    /// the process signal pipe for a worker process, and a pipe written by the
    /// supervising thread for a worker thread. Either way it carries signal
    /// numbers, so `handleSignals` does not know the difference.
    static func makeWorker(_ config: ServerConfig,
                           listenFD: Int32,
                           controlFD: Int32,
                           loaded: LoadedApplication,
                           metricsSlot: Int = 0) -> UnsafeMutablePointer<Worker>? {
        guard let poller = Poller(maxEvents: 256) else {
            Log.error("cannot create the readiness poller")
            return nil
        }

        let workerPtr = UnsafeMutablePointer<Worker>.allocate(capacity: 1)
        workerPtr.initialize(to: Worker(config: config, listenFD: listenFD, poller: poller))
        currentWorker = workerPtr
        if config.tlsEnabled {
            guard let context = makeTLSContext(config) else { return nil }
            workerPtr.pointee.tlsContext = context
        }
        workerPtr.pointee.appProtocol = loaded.proto
        workerPtr.pointee.signalFD = controlFD

        // This thread's slot of the shared page, and its own scrape listener:
        // every worker binds the metrics port with SO_REUSEPORT, exactly as
        // they all bind the service port.
        if config.metricsPort != 0 {
            Metrics.bind(slot: metricsSlot)
            Metrics.set(PG_M_SLOTS_CAPACITY, UInt64(config.maxConnections))
            let host = config.metricsHost ?? config.host
            let fd = pg_listen_tcp(host, config.metricsPort, 64, 1,
                                   config.ipv6Only ? 1 : 0)
            if fd < 0 {
                let e = pg_errno()
                Log.error { line in
                    line.str("cannot listen on the metrics port: ")
                    line.cstr(pg_strerror(e))
                }
                return nil
            }
            workerPtr.pointee.metricsFD = fd
        }
        if config.http3Enabled {
            guard let listener = makeQUICListener(config) else { return nil }
            workerPtr.pointee.quic = listener
        }

        if loaded.proto == .wsgi {
            let threads = max(1, config.wsgiThreads)
            // PEP 3333 asks two questions about the environment the application
            // is running in, and --free-threaded answers them the other way
            // round from --workers: one process, several threads.
            let siblings = config.resolvedWorkers > 1
            guard let runtime = WSGIRuntime(app: loaded.app,
                                            serverName: config.serverName,
                                            serverPort: config.serverPortString,
                                            scheme: config.scheme,
                                            rootPath: config.rootPath,
                                            multiprocess: !config.freeThreaded && siblings,
                                            multithread: threads > 1
                                                || (config.freeThreaded && siblings)) else {
                Log.error("could not prepare the WSGI runtime")
                return nil
            }
            workerPtr.pointee.wsgi = runtime
            if threads > 1 {
                guard let pool = WSGIPool(threads: threads, worker: workerPtr) else {
                    Log.error("could not start the WSGI thread pool")
                    return nil
                }
                workerPtr.pointee.wsgiPool = pool
                guard workerPtr.pointee.registerPool() else { return nil }
            }
        }

        guard workerPtr.pointee.registerListener() else { return nil }
        guard workerPtr.pointee.registerMetricsListener() else { return nil }
        guard workerPtr.pointee.registerQUIC() else { return nil }
        return workerPtr
    }

    /// The "worker ready" line. `threads` is 0 for a worker process.
    static func logReady(_ config: ServerConfig, proto: AppProtocol, threads: Int) {
        Log.info { line in
            line.str(proto == .wsgi ? "worker ready (WSGI) on " : "worker ready (ASGI) on ")
            line.cstr(config.unixPath ?? config.host)
            if config.unixPath == nil {
                line.str(":")
                line.int(Int(config.port))
            }
            if threads > 0 {
                line.str(" with ")
                line.int(threads)
                line.str(" free-threaded workers")
            }
            if proto == .wsgi && config.wsgiThreads > 1 {
                line.str(" with ")
                line.int(config.wsgiThreads)
                line.str(" application threads")
            }
        }
    }

    /// Everything from here down runs inside a worker process.
    static func runWorker(_ config: ServerConfig, listenFD: Int32,
                          metricsSlot: Int = 0) -> Bool {
        guard let loaded = bootInterpreter(config) else { return false }
        guard let workerPtr = makeWorker(config, listenFD: listenFD,
                                         controlFD: pg_signal_pipe_init(),
                                         loaded: loaded,
                                         metricsSlot: metricsSlot) else {
            return false
        }
        if loaded.proto == .asgi {
            guard ASGIRuntime.prepare(workerPtr, app: loaded.app, config: config) else {
                Log.error("could not prepare the ASGI runtime")
                return false
            }
        }

        logReady(config, proto: loaded.proto, threads: 0)

        if loaded.proto == .wsgi {
            runSynchronousLoop(workerPtr)
        } else {
            ASGIRuntime.runLoop(workerPtr)
        }

        workerPtr.pointee.destroy()
        currentWorker = nil
        Interpreter.finalize()
        return true
    }

    /// Points the embedded interpreter at a virtualenv, so that `peregrine`
    /// installed once on the system can serve an application whose dependencies
    /// live in a project environment.
    static func activateVirtualenv(_ config: ServerConfig) -> Bool {
        var path = config.venvPath
        if path == nil && !config.noAutoVenv {
            path = pg_getenv("VIRTUAL_ENV")
        }
        guard let path, path[0] != 0 else { return true }
        guard let fn = Interpreter.glueFunction("activate_venv") else { return false }
        guard let pathObj = pg_str_utf8(path, pg_ssize_t(strlen(path))) else { return false }
        defer { pg_decref(pathObj) }
        guard let result = pg_call1(fn, pathObj) else {
            PyError.logPending("activating the virtualenv")
            return false
        }
        defer { pg_decref(result) }
        if pg_is(result, Interned.none) == 0 {
            var n: pg_ssize_t = 0
            if let msg = pg_str_utf8_data(result, &n) {
                Log.error { line in
                    line.bytes(UnsafeRawPointer(msg).assumingMemoryBound(to: UInt8.self), Int(n))
                }
            }
            // An explicit --venv that cannot be used is fatal; an inherited
            // VIRTUAL_ENV that does not match is a warning, because the
            // application may well be importable without it.
            return config.venvPath == nil
        }
        return true
    }

    /// The WSGI loop. There is no asyncio here at all: the poller is the only
    /// thing that ever blocks, and the GIL is released around it so that
    /// application threads -- the optional pool, or background threads the
    /// application started itself -- can run.
    static func runSynchronousLoop(_ worker: UnsafeMutablePointer<Worker>) {
        while worker.pointee.running {
            let timeout = worker.pointee.quicPollTimeout(200)
            let saved = pg_gil_save()
            let n = worker.pointee.poller.wait(timeoutMillis: timeout)
            pg_gil_restore(saved)

            if n > 0 { worker.pointee.processEvents(n) }
            worker.pointee.quicTick()
            worker.pointee.sweepTimeouts()

            if worker.pointee.draining && worker.pointee.quiescent {
                worker.pointee.running = false
            }
        }
        worker.pointee.wsgiPool?.shutdown(deadlineMs: worker.pointee.config.gracefulShutdownMs)
    }
}
