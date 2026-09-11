//===----------------------------------------------------------------------===//
// Workers as threads: --free-threaded.
//
// Peregrine's default concurrency unit is a process, for the reason every
// Python server has used processes: a GIL makes a second thread useless for
// serving requests, so the only way to use a second core is a second
// interpreter, and the only way to get a second interpreter is a second
// process. CPython 3.13 introduced a build without the GIL (PEP 703) and that
// premise stops holding. `--free-threaded` is the option that says so.
//
// What changes is one level of the hierarchy and nothing else. A worker still
// owns its own poller, its own connection slab, its own buffer pool and its own
// event loop; it simply lives in a thread rather than in a process. Nothing
// above the transport learns that it has company, because nothing above the
// transport ever reaches outside its own worker:
//
//   * `currentWorker` is a thread-local, so a `send`/`receive` callback landing
//     from Python finds the worker belonging to the thread it runs on;
//   * the ASGI event loop, scope builder and header caches moved onto Worker,
//     so there is one of each per thread and no shared mutable state between
//     them;
//   * everything that is genuinely process-wide -- the interned constants, the
//     internal Python types, the glue functions, the application object -- is
//     written once before any worker thread starts and only read afterwards.
//
// What is genuinely shared is the application, and that is the point. One
// import, one set of module-level caches, one warm JIT -- instead of N copies
// with N times the resident memory.
//
// What is not shared is the ASGI lifespan. It is tempting to run it once, since
// there is one application, and that is what this did at first; it is wrong.
// `startup` is where an application builds asyncio objects, and an asyncio
// object binds to the loop that was running when it was created. A pool built
// on the supervising thread's loop and awaited from a worker's loop is the
// "attached to a different loop" bug, when it fails loudly at all. So the
// lifespan follows the loop: one per worker by default, each publishing its own
// `state` mapping to the scopes that loop serves. `--lifespan-scope process`
// asks for the other reading -- exactly one `startup` -- and is right only for
// applications whose start-up opens nothing loop-bound.
//
// Structure of the process:
//
//   main thread          worker thread 0     worker thread 1     ...
//   -----------          ---------------     ---------------
//   interpreter, app
//   spawn --------------> poller, slab       poller, slab
//   signal pipe           event loop         event loop
//   (asyncio loop         lifespan startup   lifespan startup
//    watching signals)      (serialised)       (serialised)
//                         serving            serving
//   SIGTERM ------------> drain              drain
//                         lifespan shutdown  lifespan shutdown
//   join <--------------- exit               exit
//
// The main thread is not a worker. It costs one mostly-idle thread and buys the
// ordering that matters: signals are delivered somewhere that is not in the
// middle of serving a request.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineASGI
import PeregrineCore
import PeregrinePython
import PeregrineWSGI

// MARK: - Group

/// The worker threads and the bookkeeping the main thread stops them through.
///
/// A class, with a mutex, on purpose: this is start-up and shutdown, one
/// interaction per worker for the life of the process, and clarity is worth
/// more here than the reference counting is worth avoiding.
final class WorkerGroup {
    private let mutex: OpaquePointer
    /// Held across one worker's lifespan startup, and never together with
    /// `mutex`, so that polling the counters below never waits on an
    /// application's `startup`.
    private let startupMutex: OpaquePointer
    private var readyCount = 0
    private var failedCount = 0
    private var doneCount = 0

    let count: Int
    var members: [WorkerThread] = []

    init?(count: Int) {
        guard let m = pg_mutex_new() else { return nil }
        guard let s = pg_mutex_new() else { pg_mutex_free(m); return nil }
        self.mutex = m
        self.startupMutex = s
        self.count = count
    }

    deinit {
        pg_mutex_free(mutex)
        pg_mutex_free(startupMutex)
    }

    /// Runs one worker's lifespan startup with no other worker inside its own.
    ///
    /// Every worker thread calls `startup` on the same application object, and
    /// on a free-threaded interpreter those calls genuinely overlap. Application
    /// start-up code has never had to be thread-safe -- it ran once per process
    /// everywhere else -- so it is serialised here. This is start-up; the
    /// serialisation costs nothing that matters.
    func withStartupLock<T>(_ body: () -> T) -> T {
        pg_mutex_lock(startupMutex)
        defer { pg_mutex_unlock(startupMutex) }
        return body()
    }

    /// Every worker has either started serving or given up trying.
    var settled: Bool {
        pg_mutex_lock(mutex)
        defer { pg_mutex_unlock(mutex) }
        return readyCount + failedCount >= count
    }

