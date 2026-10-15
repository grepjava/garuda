import Testing
import GarudaTesting
@testable import TodoExample

// The todo example driven through `app.test`: the real engine, routes and
// handlers, with no network. `:memory:` gives each test a database of its own.

@Suite("Todo example")
struct TodoExampleTests {
    @Test func createReadUpdateDelete() throws {
        let client = todoApp(databasePath: ":memory:").test

        let created = try client.post("/todos", body: #"{"title":"  write the docs "}"#)
        #expect(created.status == .created)
        let todo = try created.json(Todo.self)
        #expect(todo.id == 1 && todo.title == "write the docs" && !todo.done)

        #expect(try client.get("/todos/1").json(Todo.self) == todo)
        #expect(try client.get("/todos/2").status == .notFound)

        let patched = try client.patch("/todos/1", body: #"{"done":true}"#)
        #expect(patched.status == .ok)
        #expect(try patched.json(Todo.self).done)
        #expect(try patched.json(Todo.self).title == "write the docs")

        #expect(try client.delete("/todos/1").status == .noContent)
        #expect(try client.delete("/todos/1").status == .notFound)
        #expect(try client.get("/todos/1").status == .notFound)
    }

    @Test func listsFilterAndPage() throws {
        let client = todoApp(databasePath: ":memory:").test
        for title in ["one", "two", "three", "four"] {
            #expect(try client.post("/todos", body: "{\"title\":\"\(title)\"}").status == .created)
        }
        _ = try client.patch("/todos/2", body: #"{"done":true}"#)

        #expect(try client.get("/todos").json([Todo].self).map(\.title) == ["four", "three", "two", "one"])
        #expect(try client.get("/todos?done=true").json([Todo].self).map(\.title) == ["two"])
        #expect(try client.get("/todos?done=false&limit=2").json([Todo].self).map(\.title) == ["four", "three"])
        #expect(try client.get("/todos?limit=2&offset=2").json([Todo].self).map(\.title) == ["two", "one"])
        #expect(try client.get("/todos?limit=many").status == .badRequest)
    }

    @Test func badInputIsRefusedWithAReason() throws {
        let client = todoApp(databasePath: ":memory:").test
        let blank = try client.post("/todos", body: #"{"title":"   "}"#)
        #expect(blank.status == .unprocessableContent)
        // The field is named, so a form knows where to put the message.
        #expect(blank.text == #"{"error":"title must not be empty","#
                    + #""fields":[{"field":"title","message":"must not be empty"}]}"#, "\(blank.text)")
        #expect(try client.post("/todos", body: #"{"name":"x"}"#).status == .badRequest)

        #expect(try client.post("/todos", body: #"{"title":"same"}"#).status == .created)
        let duplicate = try client.post("/todos", body: #"{"title":"same"}"#)
        #expect(duplicate.status == .conflict)
        #expect(duplicate.text.contains("exists"))

        #expect(try client.post("/todos", body: #"{"title":"other"}"#).status == .created)
        let renamed = try client.patch("/todos/2", body: #"{"title":"same"}"#)
        #expect(renamed.status == .conflict)
    }
}
