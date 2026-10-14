import Garuda
import GarudaTesting
import Testing

struct Item: Codable, Equatable, Sendable {
    let id: Int
    let name: String
}

func routingApp() -> Application {
    let app = Application()
    app.get("/") { () in "root" }
    app.get("/user/:id") { (id: Path<Int>) in "user \(id.value)" }
    app.get("/pair/:a/:b") { (a: Path<String>, b: Path<Int>) in "\(a.value)-\(b.value)" }
    app.post("/items") { (item: Body<Item>) in JSON(item.value) }
    app.get("/raw") { request, response in
        response.addHeader("x-path", request.path)
        response.send(status: 201, "made")
    }
    app.get("/suspends") { () async throws in
        await Task.yield()
        return "after a yield"
    }
    app.get("/fails") { () throws -> String in throw HTTPError.conflict("taken") }
    app.get("/explodes") { () throws -> String in
        struct Boom: Error {}
        throw Boom()
    }
    app.get("/silent") { _, _ in }
    return app
}

@Suite struct RoutingTests {
    @Test func literalRoute() throws {
        let response = try routingApp().test.get("/")
        #expect(response.status == 200)
        #expect(response.text == "root")
        #expect(response.header("content-length") == "4")
        #expect(response.header("date") != nil)
    }

    @Test func pathParameters() throws {
        let client = routingApp().test
        #expect(try client.get("/user/42").text == "user 42")
        #expect(try client.get("/pair/x%20y/7").text == "x y-7")
    }

    @Test func pathParameterOfTheWrongTypeIs400() throws {
        let response = try routingApp().test.get("/user/abc")
        #expect(response.status == 400)
    }

    @Test func jsonBodyRoundTrips() throws {
        let response = try routingApp().test.post("/items", json: Item(id: 3, name: "pen"))
        #expect(response.status == 200)
        #expect(try response.json(Item.self) == Item(id: 3, name: "pen"))
        #expect(response.header("content-type")?.hasPrefix("application/json") == true)
    }

    @Test func missingBodyIs400() throws {
        #expect(try routingApp().test.post("/items").status == 400)
    }

    @Test func rawHandler() throws {
        let response = try routingApp().test.get("/raw")
        #expect(response.status == 201)
        #expect(response.text == "made")
        #expect(response.header("x-path") == "/raw")
    }

    @Test func handlerThatSuspends() throws {
        #expect(try routingApp().test.get("/suspends").text == "after a yield")
    }

    @Test func thrownResponseErrorIsItsStatus() throws {
        #expect(try routingApp().test.get("/fails").status == 409)
    }

    @Test func otherErrorsAre500() throws {
        #expect(try routingApp().test.get("/explodes").status == 500)
    }

    @Test func unansweredIs500() throws {
        #expect(try routingApp().test.get("/silent").status == 500)
    }

    @Test func unknownPathIs404() throws {
        #expect(try routingApp().test.get("/nowhere").status == 404)
    }

    @Test func wrongMethodIs405WithAllow() throws {
        let response = try routingApp().test.delete("/user/1")
        #expect(response.status == 405)
        #expect(response.header("allow") == "GET, HEAD")
    }

    @Test func headHasNoBody() throws {
        let response = try routingApp().test.head("/")
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
    }

    @Test func pipelinedRequestsAnsweredInOrder() throws {
        let raw = Array("GET /user/1 HTTP/1.1\r\nHost: t\r\n\r\nGET /user/2 HTTP/1.1\r\nHost: t\r\n\r\n".utf8)
        let responses = try routingApp().test.sendPipelined(raw: raw)
        #expect(responses.map(\.text) == ["user 1", "user 2"])
    }

    @Test func connectionCloseIsHonoured() throws {
        let raw = Array("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\nGET /user/2 HTTP/1.1\r\nHost: t\r\n\r\n".utf8)
        let responses = try routingApp().test.sendPipelined(raw: raw)
        #expect(responses.count == 1)
        #expect(responses.first?.header("connection") == "close")
    }

    @Test func chunkedRequestBody() throws {
        let raw = Array(("POST /items HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "9\r\n{\"id\":1,\"\r\nc\r\nname\":\"cup\"}\r\n0\r\n\r\n").utf8)
        let response = try routingApp().test.send(raw: raw)
        #expect(response.status == 200)
        #expect(try response.json(Item.self) == Item(id: 1, name: "cup"))
    }

    @Test func malformedRequestIs400() throws {
        let response = try routingApp().test.send(raw: Array("GARBAGE\r\n\r\n".utf8))
        #expect(response.status == 400)
    }

    @Test func problemsFindsTooManyPathExtractors() {
        let app = Application()
        app.get("/one/:a") { (a: Path<Int>, b: Path<Int>) in "\(a.value)\(b.value)" }
        #expect(app.problems().count == 1)
    }
}
