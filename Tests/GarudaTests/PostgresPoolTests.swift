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

private func crudApp(maxConnections: Int = 4, acquireTimeoutMilliseconds: UInt64? = nil) -> Application {
    let app = Application()
    let configuration = target!
    app.state { _ in
        let pool = PostgresPool(configuration, maxConnections: maxConnections,
                                acquireTimeoutMilliseconds: acquireTimeoutMilliseconds)
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

    // Holds a connection for a while, inside a transaction.
    app.get("/hold") { (db: State<PostgresPool>) async throws -> String in
        try await db.value.transaction { tx in
            try await tx.execute("select pg_sleep(0.4)")
        }
        return "held"
    }

    // Says why a statement failed, rather than answering 500.
    app.get("/count-why") { (db: State<PostgresPool>) async throws -> String in
        do {
            return String(try await db.value.first(Int.self, "select count(*) from garuda_pool_users") ?? -1)
        } catch let error as PostgresClientError {
            return "\(error)"
        }
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

    app.get("/tx/commit") { (db: State<PostgresPool>) async throws -> String in
        try await db.value.transaction { tx in
            try await tx.execute("insert into garuda_pool_users (name) values ($1)", "one")
            try await tx.execute("insert into garuda_pool_users (name) values ($1)", "two")
        }
        return "committed"
    }

    app.get("/tx/throw") { (db: State<PostgresPool>) async throws -> String in
        struct Abandon: Error {}
        do {
            try await db.value.transaction { tx in
                try await tx.execute("insert into garuda_pool_users (name) values ($1)", "gone")
                throw Abandon()
            }
            return "committed"
        } catch is Abandon {
            return "rolled back"
        }
    }

    // A statement fails inside the transaction and the body swallows the
    // error and returns as though nothing happened.
    app.get("/tx/swallow") { (db: State<PostgresPool>) async throws -> String in
        do {
            try await db.value.transaction { tx in
                try await tx.execute("insert into garuda_pool_users (name) values ($1)", "lost")
                _ = try? await tx.execute("select * from no_such_table")
            }
            return "committed"
        } catch let error as PostgresClientError {
            return "refused:\(error.sqlState ?? "")"
        }
    }

    // After a failure inside a transaction, every further statement is
    // refused by the server with 25P02 -- the same code the driver uses for
    // its own refusal, which is why the driver must not tell them apart by
    // code.
    app.get("/tx/aborted-statement") { (db: State<PostgresPool>) async throws -> String in
        do {
            try await db.value.transaction { tx in
                _ = try? await tx.execute("select * from no_such_table")
                try await tx.execute("insert into garuda_pool_users (name) values ($1)", "never")
            }
            return "committed"
        } catch let error as PostgresClientError {
            return "refused:\(error.sqlState ?? "")"
        }
    }

    // Begins a transaction by hand and returns without ending it.
    app.get("/raw-begin") { (db: State<PostgresPool>) async throws -> String in
        try await db.value.execute("begin")
        return "left open"
    }

    // Inside an open transaction now() is frozen at BEGIN, so after a pause the
    // statement's own timestamp is well past it. In autocommit every statement
    // is its own transaction and the two are microseconds apart -- not equal,
    // which a first version assumed and which the extended protocol does not
    // give, since they are stamped at different messages. Hence a margin.
    app.get("/in-transaction") { (db: State<PostgresPool>) async throws -> String in
        let stale = try await db.value.first(
            Bool.self, "select statement_timestamp() - now() > interval '20 milliseconds'")
        return stale == true ? "yes" : "no"
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

    @Test func aWaitForAConnectionGivesUpAtItsDeadline() throws {
        // One connection, held far longer than the pool lets anyone wait.
        let client = crudApp(maxConnections: 1, acquireTimeoutMilliseconds: 50).test
        _ = try get(client, "/setup")
        let holder = try TestWire(client)
        holder.send("GET /hold HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(holder.turn(until: { poolForTests.map { $0.counts == (open: 1, idle: 0) } ?? false }, turns: 200_000))

        let began = pg_monotonic_us()
        let waiter = try TestWire(client)
        waiter.send("GET /count-why HTTP/1.1\r\nHost: test\r\n\r\n")
        let refused = waiter.receive(turns: 2_000_000) ?? "no response"
        let waited = (pg_monotonic_us() &- began) / 1000
        #expect(body(refused) == "poolTimedOut")
        #expect(waited >= 50 && waited < 350, "waited \(waited) ms")
        // Out of the queue as soon as it gave up, not when a release reaches
        // it: with every connection stuck, none might.
        #expect(poolForTests?.waitingCount == 0)

        #expect(body(holder.receive(turns: 2_000_000) ?? "no response") == "held")
        // The wait that gave up left nothing queued: the next statement gets
        // the connection back.
        #expect(body(try get(client, "/count-why")) == "0")
        #expect(client.worker.pointee.timedWaits.isEmpty)
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

    // MARK: Transactions

    @Test func aTransactionThatReturnsIsCommitted() throws {
        let client = crudApp().test
        _ = try get(client, "/setup")
        #expect(body(try get(client, "/tx/commit")) == "committed")
        #expect(body(try get(client, "/count")) == "2")
    }

    @Test func aTransactionThatThrowsIsRolledBack() throws {
        let client = crudApp().test
        _ = try get(client, "/setup")
        #expect(body(try get(client, "/tx/throw")) == "rolled back")
        #expect(body(try get(client, "/count")) == "0")
    }

    @Test func aFailedTransactionIsNeverReportedAsCommitted() throws {
        // PostgreSQL answers COMMIT on a failed transaction by rolling back
        // and saying ROLLBACK, not by failing. A body that swallowed the error
        // and returned would be told its work was saved.
        let client = crudApp().test
        _ = try get(client, "/setup")
        #expect(body(try get(client, "/tx/swallow")) == "refused:25P02")
        #expect(body(try get(client, "/count")) == "0")
    }

    @Test func theServersOwn25P02DoesNotLoseTheConnection() throws {
        // The server refuses a statement in an aborted transaction with
        // 25P02. That error must go through the rollback and the release like
        // any other -- a pool that took it for the driver's own would lose the
        // connection for good, and with one slot, every request after it
        // would wait forever.
        let client = crudApp(maxConnections: 1).test
        _ = try get(client, "/setup")
        #expect(body(try get(client, "/tx/aborted-statement")) == "refused:25P02")
        let after = try get(client, "/count")
        #expect(status(after) == 200, "\(after)")
        #expect(try #require(poolForTests).counts.open == 1)
    }

    @Test func aTransactionLeftOpenIsNotHandedToTheNextRequest() throws {
        // A handler runs `begin` itself and returns. Reused, that connection
        // would carry the open transaction into the next request, whose
        // statements would run inside it. Closed instead, the server rolls
        // it back.
        //
        // The first version of this test ran `begin` and then an insert as
        // two pool calls, expecting the insert to be uncommitted. It came
        // back committed -- correctly: the pool closed the connection `begin`
        // left open, and the insert ran on a fresh one in autocommit. The pool
        // never pins a connection across separate calls, which is what
        // `transaction` is for. What can be tested is whether the *next*
        // request finds itself inside a transaction it never began.
        let client = crudApp(maxConnections: 1).test
        _ = try get(client, "/setup")
        #expect(body(try get(client, "/raw-begin")) == "left open")
        #expect(try #require(poolForTests).counts == (open: 0, idle: 0))
        // Long enough for a frozen now() to differ from a fresh timestamp.
        let began = pg_monotonic_ms()
        while pg_monotonic_ms() &- began < 30 { client.turn() }
        #expect(body(try get(client, "/in-transaction")) == "no")
    }

    @Test func aRowMissingAColumnTheTypeNeedsIsAServerFault() throws {
        // The program's mistake, not the client's: 500, not 400.
        let client = crudApp().test
        _ = try get(client, "/setup")
        _ = try post(client, "/user", json: #"{"name":"Ada"}"#)
        #expect(status(try get(client, "/wrong-shape")) == 500)
    }
}
