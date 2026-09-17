//===----------------------------------------------------------------------===//
// Refresh tokens: short-lived access tokens, and a long-lived way to get new
// ones that is rotated on every use and caught when stolen.
//
//     let issuer = TokenIssuer(keys: keys, store: RedisRefreshTokenStore(pool)) { subject, lifetime in
//         let user = try await users.find(subject)
//         return UserClaims(sub: subject, exp: lifetime.expiresAt, role: user.role)
//     }
//
//     app.post("/login") { (login: Body<Login>) async throws in
//         JSON(try await issuer.issue(subject: try await users.check(login.value)))
//     }
//     app.post("/token/refresh") { (body: Body<RefreshRequest>) async throws in
//         JSON(try await issuer.refresh(body.value.refreshToken))
//     }
//     app.post("/logout") { (body: Body<RefreshRequest>) async throws -> HTTPStatus in
//         try await issuer.revoke(body.value.refreshToken)
//         return .noContent
//     }
//
// An access token is a JWT that lives `accessTokenSeconds` (15 minutes): every
// route checks it without a lookup, and nothing can take it back before it
// expires, which is why it is short. A refresh token is 32 random bytes, stored
// only as its SHA-256, and exchanged at one route for a new pair.
//
// Rotation, as the OAuth 2.0 security best practice (RFC 9700) describes:
//
// - Each refresh spends the token and issues a new one in the same family --
//   the chain that began at one login.
// - A spent token presented again means two parties hold it: the client and
//   whoever copied it. Which is which cannot be known, so the whole family is
//   revoked, and both must sign in again.
// - The family is checked again once the new pair is built, so a logout that
//   lands while the claims are being made -- a database round trip, in most
//   applications -- does not hand back a working access token.
// - Except within `reuseGraceSeconds` of its use, when it is refused without
//   revoking anything: a browser with two tabs refreshing at once is not an
//   attack, and the tab that lost the race uses the other's tokens.
// - A family ends `maximumSessionSeconds` after the login however often it is
//   refreshed, and a refresh token unused for `refreshTokenSeconds` expires.
//
// The claims of every access token come from the `claims` closure, called at
// login and at each refresh, so a role taken away is gone within one access
// token's life. `revoke` ends one family (a logout); `revokeAll(subject:)` ends
// every family of a user (a password change).
//
// A refused refresh throws `RefreshTokenError`, answered 400 with
// `{"error":"invalid_grant"}` as RFC 6749 section 5.2 has it.
//
// Stores: `MemoryRefreshTokenStore` for --workers 1 and tests, and Redis and
// SQLite for the rest. Spending a token is atomic in each, so two workers
// refreshing the same token at once cannot both succeed.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaRedis
import Synchronization

/// The times an access token is issued for.
public struct TokenLifetime: Sendable {
    /// Seconds since the epoch: what `iat` and `exp` hold.
    public let issuedAt: Int
    public let expiresAt: Int
    /// A random ID, for `jti`.
    public let tokenID: String
}

/// A new access token and refresh token, as an OAuth 2.0 token response
/// (RFC 6749 section 5.1) encodes them.
public struct TokenPair: Codable, Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    /// Seconds the access token lives.
    public let expiresIn: Int
    public let refreshToken: String
    /// Seconds the refresh token may go unused.
    public let refreshExpiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshExpiresIn = "refresh_expires_in"
    }
}

/// Why a refresh was refused. Every case is answered the same way.
public enum RefreshTokenError: Error, Equatable, Sendable, ResponseError {
    /// No such token, or not one this server issued.
    case unknown
    case expired
    /// The family was revoked: by a logout, `revokeAll`, or reuse.
    case revoked
    /// Already spent, beyond the grace period: the family is now revoked.
    case reused
    /// Already spent, within the grace period: refused, nothing revoked.
    case alreadyRotated

    public var status: HTTPStatus { .badRequest }
    public var reason: String? { "invalid_grant" }
}

/// A refresh token as a store keeps it: by digest, never the token.
public struct RefreshTokenRecord: Codable, Sendable, Equatable {
    public var digest: String
    /// The chain of tokens begun at one login.
    public var family: String
    public var subject: String
    public var issuedAt: Int64
    public var expiresAt: Int64
    /// When the family ends, however it is refreshed.
    public var familyExpiresAt: Int64
    /// When it was spent, or nil.
    public var usedAt: Int64?
    /// Whether its family has been revoked.
    public var revoked: Bool

    public init(digest: String, family: String, subject: String, issuedAt: Int64, expiresAt: Int64,
                familyExpiresAt: Int64, usedAt: Int64? = nil, revoked: Bool = false) {
        self.digest = digest
        self.family = family
        self.subject = subject
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.familyExpiresAt = familyExpiresAt
        self.usedAt = usedAt
        self.revoked = revoked
    }
}

/// Where refresh tokens are kept.
public protocol RefreshTokenStore: Sendable {
    /// Records a new family for `subject`, ending at `expiresAt`.
    func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws
    func insert(_ record: RefreshTokenRecord) async throws
    /// The token with this digest, its `revoked` reflecting its family.
    func find(digest: String) async throws -> RefreshTokenRecord?
    /// Spends the token, atomically: true only for the one call that did.
    func markUsed(digest: String, at: Int64) async throws -> Bool
    func revokeFamily(_ family: String) async throws
    func revokeSubject(_ subject: String) async throws
}

