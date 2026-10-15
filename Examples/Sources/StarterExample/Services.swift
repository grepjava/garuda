//===----------------------------------------------------------------------===//
// What a shard holds: the database pool, the keys that sign access tokens,
// the issuer that hands out token pairs, and the hash a login for an unknown
// email is checked against.
//
// One state value rather than four, because they are made together and a
// route usually wants more than one. Garuda builds it in each shard as it
// starts (`app.state`), so nothing here is shared between processes. A shard
// serves on several threads at once, so what they share is `Sendable`, and
// nothing in it changes once it is built: no lock is needed to read it.
//
// A handler reaches it with `State<Services>`, and a start-up hook with
// `start.state(Services.self)`.
//===----------------------------------------------------------------------===//

import GarudaPostgres
import Vega

public final class Services: Sendable {
    public let configuration: StarterConfiguration
    public let pool: PostgresPool
    public let keys: JWTKeys
    public let issuer: TokenIssuer<AccessClaims>

    /// A hash of a password nobody has. A login for an unknown email is
    /// verified against it, so answering takes the same time as for an email
    /// that exists. Made once per shard, as it starts, because hashing costs
    /// a few hundred milliseconds of CPU.
    public let absentPasswordHash: String

    /// The services `configuration` describes. Connects to nothing yet: the
    /// pool opens connections as statements need them.
    public static func make(_ configuration: StarterConfiguration) async throws -> Services {
        let pool = PostgresPool(try PostgresConfiguration(url: configuration.databaseURL),
                                maxConnections: configuration.databasePoolSize)
        return Services(configuration: configuration, pool: pool, keys: try Services.keys(for: configuration),
                        absentPasswordHash: try await Passwords.hash(Tokens.random()))
    }

    private init(configuration: StarterConfiguration, pool: PostgresPool, keys: JWTKeys,
                 absentPasswordHash: String) {
        self.configuration = configuration
        self.pool = pool
        self.keys = keys
        self.absentPasswordHash = absentPasswordHash
        issuer = TokenIssuer(keys: keys, store: PostgresRefreshTokenStore(pool),
                             accessTokenSeconds: configuration.accessTokenSeconds,
                             refreshTokenSeconds: configuration.refreshTokenDays * 24 * 3600,
                             maximumSessionSeconds: configuration.sessionDays * 24 * 3600) { subject, lifetime in
            // Built at every login and every refresh, against the database as
            // it is now: an email that changed, or a role taken away, is in
            // the next access token and so gone within one token's life.
            let row = try await pool.first(AccountRow.self, "select id, email, role from users where id = $1",
                                           Int64(subject) ?? -1)
            guard let row else { throw HTTPError(.unauthorized, "that account no longer exists") }
            return AccessClaims(sub: subject, email: row.email, role: row.role, iat: lifetime.issuedAt,
                                exp: lifetime.expiresAt, jti: lifetime.tokenID)
        }
    }

    /// The work a shard does once, before it serves: the schema, and the
    /// administrators the deployment names.
    public func prepare() async throws {
        try await pool.migrate(starterMigrations)
        try await promoteAdministrators()
    }

    /// Makes every account in `ADMIN_EMAILS` an administrator.
    ///
    /// A new database has no administrator, and a route that promotes whoever
    /// asks is not a route, so the first one is named by the deployment. The
    /// list is a floor and not the whole truth: it only ever promotes, because
    /// a list that also demoted would undo an administrator's work at the next
    /// restart. To demote one of these accounts, take it out of the list first.
    ///
    /// Idempotent, and every shard runs it: the `where` clause means only the
    /// first to arrive writes anything.
    private func promoteAdministrators() async throws {
        let emails = configuration.adminEmails
        guard !emails.isEmpty else { return }
        let promoted = try await pool.execute(
            "update users set role = 'admin' where email = any($1) and role <> 'admin'", emails)
        if promoted > 0 {
            AppLog.info("promoted administrators", ["accounts": .int(promoted)])
        }
    }

    /// Closes what the shard opened. `app.state`'s shutdown calls it.
    public func close() {
        pool.close()
    }
}

/// Runs `work` with the services `configuration` describes, outside any
/// server, and returns what it returns: `starter migrate` uses it, and so do
/// the tests. It runs on a Vega runtime of its own, on the calling thread,
/// because the pool's connections are Vega's; and it closes the services when
/// `work` is done.
public func withServices<Result: Sendable>(
    _ configuration: StarterConfiguration,
    _ work: @escaping @Sendable (Services) async throws -> Result
) throws -> Result {
    let settled = configuration.withDevelopmentKey()
    let runtime = Runtime.currentThread(name: "starter")
    defer { runtime.shutdown() }
    return try runtime.block { () async throws -> Result in
        let services = try await Services.make(settled)
        defer { services.close() }
        return try await work(services)
    }
}

/// The claims an access token carries. `sub` is the user's id as text, as JWT
/// has it.
public struct AccessClaims: Codable, Sendable {
    public let sub: String
    public let email: String
    /// What the account may do, as of when the token was issued. Carried in
    /// the token so a route can check it without a lookup, which is what
    /// bounds how stale it can be: `accessTokenSeconds`, and less than that
    /// when the change also ends their sessions (Admin.swift).
    public let role: String
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
    let role: String
}
