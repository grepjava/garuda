//===----------------------------------------------------------------------===//
// GarudaSQLite: SQLite for a Garuda application.
//
//     import Garuda
//     import GarudaSQLite
//
//     let db = app.state { _ in try! SQLiteDatabase(SQLiteConfiguration(path: "app.db")) }
//
// The driver is vega-db's VegaSQLite, re-exported whole. What is here is
// Garuda's `UUID` and `Timestamp` as columns.
//
// Under `--shards` each shard opens the file for itself: SQLite's own locks
// order the writers, and WAL mode lets readers in every shard go on while one
// writes.
//===----------------------------------------------------------------------===//

@_exported import Garuda
@_exported import VegaSQLite
import GarudaWire

extension UUID: SQLiteBindable, SQLiteCellConvertible {
    /// Text, lowercase with hyphens: readable in the `sqlite3` shell, and
    /// equal to itself in a comparison with text written the same way.
    public var sqliteValue: SQLiteValue { .text(description) }

    /// From text, or from the 16 bytes of a blob.
    public init(sqliteValue value: SQLiteValue) throws {
        switch value {
        case .text(let s):
            if let id = UUID(s) { self = id; return }
        case .blob(let b):
            if let id = UUID(bytes: b) { self = id; return }
        default: break
        }
        throw SQLiteDecodingError.notConvertible(column: "", value: "\(value)", expected: "UUID")
    }
}

extension Timestamp: SQLiteBindable, SQLiteCellConvertible {
    /// Text in UTC, `2026-09-17 06:19:31.123456`: what SQLite's date functions
    /// read, and the same width for every instant from year 1 to 9999, so
    /// comparing and ordering the text orders the instants.
    public var sqliteValue: SQLiteValue { .text(sqliteText) }

    var sqliteText: String {
        let lower: Int64 = -62_135_596_800_000_000     // 0001-01-01
        let upper: Int64 = 253_402_300_800_000_000     // 10000-01-01
        guard microsecondsSinceEpoch >= lower && microsecondsSinceEpoch < upper else { return description }
        var text = CivilTime.format(microseconds: microsecondsSinceEpoch, .postgresWithoutZone)
        var digits = 0
        if let dot = text.utf8.firstIndex(of: UInt8(ascii: ".")) {
            digits = text.utf8.distance(from: dot, to: text.utf8.endIndex) - 1
        } else {
            text.append(".")
        }
        if digits < 6 { text.append(String(repeating: "0", count: 6 - digits)) }
        return text
    }

    /// From text -- as a Timestamp binds, as `CURRENT_TIMESTAMP` writes, or
    /// ISO 8601 -- or from an integer of seconds since 1970, as `unixepoch()`
    /// returns.
    public init(sqliteValue value: SQLiteValue) throws {
        switch value {
        case .text(let s):
            if let t = Timestamp(s) { self = t; return }
        case .integer(let n):
            let (micros, overflow) = n.multipliedReportingOverflow(by: 1_000_000)
            if !overflow { self.init(microsecondsSinceEpoch: micros); return }
        default: break
        }
        throw SQLiteDecodingError.notConvertible(column: "", value: "\(value)", expected: "Timestamp")
    }
}

// MARK: - Sessions

/// Sessions in an SQLite table of `id`, `data` (JSON) and `expires`
/// (milliseconds since the epoch). A load moves the expiry only once half of
/// the timeout has gone, so reading a session rarely writes. Make the table
/// with `createTable`, or with `schema` in a migration, and clear expired rows
/// now and then with `deleteExpired`.
public struct SQLiteSessionStore: SessionStore {
    public let database: SQLiteDatabase
    public let table: String

    public init(_ database: SQLiteDatabase, table: String = "garuda_sessions") {
        precondition(!table.isEmpty && table.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        } && !(table.utf8.first! >= 0x30 && table.utf8.first! <= 0x39),
                     "a session table's name is letters, digits and underscores: \(table)")
        self.database = database
        self.table = table
    }

    /// The statement that makes the table.
    public static func schema(table: String = "garuda_sessions") -> String {
        "CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL, "
            + "expires INTEGER NOT NULL) WITHOUT ROWID"
    }

    public func createTable() async throws {
        try await database.execute(Self.schema(table: table))
    }

    /// Deletes every expired session, and returns how many.
    @discardableResult
    public func deleteExpired() async throws -> Int {
        try await database.execute("DELETE FROM \(table) WHERE expires <= ?", nowMilliseconds())
    }

    private struct Row: Decodable {
        var data: String
        var expires: Int64
    }

    public func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]? {
        let now = nowMilliseconds()
        guard let row = try await database.first(Row.self, "SELECT data, expires FROM \(table) WHERE id = ?", id),
              row.expires > now else { return nil }
        guard let data = try? JSONCoder.decode([String: String].self, from: Array(row.data.utf8)) else {
            return nil
        }
        if row.expires - now < Int64(ttlMilliseconds) / 2 {
            try await database.execute("UPDATE \(table) SET expires = ? WHERE id = ?",
                                       now + Int64(ttlMilliseconds), id)
        }
        return data
    }

    public func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws {
        let text = String(decoding: try JSONCoder.encode(data), as: UTF8.self)
        try await database.execute(
            "INSERT INTO \(table) (id, data, expires) VALUES (?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET data = excluded.data, expires = excluded.expires",
            id, text, nowMilliseconds() + Int64(ttlMilliseconds))
    }

    public func delete(id: String) async throws {
        try await database.execute("DELETE FROM \(table) WHERE id = ?", id)
    }

    public func replace(id: String, data: [String: String], ttlMilliseconds: Int) async throws -> Bool {
        let text = String(decoding: try JSONCoder.encode(data), as: UTF8.self)
        let now = nowMilliseconds()
        return try await database.execute(
            "UPDATE \(table) SET data = ?, expires = ? WHERE id = ? AND expires > ?",
            text, now + Int64(ttlMilliseconds), id, now) > 0
    }

    public func remove(id: String) async throws -> Bool {
        try await database.execute("DELETE FROM \(table) WHERE id = ? AND expires > ?", id, nowMilliseconds()) > 0
    }

    private func nowMilliseconds() -> Int64 {
        Timestamp.now.microsecondsSinceEpoch / 1000
    }
}

