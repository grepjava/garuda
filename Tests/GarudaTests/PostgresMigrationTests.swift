import Testing
import CAvian
import AvianCore
import GarudaPostgres
@testable import Garuda

// `pool.migrate`: a fresh schema, one appended migration, nothing left to do,
// a build older than the database, and a migration that fails part-way.
//
// Opt-in through GARUDA_POSTGRES, like the driver's own integration tests.

private let migrationTarget: PostgresConfiguration? = {
    guard let raw = av_getenv("GARUDA_POSTGRES") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

/// Runs `body` against a pool on a worker, as a handler would, and answers
/// with what it returns.
private func onAPool(_ body: @escaping @Sendable (PostgresPool) async throws -> String) throws -> String {
    let configuration = migrationTarget!
    let app = Application()
    app.state { _ in PostgresPool(configuration, maxConnections: 2) }
    app.get("/run") { (db: State<PostgresPool>) async -> String in
        do {
            return try await body(db.value)
        } catch {
            return "threw \(error)"
        }
    }
    let client = app.test
    client.timeoutMillis = 20_000
    return try client.get("/run").text
}

@Suite("PostgreSQL migrations", .serialized)
struct PostgresMigrationTests {
    @Test(.enabled(if: migrationTarget != nil, "set GARUDA_POSTGRES to run"))
    func aSchemaIsBroughtUpToDateOnce() throws {
        let text = try onAPool { pool in
            let table = "garuda_test_version"
            let notes = "garuda_test_notes"
            for statement in ["drop table if exists \(notes)", "drop table if exists \(table)"] {
                try await pool.execute(statement)
            }
            var out: [String] = []
            let first: [[String]] = [["create table \(notes) (id bigserial primary key, body text not null)"]]
            out.append("\(try await pool.migrate(first, table: table))")
            // Nothing left to do, however many workers start.
            out.append("\(try await pool.migrate(first, table: table))")
            try await pool.execute("insert into \(notes) (body) values ($1)", "kept")

            // An appended migration runs, and only it. Two statements in one
            // migration go together.
            let second: [[String]] = first + [[
                "alter table \(notes) add column title text",
                "create index \(notes)_title on \(notes) (title)",
            ]]
            out.append("\(try await pool.migrate(second, table: table))")
            out.append("\(try await pool.migrate(second, table: table))")
            struct Note: Decodable { let body: String; let title: String? }
            let rows = try await pool.query(Note.self, "select body, title from \(notes)")
            out.append("\(rows.count == 1 && rows[0].body == "kept" && rows[0].title == nil)")
            struct Version: Decodable { let version: Int }
            let version = try await pool.first(Version.self, "select max(version) as version from \(table)")
            out.append("\(version?.version ?? -1)")

            // A build older than the database refuses rather than migrating
            // backwards.
            do {
                _ = try await pool.migrate(first, table: table)
                out.append("no error")
            } catch let error as PostgresMigrationError {
                out.append("\(error == .unknownSchemaVersion(found: 2, known: 1))")
            }

            // A migration that fails part-way leaves nothing behind: not the
            // table its first statement made, nor a new version.
            let broken: [[String]] = second + [[
                "create table \(notes)_extra (id bigint)",
                "this is not sql",
            ]]
            do {
                _ = try await pool.migrate(broken, table: table)
                out.append("no error")
            } catch {
                out.append("refused")
            }
            struct Found: Decodable { let found: Bool }
            let extra = try await pool.first(
                Found.self, "select count(*) > 0 as found from information_schema.tables where table_name = $1",
                "\(notes)_extra")
            out.append("\(extra?.found == false)")
            let after = try await pool.first(Version.self, "select max(version) as version from \(table)")
            out.append("\(after?.version ?? -1)")

            for statement in ["drop table if exists \(notes)", "drop table if exists \(table)"] {
                try await pool.execute(statement)
            }
            return out.joined(separator: " ")
        }
        #expect(text == "1 0 1 0 true 2 true refused true 2", "\(text)")
    }
}
