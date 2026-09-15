import Testing
import GarudaCore
@testable import Garuda

private struct Person: Codable, Equatable {
    var id: Int
    var name: String
}

private struct NewPerson: Codable, Equatable {
    var name: String
    var age: Int
}

private struct Search: Codable, Equatable {
    var q: String
    var page: Int?
    var tag: [String]?
    var ready: Bool?
}

private func extractingApp() -> Application {
    let app = Application()
    app.get("/hello") {
        "hello"
    }
    app.get("/person/:id") { (id: Path<Int>) in
        JSON(Person(id: id.value, name: "Ada"))
    }
    app.get("/pair/:a/:b") { (a: Path<String>, b: Path<Int>) in
        "\(a.value)-\(b.value)"
    }
    app.get("/search") { (query: Query<Search>) in
        JSON(query.value)
    }
    app.post("/people") { (body: Body<NewPerson>) in
        JSON(body.value, status: .created)
    }
    app.get("/maybe/:id") { (id: Path<Int>) -> JSON<Person>? in
        id.value == 1 ? JSON(Person(id: 1, name: "Ada")) : nil
    }
    app.get("/nothing") {
        HTTPStatus.noContent
    }
    app.get("/page") {
        HTML("<h1>hi</h1>")
    }
    app.get("/go") {
        Redirect(to: "/hello")
    }
    app.get("/both/:id") { (id: Path<Int>, query: Query<Search>) in
        "\(id.value) \(query.value.q)"
    }
    // The raw handlers still register through the same names.
    app.get("/raw") { _, response in
        response.send(text: "raw")
    }
    return app
}

@Suite("Typed extraction", .serialized)
struct ExtractionTests {
    @Test func aHandlerWithNoInputsAnswersWithItsValue() throws {
        let client = extractingApp().test
        let response = try client.get("/hello")
        #expect(response.status == .ok)
        #expect(response.text == "hello")
        #expect(response.header("content-type") == "text/plain; charset=utf-8")
        #expect(try client.get("/raw").text == "raw")
    }

    @Test func pathParametersArriveDecodedAndTyped() throws {
        let client = extractingApp().test
        #expect(try client.get("/person/42").json(Person.self) == Person(id: 42, name: "Ada"))
        #expect(try client.get("/pair/left/7").text == "left-7")
        // Percent-escapes are undone; a path keeps its plus sign.
        #expect(try client.get("/pair/a%20b/7").text == "a b-7")
        #expect(try client.get("/pair/a+b/7").text == "a+b-7")
    }

    @Test func aPathParameterOfTheWrongTypeIs400() throws {
        let response = try extractingApp().test.get("/person/abc")
        #expect(response.status == .badRequest)
        #expect(try response.json([String: String].self)["error"]
            == "the path parameter at 0 is \"abc\", which is not Int")
    }

    @Test func theQueryStringDecodesIntoAType() throws {
        let client = extractingApp().test
        let full = try client.get("/search?q=swift&page=3&tag=a&tag=b&ready")
        #expect(full.status == .ok)
        #expect(try full.json(Search.self)
            == Search(q: "swift", page: 3, tag: ["a", "b"], ready: true))

        let sparse = try client.get("/search?q=only")
        #expect(try sparse.json(Search.self) == Search(q: "only", page: nil, tag: nil, ready: nil))

        // A query string is form-encoded: + is a space, %XX is undone.
        let escaped = try client.get("/search?q=two+words%21")
        #expect(try escaped.json(Search.self).q == "two words!")
    }

    @Test func aQueryThatDoesNotFitTheTypeIs400() throws {
        let client = extractingApp().test
        let missing = try client.get("/search")
        #expect(missing.status == .badRequest)
        #expect(try missing.json([String: String].self)["error"]
            == "q is missing from the query")

        let wrong = try client.get("/search?q=x&page=later")
        #expect(wrong.status == .badRequest)
        #expect(try wrong.json([String: String].self)["error"] == "page=later is not Int")
    }

    @Test func aJSONBodyArrivesDecoded() throws {
        let client = extractingApp().test
        let created = try client.post("/people", body: #"{"name":"Bo","age":7}"#)
        #expect(created.status == .created)
        #expect(try created.json(NewPerson.self) == NewPerson(name: "Bo", age: 7))

        let empty = try client.post("/people", body: "")
        #expect(empty.status == .badRequest)
        #expect(try empty.json([String: String].self)["error"] == "the request has no body")

        let wrong = try client.post("/people", body: #"{"name":"Bo"}"#)
        #expect(wrong.status == .badRequest)
        #expect(try wrong.json([String: String].self)["error"] == "age is missing")
    }

    @Test func extractorsCombineInTheOrderDeclared() throws {
        let response = try extractingApp().test.get("/both/9?q=swift")
        #expect(response.text == "9 swift")
    }

    @Test func whatAHandlerReturnsDecidesTheAnswer() throws {
        let client = extractingApp().test
        #expect(try client.get("/maybe/1").json(Person.self) == Person(id: 1, name: "Ada"))
        // nil is the ordinary not-found.
        #expect(try client.get("/maybe/2").status == .notFound)

        let empty = try client.get("/nothing")
        #expect(empty.status == .noContent)
        #expect(empty.body.isEmpty)

        let page = try client.get("/page")
        #expect(page.header("content-type") == "text/html; charset=utf-8")
        #expect(page.text == "<h1>hi</h1>")

        let redirect = try client.get("/go")
        #expect(redirect.status == .found)
        #expect(redirect.header("location") == "/hello")
    }
}