/// Issues access and refresh tokens, and exchanges one for the other.
public final class TokenIssuer<Claims: Encodable & Sendable>: @unchecked Sendable {
    public let keys: JWTKeys
    public let store: any RefreshTokenStore
    public let accessTokenSeconds: Int
    public let refreshTokenSeconds: Int
    public let maximumSessionSeconds: Int
    public let reuseGraceSeconds: Int
    let claims: @Sendable (_ subject: String, _ lifetime: TokenLifetime) async throws -> Claims
    /// Seconds since the epoch; tests set their own.
    var clock: @Sendable () -> Int64 = { Timestamp.now.secondsSinceEpoch }

    public init(keys: JWTKeys, store: any RefreshTokenStore,
                accessTokenSeconds: Int = 15 * 60,
                refreshTokenSeconds: Int = 14 * 24 * 3600,
                maximumSessionSeconds: Int = 90 * 24 * 3600,
                reuseGraceSeconds: Int = 10,
                claims: @escaping @Sendable (_ subject: String, _ lifetime: TokenLifetime) async throws -> Claims) {
        precondition(accessTokenSeconds > 0 && refreshTokenSeconds > 0 && maximumSessionSeconds > 0,
                     "token lifetimes are positive")
        precondition(accessTokenSeconds < refreshTokenSeconds, "an access token lives less long than its refresh token")
        self.keys = keys
        self.store = store
        self.accessTokenSeconds = accessTokenSeconds
        self.refreshTokenSeconds = refreshTokenSeconds
        self.maximumSessionSeconds = maximumSessionSeconds
        self.reuseGraceSeconds = reuseGraceSeconds
        self.claims = claims
    }

    /// A new pair, and a new family, for `subject`: at login.
    public func issue(subject: String) async throws -> TokenPair {
        let now = clock()
        let family = Tokens.random(bytes: 16)
        let familyExpiresAt = now + Int64(maximumSessionSeconds)
        try await store.createFamily(family, subject: subject, expiresAt: familyExpiresAt)
        return try await pair(subject: subject, family: family, familyExpiresAt: familyExpiresAt, now: now)
    }

    /// A new pair for a refresh token, which is spent.
    public func refresh(_ refreshToken: String) async throws -> TokenPair {
        let now = clock()
        guard refreshToken.utf8.count <= 256, let record = try await store.find(digest: Tokens.digest(refreshToken)) else {
            throw RefreshTokenError.unknown
        }
        if record.revoked { throw RefreshTokenError.revoked }
        if let usedAt = record.usedAt {
            try await refuseReuse(record, usedAt: usedAt, now: now)
        }
        if now >= record.expiresAt || now >= record.familyExpiresAt { throw RefreshTokenError.expired }
        guard try await store.markUsed(digest: record.digest, at: now) else {
            // Another request spent it between the lookup and here.
            try await refuseReuse(record, usedAt: now, now: now)
            throw RefreshTokenError.alreadyRotated
        }
        let issued = try await pair(subject: record.subject, family: record.family,
                                    familyExpiresAt: record.familyExpiresAt, now: now)
        // `revoke` or `revokeAll` can land while the claims are being built.
        // The new refresh token is in the revoked family and so already dead,
        // but an access token cannot be taken back, so it is not handed out.
        guard try await store.find(digest: record.digest)?.revoked == false else {
            throw RefreshTokenError.revoked
        }
        return issued
    }

    /// Ends the family `refreshToken` belongs to: a logout. An unknown token
    /// is not an error, so a logout is safe to repeat.
    public func revoke(_ refreshToken: String) async throws {
        guard refreshToken.utf8.count <= 256,
              let record = try await store.find(digest: Tokens.digest(refreshToken)) else { return }
        try await store.revokeFamily(record.family)
    }

    /// Ends every family of `subject`: after a password change, or to sign a
    /// user out everywhere.
    public func revokeAll(subject: String) async throws {
        try await store.revokeSubject(subject)
    }

    private func refuseReuse(_ record: RefreshTokenRecord, usedAt: Int64, now: Int64) async throws {
        if now - usedAt <= Int64(reuseGraceSeconds) { throw RefreshTokenError.alreadyRotated }
        try await store.revokeFamily(record.family)
        throw RefreshTokenError.reused
    }

    private func pair(subject: String, family: String, familyExpiresAt: Int64, now: Int64) async throws -> TokenPair {
        let expiresAt = min(now + Int64(refreshTokenSeconds), familyExpiresAt)
        let refreshToken = Tokens.random()
        try await store.insert(RefreshTokenRecord(
            digest: Tokens.digest(refreshToken), family: family, subject: subject,
            issuedAt: now, expiresAt: expiresAt, familyExpiresAt: familyExpiresAt))
        let lifetime = TokenLifetime(issuedAt: Int(now), expiresAt: Int(now) + accessTokenSeconds,
                                     tokenID: Tokens.random(bytes: 16))
        let accessToken = try keys.sign(try await claims(subject, lifetime))
        return TokenPair(accessToken: accessToken, tokenType: "Bearer", expiresIn: accessTokenSeconds,
                         refreshToken: refreshToken, refreshExpiresIn: Int(expiresAt - now))
    }
}

