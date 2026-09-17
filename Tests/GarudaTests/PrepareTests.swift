import Testing
import CAvian
import AvianCore
@testable import Garuda

// `app.prepare`: async start-up work in each worker, before it serves.

private final class Steps: @unchecked Sendable {
    var taken: [String] = []
}

private final class Counter: @unchecked Sendable {
    var value = 0
}

@Suite("Worker preparation")
struct PrepareTests {
    @Test func everyHookRunsInOrderBeforeTheFirstRequest() throws {
        let steps = Steps()
        let app = Application()
        app.prepare { start in
            // Awaiting is the point: the worker turns its loop meanwhile.
            _ = await Worker.waitTimed(currentWorker!, milliseconds: 5) { _ in }
            steps.taken.append("migrated \(start.index)")
        }
        app.prepare { _ in steps.taken.append("warmed") }
        app.get("/steps") { () -> String in steps.taken.joined(separator: ",") }
        let client = app.test
        #expect(try client.get("/steps").text == "migrated 0,warmed")
        // Once per worker, not once per request.
        #expect(try client.get("/steps").text == "migrated 0,warmed")
    }

    @Test func aHookReachesTheStateTheWorkerBuilt() throws {
        let app = Application()
        app.state { _ in Counter() }
        app.prepare { start in
            // What a migration does: take the pool this worker built.
            try start.state(Counter.self).value = 7
        }
        app.get("/count") { (counter: State<Counter>) -> String in "\(counter.value.value)" }
        let client = app.test
        #expect(try client.get("/count").text == "7")
    }

    @Test func stateThatWasNeverRegisteredIsAFault() throws {
        let app = Application()
        app.get("/") { "up" }
        let client = app.test
        let found = client.onWorker {
            GarudaRuntime.runPreparation(client.worker, index: 0, prepare: { start in
                _ = try start.state(Counter.self)
            }, timeoutMilliseconds: 1_000) { client.turn() }
        }
        #expect(found == false)
    }

    @Test func aHookThatFailsOrHangsStopsTheWorker() throws {
        let app = Application()
        app.get("/") { "up" }
        let client = app.test

        // A hook that throws: the worker must not go on to serve.
        let threw = client.onWorker {
            GarudaRuntime.runPreparation(client.worker, index: 0,
                                         prepare: { _ in throw HTTPError(.internalServerError, "no schema") },
                                         timeoutMilliseconds: 1_000) { client.turn() }
        }
        #expect(threw == false)

        // A hook that never finishes: the time it is given runs out.
        let hung = client.onWorker {
            GarudaRuntime.runPreparation(client.worker, index: 0, prepare: { _ in
                _ = await Worker.waitTimed(currentWorker!, milliseconds: 10_000) { _ in }
            }, timeoutMilliseconds: 50) { client.turn() }
        }
        #expect(hung == false)

        // The worker itself still serves: those runs only reported.
        #expect(try client.get("/").text == "up")
    }
}
