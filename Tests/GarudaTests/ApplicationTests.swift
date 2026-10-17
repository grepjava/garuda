import Testing
import Vega
@testable import Garuda
import GarudaTesting

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
        let ms = request.withParameter(0) { $0.integer } ?? 1
        try await Runtime.sleep(for: .milliseconds(ms))
        response.send(status: 202, "late")
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
        try await Runtime.sleep(for: .milliseconds(1))
        let after = request[context: Remembered.self]
        response.send("before=\(before.map(String.init) ?? "none") after=\(after.map(String.init) ?? "none")")
    }
    return app
}

@Suite("Application and its test client")
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

    @Test func aKnownPathUnderTheWrongMethodIs405WithAllow() throws {
        // /echo takes POST only. Told "not found", a client goes looking for a
        // URL that exists; told 405 and Allow, it knows what to send instead.
        let response = try sample().test.request("DELETE", "/echo")
        #expect(response.status == 405)
        #expect(response.header("allow") == "POST")
    }

    @Test func allowIncludesHeadWhereGetIsRouted() throws {
        let response = try sample().test.request("PUT", "/user/42")
        #expect(response.status == 405)
        #expect(response.header("allow") == "GET, HEAD")
    }

    @Test func allowIsTheUnionOfWhatEachMethodActuallyMatches() throws {
        // PUT /users/me reaches a literal route that takes POST only, and a
        // parameter route beside it that takes GET. A method-by-method match
        // falls through the literal to the parameter for GET, so Allow must
        // name both -- reading only the literal node would leave GET out and
        // tell the client something false.
        let app = Application()
        app.post("/users/me") { _, response in response.send(status: 200) }
        app.get("/users/:id") { _, response in response.send(status: 200) }
        let response = try app.test.request("PUT", "/users/me")
        #expect(response.status == 405)
        #expect(response.header("allow") == "GET, HEAD, POST")
    }

    @Test func aPathNoMethodRoutesIsStill404() throws {
        let response = try sample().test.request("DELETE", "/nowhere")
        #expect(response.status == 404)
        #expect(response.header("allow") == nil)
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
        let clock = ContinuousClock()
        let started = clock.now
        let response = try client.get("/later/30")
        #expect(response.status == 202)
        #expect(response.text == "late")
        #expect(clock.now - started >= .milliseconds(25))
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
        let raw = "GET /context/8 HTTP/1.1\r\nHost: t\r\n\r\nGET /context/9 HTTP/1.1\r\nHost: t\r\n\r\n"
        // The second request on the connection reuses the first's exchange;
        // it starts empty.
        #expect(try client.sendPipelined(raw: Array(raw.utf8)).map(\.text)
                == ["before=none after=8", "before=none after=9"])
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

    @Test func aRawRequestIsParsedByTheEngine() throws {
        let bytes = Array("GET /user/7 HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n".utf8)
        let response = try sample().test.send(raw: bytes)
        #expect(response.status == 200)
        #expect(response.text == "7")
    }
}
