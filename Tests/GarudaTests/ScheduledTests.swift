import Testing
import CAvian
import AvianCore
@testable import Garuda

// `app.every`: work a worker does on a timer.

private final class Runs: @unchecked Sendable {
    var count = 0
    var failures = 0
    var workers: [Int] = []
}

@Suite("Scheduled jobs", .serialized)
struct ScheduledTests {
    /// Turns the loop until `done` or `turns` have passed. A request is what
    /// drives a test client's loop, so a job needs one too.
    private func waitFor(_ client: TestClient, turns: Int = 2_000, _ done: () -> Bool) {
        for _ in 0..<turns {
            if done() { return }
            _ = try? client.get("/tick")
        }
    }

    @Test func aJobRunsAgainAndAgain() throws {
        let runs = Runs()
        let app = Application()
        app.get("/tick") { "tick" }
        app.every(0.01, jitter: 0) { start in
            runs.count += 1
            runs.workers.append(start.index)
        }
        let client = app.test
        waitFor(client) { runs.count >= 3 }
        #expect(runs.count >= 3, "\(runs.count)")
        #expect(runs.workers.allSatisfy { $0 == 0 })
    }

    @Test func aJobThatFailsRunsAgain() throws {
        let runs = Runs()
        let app = Application()
        app.get("/tick") { "tick" }
        app.every(0.01, jitter: 0) { _ in
            runs.failures += 1
            throw HTTPError(.internalServerError, "the database is down")
        }
        let client = app.test
        waitFor(client) { runs.failures >= 3 }
        #expect(runs.failures >= 3, "a throw is logged, not the end of the job: \(runs.failures)")
    }

    @Test func aJobForOneWorkerSkipsTheOthers() throws {
        let mine = Runs()
        let theirs = Runs()
        let app = Application()
        app.get("/tick") { "tick" }
        app.every(0.01, jitter: 0, onWorker: 0) { _ in mine.count += 1 }
        app.every(0.01, jitter: 0, onWorker: 3) { _ in theirs.count += 1 }
        let client = app.test
        waitFor(client) { mine.count >= 3 }
        #expect(mine.count >= 3)
        #expect(theirs.count == 0, "worker 3 is not this one")
    }

    @Test func theFirstRunCanComeSooner() throws {
        let runs = Runs()
        let app = Application()
        app.get("/tick") { "tick" }
        // An hour apart, but the first almost at once: what a warm-up wants.
        app.every(3600, jitter: 0, firstAfter: 0.01) { _ in runs.count += 1 }
        let client = app.test
        waitFor(client) { runs.count >= 1 }
        #expect(runs.count == 1, "\(runs.count)")
    }

    @Test func aJobReachesTheStateTheWorkerBuilt() throws {
        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let app = Application()
        app.state { _ in Counter() }
        app.get("/count") { (counter: State<Counter>) -> String in "\(counter.value.value)" }
        app.every(0.01, jitter: 0) { start in
            try start.state(Counter.self).value += 1
        }
        let client = app.test
        for _ in 0..<2_000 where (try? client.get("/count").text) == "0" {}
        #expect(try client.get("/count").text != "0")
    }

    @Test func jitterStaysWithinItsFraction() throws {
        let job = ScheduledJob(interval: 10, jitter: 0.1, firstAfter: nil, worker: nil, work: { _ in })
        for _ in 0..<200 {
            let delay = job.delay(first: false)
            #expect(delay >= 9_000 && delay <= 11_000, "\(delay)")
        }
        // No jitter is exactly the interval, and the first run can differ.
        let fixed = ScheduledJob(interval: 2, jitter: 0, firstAfter: 0.5, worker: nil, work: { _ in })
        #expect(fixed.delay(first: false) == 2_000)
        #expect(fixed.delay(first: true) == 500)
    }

    @Test func jobsStopWhenTheWorkerDrains() throws {
        let runs = Runs()
        let app = Application()
        app.get("/tick") { "tick" }
        app.every(0.01, jitter: 0) { _ in runs.count += 1 }
        let client = app.test
        waitFor(client) { runs.count >= 2 }
        let before = runs.count
        client.onWorker {
            client.worker.pointee.draining = true
            GarudaRuntime.stopScheduledJobs(client.worker) { client.turn() }
        }
        #expect(client.worker.pointee.scheduled == nil, "the jobs are gone")
        for _ in 0..<50 { client.turn() }
        #expect(runs.count <= before + 1, "\(before) then \(runs.count)")
    }
}
