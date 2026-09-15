import Testing
import CGaruda
import GarudaCore
@testable import Garuda

private struct HandlerFailure: Error {}

/// The routes most tests here share.
private func sample() -> Application {
    let app = Application()
    app.get("/") { _, response in
        response.send(status: 200)
    }
    app.get("/user/:id") { request, response in
        response.send(request.parameter(0))
    }
    app.post("/echo") { request, response in
        if let type = request.header("content-type") {
            response.addHeader("content-type", type)
        }
        response.send(request.body)
    }
    app.get("/throw") { _, _ in
        throw HandlerFailure()
    }
    app.get("/later/:ms") { request, response in
        let ms = UInt64(request.parameter(0).integer ?? 1)
        response.after(milliseconds: ms) { _, response in
            response.send(status: 202, "late")
        }
    }
    app.get("/request-id") { request, response in
        if let id = request.requestID {
            response.send(id)
        } else {
            response.send(status: 200)
        }
    }
    return app
}

/// Serialized: each test client turns a worker on the test's own thread, and
/// the engine keeps its current worker in one process-wide slot.
@Suite("Application and its test client", .serialized)
struct ApplicationTests {
    @Test func routesAnswerThroughTheEngine() throws {
        let client = sample().test
        let root = try client.get("/")
        #expect(root.status == 200)
        #expect(root.body.isEmpty)
        #expect(root.header("content-length") == "0")

        let user = try client.get("/user/42")
        #expect(user.status == 200)
        #expect(user.text == "42")
        #expect(user.header("content-length") == "2")
        #expect(user.header("server") == "garuda")
    }

    @Test func anUnknownPathIs404() throws {
        let response = try sample().test.get("/nowhere")
        #expect(response.status == 404)
    }

    @Test func headIsAnsweredWhereGetIs() throws {
        let response = try sample().test.head("/user/42")
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
        #expect(response.header("content-length") == "2")
    }

    @Test func theHandlerGetsTheBodyAndHeaders() throws {
        let response = try sample().test.post("/echo", body: "hello, garuda",
                                              headers: [("Content-Type", "text/plain")])
        #expect(response.status == 200)
        #expect(response.text == "hello, garuda")
        #expect(response.header("content-type") == "text/plain")
    }

    @Test func aThrowingHandlerIsAnswered500() throws {
        let response = try sample().test.get("/throw")
        #expect(response.status == 500)
    }

    @Test func aHandlerCanWaitOnATimer() throws {
        let client = sample().test
        let started = pg_monotonic_ms()
        let response = try client.get("/later/30")
        #expect(response.status == 202)
        #expect(response.text == "late")
        #expect(pg_monotonic_ms() - started >= 25)
    }

    @Test func oneClientServesRequestAfterRequest() throws {
        let client = sample().test
        for id in 0..<50 {
            let response = try client.get("/user/\(id)")
            #expect(response.text == "\(id)")
        }
    }

    @Test func applicationsInOneProcessKeepTheirOwnRoutes() throws {
        let first = Application()
        first.get("/first") { _, response in response.send("one") }
        let second = Application()
        second.get("/second") { _, response in response.send("two") }

        #expect(try first.test.get("/first").text == "one")
        #expect(try first.test.get("/second").status == 404)
        #expect(try second.test.get("/second").text == "two")
        #expect(try second.test.get("/first").status == 404)
    }

    @Test func aTestConfigurationReachesTheWorker() throws {
        var config = ServerConfig()
        config.maxConnections = 16
        config.requestID = true
        let response = try sample().testClient(configuration: config).get("/request-id")
        let id = response.header("x-request-id")
        #expect(id != nil)
        #expect(response.text == id)
    }

    @Test func aRawRequestIsParsedByTheEngine() throws {
        let bytes = Array("GET /user/7 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n".utf8)
        let response = try sample().test.send(raw: bytes)
        #expect(response.status == 200)
        #expect(response.text == "7")
    }
}
