//===----------------------------------------------------------------------===//
// Process model and worker start-up.
//
// One process per worker, each with its own poller and its own connection slab.
//
// The supervisor creates the listening sockets and the workers inherit them
// across fork. How many there are depends on the address family:
//
//   * TCP: one socket per worker slot, all with SO_REUSEPORT, so each worker
//     gets an independent accept queue in the kernel. There is no shared accept
//     lock, no thundering herd, and the kernel spreads connections by hashing
//     the four-tuple.
//   * Unix: one socket, because a path can only be bound once, and every worker
//     accepts from it. Letting each worker bind for itself would have every one
//     of them unlink and replace the socket the previous had just published,
//     leaving only the last worker reachable.
//
// A worker could open its own TCP socket instead -- it used to -- and the
// kernel would not know the difference. The supervisor owns them so that a
// worker can be *replaced* without its socket closing: the replacement
// inherits the same one, so the SO_REUSEPORT group keeps every member and the
// accept queue keeps every connection across a reload. A socket that leaves
// the group takes its queue with it, along with every handshake still in
// flight on it, because the kernel chooses the socket when the SYN arrives
// rather than when accept() is called.
//
// Threads are not used for request handling. A worker answers from its own
// poller loop: routes are matched and handlers called synchronously
// (RouteTable.swift, Respond.swift), and a handler that has to wait parks a
// continuation on its connection slot (AsyncOps.swift) instead of holding a
// thread, so there is nothing for a second thread to do.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import CGaruda
import GarudaCore
import GarudaHTTP
import GarudaQUIC

enum GarudaRuntime {

    /// Boots the server. Returns a process exit code.
    static func run(config: ServerConfig) -> Int32 {
        // --reload: this image may be a supervisor restarted on a rebuilt
        // executable, holding the previous image's sockets and workers.
        var inherited = Reexec.take()
        let code = start(config, inherited: &inherited)
        // A rebuilt executable that could not start stops the workers it
        // inherited, rather than leaving them serving with no supervisor.
        inherited?.release()
        return code
    }

