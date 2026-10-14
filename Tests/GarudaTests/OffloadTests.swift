#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
@_spi(Testing) import Garuda
import GarudaTesting
import Synchronization
import Testing
import Vega

// Offloaded routes: extracted on a worker, run on the blocking pool, and
// answered back on a worker, which serves other requests meanwhile.

/// A gate pool threads wait at until the test opens it: blocking work, as an
/// offloaded handler's is.
private final class Gate: Sendable {
    let isOpen = Atomic<Bool>(false)
    /// Handlers that have reached the gate.
    let waiting = Atomic<Int>(0)
    /// Requests answered after waiting at it.
    let answered = Atomic<Int>(0)

    func wait() {
        waiting.add(1, ordering: .sequentiallyConsistent)
        while !isOpen.load(ordering: .acquiring) {
            #if canImport(Glibc) || canImport(Darwin)
            usleep(200)
            #endif
        }
    }

    func open() {
        isOpen.store(true, ordering: .releasing)
    }
}

private struct Order: Codable, Sendable {
    var item: String
    var quantity: Int
}

private struct Who: Decodable, Sendable {
    var who: String
}

private struct Receipt: Codable, Sendable {
    var line: String
    var onWorker: Bool
}

private struct Prices: Sendable {
    let tea: Int
}

/// Whether the calling thread is one of a runtime's workers.
private func onAWorker() -> Bool { Runtime.currentWorker != nil }

@Suite("Offloaded routes")
struct OffloadTests {
    private func offloadApp(_ gate: Gate = Gate()) -> Application {
        let app = Application()
        app.offload.get("/sum/:n") { (n: Path<Int>) -> String in
            "\((1...n.value).reduce(0, +)) \(onAWorker() ? "worker" : "pool")"
        }
        app.offload.post("/order") { (order: Body<Order>, query: Query<Who>) -> JSON<Receipt> in
            JSON(Receipt(line: "\(order.value.quantity) x \(order.value.item) for \(query.value.who)",
                         onWorker: onAWorker()))
        }
        app.offload.get("/refused") { () throws -> String in throw HTTPError.conflict("no") }
        app.offload.get("/held") { () -> String in
            gate.wait()
            return "held"
        }
        app.group("/api") {
            app.offload.get("/ping") { () -> Text in Text("pong") }
        }
        app.get("/quick") { () in "quick" }
        return app
    }

    /// The handler runs on a pool thread, not a worker, and what it
    /// returns is the response.
    @Test func anOffloadedHandlerRunsOffTheWorkerAndAnswers() throws {
        let client = offloadApp().test
        #expect(try client.get("/sum/100").text == "5050 pool")
        #expect(try client.get("/api/ping").text == "pong")
    }

    /// Extractors are taken on the worker before the handler goes, and a
    /// value the handler returns is written back there.
    @Test func extractorsAndTheAnswerCrossToThePoolAndBack() throws {
        let client = offloadApp().test
        let response = try client.post("/order?who=ana", json: Order(item: "tea", quantity: 2))
        #expect(response.status == 200)
        #expect(response.text.contains(#""line":"2 x tea for ana""#))
        #expect(response.text.contains(#""onWorker":false"#))
        // A body that does not decode is refused on the worker, before the
        // pool is asked for anything.
        #expect(try client.post("/order", body: "{", headers: [("content-type", "application/json")]).status == 400)
    }

    @Test func whatTheHandlerThrowsIsTheStatus() throws {
        #expect(try offloadApp().test.get("/refused").status == 409)
    }

    /// While offloaded handlers block -- more of them than the runtime has
    /// workers -- the workers answer other requests.
    @Test func theWorkersServeOthersWhileOffloadedHandlersBlock() async throws {
        let gate = Gate()
        let client = offloadApp(gate).test
        let held = 3
        try #require(held > 2, "more than the test client's workers")
        let requests = (0..<held).map { _ in
            Task.detached { () async throws -> HTTPStatus in
                let response = try await Runtime.blocking { try client.get("/held") }
                gate.answered.add(1, ordering: .sequentiallyConsistent)
                return response.status
            }
        }
        // Every held handler has a pool thread and is blocked on it.
        let clock = ContinuousClock()
        let giveUp = clock.now + .seconds(5)
        while gate.waiting.load(ordering: .sequentiallyConsistent) < held && clock.now < giveUp {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(gate.waiting.load(ordering: .sequentiallyConsistent) == held)

        let quick = try await Runtime.blocking { try client.get("/quick") }
        #expect(quick.text == "quick")
        #expect(gate.answered.load(ordering: .sequentiallyConsistent) == 0)

        gate.open()
        for request in requests { #expect(try await request.value == 200) }
    }

    /// An offloaded route is a typed route to everything but where its
    /// handler runs: its path parameters and the state it takes are checked
    /// before serving, and state built for the shard can be taken.
    @Test func anOffloadedRouteIsCheckedAndTakesState() throws {
        let app = Application()
        app.state { _ in Prices(tea: 3) }
        app.offload.get("/price/:item") { (item: Path<String>, prices: State<Prices>) -> String in
            "\(item.value) \(prices.value.tea)"
        }
        #expect(app.problems().isEmpty, "\(app.problems())")
        #expect(try app.test.get("/price/tea").text == "tea 3")

        let wrong = Application()
        wrong.offload.get("/wrong/:id") { (id: Path<Int>, extra: Path<Int>) -> String in "x" }
        wrong.offload.get("/unbuilt") { (prices: State<Prices>) -> String in "x" }
        #expect(wrong.problems() == [
            "GET /wrong/:id takes 2 Path parameters, and its pattern has 1",
            "GET /unbuilt asks for State<Prices>, and no app.state builds it",
        ])
    }
}
