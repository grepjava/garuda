//===----------------------------------------------------------------------===//
// Work a worker does on a timer rather than for a request: clearing what has
// expired, refreshing a cache, sending what a queue has collected.
//
//     // Every worker, every five minutes.
//     app.every(300) { start in
//         try await start.state(Caches.self).refresh()
//     }
//
//     // One worker, hourly: housekeeping nobody needs done four times.
//     app.every(3600, onWorker: 0) { start in
//         try await SQLiteRefreshTokenStore(start.state(SQLiteDatabase.self)).deleteExpired()
//     }
//
// The job runs on the worker's own thread, as a handler does, so it may use
// the same pools and the same state. It starts once the worker is serving,
// waits out the interval between runs, and stops when the worker drains. A
// job that throws is logged and runs again at its next turn: a database that
// was down is not a reason to stop cleaning up for good.
//
// Two things to keep in mind, both from a worker being a process:
//
// - **A job runs in every worker.** Four workers means four runs. That is what
//   is wanted for a per-process cache and not for housekeeping, and
//   `onWorker: 0` is the short answer for the latter.
// - **`onWorker: 0` is not "once in the cluster"** across machines, or across
//   a reload, where a new worker 0 replaces the old one. For work that must
//   happen once however many processes are running, take a lock in the
//   database: `select pg_try_advisory_lock(...)`, or a Redis `SET NX` with an
//   expiry.
//
// `jitter` spreads the runs of a job across its workers, so four of them do
// not query at the same instant: the wait is the interval, give or take that
// fraction of it.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// A job an application asked to have run on a timer.
struct ScheduledJob {
    let interval: Double
    let jitter: Double
    let firstAfter: Double?
    /// The only worker that runs it, or nil for every worker.
    let worker: Int?
    let work: @Sendable (WorkerStartup) async throws -> Void

    /// Milliseconds to wait, the interval give or take `jitter` of it.
    func delay(first: Bool) -> UInt64 {
        let base = first ? (firstAfter ?? interval) : interval
        guard jitter > 0 else { return UInt64(max(1, base * 1000)) }
        // A fraction either way, from two random bytes.
        let bytes = randomBytes(2)
        let fraction = Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / Double(UInt16.max)
        let offset = (fraction * 2 - 1) * base * jitter
        return UInt64(max(1, (base + offset) * 1000))
    }
}

extension Application {
    /// Runs `work` every `interval` seconds in each worker, from the moment
    /// that worker starts serving until it drains.
    ///
    /// - Parameters:
    ///   - interval: seconds between runs.
    ///   - jitter: how much to spread the runs of the same job across
    ///     workers, as a fraction of `interval`. 0.1 by default, so the wait
    ///     is the interval give or take a tenth.
    ///   - firstAfter: seconds before the first run, when it should not be a
    ///     whole interval.
    ///   - onWorker: the only worker index that runs it, or nil for all of
    ///     them. Read the caveat above before using it for housekeeping.
    ///   - work: what to run, given the worker and its state. A throw is
    ///     logged, and the job runs again next turn.
    public func every(_ interval: Double, jitter: Double = 0.1, firstAfter: Double? = nil,
                      onWorker: Int? = nil,
                      _ work: @escaping @Sendable (_ start: WorkerStartup) async throws -> Void) {
        precondition(compiled == nil, "a scheduled job added after the application was compiled")
        precondition(interval > 0, "a scheduled job runs at a positive interval")
        precondition(jitter >= 0 && jitter < 1, "jitter is a fraction of the interval, 0 to just under 1")
        precondition(firstAfter == nil || firstAfter! >= 0, "the first run cannot be in the past")
        scheduledJobs.append(ScheduledJob(interval: interval, jitter: jitter, firstAfter: firstAfter,
                                          worker: onWorker, work: work))
    }
}

extension GarudaRuntime {
    /// Starts the application's scheduled jobs on this worker. Each is a task
    /// that waits, runs, and waits again until the worker drains.
    static func startScheduledJobs(_ worker: UnsafeMutablePointer<Worker>, index: Int, jobs: [ScheduledJob]) {
        guard !jobs.isEmpty else { return }
        let pool = worker.pointee.handlerTasks ?? worker.pointee.makeHandlerTasks()
        let running = worker.pointee.scheduled ?? ScheduledJobs()
        worker.pointee.scheduled = running
        for job in jobs where job.worker == nil || job.worker == index {
            running.live += 1
            let carried = Unsafely((worker: worker, job: job))
            let task = Task(executorPreference: pool.executor) {
                defer { running.live -= 1 }
                let me = carried.value.worker
                let job = carried.value.job
                var first = true
                while !Task.isCancelled, me.pointee.running, !me.pointee.draining {
                    let slept = await sleepInSlices(me, milliseconds: job.delay(first: first))
                    first = false
                    guard slept, !Task.isCancelled, me.pointee.running, !me.pointee.draining else { break }
                    do {
                        try await job.work(WorkerStartup(index: index, worker: me))
                    } catch {
                        let description = String(describing: error)
                        Log.error { line in
                            line.str("a scheduled job failed: ")
                            description.withCString { line.cstr($0) }
                        }
                    }
                }
            }
            running.tasks.append(task)
        }
    }

    /// Waits in slices, so a drain is noticed in a fraction of a second even
    /// when the next run is an hour away. False means stop.
    private static func sleepInSlices(_ worker: UnsafeMutablePointer<Worker>, milliseconds: UInt64) async -> Bool {
        var left = milliseconds
        while left > 0 {
            guard !Task.isCancelled, worker.pointee.running, !worker.pointee.draining else { return false }
            let slice = min(left, 200)
            if await Worker.waitTimed(worker, milliseconds: slice, register: { _ in }) == .cancelled {
                return false
            }
            left -= slice
        }
        return true
    }

    /// Stops the jobs and lets them unwind, before the state they use goes.
    /// A job parked in a slice wakes within 200 ms; one running now has until
    /// the deadline to reach its next await and see the cancellation.
    static func stopScheduledJobs(_ worker: UnsafeMutablePointer<Worker>, turn: () -> Void) {
        guard let running = worker.pointee.scheduled, running.live > 0 else { return }
        for task in running.tasks { task.cancel() }
        running.tasks.removeAll()
        let deadline = av_monotonic_us() &+ 2_000_000
        while running.live > 0, av_monotonic_us() < deadline {
            turn()
        }
        if running.live > 0 {
            Log.warn("a scheduled job did not stop in time; it is left where it is")
        }
        worker.pointee.scheduled = nil
    }
}

/// The scheduled jobs of one worker: their tasks, and how many are still
/// running. Read and written only on that worker's thread.
final class ScheduledJobs: @unchecked Sendable {
    var tasks: [Task<Void, Never>] = []
    var live = 0
}
