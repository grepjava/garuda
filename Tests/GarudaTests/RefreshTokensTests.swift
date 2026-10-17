@testable import Garuda
import GarudaTesting
import Synchronization
import Testing

// Refresh tokens: issuing, rotating, reuse caught and forgiven, expiry, logout
// and signing out everywhere, the memory store, and a refresh route.

private struct AccessClaims: Codable, Sendable {
    let sub: String
    let iat: Int
    let exp: Int
    let jti: String
    let role: String
}

/// Roles by subject, which a test may change between refreshes.
private final class Directory: Sendable {
    private let roles = Mutex<[String: String]>(["ada": "admin", "grace": "user"])
    func role(of subject: String) -> String? { roles.withLock { $0[subject] } }
    func set(_ role: String, for subject: String) { roles.withLock { $0[subject] = role } }
}

private final class Clock: Sendable {
    private let now = Atomic<Int64>(epochSeconds())
    var seconds: Int64 {
        get { now.load(ordering: .relaxed) }
        set { now.store(newValue, ordering: .relaxed) }
    }
}

private func issuer(_ store: any RefreshTokenStore, _ directory: Directory = Directory(), clock: Clock = Clock(),
                    grace: Int = 10) throws -> (TokenIssuer<AccessClaims>, JWTKeys) {
    let keys = try JWTKeys([try JWTKey.generate(.ES256, keyID: "access")])
    keys.clock = { clock.seconds }
    let issuer = TokenIssuer(keys: keys, store: store, accessTokenSeconds: 900, refreshTokenSeconds: 3600,
                             maximumSessionSeconds: 4 * 3600, reuseGraceSeconds: grace) { subject, lifetime in
        AccessClaims(sub: subject, iat: lifetime.issuedAt, exp: lifetime.expiresAt, jti: lifetime.tokenID,
                     role: directory.role(of: subject) ?? "none")
    }
    issuer.clock = { clock.seconds }
    return (issuer, keys)
}

