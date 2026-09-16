import Testing
import CGaruda
import GarudaCore
import GarudaPostgres
@testable import Garuda

// The milestone the handler API is judged by, against a real PostgreSQL: a
// JSON CRUD API backed by a database, written with typed routes and state,
// without pointers, integer state slots, manual JSON or engine internals.
//
// Opt-in through GARUDA_POSTGRES, like the driver's own integration tests.

private let target: PostgresConfiguration? = {
    guard let raw = pg_getenv("GARUDA_POSTGRES") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

struct PoolUser: Codable, Equatable {
    let id: Int
    let name: String
    let email: String?
    let active: Bool
}

struct NewPoolUser: Decodable {
    let name: String
    let email: String?
}

/// A column the type expects that the query will not return.
struct PoolUserWithAge: Decodable {
    let id: Int
    let age: Int
}

nonisolated(unsafe) private var poolForTests: PostgresPool? = nil

private func crudApp(maxConnections: Int = 4) -> Application {
    let app = Application()
    let configuration = target!
    app.state { _ in
        let pool = PostgresPool(configuration, maxConnections: maxConnections)
        poolForTests = pool
        return pool
    }

    app.get("/setup") { (db: State<PostgresPool>) async throws -> String in
        try await db.value.execute("""
            create table if not exists garuda_pool_users (
                id serial primary key,
                name text not null,
                email text unique,
                active boolean not null default true)
            """)
        try await db.value.execute("truncate garuda_pool_users restart identity")
        return "ready"
    }

    app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws -> JSON<PoolUser>? in
        try await db.value.first(PoolUser.self,
                                 "select id, name, email, active from garuda_pool_users where id = $1",
                                 id.value).map { JSON($0) }
    }

    app.post("/user") { (body: Body<NewPoolUser>, db: State<PostgresPool>) async throws -> JSON<PoolUser> in
        do {
            guard let user = try await db.value.first(
                PoolUser.self,
                "insert into garuda_pool_users (name, email) values ($1, $2) returning id, name, email, active",
                body.value.name, body.value.email) else {
                throw HTTPError(.internalServerError)
            }
            return JSON(user, status: .created)
        } catch let error as PostgresClientError where error.sqlState == "23505" {
            // A unique violation is the client asking for something that
            // exists, and says so -- branching on the SQLSTATE, never on the
            // localised message.
            throw HTTPError(.conflict, "that email is taken")
        }
    }

    app.get("/count") { (db: State<PostgresPool>) async throws -> String in
        String(try await db.value.first(Int.self, "select count(*) from garuda_pool_users") ?? -1)
    }

    app.get("/slow") { (db: State<PostgresPool>) async throws -> String in
        String(try await db.value.first(Int.self, "select 1 from pg_sleep(0.05)") ?? -1)
    }

    app.get("/pid") { (db: State<PostgresPool>) async throws -> String in
        String(try await db.value.first(Int.self, "select pg_backend_pid()") ?? -1)
    }

    // Terminates a backend from a connection of its own, outside the pool, so
    // the pool's connection is idle -- not mid-query -- when the server ends it.
    app.onAsync(.get, "/terminate-outside/:pid") { request, response in
        let worker = request.worker
        let pid = request.withParameter(0) { span in
            Int(String(decoding: UnsafeBufferPointer(start: span.withUnsafeBufferPointer { $0.baseAddress },
                                                     count: span.count), as: UTF8.self)) ?? 0
        }
        var answer = "failed"
        do {
            let outside = try await PostgresConnection.connect(worker, configuration)
            let rows = try await outside.query("select pg_terminate_backend($1)", [String(pid)])
            answer = rows.text(row: 0, column: 0) ?? "null"
            outside.close()
        } catch {
            answer = "\(error)"
        }
        response.send(answer)
    }

    app.get("/wrong-shape") { (db: State<PostgresPool>) async throws -> String in
        let rows = try await db.value.query(PoolUserWithAge.self, "select id from garuda_pool_users")
        return String(rows.count)
    }

    return app
}

@Suite("PostgreSQL pool and typed routes", .serialized,
       .enabled(if: target != nil, "set GARUDA_POSTGRES to run"))
struct PostgresPoolTests {

    private func send(_ client: TestClient, _ raw: String, turns: Int = 2_000_000) throws -> String {
        let wire = try TestWire(client)
        wire.send(raw)
        return wire.receive(turns: turns) ?? "no response"
    }

    private func get(_ client: TestClient, _ path: String) throws -> String {
        try send(client, "GET \(path) HTTP/1.1\r\nHost: test\r\n\r\n")
    }

