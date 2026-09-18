//===----------------------------------------------------------------------===//
// Accounts: signing up, signing in, keeping a session alive, and ending it.
//
//   POST /auth/signup   {"email","password"}      201 the account, 409, 422
//   POST /auth/login    {"email","password"}      200 a token pair, or 401
//   POST /auth/refresh  {"refresh_token"}         200 a token pair, or 400
//   POST /auth/logout   {"refresh_token"}         204, and repeatable
//   POST /auth/logout-all  Bearer access token    204, every device
//   GET  /auth/me          Bearer access token    200 {"id","email","role"}
//
// A login answers with a short-lived access token (a JWT, checked on every
// request without a lookup) and a long-lived refresh token (32 random bytes,
// stored only as a digest, rotated on every use). `TokenIssuer` does the
// rotation and the reuse detection; MIDDLEWARE.md describes it.
//
// Two things here are deliberate and worth copying:
//
// - A login costs the same whether the email is unknown or the password is
//   wrong, so timing does not say which emails have accounts.
// - Passwords are hashed with 600,000 PBKDF2 iterations on the blocking pool,
//   so the worker keeps serving while a login spends its CPU.
//===----------------------------------------------------------------------===//

import Garuda

/// What a login sends. No rules of its own on purpose: the rules below say
/// what a *new* password has to be, and an account made before they changed
/// still has to be able to sign in. A login answers yes or no, and nothing
/// about the shape of what was sent.
struct Credentials: Decodable {
    let email: String
    let password: String
}

/// What a sign-up sends, and what it has to be. Refused as 422 with the field
/// named, before the handler runs -- see Validation.swift in Garuda.
struct NewAccount: Decodable, Validated {
    let email: String
    let password: String

    func validate(_ check: inout Validation) {
        // Deliberately not a grammar for RFC 5322: an address is checked by
        // sending to it, and this only refuses what cannot be one.
        check.email("email", normalised(email: email))
        check.length("email", email, atMost: 320)
        // Length is the only password rule worth having: composition rules
        // push people towards "Password1!". 72 bytes is where bcrypt
        // truncates, and this is PBKDF2, but staying under it keeps a later
        // change of algorithm open.
        check.require(password.utf8.count >= 10 && password.utf8.count <= 72,
                      "password", "is 10 to 72 bytes")
    }
}

struct RefreshRequest: Decodable {
    let refresh_token: String
}

public struct Account: Codable, Equatable, Sendable {
    public let id: Int64
    public let email: String
    /// What this account may do: `member` or `admin`. See Admin.swift.
    public let role: String
}


/// An address as it is stored and looked up: trimmed, and lowercased, so that
/// one person has one account however they type it. Shared with the
/// configuration, which normalises `ADMIN_EMAILS` the same way so that they
/// match a row.
func normalised(email: String) -> String {
    email.trimmingWhitespace().lowercased()
}

func addAccountRoutes(_ app: Application, _ configuration: StarterConfiguration) {
    app.group("/auth") {
        app.post("/signup") { (body: Body<NewAccount>, services: State<Services>)
            async throws -> JSON<Account> in
            guard services.value.configuration.signUpsOpen else {
                throw HTTPError(.forbidden, "sign-ups are closed")
            }
            // Already checked: extraction refused anything that breaks
            // `NewAccount`'s rules before this ran.
            let email = normalised(email: body.value.email)
            let hash = try await Passwords.hash(body.value.password)
            do {
                guard let account = try await services.value.pool.first(
                    Account.self,
                    "insert into users (email, password, created_at) values ($1, $2, $3) "
                        + "returning id, email, role",
                    email, hash, Timestamp.now.secondsSinceEpoch) else {
                    throw HTTPError(.internalServerError)
                }
                return JSON(account, status: .created)
            } catch let error as PostgresClientError where error.sqlState == "23505" {
                throw HTTPError(.conflict, "that email already has an account")
            }
        }
            .summary("Create an account")
            .tags("auth")

        app.post("/login") { (body: Body<Credentials>, services: State<Services>)
            async throws -> JSON<TokenPair> in
            let email = normalised(email: body.value.email)
            let found = try await services.value.pool.first(
                LoginRow.self, "select id, password from users where email = $1", email)
            // The same work either way: an unknown email verifies against a
            // hash nobody has.
            // A real hash, made once per worker at start-up, so an unknown
            // email costs what a known one does.
            let against = found?.password ?? services.value.absentPasswordHash
            let correct = try await Passwords.verify(body.value.password, against: against)
            guard let found, correct else { throw HTTPError(.unauthorized, "that email and password do not match") }
            return JSON(try await services.value.issuer.issue(subject: "\(found.id)"))
        }
            .summary("Sign in and take a token pair")
            .tags("auth")

        app.post("/refresh") { (body: Body<RefreshRequest>, services: State<Services>)
            async throws -> JSON<TokenPair> in
            JSON(try await services.value.issuer.refresh(body.value.refresh_token))
        }
            .summary("Exchange a refresh token for a new pair")
            .tags("auth")

        app.post("/logout") { (body: Body<RefreshRequest>, services: State<Services>)
            async throws -> HTTPStatus in
            // Ends this one session. An unknown token is not an error, so a
            // client that logs out twice is not told something went wrong.
            try await services.value.issuer.revoke(body.value.refresh_token)
            return .noContent
        }
            .summary("End this session")
            .tags("auth")

        app.post("/logout-all") { (jwt: JWT<AccessClaims>, services: State<Services>)
            async throws -> HTTPStatus in
            try await services.value.issuer.revokeAll(subject: jwt.claims.sub)
            return .noContent
        }
            .summary("End every session of this account")
            .tags("auth")

        app.get("/me") { (jwt: JWT<AccessClaims>) async -> JSON<Account> in
            // From the token, with no lookup: it carries who they are and what
            // they may do, as of when it was issued.
            JSON(Account(id: jwt.claims.userID ?? -1, email: jwt.claims.email, role: jwt.claims.role))
        }
            .summary("Who the access token belongs to")
            .tags("auth")
    }
}

struct LoginRow: Decodable {
    let id: Int64
    let password: String
}
