import Testing
import GarudaCore
@testable import Garuda

private struct User: Codable, Equatable {
    var id: Int
    var name: String
}

/// An error the application did not plan for.
private struct Broken: Error {}

private func typedApp() -> Application {
    let app = Application()
    app.get("/user") { _, response in
        try response.send(json: User(id: 1, name: "Ada"))
    }
    app.get("/created") { _, response in
        try response.send(status: .created, json: User(id: 2, name: "Bo"))
    }
    app.get("/text") { _, response in
        response.send(text: "plain")
    }
    app.get("/html") { _, response in
        response.send(html: "<h1>hi</h1>")
    }
    app.get("/bytes") { _, response in
        response.send(bytes: [1, 2, 3], contentType: "application/octet-stream")
    }
    app.get("/redirect") { _, response in
        response.redirect(to: "/user")
    }
    app.get("/moved") { _, response in
        response.redirect(to: "/user", status: .movedPermanently)
    }
    app.get("/own-type") { _, response in
        response.addHeader("content-type", "application/vnd.garuda+json")
        try response.send(json: User(id: 3, name: "Cy"))
    }
    app.get("/status-first") { _, response in
        response.status = .accepted
        response.send(text: "later")
    }
    app.get("/missing") { _, _ in
        throw HTTPError.notFound
    }
    app.get("/why") { _, _ in
        throw HTTPError.badRequest("id must be a number")
    }
    app.get("/quoted") { _, _ in
        throw HTTPError(.conflict, "the \"name\" is taken\nalready")
    }
    app.get("/boom") { _, _ in
        throw Broken()
    }
    app.post("/decode") { request, response in
        let user = try request.withBody { try JSON.decode(User.self, from: $0) }
        try response.send(status: .created, json: user)
    }
    return app
}

/// Serialized: each test client turns a worker on the test's own thread.
@Suite("Typed responses and errors", .serialized)
struct ResponseTests {
    @Test func jsonAnswersCarryTheirTypeAndValue() throws {
        let client = typedApp().test
        let response = try client.get("/user")
        #expect(response.status == .ok)
        #expect(response.header("content-type") == "application/json")
        #expect(try response.json(User.self) == User(id: 1, name: "Ada"))
        #expect(response.text == #"{"id":1,"name":"Ada"}"#)

        let created = try client.get("/created")
        #expect(created.status == .created)
        #expect(created.status == 201)
        #expect(try created.json(User.self).name == "Bo")
    }

    @Test func eachKindOfAnswerSaysWhatItIs() throws {
        let client = typedApp().test
        let text = try client.get("/text")
        #expect(text.header("content-type") == "text/plain; charset=utf-8")
        #expect(text.text == "plain")

        let html = try client.get("/html")
        #expect(html.header("content-type") == "text/html; charset=utf-8")
        #expect(html.text == "<h1>hi</h1>")

        let bytes = try client.get("/bytes")
        #expect(bytes.header("content-type") == "application/octet-stream")
        #expect(bytes.body == [1, 2, 3])
    }

    @Test func aHandlersOwnContentTypeIsKept() throws {
        let response = try typedApp().test.get("/own-type")
        #expect(response.header("content-type") == "application/vnd.garuda+json")
        #expect(try response.json(User.self).id == 3)
        #expect(response.headers(named: "content-type").count == 1)
    }

    @Test func aStatusSetBeforeTheBodyIsTheOneSent() throws {
        let response = try typedApp().test.get("/status-first")
        #expect(response.status == .accepted)
        #expect(response.text == "later")
    }

    @Test func redirectsCarryTheirLocation() throws {
        let client = typedApp().test
        let found = try client.get("/redirect")
        #expect(found.status == .found)
        #expect(found.header("location") == "/user")
        #expect(found.body.isEmpty)

        let moved = try client.get("/moved")
        #expect(moved.status == .movedPermanently)
        #expect(moved.header("location") == "/user")
    }

    @Test func anErrorTheApplicationThrewBecomesItsAnswer() throws {
        let client = typedApp().test
        let missing = try client.get("/missing")
        #expect(missing.status == .notFound)
        #expect(missing.body.isEmpty)

        let why = try client.get("/why")
        #expect(why.status == .badRequest)
        #expect(why.header("content-type") == "application/json")
        #expect(try why.json([String: String].self) == ["error": "id must be a number"])
    }

    @Test func aReasonIsOneJSONStringWhateverItHolds() throws {
        let response = try typedApp().test.get("/quoted")
        #expect(response.status == .conflict)
        #expect(try response.json([String: String].self)
            == ["error": "the \"name\" is taken\nalready"])
    }

    @Test func anErrorTheApplicationDidNotPlanForIs500() throws {
        let response = try typedApp().test.get("/boom")
        #expect(response.status == .internalServerError)
        #expect(response.body.isEmpty)
    }

    @Test func aBodyThatIsNotWhatItSaidIs400() throws {
        let client = typedApp().test
        let good = try client.post("/decode", body: #"{"id":7,"name":"Di"}"#)
        #expect(good.status == .created)
        #expect(try good.json(User.self) == User(id: 7, name: "Di"))

        let notJSON = try client.post("/decode", body: "{oops")
        #expect(notJSON.status == .badRequest)
        #expect(try notJSON.json([String: String].self)["error"]?.contains("not JSON") == true)

        let wrongType = try client.post("/decode", body: #"{"id":"seven","name":"Di"}"#)
        #expect(wrongType.status == .badRequest)
        #expect(try wrongType.json([String: String].self)["error"] == "id is not Int")

        let missingKey = try client.post("/decode", body: #"{"id":7}"#)
        #expect(missingKey.status == .badRequest)
        #expect(try missingKey.json([String: String].self)["error"] == "name is missing")
    }
}
