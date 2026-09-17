import Testing
import CAvian
import AvianCore
@testable import Garuda

// `app.runOnce`: one piece of async work against an application's state, with
// nothing served -- a migration or a backfill run from the command line.

private final class Ledger: @unchecked Sendable {
    var entries: [String] = []
}

@Suite("One-off commands")
struct RunOnceTests {
    @Test func workRunsAgainstTheStateAndTearsItDown() throws {
        let ledger = Ledger()
        let app = Application()
        app.state { _ in ledger } shutdown: { $0.entries.append("torn down") }
        app.get("/") { "unused" }
        try app.runOnce { start in
            // Awaiting works: this is a worker, with its loop turning.
            _ = await Worker.waitTimed(currentWorker!, milliseconds: 5) { _ in }
            try start.state(Ledger.self).entries.append("migrated \(start.index)")
        }
        #expect(ledger.entries == ["migrated 0", "torn down"])
    }

    @Test func aPrepareHookIsNotRunByACommand() throws {
        let ledger = Ledger()
        let app = Application()
        app.state { _ in ledger }
        app.prepare { _ in ledger.entries.append("prepared") }
        try app.runOnce { start in try start.state(Ledger.self).entries.append("command") }
        #expect(ledger.entries == ["command"])
    }

    @Test func workThatFailsIsReported() throws {
        let app = Application()
        app.get("/") { "unused" }
        do {
            try app.runOnce { _ in throw HTTPError(.internalServerError, "no schema") }
            Issue.record("a failure should have been thrown")
        } catch let error as RunOnceError {
            guard case .failed(let description) = error else {
                Issue.record("\(error)")
                return
            }
            #expect(description.contains("no schema"))
        }
    }

    @Test func workThatHangsRunsOutOfTime() throws {
        let app = Application()
        app.get("/") { "unused" }
        #expect(throws: RunOnceError.timedOut) {
            try app.runOnce(timeoutMilliseconds: 50) { _ in
                _ = await Worker.waitTimed(currentWorker!, milliseconds: 10_000) { _ in }
            }
        }
    }

    @Test func stateThatCannotBeBuiltIsReported() throws {
        struct NoDatabase: Error {}
        let app = Application()
        app.state { _ -> Ledger in throw NoDatabase() }
        app.get("/") { "unused" }
        do {
            try app.runOnce { _ in }
            Issue.record("a failure should have been thrown")
        } catch let error as RunOnceError {
            guard case .workerCouldNotBeBuilt = error else {
                Issue.record("\(error)")
                return
            }
        }
    }
}
