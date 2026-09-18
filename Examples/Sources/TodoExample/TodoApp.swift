//===----------------------------------------------------------------------===//
// A JSON CRUD API for todos, backed by SQLite.
//
//   GET    /todos?done=false&limit=20&offset=0   list, newest first
//   POST   /todos             {"title": "..."}     201 with the todo
//   GET    /todos/:id                              200, or 404
//   PATCH  /todos/:id         {"title"?, "done"?}  200 with the todo, or 404
//   DELETE /todos/:id                              204, or 404
//
// What it shows: typed routes with `Path`, `Query` and `Body`; state built in
// each worker with `app.state`; a schema migrated at start-up; validation
// answered as 422 and a unique title as 409, both with a JSON reason; and an
// Optional return for 404.
//===----------------------------------------------------------------------===//

import Garuda

public struct Todo: Codable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let done: Bool
    public let createdAt: Timestamp

    // Columns are snake_case; the JSON is camelCase. The row decoder matches
    // coding keys to column names, so the SQL renames the column instead.
}

/// A title is 1 to 200 characters once trimmed. Conforming to `Validated` is
/// all it takes: `Body<NewTodo>` checks the rules and answers 422 with the
/// field named before the handler runs.
struct NewTodo: Decodable, Validated {
    let title: String

    func validate(_ check: inout Validation) {
        check.notEmpty("title", title)
        check.length("title", title, atMost: 200)
    }
}

struct TodoChanges: Decodable, Validated {
    let title: String?
    let done: Bool?

    func validate(_ check: inout Validation) {
        // A title that is absent is not being changed; one that is there is
        // held to the same rule as a new todo's.
        check.notEmpty("title", title)
        check.length("title", title, atMost: 200)
    }
}

struct ListQuery: Decodable {
    let done: Bool?
    let limit: Int?
    let offset: Int?
}

/// Every column a `Todo` needs, named as its properties are.
private let columns = "id, title, done, created_at as createdAt"

let migrations = [
    """
    create table todos (
        id integer primary key,
        title text not null unique,
        done integer not null default 0,
        created_at text not null)
    """,
    "create index todos_done on todos (done, id)",
]

/// Runs `body`, answering a unique title as 409 rather than 500.
private func uniqueTitle<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as SQLiteClientError where error.sqliteCode == 2067 {
        throw HTTPError(.conflict, "a todo with that title exists")
    }
}

/// The todo API over the database at `path`. `:memory:` gives each worker an
/// empty database of its own, which suits tests.
public func todoApp(databasePath path: String) -> Application {
    let app = Application()

    app.state { _ in
        let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
        try db.migrate(migrations)
        return db
    }

    app.get("/todos") { (query: Query<ListQuery>, db: State<SQLiteDatabase>) async throws -> JSON<[Todo]> in
        let limit = min(max(query.value.limit ?? 20, 1), 100)
        let offset = max(query.value.offset ?? 0, 0)
        let todos: [Todo]
        if let done = query.value.done {
            todos = try await db.value.query(
                Todo.self, "select \(columns) from todos where done = ? order by id desc limit ? offset ?",
                done, limit, offset)
        } else {
            todos = try await db.value.query(
                Todo.self, "select \(columns) from todos order by id desc limit ? offset ?", limit, offset)
        }
        return JSON(todos)
    }

    app.post("/todos") { (body: Body<NewTodo>, db: State<SQLiteDatabase>) async throws -> JSON<Todo> in
        let title = body.value.title.trimmingWhitespace()
        let todo = try await uniqueTitle {
            try await db.value.first(
                Todo.self, "insert into todos (title, created_at) values (?, ?) returning \(columns)",
                title, Timestamp.now)
        }
        guard let todo else { throw HTTPError(.internalServerError) }
        return JSON(todo, status: .created)
    }

    app.get("/todos/:id") { (id: Path<Int>, db: State<SQLiteDatabase>) async throws -> JSON<Todo>? in
        try await db.value.first(Todo.self, "select \(columns) from todos where id = ?", id.value).map { JSON($0) }
    }

    app.patch("/todos/:id") { (id: Path<Int>, body: Body<TodoChanges>, db: State<SQLiteDatabase>)
        async throws -> JSON<Todo>? in
        let title = body.value.title?.trimmingWhitespace()
        // coalesce keeps what the request left out.
        let todo = try await uniqueTitle {
            try await db.value.first(
                Todo.self,
                "update todos set title = coalesce(?, title), done = coalesce(?, done) where id = ? returning \(columns)",
                title, body.value.done, id.value)
        }
        return todo.map { JSON($0) }
    }

    app.delete("/todos/:id") { (id: Path<Int>, db: State<SQLiteDatabase>) async throws -> HTTPStatus in
        let deleted = try await db.value.execute("delete from todos where id = ?", id.value)
        guard deleted == 1 else { throw HTTPError.notFound }
        return .noContent
    }

    return app
}