@Suite("Refresh tokens")
struct RefreshTokensTests {
    @Test func aLoginIssuesAPairThatRefreshes() async throws {
        let clock = Clock()
        let directory = Directory()
        let (issuer, keys) = try issuer(MemoryRefreshTokenStore(), directory, clock: clock)
        let first = try await issuer.issue(subject: "ada")
        #expect(first.tokenType == "Bearer")
        #expect(first.expiresIn == 900)
        #expect(first.refreshExpiresIn == 3600)
        #expect(first.refreshToken.utf8.count == 43)
        let claims = try await keys.verify(first.accessToken, as: AccessClaims.self)
        #expect(claims.sub == "ada" && claims.role == "admin")
        #expect(claims.exp == claims.iat + 900)

        // The claims are made again at each refresh: a role taken away goes.
        directory.set("user", for: "ada")
        clock.seconds += 600
        let second = try await issuer.refresh(first.refreshToken)
        #expect(second.refreshToken != first.refreshToken)
        #expect(try await keys.verify(second.accessToken, as: AccessClaims.self).role == "user")
        #expect(try await keys.verify(second.accessToken, as: AccessClaims.self).jti != claims.jti)
        clock.seconds += 600
        #expect(try await issuer.refresh(second.refreshToken).refreshToken.utf8.count == 43)

        let encoded = String(decoding: try JSONCoder.encode(second), as: UTF8.self)
        #expect(encoded.contains(#""access_token":"#) && encoded.contains(#""refresh_token":"#)
                && encoded.contains(#""token_type":"Bearer""#) && encoded.contains(#""expires_in":900"#))
    }

    @Test func aStolenTokenUsedAgainEndsTheFamily() async throws {
        let clock = Clock()
        let (issuer, _) = try issuer(MemoryRefreshTokenStore(), clock: clock)
        let login = try await issuer.issue(subject: "ada")
        let other = try await issuer.issue(subject: "ada")
        let rotated = try await issuer.refresh(login.refreshToken)

        // Within the grace period: refused, nothing revoked.
        clock.seconds += 10
        await #expect(throws: RefreshTokenError.alreadyRotated) { try await issuer.refresh(login.refreshToken) }
        clock.seconds += 1
        // Past it: the whole family ends, the token the client holds too.
        await #expect(throws: RefreshTokenError.reused) { try await issuer.refresh(login.refreshToken) }
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(rotated.refreshToken) }
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(login.refreshToken) }
        // Another login of the same user is another family.
        #expect(try await issuer.refresh(other.refreshToken).tokenType == "Bearer")
    }

    @Test func tokensAndFamiliesExpire() async throws {
        let clock = Clock()
        let (issuer, _) = try issuer(MemoryRefreshTokenStore(), clock: clock)
        let idle = try await issuer.issue(subject: "ada")
        clock.seconds += 3600
        await #expect(throws: RefreshTokenError.expired) { try await issuer.refresh(idle.refreshToken) }

        // Refreshed often, a family still ends four hours after the login, and
        // the last refresh token is cut short to that.
        clock.seconds += 1
        var pair = try await issuer.issue(subject: "ada")
        for _ in 0..<7 {
            clock.seconds += 1800
            pair = try await issuer.refresh(pair.refreshToken)
        }
        #expect(pair.refreshExpiresIn == 1800)
        clock.seconds += 1800
        await #expect(throws: RefreshTokenError.expired) { try await issuer.refresh(pair.refreshToken) }
    }

    @Test func logoutAndSigningOutEverywhere() async throws {
        let (issuer, _) = try issuer(MemoryRefreshTokenStore())
        let phone = try await issuer.issue(subject: "ada")
        let laptop = try await issuer.issue(subject: "ada")
        let grace = try await issuer.issue(subject: "grace")

        try await issuer.revoke(phone.refreshToken)
        try await issuer.revoke(phone.refreshToken)
        try await issuer.revoke("never issued")
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(phone.refreshToken) }
        let laptopAgain = try await issuer.refresh(laptop.refreshToken)

        try await issuer.revokeAll(subject: "ada")
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(laptopAgain.refreshToken) }
        #expect(try await issuer.refresh(grace.refreshToken).tokenType == "Bearer")
        await #expect(throws: RefreshTokenError.unknown) { try await issuer.refresh("made up") }
        await #expect(throws: RefreshTokenError.unknown) { try await issuer.refresh(String(repeating: "x", count: 300)) }
    }

    @Test func twoRefreshesOfOneTokenAtOnceCannotBothWin() async throws {
        /// A store where another request spends every token between the
        /// lookup and the spend.
        final class RacingStore: RefreshTokenStore {
            let inner = MemoryRefreshTokenStore()
            func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
                try await inner.createFamily(family, subject: subject, expiresAt: expiresAt)
            }
            func insert(_ record: RefreshTokenRecord) async throws { try await inner.insert(record) }
            func find(digest: String) async throws -> RefreshTokenRecord? { try await inner.find(digest: digest) }
            func markUsed(digest: String, at: Int64) async throws -> Bool {
                _ = try await inner.markUsed(digest: digest, at: at)
                return try await inner.markUsed(digest: digest, at: at)
            }
            func revokeFamily(_ family: String) async throws { try await inner.revokeFamily(family) }
            func revokeSubject(_ subject: String) async throws { try await inner.revokeSubject(subject) }
        }
        let (issuer, _) = try issuer(RacingStore())
        let login = try await issuer.issue(subject: "ada")
        await #expect(throws: RefreshTokenError.alreadyRotated) { try await issuer.refresh(login.refreshToken) }
    }

    @Test func manyRefreshesOfOneTokenOnManyThreadsLetOneWin() async throws {
        // The shard's threads share the store: one spends the token, and every
        // other is refused.
        let (issuer, _) = try issuer(MemoryRefreshTokenStore())
        let login = try await issuer.issue(subject: "ada")
        let won = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask { (try? await issuer.refresh(login.refreshToken)) != nil }
            }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(won == 1)
    }

    @Test func aLogoutWhileARefreshIsInFlightWinsTheRace() async throws {
        /// A store where a logout lands while the refresh is writing its new
        /// token -- what a slow `claims` closure leaves room for.
        final class LoggingOutStore: RefreshTokenStore {
            let inner = MemoryRefreshTokenStore()
            let logOutOnNextInsert = Atomic<Bool>(false)
            func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
                try await inner.createFamily(family, subject: subject, expiresAt: expiresAt)
            }
            func insert(_ record: RefreshTokenRecord) async throws {
                try await inner.insert(record)
                if logOutOnNextInsert.exchange(false, ordering: .relaxed) {
                    try await inner.revokeFamily(record.family)
                }
            }
            func find(digest: String) async throws -> RefreshTokenRecord? { try await inner.find(digest: digest) }
            func markUsed(digest: String, at: Int64) async throws -> Bool {
                try await inner.markUsed(digest: digest, at: at)
            }
            func revokeFamily(_ family: String) async throws { try await inner.revokeFamily(family) }
            func revokeSubject(_ subject: String) async throws { try await inner.revokeSubject(subject) }
        }
        let store = LoggingOutStore()
        let (issuer, _) = try issuer(store)
        let login = try await issuer.issue(subject: "ada")
        store.logOutOnNextInsert.store(true, ordering: .relaxed)
        // No access token comes back from a refresh the logout overtook.
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(login.refreshToken) }
        // Nor does the family live on through the token that refresh wrote.
        await #expect(throws: RefreshTokenError.revoked) { try await issuer.refresh(login.refreshToken) }
    }

    @Test func aRefreshRouteAnswersInvalidGrant() throws {
        struct RefreshRequest: Decodable {
            let refresh_token: String
        }
        // The issuer, and its store, are the shard's.
        let app = Application()
        app.state { _ in try issuer(MemoryRefreshTokenStore()).0 }
        app.post("/login") { (issuer: State<TokenIssuer<AccessClaims>>) async throws -> JSON<TokenPair> in
            JSON(try await issuer.value.issue(subject: "ada"))
        }
        app.post("/token/refresh") {
            (body: Body<RefreshRequest>, issuer: State<TokenIssuer<AccessClaims>>) async throws -> JSON<TokenPair> in
            JSON(try await issuer.value.refresh(body.value.refresh_token))
        }
        let client = app.test
        let pair = try client.post("/login").json(TokenPair.self)
        let refreshed = try client.post("/token/refresh", body: #"{"refresh_token":"\#(pair.refreshToken)"}"#)
        #expect(refreshed.status == 200)
        #expect(try refreshed.json(TokenPair.self).refreshToken != pair.refreshToken)
        let bad = try client.post("/token/refresh", body: #"{"refresh_token":"nope"}"#)
        #expect(bad.status == 400)
        #expect(bad.text == #"{"error":"invalid_grant"}"#)
    }
}

// MARK: - Stores

/// What every store must do, run against one.
private func exerciseStore(_ store: any RefreshTokenStore) async throws -> String {
    let now = epochSeconds()
    let unique = Tokens.random(bytes: 16)
    let family = "family-\(unique)"
    let subject = "subject-\(unique)"
    try await store.createFamily(family, subject: subject, expiresAt: now + 3600)
    try await store.createFamily(family + "-2", subject: subject, expiresAt: now + 3600)
    let record = RefreshTokenRecord(digest: Tokens.digest("a" + unique), family: family, subject: subject,
                                    issuedAt: now, expiresAt: now + 600, familyExpiresAt: now + 3600)
    let second = RefreshTokenRecord(digest: Tokens.digest("b" + unique), family: family + "-2", subject: subject,
                                    issuedAt: now, expiresAt: now + 600, familyExpiresAt: now + 3600)
    try await store.insert(record)
    try await store.insert(second)
    var out: [String] = []
    out.append("\(try await store.find(digest: record.digest) == record)")
    out.append("\(try await store.find(digest: "missing") == nil)")
    out.append("\(try await store.markUsed(digest: record.digest, at: now + 5))")
    out.append("\(try await store.markUsed(digest: record.digest, at: now + 6))")
    out.append("\(try await store.find(digest: record.digest)?.usedAt ?? -1 == now + 5)")
    try await store.revokeFamily(family)
    out.append("\(try await store.find(digest: record.digest)?.revoked ?? false)")
    out.append("\(try await store.find(digest: second.digest)?.revoked ?? true)")
    try await store.revokeSubject(subject)
    out.append("\(try await store.find(digest: second.digest)?.revoked ?? false)")
    return out.joined(separator: " ")
}

private let storeExpectation = "true true true false true true false true"

@Suite("Refresh token stores", .serialized)
struct RefreshTokenStoreTests {
    @Test func memory() async throws {
        #expect(try await exerciseStore(MemoryRefreshTokenStore()) == storeExpectation)
    }

    @Test func theMemoryStoreLetsEndedFamiliesGo() async throws {
        // It kept every family and token it was ever given. Ended ones go now,
        // by the issuer's own clock; a live family's spent token stays, since
        // presenting it again is how theft is noticed.
        let store = MemoryRefreshTokenStore()
        let start: Int64 = 1_000_000
        try await store.createFamily("old", subject: "ada", expiresAt: start + 60)
        try await store.insert(RefreshTokenRecord(digest: "old-token", family: "old", subject: "ada",
                                                  issuedAt: start, expiresAt: start + 60,
                                                  familyExpiresAt: start + 60))
        try await store.createFamily("live", subject: "ada", expiresAt: start + 100_000)
        try await store.insert(RefreshTokenRecord(digest: "spent", family: "live", subject: "ada",
                                                  issuedAt: start, expiresAt: start + 600,
                                                  familyExpiresAt: start + 100_000))
        #expect(try await store.markUsed(digest: "spent", at: start + 1))
        for i in 0..<MemoryRefreshTokenStore.sweepEvery {
            try await store.insert(RefreshTokenRecord(digest: "t\(i)", family: "live", subject: "ada",
                                                      issuedAt: start + 120, expiresAt: start + 720,
                                                      familyExpiresAt: start + 100_000))
        }
        #expect(store.count.families == 1)
        #expect(store.count.tokens == MemoryRefreshTokenStore.sweepEvery + 1)
        #expect(try await store.find(digest: "old-token") == nil)
        #expect(try await store.find(digest: "spent")?.usedAt == start + 1)
    }
}
