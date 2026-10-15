import Synchronization
import Testing
@testable import Garuda
import GarudaTesting
import Vega

// `app.every`: work a shard does on a timer.

private final class Runs: Sendable {
    let count = Atomic<Int>(0)
    let shards = Mutex<Set<Int>>([])
    var value: Int { count.load(ordering: .relaxed) }
}

/// Waits, a little at a time, until `done` or five seconds have passed.
private func waitFor(_ done: () -> Bool) {
    let until = ContinuousClock.now + .seconds(5)
    while !done() && ContinuousClock.now < until {
        _ = try? ClientTestRuntime.shared.block { () async throws -> Int in
            try await Runtime.sleep(for: .milliseconds(5))
            return 0
        }
    }
}

@Suite("Scheduled jobs", .serialized)
struct ScheduledTests {
    /// The app, started: its state built and its jobs running.
    private func started(_ app: Application) throws -> TestClient {
        app.get("/tick") { _, response in response.send("tick") }
        let client = app.test
        #expect(try client.get("/tick").text == "tick")
        return client
    }

    @Test func aJobRunsAgainAndAgainInItsShard() throws {
        let runs = Runs()
        let app = Application()
        app.every(.milliseconds(10), jitter: 0) { shard in
            runs.count.add(1, ordering: .relaxed)
            runs.shards.withLock { _ = $0.insert(shard.shard.index) }
        }
        let client = try started(app)
        waitFor { runs.value >= 3 }
        #expect(runs.value >= 3)
        #expect(runs.shards.withLock { $0 } == [0])
        _ = client
    }

    @Test func aJobThatFailsRunsAgain() throws {
        let runs = Runs()
        let app = Application()
        app.every(.milliseconds(10), jitter: 0) { _ in
            runs.count.add(1, ordering: .relaxed)
            throw HTTPError(.internalServerError, "the database is down")
        }
        _ = try started(app)
        waitFor { runs.value >= 3 }
        #expect(runs.value >= 3, "a throw is logged, not the end of the job")
    }

    @Test func aJobForOneShardSkipsTheOthersAndTheFirstRunCanComeSooner() throws {
        let mine = Runs()
        let theirs = Runs()
        let app = Application()
        // An hour apart, but the first almost at once: what a warm-up wants.
        app.every(.seconds(3600), jitter: 0, firstAfter: .milliseconds(10), onShard: 0) { _ in
            mine.count.add(1, ordering: .relaxed)
        }
        app.every(.milliseconds(10), jitter: 0, onShard: 3) { _ in theirs.count.add(1, ordering: .relaxed) }
        _ = try started(app)
        waitFor { mine.value >= 1 }
        // Long enough for the other job, were it this shard's, to run.
        _ = try ClientTestRuntime.shared.block { () async throws -> Int in
            try await Runtime.sleep(for: .milliseconds(50))
            return 0
        }
        #expect(mine.value == 1)
        #expect(theirs.value == 0, "shard 3 is not this one")
    }

    @Test func aJobReachesTheStateTheShardBuilt() throws {
        final class Counter: Sendable {
            let value = Atomic<Int>(0)
        }
        let app = Application()
        app.state { _ in Counter() }
        app.get("/count") { (counter: State<Counter>) -> String in "\(counter.value.value.load(ordering: .relaxed))" }
        app.every(.milliseconds(10), jitter: 0) { shard in
            try shard.state(Counter.self).value.add(1, ordering: .relaxed)
        }
        let client = app.test
        var seen = "0"
        waitFor {
            seen = (try? client.get("/count").text) ?? "0"
            return seen != "0"
        }
        #expect(seen != "0")
    }

    @Test func jitterStaysWithinItsFraction() {
        let job = ScheduledJob(interval: .seconds(10), jitter: 0.1, firstAfter: nil, shard: nil, work: { _ in })
        for _ in 0..<200 {
            let delay = job.delay(first: false)
            #expect(delay >= .seconds(9) && delay <= .seconds(11), "\(delay)")
        }
        // No jitter is exactly the interval, and the first run can differ.
        let fixed = ScheduledJob(interval: .seconds(2), jitter: 0, firstAfter: .milliseconds(500), shard: nil, work: { _ in })
        #expect(fixed.delay(first: false) == .seconds(2))
        #expect(fixed.delay(first: true) == .milliseconds(500))
    }

    @Test func jobsStopWhenTheShardStops() throws {
        let runs = Runs()
        let app = Application()
        app.every(.milliseconds(10), jitter: 0) { _ in runs.count.add(1, ordering: .relaxed) }
        _ = try started(app)
        waitFor { runs.value >= 2 }
        let compiled = app.compile()
        try ClientTestRuntime.shared.block { () async throws -> Int in
            await compiled.stopScheduledJobs()
            return 0
        }
        #expect(compiled.scheduled.live.load(ordering: .relaxed) == 0)
        let before = runs.value
        _ = try ClientTestRuntime.shared.block { () async throws -> Int in
            try await Runtime.sleep(for: .milliseconds(50))
            return 0
        }
        #expect(runs.value == before)
    }
}