    var failed: Int {
        pg_mutex_lock(mutex)
        defer { pg_mutex_unlock(mutex) }
        return failedCount
    }

    /// Every worker thread has returned from its loop.
    var allDone: Bool {
        pg_mutex_lock(mutex)
        defer { pg_mutex_unlock(mutex) }
        return doneCount + failedCount >= count
    }

    func markReady() {
        pg_mutex_lock(mutex)
        readyCount += 1
        pg_mutex_unlock(mutex)
    }

    func markFailed() {
        pg_mutex_lock(mutex)
        failedCount += 1
        pg_mutex_unlock(mutex)
    }

    func markDone() {
        pg_mutex_lock(mutex)
        doneCount += 1
        pg_mutex_unlock(mutex)
    }

    /// Asks every worker to drain, by putting a signal number down the pipe it
    /// already polls. A worker cannot be interrupted with a real signal -- its
    /// signal mask is full, deliberately -- so this is how it is told.
    func requestDrain() {
        for member in members { member.requestDrain() }
    }

    func joinAll() {
        for member in members { member.join() }
    }
}

/// One worker thread: the descriptors it owns and the handle to join it by.
final class WorkerThread {
    let index: Int
    let config: ServerConfig
    let loaded: Peregrine.LoadedApplication
    let listenFD: Int32
    /// The worker polls the read end; the main thread holds the write end.
    let controlRead: Int32
    let controlWrite: Int32
    unowned let group: WorkerGroup
    /// Under `.once`, the `state` mapping the one process-wide lifespan
    /// published; under `.perWorker` this stays nil and the thread runs a
    /// lifespan of its own.
    var sharedLifespanState: PyObj? = nil
    private var handle: OpaquePointer? = nil

    init?(index: Int, config: ServerConfig, loaded: Peregrine.LoadedApplication,
          listenFD: Int32, group: WorkerGroup) {
        var fds: (Int32, Int32) = (-1, -1)
        let rc = withUnsafeMutableBytes(of: &fds) { raw in
            pg_pipe(raw.baseAddress!.assumingMemoryBound(to: Int32.self))
        }
        if rc != 0 {
            Log.error("cannot create the worker control pipe")
            return nil
        }
        self.index = index
        self.config = config
        self.loaded = loaded
        self.listenFD = listenFD
        self.controlRead = fds.0
        self.controlWrite = fds.1
        self.group = group
    }

    func start() -> Bool {
        let arg = Unmanaged.passUnretained(self).toOpaque()
        guard let h = pg_thread_start(workerThreadEntry, arg) else {
            Log.error("cannot start a worker thread")
            return false
        }
        handle = h
        return true
    }

    func requestDrain() {
        var byte = UInt8(SIGTERM)
        _ = withUnsafeBytes(of: &byte) { raw in
            pg_write(controlWrite, raw.baseAddress!, 1)
        }
    }

    func join() {
        guard let h = handle else { return }
        handle = nil
        pg_thread_join(h)
    }

