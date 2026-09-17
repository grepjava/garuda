//===----------------------------------------------------------------------===//
// Bringing a PostgreSQL schema up to date, the same way `SQLiteDatabase`
// does: an ordered list that only ever grows, and a version the database
// keeps.
//
//     let migrations: [[String]] = [
//         ["""
//          create table users (id bigserial primary key, email text not null unique,
//                              password text not null, created_at timestamptz not null default now())
//          """],
//         ["alter table users add column name text",
//          "create index users_created_at on users (created_at)"],
//     ]
//
//     app.state { _ in PostgresPool(configuration) }
//     app.prepare { start in
//         try await start.state(PostgresPool.self).migrate(migrations)
//     }
//
// Each migration is the statements it needs, run together in one transaction,
// so a migration that half-succeeds does not exist. A list rather than one
// string because the driver sends one statement per message, and splitting SQL
// on semicolons is not something a driver should guess at.
//
// Every worker calls it as it starts. The first takes an advisory lock and
// migrates; the others wait on that lock and then find nothing to do. A
// database further ahead than the build knows about is an error, not something
// to migrate backwards: that is a binary older than the schema, and rolling
// back a deployment should not drop columns.
//===----------------------------------------------------------------------===//

import AvianCore

public enum PostgresMigrationError: Error, Equatable, Sendable {
    /// The database has had more migrations run than this build has, which is
    /// a build older than the schema.
    case unknownSchemaVersion(found: Int, known: Int)
}

extension PostgresPool {
    /// Runs every migration past the version the database records, in one
    /// transaction, and returns how many ran.
    ///
    /// Append to `migrations`; never change or remove one that has run. The
    /// version is the number of migrations applied, kept in `table`, which is
    /// created if it is missing.
    @discardableResult
    public func migrate(_ migrations: [[String]], table: String = "garuda_schema_version") async throws -> Int {
        precondition(!table.isEmpty && table.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        } && !(table.utf8.first! >= 0x30 && table.utf8.first! <= 0x39),
                     "a schema version table's name is letters, digits and underscores: \(table)")
        return try await transaction { tx in
            // Held until the transaction ends, so two workers starting at once
            // cannot both run the same migration. The key is arbitrary and
            // fixed: "garuda" and a counter, so another application's locks do
            // not collide with these.
            try await tx.execute("select pg_advisory_xact_lock($1)", Int64(0x6761_7275_6461_0001))
            // Inside the lock: two CREATE TABLE IF NOT EXISTS at the same
            // moment can still collide on the catalogue.
            try await tx.execute("create table if not exists \(table) (version integer not null)")
            let found = try await tx.first(SchemaVersion.self,
                                           "select coalesce(max(version), 0) as version from \(table)")?.version ?? 0
            guard found <= migrations.count else {
                throw PostgresMigrationError.unknownSchemaVersion(found: found, known: migrations.count)
            }
            guard found < migrations.count else { return 0 }
            for migration in migrations[found...] {
                for statement in migration { try await tx.execute(statement) }
            }
            try await tx.execute("delete from \(table)")
            try await tx.execute("insert into \(table) (version) values ($1)", migrations.count)
            return migrations.count - found
        }
    }
}

private struct SchemaVersion: Decodable {
    let version: Int
}
