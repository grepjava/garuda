//===----------------------------------------------------------------------===//
// Work a shard does on a timer rather than for a request: clearing what has
// expired, refreshing a cache, sending what a queue has collected.
//
//     // Every shard, every five minutes.
//     app.every(.seconds(300)) { shard in
//         try await shard.state(Caches.self).refresh()
//     }
//
//     // One shard, hourly: housekeeping nobody needs done four times.
//     app.every(.seconds(3600), onShard: 0) { shard in
//         try await SQLiteRefreshTokenStore(shard.state(SQLiteDatabase.self)).deleteExpired()
//     }
//
// A job is a task on the shard's runtime, so it may use the same pools and
// the same state as the handlers. It starts once the shard's state is built,
// waits out the interval between runs, and is cancelled when the shard stops,
// before its state is shut down. A job that throws is logged and runs again
// at its next turn: a database that was down is not a reason to stop cleaning
// up for good.
//
// Two things to keep in mind, both from a shard being a process:
//
// - **A job runs in every shard.** Four shards means four runs. That is what
//   is wanted for a per-process cache and not for housekeeping, and
//   `onShard: 0` is the short answer for the latter.
// - **`onShard: 0` is not "once in the cluster"** across machines, or across
//   a restart, where a new shard 0 replaces the old one. For work that must
//   happen once however many processes are running, take a lock in the
//   database: `select pg_try_advisory_lock(...)`, or a Redis `SET NX` with an
//   expiry.
//
// `jitter` spreads the runs of a job across its shards, so four of them do
// not query at the same instant: the wait is the interval, give or take that
// fraction of it.
//===----------------------------------------------------------------------===//

import Synchronization
import Vega

/// A job an application asked to have run on a timer.
struct ScheduledJob: Sendable {
    let interval: Duration
    let jitter: Double
    let firstAfter: Duration?
    /// The only shard that runs it, or nil for every shard.
    let shard: Int?
    let work: @Sendable (ShardContext) async throws -> Void

    /// The wait before a run: the interval, give or take `jitter` of it.
    func delay(first: Bool) -> Duration {
        let base = first ? (firstAfter ?? interval) : interval
        guard jitter > 0 else { return base }
        return base * (1 + Double.random(in: -jitter...jitter))
    }
}

extension Application {
    /// Runs `work` every `interval` in each shard, from the moment its state
    /// is built until it stops.
    ///
    /// - Parameters:
    ///   - interval: the time between runs.
    ///   - jitter: how much to spread the runs of the same job across
    ///     shards, as a fraction of `interval`. 0.1 by default, so the wait
    ///     is the interval give or take a tenth.
    ///   - firstAfter: the wait before the first run, when it should not be a
    ///     whole interval.
    ///   - onShard: the only shard index that runs it, or nil for all of
    ///     them. Read the caveat above before using it for housekeeping.
    ///   - work: what to run, given the shard and its state. A throw is
    ///     logged, and the job runs again next turn.
    public func every(_ interval: Duration, jitter: Double = 0.1, firstAfter: Duration? = nil,
                      onShard: Int? = nil,
                      _ work: @escaping @Sendable (_ shard: ShardContext) async throws -> Void) {
        precondition(compiledApplication == nil, "a scheduled job added after the application was compiled")
        precondition(interval > .zero, "a scheduled job runs at a positive interval")
        precondition(jitter >= 0 && jitter < 1, "jitter is a fraction of the interval, 0 to just under 1")
        precondition(firstAfter == nil || firstAfter! >= .zero, "the first run cannot be in the past")
        scheduledJobs.append(ScheduledJob(interval: interval, jitter: jitter, firstAfter: firstAfter,
                                          shard: onShard, work: work))
    }
}

/// A shard's running jobs, and how many have not yet returned.
final class ScheduledRun: Sendable {
    let tasks = Mutex<[Task<Void, Never>]>([])
    let live = Atomic<Int>(0)
}

extension CompiledApplication {
    /// Starts this shard's jobs, each a task that waits, runs, and waits
    /// again until it is cancelled.
    func startScheduledJobs(_ context: ShardContext) {
        let mine = scheduledJobs.filter { $0.shard == nil || $0.shard == context.shard.index }
        guard !mine.isEmpty else { return }
        let run = scheduled
        run.live.add(mine.count, ordering: .relaxed)
        let tasks = mine.map { job in
            Runtime.spawn {
                defer { run.live.subtract(1, ordering: .releasing) }
                var first = true
                while !Task.isCancelled {
                    do {
                        try await Runtime.sleep(for: job.delay(first: first))
                    } catch {
                        return
                    }
                    first = false
                    do {
                        try await job.work(context)
                    } catch {
                        if Task.isCancelled { return }
                        Log.error("a scheduled job failed: \(error)")
                    }
                }
            }
        }
        run.tasks.withLock { $0 = tasks }
    }

    /// Stops the jobs and lets them unwind, before the state they use goes.
    /// A job waiting wakes at once; one running has two seconds to reach its
    /// next await and see the cancellation.
    func stopScheduledJobs() async {
        let tasks = scheduled.tasks.withLock { tasks in
            let all = tasks
            tasks = []
            return all
        }
        guard !tasks.isEmpty else { return }
        for task in tasks { task.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while scheduled.live.load(ordering: .acquiring) > 0 && ContinuousClock.now < deadline {
            try? await Runtime.sleep(for: .milliseconds(5))
        }
        if scheduled.live.load(ordering: .acquiring) > 0 {
            Log.warning("a scheduled job did not stop in time; it is left where it is")
        }
    }
}
