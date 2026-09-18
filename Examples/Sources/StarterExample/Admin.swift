//===----------------------------------------------------------------------===//
// Administration: the routes only an administrator may reach.
//
//   GET /admin/accounts?limit=20&before=41    200 a page of accounts
//   PUT /admin/accounts/:id/role  {"role"}    200 the account, 404, 409, 422
//
// The whole feature is guarded in two lines, and no handler here checks
// anything about who is asking:
//
//     app.authenticate(jwt: AccessClaims.self)      // whose request it is
//     app.authorize(jwt: AccessClaims.self, .admin) // whether they may
//
// A member's token is refused 403 saying `this route needs an administrator`;
// a request with no token is 401 with the challenge. Both come from the two
// lines above, and both are in the OpenAPI document for every route here
// without either route saying so.
//
// The role is in the access token, so guarding a route costs no lookup. What
// that buys has a price, and the price is bounded: an account demoted a moment
// ago keeps its token's word until the token expires, at most
// `ACCESS_TOKEN_SECONDS`. A change of role therefore also ends that account's
// sessions, so the next refresh mints the truth rather than waiting out the
// refresh window.
//
// The one rule a policy cannot hold is the last administrator: whether this
// demotion leaves any is a question for the database, and the answer is 409.
//===----------------------------------------------------------------------===//

import Garuda

extension Policy where Value == AccessClaims {
    /// An administrator, as the token says. Named once, used by the group
    /// below, and callable in a test without a request.
    static let admin = Policy(needs: "an administrator") { $0.role == "admin" }
}

/// What a role may be. `oneOf` rather than an enum only because the column is
/// text and the message should name the choices; an enum would answer 400 for
/// a value outside them, and this is a value the client got wrong, not a shape.
struct RoleChange: Decodable, Validated {
    let role: String

    func validate(_ check: inout Validation) {
        check.oneOf("role", role, ["member", "admin"])
    }
}

public struct AccountPage: Codable, Sendable {
    public let accounts: [Account]
    /// What to pass as `before` for the next page, or nil at the end.
    public let nextBefore: Int64?
}

/// Every route an administrator has, as a value. It needs nothing but the
/// worker's `Services` and the verifier `app.jwtVerifier` registered, so it is
/// a `Router`: `app.nest("/admin", adminRoutes())`.
func adminRoutes() -> Router {
    let app = Router()

    // Who is asking, then whether they may. In this order, because the rule is
    // about what the first one found.
    app.authenticate(jwt: AccessClaims.self)
    app.authorize(jwt: AccessClaims.self, .admin)

    app.get("/accounts") { (query: Query<PageQuery>, services: State<Services>)
        async throws -> JSON<AccountPage> in
        let limit = min(max(query.value.limit ?? 20, 1), 100)
        let before = query.value.before ?? Int64.max
        let accounts = try await services.value.pool.query(
            Account.self,
            "select id, email, role from users where id < $1 order by id desc limit $2", before, limit)
        return JSON(AccountPage(accounts: accounts,
                                nextBefore: accounts.count == limit ? accounts.last?.id : nil))
    }
        .summary("A page of accounts, newest first")
        .tags("admin")

    app.put("/accounts/:id/role") { (id: Path<Int64>, body: Body<RoleChange>,
                                     jwt: JWT<AccessClaims>, services: State<Services>)
        async throws -> JSON<Account>? in
        let role = body.value.role
        let services = services.value
        let outcome = try await services.pool.transaction { tx -> (account: Account, changed: Bool)? in
            // Locked for the length of the transaction, so two administrators
            // demoting the last two administrators at the same moment cannot
            // both pass the count below.
            guard let current = try await tx.first(Account.self,
                                                   "select id, email, role from users where id = $1 for update",
                                                   id.value) else {
                return nil
            }
            // Already what it should be: nothing to write, and nobody's
            // sessions to end.
            guard current.role != role else { return (current, false) }
            if current.role == "admin" {
                struct Count: Decodable { let n: Int }
                let left = try await tx.first(Count.self,
                                              "select count(*)::int as n from users where role = 'admin'")?.n ?? 0
                guard left > 1 else {
                    throw HTTPError(.conflict, "the last administrator cannot be demoted")
                }
                // A demotion the deployment would undo at the next restart is
                // not a demotion, so say so rather than appearing to do it.
                guard !services.configuration.adminEmails.contains(current.email) else {
                    throw HTTPError(.conflict,
                                    "\(current.email) is in ADMIN_EMAILS; take it out of the list first")
                }
            }
            guard let changed = try await tx.first(
                Account.self, "update users set role = $1 where id = $2 returning id, email, role",
                role, id.value) else {
                throw HTTPError(.internalServerError)
            }
            return (changed, true)
        }
        guard let outcome else { return nil }
        if outcome.changed {
            // After the commit, not inside it: sessions ended for a change
            // that then rolled back would sign somebody out for nothing. Their
            // refresh tokens are gone, so the next refresh is refused and
            // signing in again mints a token that says the new role. The
            // access token they hold says the old one until it expires.
            try await services.issuer.revokeAll(subject: "\(outcome.account.id)")
            AppLog.info("role changed", ["account": "\(outcome.account.id)",
                                         "role": "\(outcome.account.role)",
                                         "by": "\(jwt.claims.sub)"])
        }
        return JSON(outcome.account)
    }
        .summary("Make an account an administrator, or a member again")
        .tags("admin")
        .response(.notFound, "No account has that id")
        .response(.conflict, "The last administrator, or one the deployment names")

    return app
}
