//===----------------------------------------------------------------------===//
// What a worker holds: the database pool, the keys that sign access tokens,
// and the issuer that hands out token pairs.
//
// One state value rather than three, because they are made together and a
// route usually wants more than one. Garuda builds it in each worker after the
// fork (`app.state`), so nothing here is shared between processes and nothing
// needs a lock: a worker is one process with one thread.
//
// A handler reaches it with `State<Services>`, and a start-up hook with
// `start.state(Services.self)`.
//===----------------------------------------------------------------------===//

import Garuda

public final class Services {
    public let configuration: StarterConfiguration
    public let pool: PostgresPool
    public let keys: JWTKeys
    public let issuer: TokenIssuer<AccessClaims>

    public init(_ configuration: StarterConfiguration) throws {
        self.configuration = configuration
        let pool = PostgresPool(try PostgresConfiguration(url: configuration.databaseURL),
                                maxConnections: configuration.databasePoolSize)
        self.pool = pool
        keys = try Services.keys(for: configuration)
        issuer = TokenIssuer(keys: keys, store: PostgresRefreshTokenStore(pool),
                             accessTokenSeconds: configuration.accessTokenSeconds,
                             refreshTokenSeconds: configuration.refreshTokenDays * 24 * 3600,
                             maximumSessionSeconds: configuration.sessionDays * 24 * 3600) { subject, lifetime in
            // Built at every login and every refresh, against the database as
            // it is now: an email that changed, or a role taken away, is in
            // the next access token and so gone within one token's life.
            let row = try await pool.first(AccountRow.self, "select id, email from users where id = $1",
                                           Int64(subject) ?? -1)
            guard let row else { throw HTTPError(.unauthorized, "that account no longer exists") }
            return AccessClaims(sub: subject, email: row.email, iat: lifetime.issuedAt,
                                exp: lifetime.expiresAt, jti: lifetime.tokenID)
        }
    }

    /// A hash of a password nobody has. A login for an unknown email is
    /// verified against it, so answering takes the same time as for an email
    /// that exists. Made once per worker in `app.prepare`, because hashing
    /// costs a few hundred milliseconds of CPU.
    public private(set) var absentPasswordHash = ""

    /// The work a worker does once, before it serves: the schema, and the
    /// hash above.
    public func warmUp() async throws {
        try await pool.migrate(starterMigrations)
        absentPasswordHash = try await Passwords.hash(Tokens.random())
    }

    /// Closes what the worker opened. `app.state`'s shutdown calls it.
    public func close() {
        pool.close()
    }
}

/// The claims an access token carries. `sub` is the user's id as text, as JWT
/// has it.
public struct AccessClaims: Codable, Sendable {
    public let sub: String
    public let email: String
    public let iat: Int
    public let exp: Int
    /// The token's own id, so one can be named in a log without the token
    /// itself appearing there.
    public let jti: String

    public var userID: Int64? { Int64(sub) }
}

struct AccountRow: Decodable {
    let id: Int64
    let email: String
}
