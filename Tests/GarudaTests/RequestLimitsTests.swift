import Testing
import Synchronization
import Vega
@testable import Garuda
import GarudaTesting

// maxBodySize and concurrencyLimit, and the server's own body limit.

private let count: Handler = { request, response in response.send("\(request.body.count)") }

private func bodyApp() -> Application {
    let app = Application()
    app.post("/default", count)
    app.maxBodySize(64) {
        app.post("/big", count)
        app.maxBodySize(8) {
            app.post("/tiny", count)
            app.post("/tiny/:id", count)
        }
        app.group("/under") {
            app.fallback(count)
        }
    }
    let router = Router()
    router.maxBodySize(4) {
        router.post("/routed", count)
    }
    app.merge(router)
    return app
}

private func bodyClient(_ app: Application = bodyApp()) -> TestClient {
    var config = ServerConfig()
    config.maxBodySize = 16
    return app.testClient(configuration: config)
}

/// Holds the handlers that pass it until it is opened, and counts them in.
private final class Gate: Sendable {
    private let inside = Atomic<Int>(0)
    private let opened = Atomic<Bool>(false)

    func pass() async throws {
        inside.add(1, ordering: .relaxed)
        while !opened.load(ordering: .acquiring) { try await Runtime.sleep(for: .milliseconds(1)) }
    }

    /// Waits until `n` handlers are being held.
    func waitFor(_ n: Int) async throws {
        while inside.load(ordering: .relaxed) < n { try await Task.sleep(for: .milliseconds(1)) }
    }

    func open() { opened.store(true, ordering: .releasing) }
}

private let authorized = [("authorization", "yes")]

private func concurrencyApp(_ gate: Gate) -> Application {
    let app = Application()
    app.get("/free") { () in "free" }
    app.group("/limited") {
        app.use { request, response, next in
            guard request.header("authorization") != nil else { return response.send(status: .unauthorized) }
            try await next()
        }
        app.concurrencyLimit(1) {
            app.get("/slow") { () async throws in
                try await gate.pass()
                return "done"
            }
            app.get("/quick") { () in "quick" }
            app.get("/fails") { () throws -> String in throw HTTPError.conflict("no") }
        }
    }
    return app
}

@Suite("Request limits")
struct RequestLimitsTests {

    // MARK: Body size

    @Test func aBodyPastMaxBodySizeIs413() throws {
        let client = bodyClient()
        #expect(try client.post("/default", body: String(repeating: "x", count: 40)).status == 413)
        #expect(try client.post("/default", body: "0123456789").text == "10")
        #expect(try client.post("/default", body: String(repeating: "x", count: 16)).text == "16")
        #expect(try client.post("/default", body: String(repeating: "x", count: 17)).status == 413)
    }

    @Test func aScopesLimitReplacesMaxBodyEitherWay() throws {
        let client = bodyClient()
        let forty = String(repeating: "x", count: 40)
        #expect(try client.post("/big", body: forty).text == "40")
        #expect(try client.post("/big", body: forty + forty).status == 413)
        #expect(try client.post("/tiny", body: "01234567").text == "8")
        #expect(try client.post("/tiny", body: "012345678").status == 413)
        #expect(try client.post("/tiny/3", body: "012345678").status == 413)
        #expect(try client.post("/routed", body: "01234").status == 413)
        #expect(try client.post("/routed", body: "0123").text == "4")
    }

    @Test func aChunkedBodyIsRefusedWhenItGrowsPastTheLimit() throws {
        let client = bodyClient()
        let chunked = "POST /tiny HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        let within = try client.send(raw: Array((chunked + "4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n").utf8))
        #expect(within.text == "8")
        let past = try client.send(raw: Array((chunked + "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n").utf8))
        #expect(past.status == 413)
        // And under the server's limit, in an application with scoped ones.
        let server = "POST /default HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        let large = try client.send(raw: Array((server + "9\r\nhello wor\r\n9\r\nld, again\r\n0\r\n\r\n").utf8))
        #expect(large.status == 413)
    }

    @Test func aFallbackHasItsScopesLimit() throws {
        let client = bodyClient()
        let forty = String(repeating: "x", count: 40)
        #expect(try client.post("/under/anything", body: forty).text == "40")
        #expect(try client.post("/under/anything", body: forty + forty).status == 413)
        // A miss with no fallback is held to the server's limit.
        #expect(try client.post("/nowhere", body: forty).status == 413)
        #expect(try client.post("/nowhere", body: "0123").status == 404)
    }

