//===----------------------------------------------------------------------===//
// GarudaPostgres: PostgreSQL for a Garuda application.
//
//     import Garuda
//     import GarudaPostgres
//
//     let db = app.state { _ in
//         try! PostgresPool(PostgresConfiguration(url: "postgres://app:secret@db/app"))
//     }
//     app.get("/users/:id") { (id: Path<Int>, db: State<PostgresPool>) in
//         try await db.first(User.self, "select id, name from users where id = $1", id.value)
//     }
//
// The driver is vega-db's VegaPostgres, re-exported whole. What is here is
// what joins it to Garuda: its `UUID` and `Timestamp` as uuid and timestamptz
// columns, `PostgresJSON` over Garuda's JSON coder, and spans on the tracer
// the application traces with.
//===----------------------------------------------------------------------===//

@_exported import Garuda
@_exported import VegaPostgres

extension UUID: PostgresBindable, PostgresCellConvertible {
    public var postgresValue: PostgresValue { PostgresUUID(bytes: bytes)!.postgresValue }

    public init(postgresRepresentation value: PostgresUUID) throws {
        self.init(bytes: value.bytes)!
    }
}

extension Timestamp: PostgresBindable, PostgresCellConvertible {
    public var postgresValue: PostgresValue {
        PostgresTimestamp(microsecondsSinceEpoch: microsecondsSinceEpoch).postgresValue
    }

    public init(postgresRepresentation value: PostgresTimestamp) throws {
        self.init(microsecondsSinceEpoch: value.microsecondsSinceEpoch)
    }
}

/// A `json` or `jsonb` column, decoded into `Value`.
///
/// ```
/// struct Row: Decodable { let meta: PostgresJSON<Metadata> }
/// let metadata = try await pool.first(Row.self, "select meta from things")?.meta.value
/// ```
public struct PostgresJSON<Value: Codable & Sendable>: Sendable, Codable, CustomStringConvertible {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        // From a row the column's text comes through `postgresRepresentation`;
        // from anything else, it decodes as the value itself.
        value = try Value(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    public var description: String {
        (try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "\(value)"
    }
}

extension PostgresJSON: PostgresCellConvertible {
    /// The column's text, which is the document.
    public init(postgresRepresentation text: String) throws {
        value = try JSONCoder.decode(Value.self, from: Array(text.utf8))
    }
}

extension PostgresJSON: PostgresBindable {
    public var postgresValue: PostgresValue {
        PostgresValue((try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "null")
    }
}

// MARK: - Refresh tokens

/// Refresh tokens in two PostgreSQL tables: families, and tokens by digest.
/// Make them with `createTables`, or with `schema` as a migration of your own
/// (`try await pool.migrate([PostgresRefreshTokenStore.schema()] + mine)`), and
/// clear ended families now and then with `deleteExpired`.
public struct PostgresRefreshTokenStore: RefreshTokenStore {
    public let pool: PostgresPool
    public let table: String

    public init(_ pool: PostgresPool, table: String = "garuda_refresh_tokens") {
        precondition(!table.isEmpty && table.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        } && !(table.utf8.first! >= 0x30 && table.utf8.first! <= 0x39),
                     "a refresh token table's name is letters, digits and underscores: \(table)")
        self.pool = pool
        self.table = table
    }

    /// The statements that make the tables, as one migration.
    public static func schema(table: String = "garuda_refresh_tokens") -> [String] {
        [
            "create table if not exists \(table)_families (family text primary key, subject text not null, "
                + "expires_at bigint not null, revoked boolean not null default false)",
            "create index if not exists \(table)_families_subject on \(table)_families (subject)",
            "create table if not exists \(table) (digest text primary key, family text not null, "
                + "subject text not null, issued_at bigint not null, expires_at bigint not null, "
                + "family_expires_at bigint not null, used_at bigint)",
            "create index if not exists \(table)_family on \(table) (family)",
        ]
    }

    public func createTables() async throws {
        for statement in Self.schema(table: table) { try await pool.execute(statement) }
    }

    /// Deletes families that have ended, and their tokens. Returns how many
    /// tokens went.
    @discardableResult
    public func deleteExpired() async throws -> Int {
        let now = Timestamp.now.secondsSinceEpoch
        let tokens = try await pool.execute("delete from \(table) where family_expires_at <= $1", now)
        try await pool.execute("delete from \(table)_families where expires_at <= $1", now)
        return tokens
    }

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        try await pool.execute("insert into \(table)_families (family, subject, expires_at) values ($1, $2, $3)",
                               family, subject, expiresAt)
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        try await pool.execute(
            "insert into \(table) (digest, family, subject, issued_at, expires_at, family_expires_at, used_at) "
                + "values ($1, $2, $3, $4, $5, $6, null)",
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
        var revoked: Bool?
    }

    public func find(digest: String) async throws -> RefreshTokenRecord? {
        // Quoted aliases: PostgreSQL lowercases a bare one, and the row is
        // decoded by name.
        guard let row = try await pool.first(
            Row.self,
            "select t.digest, t.family, t.subject, t.issued_at as \"issuedAt\", t.expires_at as \"expiresAt\", "
                + "t.family_expires_at as \"familyExpiresAt\", t.used_at as \"usedAt\", f.revoked "
                + "from \(table) t left join \(table)_families f on f.family = t.family where t.digest = $1",
            digest) else { return nil }
        return RefreshTokenRecord(digest: row.digest, family: row.family, subject: row.subject,
                                  issuedAt: row.issuedAt, expiresAt: row.expiresAt,
                                  familyExpiresAt: row.familyExpiresAt, usedAt: row.usedAt,
                                  revoked: row.revoked ?? true)
    }

    public func markUsed(digest: String, at: Int64) async throws -> Bool {
        // One conditional UPDATE, so two workers spending the same token at
        // once cannot both win: the second finds used_at already set.
        try await pool.execute("update \(table) set used_at = $1 where digest = $2 and used_at is null",
                               at, digest) == 1
    }

    public func revokeFamily(_ family: String) async throws {
        try await pool.execute("update \(table)_families set revoked = true where family = $1", family)
    }

    public func revokeSubject(_ subject: String) async throws {
        try await pool.execute("update \(table)_families set revoked = true where subject = $1", subject)
    }
}