// MARK: - Stores

/// Refresh tokens in the worker's memory: for --workers 1 and tests.
///
/// A worker runs its handlers on its one thread, so in the ordinary case
/// nothing here is reached from two threads. A store is a public type though,
/// and user code can reach one from the blocking pool or a thread of its own,
/// and what it holds decides whether a session is still valid -- so the state
/// is behind a lock. A login or a refresh takes a handful of these calls, so
/// the lock costs nothing that can be measured.
public final class MemoryRefreshTokenStore: RefreshTokenStore, Sendable {
    private struct State {
        var tokens: [String: RefreshTokenRecord] = [:]
        var families: [String: (subject: String, expiresAt: Int64, revoked: Bool)] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        state.withLock { $0.families[family] = (subject, expiresAt, false) }
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        state.withLock { $0.tokens[record.digest] = record }
    }

    public func find(digest: String) async throws -> RefreshTokenRecord? {
        state.withLock {
            guard var record = $0.tokens[digest] else { return nil }
            record.revoked = $0.families[record.family]?.revoked ?? true
            return record
        }
    }

    public func markUsed(digest: String, at: Int64) async throws -> Bool {
        state.withLock {
            guard var record = $0.tokens[digest], record.usedAt == nil else { return false }
            record.usedAt = at
            $0.tokens[digest] = record
            return true
        }
    }

    public func revokeFamily(_ family: String) async throws {
        state.withLock { $0.families[family]?.revoked = true }
    }

    public func revokeSubject(_ subject: String) async throws {
        state.withLock {
            for (family, value) in $0.families where value.subject == subject {
                $0.families[family]?.revoked = true
            }
        }
    }
}

/// Refresh tokens in Redis, each key expiring with what it describes:
/// `t:` a token's record, `u:` when it was spent (set with NX, so only one
/// request spends it), `f:` a family's state, and `s:` a subject's families.
public struct RedisRefreshTokenStore: RefreshTokenStore {
    public let redis: RedisPool
    public let prefix: String

    public init(_ redis: RedisPool, prefix: String = "refresh:") {
        self.redis = redis
        self.prefix = prefix
    }

    private func ttl(_ until: Int64) -> Int {
        max(1, Int(until - Timestamp.now.secondsSinceEpoch)) * 1000
    }

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        _ = try await redis.pipeline([
            RedisCommand("SET", prefix + "f:" + family, "active", "PX", ttl(expiresAt)),
            RedisCommand("SADD", prefix + "s:" + subject, family),
            // The index must outlive the family that ends last, so its expiry
            // only ever grows: two logins can reach Redis in either order, and
            // an index that went first would lose `revokeSubject` a family
            // that is still good. `PEXPIRE GT` says this in one word, but that
            // is Redis 7; this works on 6 as well, and is atomic either way.
            RedisCommand("EVAL", "local left = redis.call('PTTL', KEYS[1]) "
                + "local want = tonumber(ARGV[1]) "
                + "if left < want then redis.call('PEXPIRE', KEYS[1], want) end "
                + "return redis.call('PTTL', KEYS[1])",
                         1, prefix + "s:" + subject, ttl(expiresAt)),
        ])
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        // Kept until the family ends, so a spent token is still recognised
        // when it is presented again.
        try await redis.set(prefix + "t:" + record.digest, try JSONCoder.encode(record),
                            expireMilliseconds: ttl(record.familyExpiresAt))
    }

    public func find(digest: String) async throws -> RefreshTokenRecord? {
        let replies = try await redis.pipeline([
            RedisCommand("GET", prefix + "t:" + digest),
            RedisCommand("GET", prefix + "u:" + digest),
        ])
        guard let bytes = replies[0].bytes, var record = try? JSONCoder.decode(RefreshTokenRecord.self, from: bytes)
        else { return nil }
        record.usedAt = replies[1].string.flatMap { Int64($0) }
        record.revoked = try await redis.get(prefix + "f:" + record.family) != "active"
        return record
    }

    public func markUsed(digest: String, at: Int64) async throws -> Bool {
        guard let bytes = try await redis.getBytes(prefix + "t:" + digest),
              let record = try? JSONCoder.decode(RefreshTokenRecord.self, from: bytes) else { return false }
        return try await redis.set(prefix + "u:" + digest, Int(at), expireMilliseconds: ttl(record.familyExpiresAt),
                                   condition: .ifAbsent)
    }

    public func revokeFamily(_ family: String) async throws {
        try await redis.send("SET", prefix + "f:" + family, "revoked", "XX", "KEEPTTL")
    }

    public func revokeSubject(_ subject: String) async throws {
        for family in try await redis.smembers(prefix + "s:" + subject) {
            try await revokeFamily(family)
        }
    }
}

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
