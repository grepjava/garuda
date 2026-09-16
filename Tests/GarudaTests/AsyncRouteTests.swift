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
}

private struct Chosen: Codable, Equatable {
    var who: String
}

/// State an async handler asks for, to prove extraction reaches a task.
private final class Directory {
    let names = ["Ada", "Grace"]
    func name(_ id: Int) -> String? { names.indices.contains(id) ? names[id] : nil }
}

private func asyncRouteApp() -> Application {
    let app = Application()
    app.state { _ in Directory() }

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
    // Several extractors, in the order declared, plus state.
    app.get("/pick/:id") { (id: Path<Int>, query: Query<Search>,
                            directory: State<Directory>) async throws -> JSON<Chosen> in
        await Task.yield()
        let who = directory.value.name(id.value) ?? query.value.q
        return JSON(Chosen(who: who))
    }
    // A body decoded before the handler body runs.
    app.post("/people") { (body: Body<NewPerson>) async throws -> JSON<NewPerson> in
        await Task.yield()
        return JSON(body.value, status: .created)
    }
    // nil is the ordinary 404, from a task like anywhere else.
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
    // The synchronous overload, spelled the same way, for the comparison.
    app.get("/sync-hello") {
        "hello"
    }
    app.get("/sync-person/:id") { (id: Path<Int>) in
        JSON(Person(id: id.value, name: "Ada"))
    }
    return app
}

private struct Boom: Error {}

/// Serialized for the same reason as the handler task tests: each client turns
/// a worker on the test's own thread.
@Suite("Async routes", .serialized)
struct AsyncRouteTests {
    @Test func anAsyncHandlerTakingNothingAnswers() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/hello")
        #expect(response.status == 200)
        #expect(response.text == "hello")
    }

    @Test func anAsyncHandlerTakesAPathParameter() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/person/7")
        #expect(response.status == 200)
        #expect(try response.json(Person.self) == Person(id: 7, name: "Ada"))
    }

    @Test func anAsyncHandlerTakesSeveralExtractorsAndState() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/pick/1?q=nobody").json(Chosen.self) == Chosen(who: "Grace"))
        // Out of the directory's range, so the query string answers instead.
        #expect(try client.get("/pick/9?q=nobody").json(Chosen.self) == Chosen(who: "nobody"))
    }

    @Test func anAsyncHandlerDecodesABody() throws {
        let client = asyncRouteApp().test
        let response = try client.post("/people", body: #"{"name":"Ada","age":36}"#)
        #expect(response.status == 201)
        #expect(try response.json(NewPerson.self) == NewPerson(name: "Ada", age: 36))
    }

    @Test func anAsyncHandlerReturningNilIs404() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/maybe/1").status == 200)
        #expect(try client.get("/maybe/2").status == 404)
    }

    @Test func aBadPathParameterIs400BeforeTheHandlerRuns() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/person/not-a-number").status == 400)
    }

    @Test func aConformingErrorFromATaskIsTheAnswer() throws {
        let client = asyncRouteApp().test
        let response = try client.get("/conflict")
        #expect(response.status == 409)
        #expect(response.text == #"{"error":"the name is taken"}"#)
    }

    @Test func anUnplannedErrorFromATaskIs500() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/boom").status == 500)
    }

    /// The overloads differ only in whether the closure awaits, so this is the
    /// test that they do not quietly trade places: a synchronous handler must
    /// never reach the pool, and an async one must.
    @Test func onlyTheAwaitingHandlersUseTasks() throws {
        let client = asyncRouteApp().test
        #expect(try client.get("/sync-hello").text == "hello")
        #expect(try client.get("/sync-person/3").status == 200)
        #expect(client.worker.pointee.handlerTasks == nil)

        #expect(try client.get("/hello").text == "hello")
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 1)
    }

    @Test func asyncHandlersShareTheWorkersTasks() throws {
        let client = asyncRouteApp().test
        for _ in 0..<20 {
            #expect(try client.get("/person/1").status == 200)
            #expect(try client.get("/hello").status == 200)
        }
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 1)
        #expect(pool.idleCount == 1)
    }
}
