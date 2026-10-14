import Testing
@testable import Garuda
import GarudaTesting

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
}

private struct Chosen: Codable, Equatable {
    var who: String
}

private let directory = ["Ada", "Grace"]

private struct Boom: Error {}

private func asyncRouteApp() -> Application {
    let app = Application()

    // Takes nothing, awaits, returns a string.
    app.get("/hello") { () async throws -> String in
        await Task.yield()
        return "hello"
    }
    // One path parameter across a wait.
    app.get("/person/:id") { (id: Path<Int>) async throws -> JSON<Person> in
        await Task.yield()
        return JSON(Person(id: id.value, name: "Ada"))
    }
    // Several extractors, in the order declared.
    app.get("/pick/:id") { (id: Path<Int>, query: Query<Search>) async throws -> JSON<Chosen> in
        await Task.yield()
        let who = directory.indices.contains(id.value) ? directory[id.value] : query.value.q
        return JSON(Chosen(who: who))
    }
    // A body decoded before the handler body runs.
    app.post("/people") { (body: Body<NewPerson>) async throws -> JSON<NewPerson> in
        await Task.yield()
        return JSON(body.value, status: .created)
    }
    // nil is the ordinary 404, after a wait like anywhere else.
    app.get("/maybe/:id") { (id: Path<Int>) async throws -> JSON<Person>? in
        await Task.yield()
        return id.value == 1 ? JSON(Person(id: 1, name: "Ada")) : nil
    }
    // A conforming error thrown after a wait is still the answer, not a 500.
    app.get("/conflict") { () async throws -> String in
        await Task.yield()
        throw HTTPError(.conflict, "the name is taken")
    }
    // An error that conforms to nothing is a 500.
    app.get("/boom") { () async throws -> String in
        await Task.yield()
        throw Boom()
    }
    return app
}

@Suite("Async routes")
struct AsyncRouteTests {
    @Test func anAsyncHandlerTakingNothingAnswers() throws {
        let response = try asyncRouteApp().test.get("/hello")
        #expect(response.status == 200)
        #expect(response.text == "hello")
    }

    @Test func anAsyncHandlerTakesAPathParameter() throws {
        let response = try asyncRouteApp().test.get("/person/7")
        #expect(response.status == 200)
        #expect(try response.json(Person.self) == Person(id: 7, name: "Ada"))
    }

    @Test func anAsyncHandlerTakesSeveralExtractors() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/pick/1?q=nobody").json(Chosen.self) == Chosen(who: "Grace"))
        // Out of the directory's range, so the query string answers instead.
        #expect(try client.get("/pick/9?q=nobody").json(Chosen.self) == Chosen(who: "nobody"))
    }

    @Test func anAsyncHandlerDecodesABody() throws {
        let response = try asyncRouteApp().test.post("/people", body: #"{"name":"Ada","age":36}"#)
        #expect(response.status == 201)
        #expect(try response.json(NewPerson.self) == NewPerson(name: "Ada", age: 36))
    }

    @Test func anAsyncHandlerReturningNilIs404() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/maybe/1").status == 200)
        #expect(try client.get("/maybe/2").status == 404)
    }

    @Test func aBadPathParameterIs400BeforeTheHandlerRuns() throws {
        #expect(try asyncRouteApp().test.get("/person/not-a-number").status == 400)
    }

    @Test func aConformingErrorAfterAWaitIsTheAnswer() throws {
        let response = try asyncRouteApp().test.get("/conflict")
        #expect(response.status == 409)
        #expect(response.text == #"{"error":"the name is taken"}"#)
    }

    @Test func anUnplannedErrorAfterAWaitIs500() throws {
        #expect(try asyncRouteApp().test.get("/boom").status == 500)
    }
}