    static func start(_ config: ServerConfig, inherited: inout Reexec?) -> Int32 {
        Log.level = config.logLevel
        Log.pid = Int(pg_getpid())
        // The short name top and pkill match on, set once here so that every
        // worker forked from here inherits it. See pg_set_process_name.
        pg_set_process_name("garuda")
        pg_ignore_sigpipe()
        let limit = pg_raise_nofile_limit()
        if limit > 0 && limit < Int(config.maxConnections) + 32 {
            Log.warn { line in
                line.str("file descriptor limit ")
                line.int(Int(limit))
                line.str(" is below max-connections; lower --max-connections or raise ulimit -n")
            }
        }

        // --acme-domain. Workers need a certificate to start, and the challenge
        // that gets a real one is answered by those same workers, so a server
        // with nothing cached yet starts on a self-signed placeholder and
        // reloads off it once the CA has issued.
        if config.acmeEnabled, let dir = config.acmeCacheDir,
           let cert = config.tlsCertPath, let key = config.tlsKeyPath {
            if pg_acme_mkdirs(dir) != 0 {
                Log.error("cannot create the --acme-cache directory")
                return 1
            }
            if access(cert, R_OK) != 0 {
                let names = ACME.settings(config).names
                var error = [CChar](repeating: 0, count: 256)
                let made = names.withCString { pg_acme_placeholder($0, cert, key, &error, 256) }
                if made != 0 {
                    Log.error { line in
                        line.str("acme: ")
                        error.withUnsafeBufferPointer { line.cstr($0.baseAddress!) }
                    }
                    return 1
                }
                Log.info("acme: nothing cached yet; serving a placeholder until the CA issues")
            }
        }

        // Certificates are checked once, here, rather than discovered to be
        // unreadable inside each worker after the sockets are already open.
        if config.tlsEnabled {
            if pg_tls_available() == 0 {
                Log.error("this build has no TLS support; rebuild against OpenSSL")
                return 1
            }
            // --ktls, before any context is built: the option is read when each
            // one is, here and in every worker after the fork.
            if config.ktls {
                if pg_tls_enable_ktls(1) == 0 {
                    Log.warn("--ktls: this OpenSSL has no kernel TLS; encrypting in the process")
                } else if pg_tls_kernel_ready() == 0 {
                    Log.warn("--ktls: the kernel tls module is not loaded (modprobe tls); encrypting in the process")
                } else {
                    Log.info("kernel TLS requested (--ktls)")
                }
            }
            guard let context = makeTLSContext(config) else { return 1 }
            context.logCertificateNames()
        }

        let workerCount = config.resolvedWorkers

        // Before any fork: children inherit the mapping, and a page mapped
        // after one would be private to whoever mapped it.
        //
        // Twice as many slots as workers, because a reload overlaps the worker
        // being replaced with its replacement and they must not write to the
        // same one. They are both live at that moment -- the old one is still
        // finishing requests -- so sharing a slot would have each overwrite the
        // other's gauges and report a connection count belonging to neither.
        // The pair for slot `i` is `i` and `i + workerCount`, and a handover
        // moves to whichever of the two is free.
        if config.metricsPort != 0 {
            if pg_metrics_init(Int32(max(1, workerCount) * 2)) != 0 {
                Log.error("cannot map the shared metrics page")
                return 1
            }
        }

        // --cache-size. Mapped here for the same reason again: a response one
        // worker stored is only worth keeping if every other worker can read it.
        if config.cacheSizeMiB > 0 {
            let slots = pg_cache_init(UInt64(config.cacheSizeMiB) * 1024 * 1024,
                                      UInt32(responseCacheMaxHead),
                                      UInt32(config.cacheMaxObject))
            if slots < 0 {
                Log.error("--cache-size is too small to hold even one response of --cache-max-object")
                return 1
            }
            let entries = slots
            let largest = config.cacheMaxObject / 1024
            let size = config.cacheSizeMiB
            Log.info { line in
                line.str("response cache: ")
                line.int(size)
                line.str(" MiB, room for ")
                line.int(entries)
                line.str(" responses, bodies up to ")
                line.int(largest)
                line.str(" KiB")
            }
        }

        // --rate-limit. Mapped here for the same reason as the metrics page:
        // it has to exist before the first fork for every worker to share it.
        if config.rateLimitCount > 0 {
            let emission = config.rateLimitPeriodMs * 1000 / UInt64(config.rateLimitCount)
            let burst = config.rateLimitBurst > 0 ? config.rateLimitBurst : config.rateLimitCount
            // 2^16 entries, a megabyte: room for tens of thousands of clients
            // active at once before entries have to be reused.
            if pg_ratelimit_init(emission, emission * UInt64(burst - 1), 16) != 0 {
                Log.error("cannot map the shared rate-limit table")
                return 1
            }
            let unit: StaticString = config.rateLimitPeriodMs == 1000 ? " per second"
                : config.rateLimitPeriodMs == 60_000 ? " per minute" : " per hour"
            let count = config.rateLimitCount
            Log.info { line in
                line.str("rate limit: ")
                line.int(count)
                line.str(unit)
                line.str(", burst ")
                line.int(burst)
                line.str(", shared by every worker")
            }
        }

        // Everything runs under a supervisor, including a single worker.
        //
        // It used to be skipped in that case, which cost one process and lost
        // SIGHUP: the reload is the supervisor replacing a child, so with no
        // supervisor there was nothing to reload into and the signal did
        // nothing at all. A lone worker ignores SIGHUP -- silently, which is
        // the worst way for a certbot deploy hook to fail.
        return runSupervisor(config,
                             workers: max(1, workerCount),
                             listeners: workerCount,
                             inherited: &inherited)
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
        guard let context = TLSContext.make(certPath: cert, keyPath: key,
                                            alpn: alpn, ciphers: config.tlsCiphers)
        else { return nil }
        for extra in config.tlsExtraCerts {
            guard context.add(certPath: extra.cert, keyPath: extra.key,
                              ciphers: config.tlsCiphers) else { return nil }
        }
        if config.acmeEnabled, let dir = config.acmeCacheDir {
            if pg_tls_ctx_set_acme_dir(context.raw, dir) != 0 {
                Log.error("cannot turn on tls-alpn-01 answering for --acme-domain")
                return nil
            }
        }
        return context
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
            // --request-start-header. On the listener so that accepted sockets
            // inherit it, and so that timestamping is already on when a
            // request that will queue behind a busy worker arrives.
            if fd >= 0 && config.requestStartHeader { _ = pg_set_rx_timestamps(fd) }
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

    /// `workers` is how many children the supervisor watches; `listeners` is how
    /// many listening sockets to create, one per worker slot.
    static func runSupervisor(_ config: ServerConfig, workers: Int,
                              listeners listenerCount: Int,
                              inherited: inout Reexec?) -> Int32 {
        // One listener per worker, created here and inherited across fork.
        //
        // For TCP that is N sockets with SO_REUSEPORT -- N independent accept
        // queues, no shared accept lock, exactly what a worker used to open for
        // itself. What changed is who owns them. Because the supervisor holds
        // each socket open, a replacement worker inherits the *same* socket its
        // predecessor had, so the SO_REUSEPORT group never loses a member
        // during a reload.
        //
        // That is the difference between a reload that drops connections and
        // one that does not, and it cannot be fixed on the worker side. The
        // kernel picks which socket in the group a connection belongs to when
        // the SYN arrives, not when accept() is called, so a socket that closes
        // takes its accept queue and every half-finished handshake on it down
        // with it -- however carefully the worker drained first.
        //
        // For unix there is one socket, because a path can only be bound once,
        // and every worker accepts from it.
        let count = max(1, listenerCount)
        let listeners = UnsafeMutablePointer<Int32>.allocate(capacity: count)
        defer { listeners.deallocate() }
        listeners.initialize(repeating: -1, count: count)
        // --reload, after an exec: the sockets are the ones already listening,
        // and the workers already serving from them are adopted below.
        var adopted: [pid_t] = []
        if let record = inherited {
            inherited = nil
            if record.fits(workers: workers, listeners: count) {
                for i in 0..<count {
                    listeners[i] = record.listeners[i]
                    // Open across the exec on purpose; closed across any other.
                    _ = pg_set_cloexec(listeners[i])
                }
                adopted = record.workers
            } else {
                Log.warn("the rebuilt executable runs a different number of workers; starting afresh")
                record.release()
            }
        }
        if !adopted.isEmpty {
            // Already listening.
        } else if config.unixPath != nil {
            guard let fd = openListener(config, reusePort: false, unlinkStale: true) else {
                return 1
            }
            for i in 0..<count { listeners[i] = fd }
        } else {
            for i in 0..<count {
                guard let fd = openListener(config, reusePort: true, unlinkStale: false) else {
                    // A bad bind is one clear error, not N identical ones
                    // arriving from N children.
                    for k in 0..<i { _ = pg_close(listeners[k]) }
                    return 1
                }
                listeners[i] = fd
            }
        }
        defer { removeUnixPath(config) }

        let signalFD = pg_signal_pipe_init()
        // A supervisor that exec'd this image blocked these first, so that
        // one arriving in between would wait for the handlers just installed.
        pg_unblock_piped_signals()
        let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: workers)
        defer { pids.deallocate() }
        pids.initialize(repeating: 0, count: workers)

        if adopted.isEmpty {
            Log.info { line in
                line.str("garuda starting with ")
                line.int(workers)
                line.str(" workers")
            }
        } else {
            Log.info { line in
                line.str("garuda restarted on the rebuilt executable, adopting ")
                line.int(workers)
                line.str(" workers")
            }
        }

        // Metrics slots come in pairs, so that a worker and the replacement
        // overlapping it never write to the same one -- see `pg_metrics_init`.
        // `metricsSlotOf[i]` is the slot the worker currently in `i` was given,
        // and a handover takes the other half of the pair.
        let metricsSlotOf = UnsafeMutablePointer<Int>.allocate(capacity: workers)
        defer { metricsSlotOf.deallocate() }
        for i in 0..<workers { metricsSlotOf[i] = i }

        /// Moves slot `slot` to the other half of its metrics pair, so that a
        /// replacement does not land on the slot its predecessor is still using.
        func flipMetricsSlot(_ slot: Int) {
            let base = slot
            metricsSlotOf[slot] = metricsSlotOf[slot] == base ? base + count : base
        }

        /// Forks the worker for `slot`, handing it that slot's listener and
        /// letting it drop the handles on every other slot's.
        func spawn(_ slot: Int) -> (pid: pid_t, ready: Int32) {
            spawnWorker(config, listeners: listeners, listenerCount: count,
                        index: slot, metricsSlot: metricsSlotOf[slot])
        }

        for i in 0..<workers {
            if !adopted.isEmpty && adopted[i] > 0 {
                pids[i] = adopted[i]
                continue
            }
            let started = spawn(i)
            // Nothing is waiting on readiness at start-up: there is no worker
            // being replaced, so there is nothing to hold on to it for.
            if started.ready >= 0 { _ = pg_close(started.ready) }
            pids[i] = started.pid
            if pids[i] < 0 { return 1 }
        }

        let watcher = config.reload ? ReloadWatcher(config: config) : nil
        if let watcher {
            if let path = watcher.executablePath {
                Log.info { line in
                    line.str("--reload: watching ")
                    path.withCString { line.cstr($0) }
                    line.str(" for a rebuild")
                }
            } else {
                Log.warn("--reload: cannot find the running executable; only certificates are watched")
            }
        }
        /// A rebuilt executable waiting for a restart pass or a draining
        /// worker to finish, since neither survives the exec.
        var execPending = false

        var shuttingDown = false
        var killDeadline: UInt64 = 0
        var alive = workers

        // --acme-domain. The client runs in a helper process forked from here,
        // one at a time, and its exit status is the whole of its report: 0
        // means a new certificate is on disk and the workers should reload
        // onto it, which they do the way a SIGHUP has them do.
        //
        // A process rather than a thread because this process forks workers,
        // and forking while another thread holds the allocator's lock leaves
        // the child with a lock nobody will ever release.
        let acmeSettings: ACME.Settings? = config.acmeEnabled ? ACME.settings(config) : nil
        var acmePid: pid_t = 0
        var acmeNextCheck: UInt64 = 0
        var acmeFailures = 0

        /// Starts the helper when the certificate is missing, is the
        /// placeholder, lacks a name, or is inside its renewal window.
        func checkCertificate() {
            guard let settings = acmeSettings, acmePid == 0, !shuttingDown else { return }
            let now = pg_monotonic_ms()
            if now < acmeNextCheck { return }
            // A month to spare. Let's Encrypt certificates last ninety days
            // and it asks for renewal once two thirds have gone, which leaves
            // the retries below a month to succeed in.
            let needed = settings.certPath.withCString { cert in
                settings.names.withCString { names in
                    pg_acme_needs_certificate(cert, names, 30 * 86_400)
                }
            }
            if needed == 0 {
                acmeNextCheck = now &+ 12 * 3_600_000
                return
            }
            let pid = pg_fork()
            if pid == 0 {
                // SIGTERM at shutdown has to end the helper, not be written
                // into the supervisor's pipe by the handler it inherited.
                pg_signals_default()
                // The helper serves nothing, so it lets go of the sockets: a
                // helper still waiting on a slow CA after the server has gone
                // must not be what keeps the port bound.
                for i in 0..<count where listeners[i] >= 0 { _ = pg_close(listeners[i]) }
                _ = pg_close(signalFD)
                _exit(ACME.obtain(settings) ? 0 : 1)
            }
            if pid < 0 {
                Log.error("cannot fork the ACME helper")
                acmeNextCheck = now &+ 60_000
                return
            }
            acmePid = pid
        }

        // A restart replaces the workers one slot at a time, and the
        // replacement is spawned and accepting *before* the worker it replaces
        // is asked to stop. The port is therefore bound by somebody at every
        // instant of a reload, which is what makes a SIGHUP certificate reload
        // cost nothing: the TLS context is built per worker, so the new process
        // reads the new certificate off disk, and the old one finishes the
        // requests it already had.
        //
        // Killing them all at once instead -- which is what this did -- did not
        // unbind the port, because a draining worker only stopped polling its
        // listener and went on holding it open. It was worse than that: the
        // socket stayed in the SO_REUSEPORT group, so the kernel kept giving it
        // a share of new connections, which sat in a queue nobody was serving
        // until the worker exited and reset them. Measured over 40,000
        // requests and three reloads, that was 56 connections lost and a
        // worst-case latency of just over a second, against none lost and 94ms
        // here.
        //
        // `retiring[i]` is the worker that used to hold slot `i` and is now
        // draining. It is not replaced when it is reaped, because its
        // replacement is already serving.
        let retiring = UnsafeMutablePointer<pid_t>.allocate(capacity: workers)
        defer { retiring.deallocate() }
        retiring.initialize(repeating: 0, count: workers)

        /// The slot a rolling restart is about to replace, or -1 when no
        /// restart is in flight.
        var restartCursor = -1
        /// A reload asked for while one was already running. The pass in flight
        /// is carrying workers that predate the request, so another has to
        /// follow it; without this a save during a `--reload` restart would be
        /// silently skipped.
        var restartPending = false

        // A handover in flight. The replacement has been forked and the worker
        // it replaces has *not* been signalled yet, because until the
        // replacement is actually accepting the old one is the only thing
        // serving that slot. Retiring it first does not drop connections --
        // the socket belongs to the supervisor -- but it does leave the slot's
        // accept queue unserved for as long as a worker takes to start.
        var handoverSlot = -1
        var handoverOld: pid_t = 0
        var handoverReadyFD: Int32 = -1
        var handoverDeadline: UInt64 = 0

        /// How long to wait for a replacement to report ready before retiring
        /// the old worker regardless.
        ///
        /// Generous, because the wait is safe: the worker being replaced is
        /// still serving throughout it. This only bounds the case of a
        /// replacement that is alive but never finishes starting, where the
        /// alternative is a reload that was asked for and never happened.
        let readyTimeoutMs: UInt64 = 60_000

        /// Signals every live worker -- including the ones already draining,
        /// which shutdown still has to reach -- and, past the grace period,
        /// kills it.
        func signalAll(_ sig: Int32) {
            for k in 0..<workers where retiring[k] > 0 { _ = pg_kill(retiring[k], sig) }
            // Mid-handover the outgoing worker is in neither array, and a
            // shutdown still has to reach it.
            if handoverOld > 0 { _ = pg_kill(handoverOld, sig) }
            for k in 0..<workers where pids[k] > 0 { _ = pg_kill(pids[k], sig) }
        }

        /// Clears the handover state, releasing the readiness pipe.
        func clearHandover() {
            if handoverReadyFD >= 0 { _ = pg_close(handoverReadyFD) }
            handoverSlot = -1
            handoverOld = 0
            handoverReadyFD = -1
            handoverDeadline = 0
        }

        /// The replacement is accepting, so the worker it replaced can go.
        func retireHandover() {
            guard handoverSlot >= 0 else { return }
            let slot = handoverSlot
            let old = handoverOld
            clearHandover()
            retiring[slot] = old
            // SIGQUIT, not SIGTERM: its replacement is already serving, so
            // there is nothing for --drain-delay to wait for.
            _ = pg_kill(old, SIGQUIT)
        }

        /// Replaces the slot at `restartCursor`, then advances. One slot is in
        /// flight at a time: the whole point is that somebody is always
        /// listening, and that holds with one spare worker just as well as with
        /// a second full set, at a fraction of the memory. Every worker has
        /// its own connection slab and buffer pool, so doubling the process
        /// count for the length of a reload is not free on the kind of server
        /// that most wants zero-downtime reloads.
        func advanceRestart() {
            while restartCursor >= 0 && restartCursor < workers {
                let i = restartCursor
                // An empty slot needs no handover, and a slot whose previous
                // occupant has not finished draining is not ready for another.
                if pids[i] <= 0 || retiring[i] != 0 {
                    restartCursor += 1
                    continue
                }
                let old = pids[i]
                // The two overlap, so the replacement takes the other half of
                // the metrics pair; the one it would otherwise land on is still
                // being written to by the worker it is replacing.
                flipMetricsSlot(i)
                let fresh = spawn(i)
                if fresh.pid < 0 {
                    // Keep the worker that is already serving. A failed fork is
                    // a bad moment to also give up the process that works.
                    Log.error("cannot spawn a replacement worker; keeping the current one")
                    flipMetricsSlot(i)
                    restartCursor = -1
                    restartPending = false
                    return
                }
                pids[i] = fresh.pid
                alive += 1
                // The old worker is left alone until the replacement reports
                // that it is accepting; see the handover state above. Both are
                // serving the slot until then, which is the point.
                handoverSlot = i
                handoverOld = old
                handoverReadyFD = fresh.ready
                handoverDeadline = pg_monotonic_ms() &+ readyTimeoutMs
                return
            }
            restartCursor = -1
            Log.info("workers reloaded")
            if restartPending {
                restartPending = false
                restartCursor = 0
                advanceRestart()
            }
        }

        /// Starts a rolling restart, or notes that one is wanted next.
        func beginRestart(_ why: StaticString) {
            if shuttingDown { return }
            Log.info(why)
            // New workers may run new code, which may answer the same request
            // differently; nothing the old ones cached is served again.
            pg_cache_flush()
            if restartCursor >= 0 {
                restartPending = true
                return
            }
            restartCursor = 0
            advanceRestart()
        }

        /// Execs the rebuilt executable in place of this process, handing it
        /// the listening sockets and the workers. Returns only if that failed,
        /// with everything as it was.
        func reexec() {
            guard let path = watcher?.executablePath else { return }
            // Catches a file that is not a whole executable before this
            // process becomes it: a failed exec returns, a bad image does not.
            if pg_probe_executable(path, 5_000) == 0 {
                Log.error("--reload: the rebuilt executable does not run; keeping the current one")
                return
            }
            Log.info("executable rebuilt; restarting the supervisor on it")
            let record = Reexec(listeners: (0..<count).map { listeners[$0] },
                                workers: (0..<workers).map { pids[$0] })
            var distinct: [Int32] = []
            for fd in record.listeners where !distinct.contains(fd) { distinct.append(fd) }
            setenv(Reexec.variable, record.encoded(), 1)
            for fd in distinct { _ = pg_clear_cloexec(fd) }
            pg_block_piped_signals()
            _ = path.withCString { pg_execv($0, CommandLine.unsafeArgv) }
            let e = pg_errno()
            pg_unblock_piped_signals()
            for fd in distinct { _ = pg_set_cloexec(fd) }
            unsetenv(Reexec.variable)
            Log.error { line in
                line.str("--reload: cannot exec the rebuilt executable: ")
                line.cstr(pg_strerror(e))
            }
        }

        // The workers adopted after an exec run the old code; replace them.
        if !adopted.isEmpty {
            beginRestart("replacing the workers forked from the previous executable")
        }

        while alive > 0 {
            // A pending handover is the one thing this loop waits on that is
            // not a signal, and the wait is measured in the tens of
            // milliseconds a worker takes to start, so the idle quarter
            // second would be most of the delay it exists to remove. The same
            // goes for a --reload notification waiting for a save to settle.
            let waitMs: Int32 = handoverReadyFD >= 0 || watcher?.checkSoon == true ? 5 : 250
            // The reload watcher's descriptor wakes the loop the moment a
            // source file changes. Not while shutting down: nothing drains it
            // then, and a readable descriptor nobody reads would spin here.
            let watchFD: Int32 = shuttingDown ? -1 : (watcher?.notifyFD ?? -1)
            var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
            let n = withUnsafeMutableBytes(of: &buf) { raw -> Int in
                let r = pg_poll_either(signalFD, watchFD, waitMs)
                if r <= 0 || r & 1 == 0 { return 0 }
                return pg_read(signalFD, raw.baseAddress!, 8)
            }

            if handoverReadyFD >= 0 {
                // Readable is the replacement saying it is accepting; an error
                // is the pipe hanging up because it died first, which the reap
                // below turns into keeping the worker it was replacing.
                // Any event at all, then read to find out which it was. A
                // worker signals by writing one byte and closing, so by the
                // time the supervisor looks the pipe usually reports POLLIN and
                // POLLHUP together and a poll cannot tell "ready" from "died
                // during start-up" -- it reports the hangup either way. The
                // read can: one byte is the signal, end of file is the death.
                if pg_poll_single(handoverReadyFD, 0, 0) != 0 {
                    var byte: UInt8 = 0
                    let got = withUnsafeMutableBytes(of: &byte) { raw in
                        pg_read(handoverReadyFD, raw.baseAddress!, 1)
                    }
                    if got == 1 {
                        retireHandover()
                    } else {
                        // The reap below has the pid and puts the slot back;
                        // all that is needed here is to stop watching a pipe
                        // with nothing left to say.
                        _ = pg_close(handoverReadyFD)
                        handoverReadyFD = -1
                    }
                } else if handoverDeadline > 0 && pg_monotonic_ms() > handoverDeadline {
                    Log.error("a replacement worker has not started serving after 60s;")
                    Log.error("retiring the worker it replaces anyway, as the reload asked")
                    retireHandover()
                }
            }
            if n > 0 {
                withUnsafeBytes(of: &buf) { raw in
                    let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<n {
                        switch Int32(p[i]) {
                        case SIGTERM:
                            if !shuttingDown {
                                shuttingDown = true
                                if config.drainDelayMs > 0 {
                                    Log.info("shutting down after --drain-delay; health check now failing")
                                } else {
                                    Log.info("shutting down; signalling workers")
                                }
                                // The workers keep the delay themselves: an init
                                // system that signals the whole group reaches
                                // them without going through this process.
                                signalAll(SIGTERM)
                                if acmePid > 0 { _ = pg_kill(acmePid, SIGTERM) }
                                // Workers get the same grace period they give
                                // their own requests, plus a moment to exit.
                                killDeadline = pg_monotonic_ms() &+ config.drainDelayMs
                                    &+ config.gracefulShutdownMs &+ 2_000
                            }
                        case SIGINT, SIGQUIT:
                            // No delay, and a way to cut one short.
                            let deadline = pg_monotonic_ms() &+ config.gracefulShutdownMs &+ 2_000
                            if !shuttingDown {
                                shuttingDown = true
                                Log.info("shutting down; signalling workers")
                                signalAll(SIGQUIT)
                                if acmePid > 0 { _ = pg_kill(acmePid, SIGTERM) }
                                killDeadline = deadline
                            } else if killDeadline > deadline {
                                Log.info("shutting down now, without waiting out --drain-delay")
                                signalAll(SIGQUIT)
                                killDeadline = deadline
                            }
                        case SIGHUP:
                            beginRestart("SIGHUP: reloading workers")
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

            if let watcher, !shuttingDown {
                switch watcher.poll() {
                case .executable:
                    execPending = true
                case .certificates:
                    beginRestart("certificate changed on disk; reloading workers")
                case .none:
                    break
                }
            }
            if execPending && !shuttingDown && restartCursor < 0 && handoverSlot < 0
                && acmePid == 0 && !(0..<workers).contains(where: { retiring[$0] != 0 }) {
                execPending = false
                reexec()
            }

            checkCertificate()

            // Reap whatever has exited.
            while true {
                var status: Int32 = 0
                let pid = pg_waitpid(-1, &status, 1)
                if pid <= 0 { break }

                // The ACME helper is not a worker and never counted as one.
                if acmePid > 0 && pid == acmePid {
                    acmePid = 0
                    let now = pg_monotonic_ms()
                    if pg_acme_exit_ok(status) != 0 {
                        acmeFailures = 0
                        acmeNextCheck = now &+ 12 * 3_600_000
                        beginRestart("certificate installed; reloading workers")
                    } else {
                        // A minute, doubling to six hours. A CA that is briefly
                        // down is asked again soon; one that keeps refusing is
                        // not hammered, and Let's Encrypt counts failed
                        // validations against a rate limit.
                        acmeFailures += 1
                        let backoff = min(UInt64(60_000) << UInt64(min(acmeFailures - 1, 9)),
                                          UInt64(6 * 3_600_000))
                        acmeNextCheck = now &+ backoff
                        Log.warn { line in
                            line.str("no certificate this time; asking again in ")
                            line.int(Int(backoff / 1000))
                            line.str("s")
                        }
                    }
                    continue
                }

                alive -= 1

                // A replacement that died before it ever served. The worker it
                // was meant to replace has not been signalled and is still
                // serving, so the slot goes back to it and the pass stops --
                // replacing the rest with something that cannot start would
                // turn one bad worker into no workers.
                if handoverSlot >= 0 && pid == pids[handoverSlot] {
                    let slot = handoverSlot
                    let old = handoverOld
                    clearHandover()
                    flipMetricsSlot(slot)
                    pids[slot] = old
                    restartCursor = -1
                    restartPending = false
                    Log.error { line in
                        line.str("replacement worker ")
                        line.int(Int(pid))
                        line.str(" exited before it started serving; keeping the current one")
                    }
                    continue
                }

                // The worker being replaced died on its own before it was
                // asked to. Its replacement is already up, so there is nothing
                // to hand over and the pass simply carries on.
                if handoverSlot >= 0 && pid == handoverOld {
                    clearHandover()
                    if !shuttingDown && restartCursor >= 0 {
                        restartCursor += 1
                        advanceRestart()
                    }
                    continue
                }

                // A worker that was handed over is gone on purpose, and its
                // replacement has been serving since before it was signalled.
                var retired = -1
                for k in 0..<workers where retiring[k] == pid { retired = k }
                if retired >= 0 {
                    retiring[retired] = 0
                    if !shuttingDown && restartCursor >= 0 {
                        restartCursor += 1
                        advanceRestart()
                    }
                    continue
                }

                var index = -1
                for k in 0..<workers where pids[k] == pid { index = k }
                if index >= 0 { pids[index] = 0 }
                if !shuttingDown {
                    Log.warn { line in
                        line.str("worker ")
                        line.int(Int(pid))
                        line.str(" exited; restarting")
                    }
                    if index >= 0 {
                        // A crash replacement has nobody to hand over from, so
                        // its readiness is nothing to wait for either.
                        let restarted = spawn(index)
                        if restarted.ready >= 0 { _ = pg_close(restarted.ready) }
                        pids[index] = restarted.pid
                        if pids[index] > 0 { alive += 1 }
                    }
                }
            }
        }
        // Every worker is gone, so these are the last handles on the listeners.
        // A unix socket is one descriptor repeated across the slots, so each
        // distinct one is closed once.
        for i in 0..<count where listeners[i] >= 0 {
            var alreadyClosed = false
            for k in 0..<i where listeners[k] == listeners[i] { alreadyClosed = true }
            if !alreadyClosed { _ = pg_close(listeners[i]) }
        }
        Log.info("garuda stopped")
        return 0
    }

    /// Forks a worker and returns its pid together with the read end of its
    /// readiness pipe, which becomes readable when the worker starts accepting
    /// and hangs up if it dies first. The caller owns that descriptor.
    static func spawnWorker(_ config: ServerConfig,
                            listeners: UnsafeMutablePointer<Int32>,
                            listenerCount: Int,
                            index: Int,
                            metricsSlot: Int) -> (pid: pid_t, ready: Int32) {
        var fds: (Int32, Int32) = (-1, -1)
        let piped = withUnsafeMutableBytes(of: &fds) { raw in
            pg_pipe(raw.baseAddress!.assumingMemoryBound(to: Int32.self))
        }
        if piped != 0 {
            Log.error("cannot create the worker readiness pipe")
            return (-1, -1)
        }

        // Not plain fork: a signal that arrived before the child had a pipe of
        // its own was lost. See pg_fork_worker.
        let pid = pg_fork_worker()
        if pid < 0 {
            Log.error("fork failed")
            _ = pg_close(fds.0)
            _ = pg_close(fds.1)
            return (-1, -1)
        }
        if pid > 0 {
            // The supervisor keeps the read end only. Holding the write end
            // too would stop the pipe ever hanging up, and the hangup is how a
            // worker that dies during start-up is noticed.
            _ = pg_close(fds.1)
            return (pid, fds.0)
        }

        // --- child ---
        _ = pg_close(fds.0)
        readyPipeFD = fds.1
        Log.pid = Int(pg_getpid())

        // fork hands over the whole descriptor table, so this worker starts out
        // holding a listener for every slot. It will only ever poll its own;
        // the rest are the supervisor's to keep, and holding them here would
        // mean a slot's socket outliving the supervisor inside an unrelated
        // worker. A unix socket is the same descriptor in every slot, which is
        // what the comparison against `mine` is for.
        let mine = listeners[index]
        for k in 0..<listenerCount where listeners[k] >= 0 && listeners[k] != mine {
            _ = pg_close(listeners[k])
        }

        var fd = mine
        if fd < 0 {
            guard let opened = openListener(config, reusePort: true, unlinkStale: false) else {
                exitProcess(1)
            }
            fd = opened
        }
        let ok = runWorker(config, listenFD: fd, index: index, metricsSlot: metricsSlot)
        exitProcess(ok ? 0 : 1)
    }

    static func exitProcess(_ code: Int32) -> Never {
        exit(code)
    }

    // MARK: - Worker

    /// Builds one worker: poller, connection slab, TLS, QUIC listener.
    static func makeWorker(_ config: ServerConfig,
                           listenFD: Int32,
                           controlFD: Int32,
                           metricsSlot: Int = 0) -> UnsafeMutablePointer<Worker>? {
        guard let poller = Poller(maxEvents: 256) else {
            Log.error("cannot create the readiness poller")
            return nil
        }

        let workerPtr = UnsafeMutablePointer<Worker>.allocate(capacity: 1)
        workerPtr.initialize(to: Worker(config: config, listenFD: listenFD, poller: poller))
        workerPtr.pointee.application = application
        currentWorker = workerPtr
        if config.tlsEnabled {
            guard let context = makeTLSContext(config) else { return nil }
            workerPtr.pointee.tlsContext = context
        }
        workerPtr.pointee.signalFD = controlFD

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
        if config.redirectHTTPPort != 0 {
            let fd = pg_listen_tcp(config.host, config.redirectHTTPPort, config.backlog, 1,
                                   config.ipv6Only ? 1 : 0)
            if fd < 0 {
                let e = pg_errno()
                Log.error { line in
                    line.str("cannot listen on the --redirect-http port: ")
                    line.cstr(pg_strerror(e))
                }
                return nil
            }
            workerPtr.pointee.redirectFD = fd
        }
        if config.http3Enabled {
            guard let listener = makeQUICListener(config) else { return nil }
            workerPtr.pointee.quic = listener
        }

        guard workerPtr.pointee.registerListener() else { return nil }
        guard workerPtr.pointee.registerMetricsListener() else { return nil }
        guard workerPtr.pointee.registerRedirectListener() else { return nil }
        guard workerPtr.pointee.registerQUIC() else { return nil }
        return workerPtr
    }

    /// The write end of the readiness pipe, in a worker process.
    nonisolated(unsafe) static var readyPipeFD: Int32 = -1

    static func signalReady() {
        guard readyPipeFD >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { raw in
            pg_write(readyPipeFD, raw.baseAddress!, 1)
        }
        _ = pg_close(readyPipeFD)
        readyPipeFD = -1
    }

    static func logReady(_ config: ServerConfig) {
        signalReady()
        Log.info { line in
            line.str("worker ready on ")
            line.cstr(config.unixPath ?? config.host)
            if config.unixPath == nil {
                line.str(":")
                line.int(Int(config.port))
            }
        }
    }

    static func runWorker(_ config: ServerConfig, listenFD: Int32,
                          index: Int = 0, metricsSlot: Int = 0) -> Bool {
        guard let workerPtr = makeWorker(config, listenFD: listenFD,
                                         controlFD: pg_signal_pipe_init(),
                                         metricsSlot: metricsSlot) else {
            return false
        }
        // Before the worker reports ready, so that a reload does not retire
        // the worker this one replaces until its start-up hook has returned.
        // A signal that arrives meanwhile waits in the pipe for the loop.
        application?.pointee.onStart?(index)
        logReady(config)
        runSynchronousLoop(workerPtr)
        // The loop ends once in-flight requests have finished or the grace
        // period has; the exit watchdog armed at the drain bounds this too.
        application?.pointee.onShutdown?(index)
        workerPtr.pointee.destroy()
        currentWorker = nil
        return true
    }

    static func runSynchronousLoop(_ worker: UnsafeMutablePointer<Worker>) {
        while worker.pointee.running {
            let timeout = worker.pointee.quicPollTimeout(200)
            let n = worker.pointee.poller.wait(timeoutMillis: timeout)
            if n > 0 { worker.pointee.processEvents(n) }
            worker.pointee.fireDueTimers()
            worker.pointee.drainReadyQueue()
            worker.pointee.quicTick()
            worker.pointee.sweepTimeouts()
            if worker.pointee.draining && worker.pointee.quiescent {
                worker.pointee.running = false
            }
        }
    }
}