    private func post(_ client: TestClient, _ path: String, json: String) throws -> String {
        try send(client, "POST \(path) HTTP/1.1\r\nHost: test\r\nContent-Type: application/json\r\n"
                 + "Content-Length: \(json.utf8.count)\r\n\r\n\(json)")
    }

    private func body(_ response: String) -> String {
        let bytes = Array(response.utf8)
        guard let range = bytes.firstRange(of: [13, 10, 13, 10]) else { return response }
        return String(decoding: bytes[range.upperBound...], as: UTF8.self)
    }

    private func status(_ response: String) -> Int {
        let parts = response.split(separator: " ", maxSplits: 2)
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    @Test func createReadAndConflict() throws {
        let client = crudApp().test
        #expect(body(try get(client, "/setup")) == "ready")

        let created = try post(client, "/user", json: #"{"name":"Ada","email":"ada@example.com"}"#)
        #expect(status(created) == 201)
        #expect(body(created) == #"{"id":1,"name":"Ada","email":"ada@example.com","active":true}"#)

        let read = try get(client, "/user/1")
        #expect(status(read) == 200)
        #expect(body(read) == #"{"id":1,"name":"Ada","email":"ada@example.com","active":true}"#)

        // A NULL column into an Optional property. The key is absent from the
        // JSON rather than null: synthesized Encodable writes an Optional with
        // encodeIfPresent, which omits nil, as every Swift JSON encoder does.
        let noEmail = try post(client, "/user", json: #"{"name":"Grace"}"#)
        #expect(body(noEmail) == #"{"id":2,"name":"Grace","active":true}"#)

        // Missing is the ordinary 404 -- nil from `first` returned as is.
        #expect(status(try get(client, "/user/99")) == 404)

        let taken = try post(client, "/user", json: #"{"name":"Imposter","email":"ada@example.com"}"#)
        #expect(status(taken) == 409)
        #expect(body(try get(client, "/count")) == "2")
    }

    @Test func connectionsAreReusedRatherThanOpenedPerRequest() throws {
        let client = crudApp().test
        _ = try get(client, "/setup")
        for _ in 0..<20 { _ = try get(client, "/count") }
        let counts = try #require(poolForTests).counts
        #expect(counts.open == 1)
        #expect(counts.idle == 1)
    }

    @Test func requestsBeyondThePoolWaitTheirTurn() throws {
        // Five slow requests at once through a pool of two. None may fail for
        // want of a connection, and the pool may never open a third.
        let client = crudApp(maxConnections: 2).test
        _ = try get(client, "/setup")
        let wires = try (0..<5).map { _ in try TestWire(client) }
        for wire in wires { wire.send("GET /slow HTTP/1.1\r\nHost: test\r\n\r\n") }
        var answers: [String] = []
        for wire in wires { answers.append(wire.receive(turns: 2_000_000) ?? "no response") }
        #expect(answers.allSatisfy { status($0) == 200 && body($0) == "1" }, "\(answers)")
        let counts = try #require(poolForTests).counts
        #expect(counts.open <= 2)
    }

    @Test func aConnectionTheServerClosedWhileIdleIsNotUsed() throws {
        // The server ends an idle connection -- an idle timeout, a restart,
        // here pg_terminate_backend from another session. The next request
        // must not write its statement into the dead one: it cannot tell
        // afterwards whether the statement ran. The pool checks an idle
        // connection for pending input before handing it out.
        //
        // An earlier version terminated the backend from a request running
        // at the same time as one using it. That killed a connection mid-
        // query, whose own failed read closed it -- so no dead connection was
        // ever left idle, and the test passed with the check deleted. The
        // termination has to come from outside the pool, while the pool's
        // one connection sits idle.
        let client = crudApp(maxConnections: 2).test
        _ = try get(client, "/setup")
        let pid = body(try get(client, "/pid"))
        #expect(Int(pid) != nil)
        #expect(try #require(poolForTests).counts == (open: 1, idle: 1))

        #expect(body(try get(client, "/terminate-outside/\(pid)")) == "t")
        // pg_terminate_backend signals and returns; the backend's goodbye
        // reaches the socket a moment later. Real time, not turns.
        let began = pg_monotonic_ms()
        while pg_monotonic_ms() &- began < 300 { client.turn() }

        let answer = try get(client, "/count")
        #expect(status(answer) == 200, "\(answer)")
        #expect(body(answer) == "0")
    }

    @Test func aRowMissingAColumnTheTypeNeedsIsAServerFault() throws {
        // The program's mistake, not the client's: 500, not 400.
        let client = crudApp().test
        _ = try get(client, "/setup")
        _ = try post(client, "/user", json: #"{"name":"Ada"}"#)
        #expect(status(try get(client, "/wrong-shape")) == 500)
    }
}