    @Test func anIgnoredTrailingSlashKeepsTheRoutesLimit() throws {
        let app = bodyApp()
        app.trailingSlash(.ignore)
        let client = bodyClient(app)
        #expect(try client.post("/big/", body: String(repeating: "x", count: 40)).text == "40")
        #expect(try client.post("/tiny/", body: "012345678").status == 413)
    }

    @Test func aRefusedBodyIsReportedWithNoRoute() throws {
        let seen = Mutex<[CompletedRequest]>([])
        let app = bodyApp()
        app.onResponse { completed in seen.withLock { $0.append(completed) } }
        let client = bodyClient(app)
        #expect(try client.post("/tiny", body: "012345678").status == 413)
        #expect(try client.post("/tiny", body: "0").text == "1")
        let reports = seen.withLock { $0.map { "\($0.status) \($0.route ?? "-")" } }
        #expect(reports == ["413 -", "200 /tiny"])
    }

    @Test func pipelinedRequestsUnderScopedLimits() throws {
        // The route matched before the body is the one that answers, with its
        // parameters, request after request on one connection.
        let raw = "POST /tiny/1 HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\nab"
            + "POST /big HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n" + String(repeating: "y", count: 20)
            + "POST /tiny/2 HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc"
        let responses = try bodyClient().sendPipelined(raw: Array(raw.utf8))
        #expect(responses.map(\.text) == ["2", "20", "3"])
    }

    // MARK: Concurrency

    @Test func onePastTheLimitIsAnswered503AndThePlaceComesBack() async throws {
        let gate = Gate()
        let client = concurrencyApp(gate).test
        let first = Task.detached { try client.get("/limited/slow", headers: authorized).text }
        try await gate.waitFor(1)

        #expect(try client.get("/limited/slow", headers: authorized).status == 503)
        #expect(try client.get("/limited/quick", headers: authorized).status == 503)
        // Middleware runs before the count: a refused request takes no place
        // and is refused as it would be anyway.
        #expect(try client.get("/limited/quick").status == 401)
        #expect(try client.get("/free").text == "free")

        gate.open()
        #expect(try await first.value == "done")
        #expect(try client.get("/limited/quick", headers: authorized).text == "quick")
        #expect(try client.get("/limited/slow", headers: authorized).text == "done")
    }

    @Test func aHandlerThatThrowsGivesItsPlaceBack() throws {
        let client = concurrencyApp(Gate()).test
        #expect(try client.get("/limited/fails", headers: authorized).status == 409)
        #expect(try client.get("/limited/quick", headers: authorized).text == "quick")
    }

    @Test func aRouterMergedTwiceHasALimitInEachPlace() async throws {
        let gate = Gate()
        let router = Router()
        router.concurrencyLimit(1) {
            router.get("/slow") { () async throws in
                try await gate.pass()
                return "done"
            }
            router.get("/quick") { () in "quick" }
        }
        let app = Application()
        app.nest("/a", router)
        app.nest("/b", router)
        let client = app.test
        let first = Task.detached { try client.get("/a/slow").text }
        try await gate.waitFor(1)
        #expect(try client.get("/a/quick").status == 503)
        #expect(try client.get("/b/quick").text == "quick")
        gate.open()
        #expect(try await first.value == "done")
    }

    @Test func nestedLimitsAllApply() async throws {
        let gate = Gate()
        let app = Application()
        app.concurrencyLimit(2) {
            app.get("/outer") { () async throws in
                try await gate.pass()
                return "outer"
            }
            app.concurrencyLimit(1) {
                app.get("/inner") { () async throws in
                    try await gate.pass()
                    return "inner"
                }
            }
        }
        let client = app.test
        let inner = Task.detached { try client.get("/inner").text }
        try await gate.waitFor(1)
        let outer = Task.detached { try client.get("/outer").text }
        try await gate.waitFor(2)
        // The outer scope is full with one of each; the inner, with one.
        #expect(try client.get("/outer").status == 503)
        #expect(try client.get("/inner").status == 503)
        gate.open()
        #expect(try await inner.value == "inner")
        #expect(try await outer.value == "outer")
    }

    @Test func placesUnderNestedLimitsAreAllOrNothing() {
        let outer = Vega.Semaphore(permits: 2)
        let inner = Vega.Semaphore(permits: 1)
        #expect(acquirePlaces([outer, inner]))
        #expect(!acquirePlaces([outer, inner]))
        #expect(outer.availablePermits == 1)
        #expect(acquirePlaces([outer]))
        #expect(!acquirePlaces([outer]))
        outer.release()
        inner.release()
        #expect(outer.availablePermits == 1 && inner.availablePermits == 1)
    }
}
