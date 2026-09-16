import Testing
import CGaruda
import GarudaCore
import GarudaPostgres
@testable import Garuda

// The PostgreSQL driver against a real server.
//
// Opt-in: set GARUDA_POSTGRES to host:port:user:password:database, for example
//
//     GARUDA_POSTGRES=127.0.0.1:55432:garuda:garuda-secret:postgres swift test
//
// and these run; without it they are skipped, so the unit suite never depends
// on a database being up. The scripted-server tests cover what an honest
// server never does; these cover what it does, which a script can only agree
// with.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var run: (@Sendable (UnsafeMutablePointer<Worker>) async -> String)? = nil

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

private func app() -> Application {
    let app = Application()
    app.onAsync(.get, "/run") { request, response in
        let worker = request.worker
        outcome = await run?(worker) ?? "no body"
        response.send(outcome)
    }
    return app
}

/// Runs `body` inside a handler on a worker, and returns what it reported.
private func onWorker(_ body: @escaping @Sendable (UnsafeMutablePointer<Worker>) async -> String) throws -> String {
    outcome = ""
    run = body
    let client = app().test
    let wire = try TestWire(client)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    _ = wire.turn(until: { !outcome.isEmpty }, turns: 2_000_000)
    return outcome
}

private func describe(_ error: Error) -> String {
    if let error = error as? PostgresClientError,
       case .postgres(.server(let fields)) = error {
        return "server:\(fields.code)"
    }
    return "\(error)"
}

@Suite("PostgreSQL against a real server", .serialized,
       .enabled(if: target != nil, "set GARUDA_POSTGRES to run"))
struct PostgresIntegrationTests {