    /// The body of the thread. Everything here is this thread's own.
    fileprivate func run() {
        // A fresh OS thread has no interpreter thread state. On a free-threaded
        // build this attaches one without taking any lock; the name is a relic
        // of the interpreter it was written for.
        let state = pg_gil_ensure()

        guard let workerPtr = Peregrine.makeWorker(config, listenFD: listenFD,
                                                   controlFD: controlRead,
                                                   loaded: loaded,
                                                   metricsSlot: index) else {
            currentWorker = nil
            group.markFailed()
            pg_gil_release(state)
            return
        }
        // The process, not this thread, decides when it is over: the drain here
        // is followed by a join on the main thread.
        workerPtr.pointee.ownsExitWatchdog = false

        /// Gives back everything this thread has taken and reports the failure,
        /// so that start-up ends as one clear error rather than a server that
        /// came up with fewer workers than it was asked for.
        func abandon(_ what: StaticString) {
            Log.error(what)
            workerPtr.pointee.destroy()
            workerPtr.deinitialize(count: 1)
            workerPtr.deallocate()
            currentWorker = nil
            group.markFailed()
            pg_gil_release(state)
        }

        if loaded.proto == .asgi {
            guard let loop = ASGIRuntime.makeLoop(config) else {
                abandon("could not create the event loop for a worker thread")
                return
            }

            // The lifespan belongs to the loop that will await what it opened.
            // Under `.perWorker` that is this loop, and this thread runs the
            // handshake itself; under `.once` it already ran on the supervising
            // thread and this worker only inherits the state mapping.
            var scopeState = sharedLifespanState
            var ownsScopeState = false
            if config.lifespanScope == .perWorker {
                guard let ls = group.withStartupLock({
                    ASGIRuntime.startLifespan(app: loaded.app, loop: loop, config: config)
                }) else {
                    abandon("lifespan startup failed on a worker thread")
                    return
                }
                // This worker's own lifespan, shut down on this loop once this
                // worker has drained -- not on the main thread, and not while
                // another worker is still serving from a pool of its own.
                workerPtr.pointee.asgiLifespan = ls.driver
                scopeState = ls.state
                ownsScopeState = true
            }

            let prepared = ASGIRuntime.prepareWorker(workerPtr, config: config, loop: loop,
                                                     lifespanState: scopeState)
            // The scope builder holds a reference of its own now.
            if ownsScopeState, let st = scopeState { pg_decref(st) }
            guard prepared else {
                abandon("could not prepare the ASGI runtime for a worker thread")
                return
            }
        }

        group.markReady()

        if loaded.proto == .wsgi {
            Peregrine.runSynchronousLoop(workerPtr)
        } else {
            ASGIRuntime.runLoop(workerPtr)
        }

        workerPtr.pointee.destroy()
        workerPtr.deinitialize(count: 1)
        workerPtr.deallocate()
        currentWorker = nil
        group.markDone()
        pg_gil_release(state)
    }
}

/// Thread entry point. Top level because a `@convention(c)` function cannot
/// capture, and the worker is reached through the pointer instead.
private func workerThreadEntry(_ raw: UnsafeMutableRawPointer?) {
    guard let raw else { return }
    Unmanaged<WorkerThread>.fromOpaque(raw).takeUnretainedValue().run()
}

// MARK: - Supervising thread

/// The shutdown state the main thread keeps while the workers serve.
///
/// In ASGI mode this is reached from Python callbacks, which carry a 64-bit
/// context word and nothing else, so the instance is addressed by pointer.
final class ThreadSupervisor {
    let group: WorkerGroup
    let config: ServerConfig
    let signalFD: Int32
    /// The main thread's own event loop in ASGI mode: it watches the signal
    /// pipe and keeps running while the workers drain. Under
    /// `--lifespan-scope process` it also hosts the one lifespan.
    var loop: PyObj? = nil
    var lifespan: PyObj? = nil
    var timerCallback: PyObj? = nil

    var shuttingDown = false
    /// When a drain that is taking too long stops being a drain.
    var deadline: UInt64 = 0

    init(group: WorkerGroup, config: ServerConfig, signalFD: Int32) {
        self.group = group
        self.config = config
        self.signalFD = signalFD
    }

    /// Reads whatever the signal handler put down the pipe.
    func readSignals() {
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        while true {
            let n = withUnsafeMutableBytes(of: &buf) { raw in
                pg_read(signalFD, raw.baseAddress!, 8)
            }
            if n <= 0 { break }
            withUnsafeBytes(of: &buf) { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(n) {
                    switch Int32(p[i]) {
                    case SIGTERM, SIGINT, SIGQUIT:
                        beginShutdown()
                    default:
                        break
                    }
                }
            }
        }
    }

    func beginShutdown() {
        if shuttingDown { return }
        shuttingDown = true
        Log.info("shutting down; draining workers")
        group.requestDrain()
        deadline = pg_monotonic_ms() &+ config.gracefulShutdownMs &+ 2_000
        // Same reasoning as a worker's own watchdog: every deadline below this
        // one is cooperative, and a thread wedged inside a C extension cannot be
        // cancelled at all. This one fires from a signal handler and _exit()s.
        // The margin has to cover the drain, the join, the lifespan shutdown and
        // interpreter finalisation.
        let margin = config.gracefulShutdownMs / 1000 &+ 15
        pg_exit_after(UInt32(truncatingIfNeeded: margin), 0)
    }

    /// True once there is nothing left to wait for.
    var finished: Bool {
        guard shuttingDown else { return false }
        if group.allDone { return true }
        if deadline > 0 && pg_monotonic_ms() > deadline {
            Log.warn("worker threads did not drain within the grace period")
            return true
        }
        return false
    }
}