// MARK: - Refresh tokens

/// Refresh tokens in two SQLite tables: families, and tokens by digest. Make
/// them with `createTables`, or with `schema` in a migration, and clear ended
/// families now and then with `deleteExpired`.
public struct SQLiteRefreshTokenStore: RefreshTokenStore {
    public let database: SQLiteDatabase
    public let table: String

    public init(_ database: SQLiteDatabase, table: String = "garuda_refresh_tokens") {
        precondition(!table.isEmpty && table.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        } && !(table.utf8.first! >= 0x30 && table.utf8.first! <= 0x39),
                     "a refresh token table's name is letters, digits and underscores: \(table)")
        self.database = database
        self.table = table
    }

    /// The statements that make the tables.
    public static func schema(table: String = "garuda_refresh_tokens") -> [String] {
        [
            "CREATE TABLE IF NOT EXISTS \(table)_families (family TEXT PRIMARY KEY NOT NULL, subject TEXT NOT NULL, "
                + "expires_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID",
            "CREATE INDEX IF NOT EXISTS \(table)_families_subject ON \(table)_families (subject)",
            "CREATE TABLE IF NOT EXISTS \(table) (digest TEXT PRIMARY KEY NOT NULL, family TEXT NOT NULL, "
                + "subject TEXT NOT NULL, issued_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, "
                + "family_expires_at INTEGER NOT NULL, used_at INTEGER) WITHOUT ROWID",
            "CREATE INDEX IF NOT EXISTS \(table)_family ON \(table) (family)",
        ]
    }

    public func createTables() async throws {
        for statement in Self.schema(table: table) { try await database.execute(statement) }
    }

    /// Deletes families that have ended, and their tokens. Returns how many
    /// tokens went.
    @discardableResult
    public func deleteExpired() async throws -> Int {
        let now = Timestamp.now.secondsSinceEpoch
        let tokens = try await database.execute("DELETE FROM \(table) WHERE family_expires_at <= ?", now)
        try await database.execute("DELETE FROM \(table)_families WHERE expires_at <= ?", now)
        return tokens
    }

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        try await database.execute("INSERT INTO \(table)_families (family, subject, expires_at) VALUES (?, ?, ?)",
                                   family, subject, expiresAt)
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        try await database.execute(
            "INSERT INTO \(table) (digest, family, subject, issued_at, expires_at, family_expires_at, used_at) "
                + "VALUES (?, ?, ?, ?, ?, ?, NULL)",
            record.digest, record.family, record.subject, record.issuedAt, record.expiresAt, record.familyExpiresAt)
    }

    private struct Row: Decodable {
        var digest: String
        var family: String
        var subject: String
        var issuedAt: Int64
        var expiresAt: Int64
        var familyExpiresAt: Int64
        var usedAt: Int64?
        var revoked: Int64?
    }

    public func find(digest: String) async throws -> RefreshTokenRecord? {
        guard let row = try await database.first(
            Row.self,
            "SELECT t.digest, t.family, t.subject, t.issued_at AS issuedAt, t.expires_at AS expiresAt, "
                + "t.family_expires_at AS familyExpiresAt, t.used_at AS usedAt, f.revoked "
                + "FROM \(table) t LEFT JOIN \(table)_families f ON f.family = t.family WHERE t.digest = ?",
            digest) else { return nil }
        return RefreshTokenRecord(digest: row.digest, family: row.family, subject: row.subject,
                                  issuedAt: row.issuedAt, expiresAt: row.expiresAt,
                                  familyExpiresAt: row.familyExpiresAt, usedAt: row.usedAt,
                                  revoked: (row.revoked ?? 1) != 0)
    }

    public func markUsed(digest: String, at: Int64) async throws -> Bool {
        try await database.execute("UPDATE \(table) SET used_at = ? WHERE digest = ? AND used_at IS NULL",
                                   at, digest) == 1
    }

    public func revokeFamily(_ family: String) async throws {
        try await database.execute("UPDATE \(table)_families SET revoked = 1 WHERE family = ?", family)
    }

    public func revokeSubject(_ subject: String) async throws {
        try await database.execute("UPDATE \(table)_families SET revoked = 1 WHERE subject = ?", subject)
    }
}
