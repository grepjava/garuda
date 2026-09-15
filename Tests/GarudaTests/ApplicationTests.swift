import Testing
import CGaruda
import GarudaCore
@testable import Garuda

private struct HandlerFailure: Error {}

/// What `/context/:n` keeps across its wait.
private enum Remembered: RequestContextKey {
    typealias Value = Int
}

/// The routes most tests here share.
private func sample() -> Application {
    let app = Application()
    app.get("/") { _, response in
        response.send(status: 200)
    }
    app.get("/user/:id") { request, response in
        request.withParameter(0) { response.send($0) }
    }
    app.post("/echo") { request, response in
        request.withHeader("content-type") { response.addHeader("content-type", $0) }
        request.withBody { response.send($0) }
    }
    app.get("/throw") { _, _ in
        throw HandlerFailure()
    }
    app.get("/later/:ms") { request, response in
        let ms = UInt64(request.withParameter(0) { $0.integer } ?? 1)
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
    app.get("/copies/:id") { request, response in
        // Owned copies, kept past the closures that could have lent them.
        let id = request.parameter(0)
        let path = request.path
        let agent = request.header("user-agent") ?? "none"
        response.send("\(id) \(path) \(agent)")
    }
    app.get("/context/:n") { request, response in
        let before = request[context: Remembered.self]
        request[context: Remembered.self] = request.withParameter(0) { $0.integer }
        response.after(milliseconds: 1) { request, response in
            let after = request[context: Remembered.self]
            response.send("before=\(before.map(String.init) ?? "none") after=\(after.map(String.init) ?? "none")")
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

    @Test func ownedCopiesOutliveTheirRequest() throws {
        let response = try sample().test.get("/copies/9", headers: [("User-Agent", "probe/1")])
        #expect(response.text == "9 /copies/9 probe/1")
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

    @Test func contextCrossesAWaitButNotARequest() throws {
        let client = sample().test
        #expect(try client.get("/context/7").text == "before=none after=7")
        // The next request most likely takes the same slot; it starts empty.
        #expect(try client.get("/context/9").text == "before=none after=9")
    }

    @Test func aCancelledWaitNeverAnswersALaterRequest() throws {
        let client = sample().test
        // A client that asks for a 40 ms wait and goes away after two turns:
        // the worker closes the connection with the timer still armed.
        try client.abandon(Array("GET /later/40 HTTP/1.1\r\nHost: test\r\n\r\n".utf8), turns: 2)
        #expect(client.worker.pointee.table.liveCount == 0)
        // A new request, very likely on the same slot, before the old deadline.
        #expect(try client.get("/user/5").text == "5")
        // Past the old deadline: nothing resumes into the reused slot.
        let started = pg_monotonic_ms()
        while pg_monotonic_ms() - started < 80 { client.turn() }
        #expect(client.worker.pointee.table.liveCount == 0)
        #expect(try client.get("/user/6").text == "6")
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