private func supervisorSignalCallback(_ context: UInt64, _ args: PyObj?) -> PyObj? {
    guard let p = UnsafeRawPointer(bitPattern: UInt(context)) else { return nil }
    Unmanaged<ThreadSupervisor>.fromOpaque(p).takeUnretainedValue().readSignals()
    return nil
}

private func supervisorTimerCallback(_ context: UInt64, _ args: PyObj?) -> PyObj? {
    guard let p = UnsafeRawPointer(bitPattern: UInt(context)) else { return nil }
    let sup = Unmanaged<ThreadSupervisor>.fromOpaque(p).takeUnretainedValue()
    guard let loop = sup.loop else { return nil }
    if sup.finished || (!sup.shuttingDown && sup.group.allDone) {
        if let r = pg_call1(ASGIRuntime.fnStopLoop, loop) { pg_decref(r) } else { pg_err_clear() }
        return nil
    }
    if let r = pg_call2(ASGIRuntime.fnArmTimer, loop, sup.timerCallback) {
        pg_decref(r)
    } else {
        pg_err_clear()
    }
    return nil
}

// MARK: - Entry point

extension Peregrine {

    /// Runs `workers` workers as threads of this process.
    ///
    /// `inherited` is a listening descriptor created elsewhere -- a unix socket
    /// bound by the supervisor, which can only be bound once -- or -1, in which
    /// case each worker opens a TCP listener of its own with `SO_REUSEPORT` and
    /// gets an independent accept queue, exactly as a worker process does.
    static func runFreeThreaded(_ config: ServerConfig,
                                workers: Int,
                                inherited: Int32) -> Bool {
        let count = max(1, workers)

        if pg_py_free_threaded() == 0 {
            Log.error { line in
                line.str("--free-threaded needs a free-threaded CPython (PEP 703); this one is ")
                line.cstr(pg_py_runtime_version())
            }
            Log.error("build against python3.13t or newer, or drop --free-threaded")
            return false
        }

        guard let loaded = bootInterpreter(config) else { return false }

        // --- process-wide ASGI setup, before any worker ---
        var mainLoop: PyObj? = nil
        var lifespan: PyObj? = nil
        var sharedState: PyObj? = nil
        if loaded.proto == .asgi {
            guard ASGIRuntime.prepareProcess(app: loaded.app, config: config) else {
                Log.error("could not prepare the ASGI runtime")
                return false
            }
            // The supervising thread needs a loop whether or not a lifespan
            // runs on it: it is how the signal pipe is watched.
            guard let l = ASGIRuntime.makeLoop(config) else { return false }
            mainLoop = l
            if config.lifespanScope == .once {
                // One handshake, on a loop that serves no requests. Whatever it
                // opened is therefore bound to a loop no worker awaits on --
                // safe only for resources that are not loop-bound, which is why
                // this is not the default.
                guard let ls = ASGIRuntime.startLifespan(app: loaded.app, loop: l,
                                                         config: config) else {
                    return false
                }
                lifespan = ls.driver
                // Held for the life of the process: worker threads take their
                // own reference as they build their scopes, and they do that
                // after this function has moved on.
                sharedState = ls.state
            }
        }

        // Importing the application -- or uvloop, which `makeLoop` pulls in by
        // default -- can turn the GIL back on: an extension that has not
        // declared itself free-threading-safe re-enables it as it is imported,
        // and so does PYTHON_GIL=1. The threads below still work in that case
        // -- they just stop running in parallel, which is the one thing the
        // option was asked for, so say so rather than quietly serving at a
        // fraction of the expected rate. The check is after both imports.
        if pg_py_gil_active() != 0 {
            Log.warn("the GIL is enabled on this free-threaded interpreter, so worker")
            Log.warn("threads will not run in parallel; an extension module imported by")
            Log.warn("the application or the event loop re-enabled it, or PYTHON_GIL=1 is set")
        }

        guard let group = WorkerGroup(count: count) else { return false }

        // A unix path can only be bound once, so it is bound once here and every
        // worker accepts on the same descriptor. They contend for it, which is
        // the cost of a listener that cannot be duplicated -- letting each
        // worker bind for itself would have each one unlink and replace the
        // socket the last had just published, leaving one worker reachable.
        var sharedUnixFD = inherited
        if sharedUnixFD < 0 && config.unixPath != nil {
            guard let opened = openListener(config, reusePort: false, unlinkStale: true) else {
                return false
            }
            sharedUnixFD = opened
        }

        for index in 0..<count {
            let fd: Int32
            if sharedUnixFD >= 0 {
                fd = sharedUnixFD
            } else {
                // TCP: one socket per worker with SO_REUSEPORT, so each gets an
                // independent accept queue, exactly as a worker process does.
                guard let opened = openListener(config, reusePort: true,
                                                unlinkStale: false) else {
                    return false
                }
                fd = opened
            }
            guard let member = WorkerThread(index: index, config: config, loaded: loaded,
                                            listenFD: fd, group: group) else {
                return false
            }
            member.sharedLifespanState = sharedState
            group.members.append(member)
        }

        // The signal pipe belongs to this thread. Worker threads are started
        // with every signal blocked, so a signal cannot be delivered on top of a
        // request being served.
        let signalFD = pg_signal_pipe_init()
        let supervisor = ThreadSupervisor(group: group, config: config, signalFD: signalFD)
        supervisor.loop = mainLoop
        supervisor.lifespan = lifespan

        for member in group.members {
            if member.start() { continue }
            // Whatever did start is already serving, so it has to be stopped
            // rather than abandoned: coming up with fewer workers than asked for
            // is not a degraded mode anyone requested.
            group.requestDrain()
            group.joinAll()
            return false
        }

        // Wait for the workers to report in, so that a failure to bind or to
        // build a scope is one clear error at start-up rather than a server that
        // silently came up with fewer workers than it was asked for.
        while !group.settled {
            let saved = pg_gil_save()
            _ = pg_poll_single(signalFD, 0, 10)
            pg_gil_restore(saved)
        }
        if group.failed > 0 {
            Log.error("a worker thread failed to start")
            group.requestDrain()
            group.joinAll()
            return false
        }

        logReady(config, proto: loaded.proto, threads: count)

        if loaded.proto == .asgi {
            superviseWithLoop(supervisor)
        } else {
            superviseSynchronously(supervisor)
        }

        group.joinAll()

        // Under `.perWorker` each worker has already drained its connections and
        // run its own lifespan shutdown on its own loop, in that order, before
        // the join above returned; `lifespan` is nil and this only closes the
        // supervising loop. Under `.once` this is the one shutdown, and it runs
        // here rather than earlier because no worker holds a connection any
        // more -- the application's pool is not pulled out from under a request
        // still finishing on another thread.
        if let l = mainLoop {
            ASGIRuntime.finishLoop(l, lifespan: lifespan)
        }
        Log.info("worker threads stopped")
        Interpreter.finalize()
        return true
    }

