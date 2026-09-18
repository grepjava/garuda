//===----------------------------------------------------------------------===//
// Accounts: signing up, signing in, keeping a session alive, and ending it.
//
//   POST /auth/signup   {"email","password"}      201 {"id","email"}, 409, 422
//   POST /auth/login    {"email","password"}      200 a token pair, or 401
//   POST /auth/refresh  {"refresh_token"}         200 a token pair, or 400
//   POST /auth/logout   {"refresh_token"}         204, and repeatable
//   POST /auth/logout-all  Bearer access token    204, every device
//   GET  /auth/me          Bearer access token    200 {"id","email"}
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

struct Credentials: Decodable {
    let email: String
    let password: String
}

struct RefreshRequest: Decodable {
    let refresh_token: String
}

public struct Account: Codable, Equatable, Sendable {
    public let id: Int64
    public let email: String
}


private func validEmail(_ raw: String) throws -> String {
    let email = raw.trimmingWhitespace().lowercased()
    // Deliberately not a grammar for RFC 5322: an address is checked by
    // sending to it. This only refuses what cannot be one.
    guard email.count >= 3, email.count <= 320,
          let at = email.firstIndex(of: "@"), at != email.startIndex,
          email.index(after: at) != email.endIndex,
          email[email.index(after: at)...].contains("."),
          !email.contains(" ") else {
        throw HTTPError(.unprocessableContent, "that is not an email address")
    }
    return email
}

private func validPassword(_ password: String) throws -> String {
    // Length is the only rule worth having: composition rules push people
    // towards "Password1!". 72 bytes is where bcrypt truncates, and this is
    // PBKDF2, but staying under it keeps a later change of algorithm open.
    guard password.utf8.count >= 10, password.utf8.count <= 72 else {
        throw HTTPError(.unprocessableContent, "a password is 10 to 72 bytes")
    }
    return password
}

func addAccountRoutes(_ app: Application, _ configuration: StarterConfiguration) {
    app.group("/auth") {
        app.post("/signup") { (body: Body<Credentials>, services: State<Services>)
            async throws -> JSON<Account> in
            guard services.value.configuration.signUpsOpen else {
                throw HTTPError(.forbidden, "sign-ups are closed")
            }
            let email = try validEmail(body.value.email)
            let password = try validPassword(body.value.password)
            let hash = try await Passwords.hash(password)
            do {
                guard let account = try await services.value.pool.first(
                    Account.self,
                    "insert into users (email, password, created_at) values ($1, $2, $3) returning id, email",
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
            let email = (try? validEmail(body.value.email)) ?? body.value.email
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
            JSON(Account(id: jwt.claims.userID ?? -1, email: jwt.claims.email))
        }
            .summary("Who the access token belongs to")
            .tags("auth")
    }
}

struct LoginRow: Decodable {
    let id: Int64
    let password: String
}