    @Test func connectsWithSCRAMAndRunsAQuery() throws {
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query("select $1::int + 1 as answer", ["41"])
                return rows.text(row: 0, column: 0) ?? "null"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "42")
    }

    @Test func aWrongPasswordIsRefusedByTheServer() throws {
        var wrong = try #require(target)
        wrong.password = "not-the-password"
        let configuration = wrong
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                connection.close()
                return "connected"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "server:28P01")
    }

    @Test func aFailedStatementLeavesTheConnectionUsable() throws {
        // The server refuses the statement and then says it is ready. That is
        // a statement failing, not a connection failing, and the next query
        // on the same connection has to work.
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                var first = ""
                do {
                    _ = try await connection.query("select * from no_such_table")
                    first = "unexpectedly ran"
                } catch {
                    first = describe(error)
                }
                let rows = try await connection.query("select 'still here'")
                return first + "|" + (rows.text(row: 0, column: 0) ?? "null")
            } catch {
                return describe(error)
            }
        }
        #expect(text == "server:42P01|still here")
    }

    @Test func manyRowsAndNullsComeBack() throws {
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query(
                    "select n, case when n % 10 = 0 then null else 'v' || n end from generate_series(1, 5000) n")
                let nulls = (0..<rows.count).filter { rows.text(row: $0, column: 1) == nil }.count
                return "\(rows.count)|\(nulls)|\(rows.text(row: 4999, column: 0) ?? "")|\(rows.affected)"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "5000|500|5000|5000")
    }

    @Test func anInjectionStringIsOnlyEverAValue() throws {
        let configuration = try #require(target)
        let hostile = "x'); drop table pg_class; --"
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query("select $1::text, length($1::text)", [hostile])
                return (rows.text(row: 0, column: 0) ?? "") + "|" + (rows.text(row: 0, column: 1) ?? "")
            } catch {
                return describe(error)
            }
        }
        #expect(text == "\(hostile)|\(hostile.count)")
    }

    @Test func requiringTLSNeverSettlesForLess() throws {
        // Required means required, and there are two ways a test server falls
        // short of it. One with no TLS answers the request with N, and the
        // connection fails rather than carrying on in the clear. One with TLS
        // on a certificate nobody vouches for -- Ubuntu's packages ship with
        // a self-signed "snakeoil" one -- answers S and then fails
        // verification. Both are refusals; what must never happen is
        // connecting. Which one a given server produces is its configuration,
        // not this client's choice, so both are accepted.
        var required = try #require(target)
        required.tls = .require
        let configuration = required
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                connection.close()
                return "connected"
            } catch {
                return "\(error)"
            }
        }
        #expect(text == "tlsUnavailable" || text.hasPrefix("connect("), "got \(text)")
    }

    // MARK: Prepared statements

    /// Runs `body` on one connection with a statement cache of `capacity`.
    private func onConnection(capacity: Int = 256,
                              _ body: @escaping @Sendable (PostgresConnection) async throws -> String) throws -> String {
        var configuration = try #require(target)
        configuration.statementCacheCapacity = capacity
        let settings = configuration
        return try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, settings)
                defer { connection.close() }
                return try await body(connection)
            } catch {
                return describe(error)
            }
        }
    }

    /// What the server says this session has prepared, counting the statement
    /// asking, which is prepared too.
    private static func preparedOnServer(_ connection: PostgresConnection) async throws -> String {
        try await connection.query("select count(*) from pg_prepared_statements").text(row: 0, column: 0) ?? "null"
    }

    /// The name the cache prepared `sql` under.
    private static func nameOf(_ sql: String, _ connection: PostgresConnection) -> String {
        connection.prepared.first { $0.key.sql == sql }?.value.name ?? "none"
    }

    @Test func aStatementRunAgainIsPreparedOnce() throws {
        let text = try onConnection { connection in
            var answers: [String] = []
            for n in 1...3 {
                let rows = try await connection.query("select $1::int + 1", [String(n)])
                answers.append(rows.text(row: 0, column: 0) ?? "null")
            }
            return answers.joined(separator: ",") + "|" + (try await Self.preparedOnServer(connection))
                + "|" + String(connection.prepared.count)
        }
        #expect(text == "2,3,4|2|2")
    }

    @Test func aFullCacheClosesTheLeastRecentlyUsed() throws {
        let text = try onConnection(capacity: 3) { connection in
            _ = try await connection.query("select 1")
            _ = try await connection.query("select 2")
            _ = try await connection.query("select 1")   // 2 is now the least recent
            _ = try await connection.query("select 3")
            let server = try await Self.preparedOnServer(connection)
            let kept = connection.prepared.keys.map(\.sql).sorted().joined(separator: ",")
            return server + "|" + kept
        }
        #expect(text == "3|select 1,select 3,select count(*) from pg_prepared_statements")
    }

    @Test func aCacheOfNothingPreparesNothing() throws {
        let text = try onConnection(capacity: 0) { connection in
            _ = try await connection.query("select 1")
            return try await Self.preparedOnServer(connection) + "|" + String(connection.prepared.count)
        }
        #expect(text == "0|0")
    }

    @Test func discardAllEmptiesTheCache() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("select 1")
            _ = try await connection.query("discard all")
            let after = connection.prepared.count
            let rows = try await connection.query("select 1")
            return "\(after)|" + (rows.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "0|1")
    }

    @Test func aStatementDeallocatedBehindTheCachesBackIsPreparedAgain() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("select 'first'")
            let name = Self.nameOf("select 'first'", connection)
            _ = try await connection.query("deallocate \(name)")
            let rows = try await connection.query("select 'first'")
            return rows.text(row: 0, column: 0) ?? "null"
        }
        #expect(text == "first")
    }

    @Test func aTableThatChangesShapeUnderAStatementIsPreparedAgain() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("create temporary table shapes (a int)")
            _ = try await connection.query("insert into shapes values (7)")
            let before = try await connection.query("select * from shapes")
            _ = try await connection.query("alter table shapes add column b text default 'new'")
            let after = try await connection.query("select * from shapes")
            return "\(before.columns.count)|\(after.columns.count)|" + (after.text(row: 0, column: 1) ?? "null")
        }
        #expect(text == "1|2|new")
    }

    @Test func aStaleStatementInsideATransactionIsReportedNotRetried() throws {
        // The refusal has already failed the transaction: running the
        // statement again inside it could only be refused again.
        let text = try onConnection { connection in
            _ = try await connection.query("select 'x'")
            let name = Self.nameOf("select 'x'", connection)
            _ = try await connection.query("begin")
            _ = try await connection.query("deallocate \(name)")
            var outcome = ""
            do {
                _ = try await connection.query("select 'x'")
                outcome = "ran"
            } catch {
                outcome = describe(error)
            }
            _ = try await connection.query("rollback")
            let rows = try await connection.query("select 'x'")
            return outcome + "|" + (rows.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "server:26000|x")
    }

    @Test func theSameSQLWithValuesOfAnotherTypeIsAnotherStatement() throws {
        // Bytes declare their type when the statement is parsed. Reusing that
        // statement for text would have the server read the text as bytea.
        let text = try onConnection { connection in
            let bytes = try await connection.query("select $1::text", values: [.binary(Array("hi".utf8), type: PostgresType.bytea)])
            let words = try await connection.query("select $1::text", values: [PostgresValue("hello")])
            return (bytes.text(row: 0, column: 0) ?? "null") + "|" + (words.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "\\x6869|hello")
    }

    @Test func aStatementThatFailsToParseIsNotKept() throws {
        let text = try onConnection { connection in
            var outcome = ""
            do {
                _ = try await connection.query("selec 1")
            } catch {
                outcome = describe(error)
            }
            return outcome + "|" + String(connection.prepared.count)
        }
        #expect(text == "server:42601|0")
    }

    @Test func onlyTheStatementThatFoundItsPreparationStaleIsRunAgain() throws {
        // A sequence is not rolled back with the statement that advanced it,
        // so it counts how many times a failing statement really ran.
        let text = try onConnection { connection in
            _ = try await connection.query("create temporary sequence attempts")
            _ = try await connection.query("select 'stale soon'")
            let name = Self.nameOf("select 'stale soon'", connection)
            _ = try await connection.query("deallocate \(name)")
            _ = try await connection.query("select 'stale soon'")        // refused once, run again
            do {
                _ = try await connection.query("select nextval('attempts') / 0")
            } catch {}
            return try await connection.query("select last_value from attempts").text(row: 0, column: 0) ?? "null"
        }
        #expect(text == "1")
    }
}
