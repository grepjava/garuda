import Testing
@testable import Garuda
import CAvian

// maxBodySize and concurrencyLimit.

/// A request sent on a connection of its own, answered while other
/// connections wait.
private final class Pending {
    let client: TestClient
    let fd: Int32
    private var received: [UInt8] = []
    private var closed = false

    init(_ client: TestClient, _ request: String) throws {
        self.client = client
        fd = try client.connect().client
        var request = request
        request.withUTF8 { _ = av_write(fd, $0.baseAddress!, $0.count) }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        _ = av_close(fd)
    }

    /// The response once it is whole, turning the worker up to `turns` times.
    func response(turns: Int = 3_000) throws -> TestResponse? {
        var chunk = [UInt8](repeating: 0, count: 16384)
        for _ in 0..<turns {
            client.turn()
            while true {
                let n = chunk.withUnsafeMutableBufferPointer { av_read(fd, $0.baseAddress!, $0.count) }
                if n <= 0 { break }
                received.append(contentsOf: chunk[0..<n])
            }
            if let response = try TestResponse.parse(received, bodyless: false, closed: false) { return response }
        }
        return nil
    }
}

private func post(_ path: String, _ body: String) -> String {
    "POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
}

@Suite("Request limits")
struct RequestLimitsTests {

    private func bodyApp() -> Application {
        let app = Application()
        let count: Handler = { request, response in response.send("\(request.body.count)") }
        app.post("/default", count)
        app.maxBodySize(64) {
            app.post("/big", count)
            app.maxBodySize(8) {
                app.post("/tiny", count)
            }
            app.onStreamingBody(.post, "/stream", maxBodySize: 100) { _, response, body in
                let all = try await body.readAll(maxBytes: 1000)
                response.send("\(all.count)")
            }
        }
        let router = Router()
        router.maxBodySize(4) {
            router.post("/routed", count)
        }
        app.merge(router)
        return app
    }

    private func bodyClient() -> TestClient {
        var config = ServerConfig()
        config.maxConnections = 16
        config.maxBodySize = 16
        return bodyApp().testClient(configuration: config)
    }

    @Test func aScopesLimitReplacesMaxBodyEitherWay() throws {
        let client = bodyClient()
        let forty = String(repeating: "x", count: 40)
        #expect(try client.post("/default", body: forty).status == 413)
        #expect(try client.post("/default", body: "0123456789").text == "10")
        #expect(try client.post("/big", body: forty).text == "40")
        #expect(try client.post("/big", body: forty + forty).status == 413)
        #expect(try client.post("/tiny", body: "01234567").text == "8")
        #expect(try client.post("/tiny", body: "012345678").status == 413)
        #expect(try client.post("/routed", body: "01234").status == 413)
        #expect(try client.post("/routed", body: "0123").text == "4")
    }

    @Test func aStreamingRouteKeepsItsOwnLimit() throws {
        let client = bodyClient()
        #expect(try client.post("/stream", body: String(repeating: "y", count: 90)).text == "90")
        #expect(try client.post("/stream", body: String(repeating: "y", count: 120)).status == 413)
    }

    @Test func aChunkedBodyIsRefusedWhenItGrowsPastTheLimit() throws {
        let client = bodyClient()
        let chunked = "POST /tiny HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        let within = try client.send(raw: Array((chunked + "4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n").utf8))
        #expect(within.text == "8")
        let past = try client.send(raw: Array((chunked + "5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n").utf8))
        #expect(past.status == 413)
    }

    private func concurrencyApp() -> Application {
        let app = Application()
        app.get("/free") { _, response in response.send("free") }
        app.group("/limited") {
            app.use { request, _ in request.header("authorization") == nil ? HTTPStatus.unauthorized : nil }
            app.concurrencyLimit(1) {
                app.onAsync(.get, "/slow") { _, response in
                    try await response.sleep(milliseconds: 150)
                    response.send("done")
                }
                app.get("/quick") { _, response in response.send("quick") }
            }
        }
        return app
    }

    @Test func onePastTheLimitIsAnswered503AndThePlaceComesBack() throws {
        let client = concurrencyApp().test
        let auth = "Authorization: yes\r\n"
        let first = try Pending(client, "GET /limited/slow HTTP/1.1\r\nHost: x\r\n\(auth)\r\n")
        for _ in 0..<20 { client.turn() }

        #expect(try client.get("/limited/slow", headers: [("authorization", "yes")]).status == 503)
        #expect(try client.get("/limited/quick", headers: [("authorization", "yes")]).status == 503)
        // Middleware runs before the count: a refused request takes no place
        // and is refused as it would be anyway.
        #expect(try client.get("/limited/quick").status == 401)
        #expect(try client.get("/free").text == "free")

        #expect(try first.response()?.text == "done")
        #expect(try client.get("/limited/quick", headers: [("authorization", "yes")]).text == "quick")
        #expect(try client.get("/limited/slow", headers: [("authorization", "yes")]).text == "done")
    }

    @Test func aRequestThatGoesAwayGivesItsPlaceBack() throws {
        let client = concurrencyApp().test
        try client.abandon(Array("GET /limited/slow HTTP/1.1\r\nHost: x\r\nAuthorization: yes\r\n\r\n".utf8), turns: 20)
        for _ in 0..<20 { client.turn() }
        #expect(try client.get("/limited/quick", headers: [("authorization", "yes")]).text == "quick")
    }

    @Test func permitsUnderNestedLimitsAreAllOrNothing() {
        let outer = ConcurrencyLimiter(max: 2)
        let inner = ConcurrencyLimiter(max: 1)
        let a = ConcurrencyLimiter.acquire([outer, inner])
        #expect(a != nil)
        #expect(ConcurrencyLimiter.acquire([outer, inner]) == nil)
        #expect(outer.running.load(ordering: .relaxed) == 1)
        let b = ConcurrencyLimiter.acquire([outer])
        #expect(b != nil)
        #expect(ConcurrencyLimiter.acquire([outer]) == nil)
        a?.release()
        a?.release()
        #expect(outer.running.load(ordering: .relaxed) == 1 && inner.running.load(ordering: .relaxed) == 0)
        _ = b
    }
}
