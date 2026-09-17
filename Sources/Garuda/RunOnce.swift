//===----------------------------------------------------------------------===//
// Running one piece of async work against an application's state, without
// serving anything: what a command-line task needs.
//
//     // starter migrate
//     try app.runOnce { start in
//         try await start.state(PostgresPool.self).migrate(migrations)
//     }
//
// A worker is built in this process with no listening socket, its `app.state`
// factories run, the work runs on that worker's own thread as a handler's
// would, and then the state is torn down. Nothing is accepted and no port is
// bound, so it is safe to run beside a server that is already up.
//
// `app.prepare` hooks are not run: the point of a one-off command is to do one
// thing. A migration that both the server and a command should run belongs in
// a function both call.
//
// The application cannot be served afterwards in the same process: its state
// has been built and torn down, and `run()` would compile it again. Use a
// fresh `Application` for each, as `starterApp(configuration:)` in the starter
// example does.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// Why a one-off command did not finish.
public enum RunOnceError: Error, Equatable, Sendable {
    /// The work threw. Its description, since the error itself cannot cross
    /// the worker that ran it.
    case failed(String)
    /// It outstayed `timeoutMilliseconds`.
    case timedOut
    case workerCouldNotBeBuilt(String)
}

extension Application {
    /// Runs `work` against this application's state on a worker of its own,
    /// then tears the state down.
    public func runOnce(timeoutMilliseconds: UInt64 = 5 * 60 * 1000,
                        _ work: @escaping (_ start: WorkerStartup) async throws -> Void) throws {
        precondition(timeoutMilliseconds > 0, "a one-off command needs time to run in")
        var configuration = ServerConfig()
        configuration.maxConnections = 4
        let client = OneOffWorker(application: self, configuration: configuration)
        defer { client.finish() }
        try client.run(work, timeoutMilliseconds: timeoutMilliseconds)
    }
}

/// A worker with nothing to listen on, for `runOnce`.
final class OneOffWorker {
    private let application: Application
    private let worker: UnsafeMutablePointer<Worker>
    private var built = false

    init(application: Application, configuration: ServerConfig) {
        av_ignore_sigpipe()
        guard let poller = Poller(maxEvents: 16) else {
            fatalError("cannot create a readiness poller for a one-off command")
        }
        self.application = application
        worker = UnsafeMutablePointer<Worker>.allocate(capacity: 1)
        worker.initialize(to: Worker(config: configuration, listenFD: -1, poller: poller))
        worker.pointee.application = application.compile()
        worker.pointee.pollsBroadcast = false
    }

    func run(_ work: @escaping (WorkerStartup) async throws -> Void, timeoutMilliseconds: UInt64) throws {
        let previous = currentWorker
        currentWorker = worker
        defer { currentWorker = previous }
        do {
            try worker.pointee.buildState(worker.pointee.application, index: 0)
            built = true
        } catch {
            throw RunOnceError.workerCouldNotBeBuilt(String(describing: error))
        }
        let outcome = OneOffOutcome()
        nonisolated(unsafe) let body = work
        nonisolated(unsafe) let me = worker
        let pool = worker.pointee.handlerTasks ?? worker.pointee.makeHandlerTasks()
        let task = Task(executorPreference: pool.executor) {
            do {
                try await body(WorkerStartup(index: 0, worker: me))
            } catch {
                outcome.failure = String(describing: error)
            }
            outcome.done = true
        }
        let deadline = av_monotonic_us() &+ max(1, timeoutMilliseconds) &* 1000
        while !outcome.done {
            if av_monotonic_us() >= deadline {
                task.cancel()
                throw RunOnceError.timedOut
            }
            turn()
        }
        if let failure = outcome.failure { throw RunOnceError.failed(failure) }
    }

    /// One turn of the loop: what the work is waiting on is the only thing
    /// this worker has.
    private func turn() {
        let n = worker.pointee.poller.wait(timeoutMillis: 10)
        if n > 0 { worker.pointee.processEvents(n) }
        worker.pointee.fireDueTimers()
        worker.pointee.drainReadyQueue()
        worker.pointee.runHandlerTasks()
        worker.pointee.sweepTimeouts()
    }

    func finish() {
        let previous = currentWorker
        currentWorker = worker
        if built { worker.pointee.tearDownState(worker.pointee.application) }
        worker.pointee.destroy()
        currentWorker = previous
        worker.deinitialize(count: 1)
        worker.deallocate()
    }
}

private final class OneOffOutcome: @unchecked Sendable {
    var done = false
    var failure: String? = nil
}
