//===----------------------------------------------------------------------===//
// Refresh tokens: short-lived access tokens, and a long-lived way to get new
// ones that is rotated on every use and caught when stolen.
//
//     app.state { _ in
//         TokenIssuer(keys: keys, store: MemoryRefreshTokenStore()) { subject, lifetime in
//             UserClaims(sub: subject, exp: lifetime.expiresAt, role: try await users.role(of: subject))
//         }
//     }
//
//     app.post("/login") { (login: Body<Login>, issuer: State<TokenIssuer<UserClaims>>) in
//         JSON(try await issuer.value.issue(subject: try await users.check(login.value)))
//     }
//     app.post("/token/refresh") { (body: Body<RefreshRequest>, issuer: State<TokenIssuer<UserClaims>>) in
//         JSON(try await issuer.value.refresh(body.value.refreshToken))
//     }
//     app.post("/logout") { (body: Body<RefreshRequest>, issuer: State<TokenIssuer<UserClaims>>) in
//         try await issuer.value.revoke(body.value.refreshToken)
//         return HTTPStatus.noContent
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
// Stores: a `RefreshTokenStore` is where tokens are kept, and spending one must
// be atomic in it, so two requests refreshing the same token at once cannot
// both succeed. `MemoryRefreshTokenStore` keeps them in the shard's memory:
// built with `app.state`, it is one shard's, so it suits a server of one shard
// and tests. A server of several needs a store they all reach -- a database --
// since a refresh may land on any shard.
//===----------------------------------------------------------------------===//

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
    /// Seconds since the epoch; tests set their own, before the issuer is
    /// shared.
    var clock: @Sendable () -> Int64 = { epochSeconds() }

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

/// Refresh tokens in the shard's memory: for a server of one shard, and tests.
///
/// The shard's threads share it, and what it holds decides whether a session
/// is still valid, so its state is behind a lock. A login or a refresh takes a
/// handful of these calls, against one signature each, so the lock costs
/// nothing that can be measured; no request that only checks an access token
/// comes here at all.
///
/// A family, and every token of it, is let go once the family has expired:
/// until then a spent token is kept, because presenting it again is how a
/// stolen one is noticed. Without that the store would hold every login and
/// every refresh the shard had ever issued. There is no clock of its own:
/// "now" is the latest time the issuer has written, so an issuer's own clock
/// is the one that counts.
public final class MemoryRefreshTokenStore: RefreshTokenStore, Sendable {
    private struct Family {
        var subject: String
        var expiresAt: Int64
        var revoked: Bool
    }

    private struct State {
        var tokens: [String: RefreshTokenRecord] = [:]
        var families: [String: Family] = [:]
        /// The latest time written by the issuer, in seconds since the epoch.
        var now: Int64 = .min
        var writesSinceSweep = 0

        mutating func wrote(at time: Int64) {
            now = max(now, time)
            writesSinceSweep += 1
            // Every so many writes, so the cost of a sweep is spread over them.
            guard writesSinceSweep >= MemoryRefreshTokenStore.sweepEvery else { return }
            writesSinceSweep = 0
            let now = self.now
            families = families.filter { $0.value.expiresAt > now }
            tokens = tokens.filter { $0.value.familyExpiresAt > now }
        }
    }

    static let sweepEvery = 1024

    private let state = Mutex(State())

    public init() {
        MemoryStores.made("MemoryRefreshTokenStore")
    }

    /// How many families and tokens are held, ended ones not yet swept
    /// included.
    public var count: (families: Int, tokens: Int) {
        state.withLock { ($0.families.count, $0.tokens.count) }
    }

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        state.withLock { $0.families[family] = Family(subject: subject, expiresAt: expiresAt, revoked: false) }
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        state.withLock { state in
            state.tokens[record.digest] = record
            state.wrote(at: record.issuedAt)
        }
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
            $0.now = max($0.now, at)
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
