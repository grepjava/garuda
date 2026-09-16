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
}
