import Testing
import AvianCore
@testable import Garuda

/// A service with identity, so a test can see how often it was built.
private final class Pool {
    var queries = 0
    var closed = false
}

private struct Settings: Equatable {
    var name: String
}

private struct FactoryFailed: Error {}

/// Counts across a test, since a class survives being captured.
private final class Tally {
    var built = 0
    var torn = 0
}

@Suite("Typed application state", .serialized)
struct StateTests {
    @Test func aHandlerReachesStateByItsType() throws {
        let app = Application()
        app.state { _ in Settings(name: "ada") }
        app.get("/name") { (settings: State<Settings>) in
            settings.value.name
        }
        #expect(try app.test.get("/name").text == "ada")
    }

    @Test func theFactoryRunsOncePerWorkerAndIsTornDownAfter() throws {
        let tally = Tally()
        do {
            let app = Application()
            app.state({ _ in
                tally.built += 1
                return Pool()
            }, shutdown: { pool in
                pool.closed = true
                tally.torn += 1
            })
            app.get("/query") { (pool: State<Pool>) in
                pool.value.queries += 1
                return "\(pool.value.queries)"
            }
            let client = app.test
            #expect(try client.get("/query").text == "1")
            #expect(try client.get("/query").text == "2")
            #expect(try client.get("/query").text == "3")
            // One worker, one build: the state is the same value each time.
            #expect(tally.built == 1)
            #expect(tally.torn == 0)
        }
        // The client let its worker go, which tore the state down.
        #expect(tally.torn == 1)
    }

    @Test func severalKindsOfStateLiveTogether() throws {
        let app = Application()
        app.state { _ in Settings(name: "bo") }
        app.state { worker in Pool() }
        app.state { worker in worker }
        app.get("/all") { (settings: State<Settings>, pool: State<Pool>, index: State<Int>) in
            "\(settings.value.name) \(pool.value.queries) worker \(index.value)"
        }
        #expect(try app.test.get("/all").text == "bo 0 worker 0")
    }

    @Test func stateAndExtractorsCombine() throws {
        let app = Application()
        app.state { _ in Settings(name: "cy") }
        app.get("/greet/:id") { (id: Path<Int>, settings: State<Settings>) in
            "\(settings.value.name) \(id.value)"
        }
        #expect(try app.test.get("/greet/7").text == "cy 7")
    }

    @Test func askingForStateNobodyRegisteredIs500() throws {
        let app = Application()
        app.get("/missing") { (settings: State<Settings>) in
            settings.value.name
        }
        let response = try app.test.get("/missing")
        #expect(response.status == .internalServerError)
        #expect(try response.json(ErrorBody.self).error
            == "no Settings was registered with app.state")
    }

    @Test func aFactoryThatThrowsStopsTheWorkerStarting() throws {
        let app = Application()
        app.state { (_: Int) throws -> Settings in throw FactoryFailed() }
        let compiled = app.compile()
        guard let poller = Poller(maxEvents: 8) else {
            Issue.record("no poller")
            return
        }
        var worker = Worker(config: ServerConfig(), listenFD: -1, poller: poller)
        #expect(throws: FactoryFailed.self) {
            try worker.buildState(compiled, index: 0)
        }
        worker.destroy()
    }
}