    /// ASGI: the main thread runs an event loop of its own, watching the signal
    /// pipe the same way a worker watches its poller -- `add_reader` on a
    /// descriptor -- and hosting the lifespan while the workers drain.
    private static func superviseWithLoop(_ supervisor: ThreadSupervisor) {
        guard let loop = supervisor.loop else { return }
        let context = UInt64(UInt(bitPattern: Unmanaged.passUnretained(supervisor).toOpaque()))

        guard let onSignal = PyTrampoline.make(supervisorSignalCallback, context: context),
              let onTimer = PyTrampoline.make(supervisorTimerCallback, context: context) else {
            PyError.logPending("creating the supervisor callbacks")
            return
        }
        defer { pg_decref(onSignal); pg_decref(onTimer) }
        supervisor.timerCallback = onTimer

        if let r = pg_call2(ASGIRuntime.fnArmTimer, loop, onTimer) {
            pg_decref(r)
        } else {
            pg_err_clear()
        }

        guard let fdObj = pg_int(Int(supervisor.signalFD)) else { return }
        defer { pg_decref(fdObj) }
        if let r = pg_call3(ASGIRuntime.fnRunLoop, loop, fdObj, onSignal) {
            pg_decref(r)
        } else {
            PyError.logPending("running the supervising event loop")
        }
        supervisor.timerCallback = nil
    }

    /// WSGI: no asyncio anywhere, so the main thread simply waits on the signal
    /// pipe. The interpreter thread state is released around the wait, because
    /// the workers need it and this thread has nothing to do with it.
    private static func superviseSynchronously(_ supervisor: ThreadSupervisor) {
        while !supervisor.finished {
            let saved = pg_gil_save()
            let ready = pg_poll_single(supervisor.signalFD, 0, 100)
            pg_gil_restore(saved)
            if ready > 0 { supervisor.readSignals() }
            // A worker that stops on its own -- every one of them failing to
            // accept, say -- must not leave this thread waiting for a signal
            // that is never coming.
            if !supervisor.shuttingDown && supervisor.group.allDone { return }
        }
    }
}
