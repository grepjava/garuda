//===----------------------------------------------------------------------===//
// Accounts and sessions: sign-up, login, logout and a protected route.
//
//   POST /signup   {"username", "password"}   201 {"id", "username"}, or 409
//   POST /login    {"username", "password"}   200 {"token", "expiresAt"}, or 401
//   GET  /me       Authorization: Bearer ...  200 {"id", "username"}, or 401
//   POST /logout   Authorization: Bearer ...  204
//
// What it shows:
//
// - Passwords stored as PBKDF2 hashes (`Passwords`), hashed on the blocking
//   pool so a worker keeps serving while a login spends its few hundred
//   milliseconds of CPU.
// - Session tokens that are random (`Tokens.random`), with only their digest
//   in the database: a copy of the table holds no token that works.
// - A login that takes as long for an unknown username as for a wrong
//   password, so timing does not say which usernames exist.
// - `authenticate(bearer:state:)` guarding a group of routes, with the user it
//   found handed to handlers through the request's context.
//
// Run it behind TLS, and with `--rate-limit`: every login attempt costs a
// thread of CPU.
//===----------------------------------------------------------------------===//

import Garuda

public struct User: Codable, Equatable, Sendable {
    public let id: Int
    public let username: String
}

enum CurrentUser: RequestContextKey {
    typealias Value = User
}

struct Credentials: Decodable {
    let username: String
    let password: String
}

struct Session: Encodable {
    let token: String
    let expiresAt: Timestamp
}

let migrations = [
    """
    create table users (
        id integer primary key,
        username text not null unique,
        password_hash text not null,
        created_at text not null);
    create table sessions (
        token_digest text primary key,
        user_id integer not null references users(id) on delete cascade,
        expires_at text not null);
    create index sessions_user on sessions (user_id);
    """,
]

/// How long a session lasts.
let sessionSeconds: Int64 = 7 * 24 * 3600

/// A username is 3 to 32 lowercase letters, digits and underscores.
private func validUsername(_ name: String) -> Bool {
    (3...32).contains(name.utf8.count) && name.utf8.allSatisfy {
        ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95
    }
}

/// A password is 8 to 1024 bytes. The upper bound keeps a request from
/// making every hashing iteration work on megabytes.
private func validPassword(_ password: String) -> Bool {
    (8...1024).contains(password.utf8.count)
}

/// What an unknown username's login is checked against, so it costs what a
/// known one does. Made once per worker, on first use.
private final class DecoyHash: @unchecked Sendable {
    var value: String? = nil
}

/// The accounts API over the database at `path`. `iterations` is for tests,
/// which cannot wait 600,000 iterations per login; leave it alone otherwise.
public func authApp(databasePath path: String, iterations: Int = Passwords.defaultIterations) -> Application {
    let app = Application()

    app.state { _ in
        let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
        try db.migrate(migrations)
        return db
    }
    app.state { _ in DecoyHash() }

    app.post("/signup") { (body: Body<Credentials>, db: State<SQLiteDatabase>) async throws -> JSON<User> in
        let username = body.value.username.lowercased()
        guard validUsername(username) else {
            throw HTTPError(.unprocessableContent, "a username is 3 to 32 letters, digits and underscores")
        }
        guard validPassword(body.value.password) else {
            throw HTTPError(.unprocessableContent, "a password is 8 to 1024 bytes")
        }
        let hash = try await Passwords.hash(body.value.password, iterations: iterations)
        do {
            guard let user = try await db.value.first(
                User.self,
                "insert into users (username, password_hash, created_at) values (?, ?, ?) returning id, username",
                username, hash, Timestamp.now) else {
                throw HTTPError(.internalServerError)
            }
            return JSON(user, status: .created)
        } catch let error as SQLiteClientError where error.isConstraintViolation {
            throw HTTPError(.conflict, "that username is taken")
        }
    }

    app.post("/login") { (body: Body<Credentials>, db: State<SQLiteDatabase>, decoy: State<DecoyHash>)
        async throws -> JSON<Session> in
        struct Account: Decodable {
            let id: Int
            let passwordHash: String
        }
        let refused = HTTPError(.unauthorized, "wrong username or password")
        let username = body.value.username.lowercased()
        guard validPassword(body.value.password) else { throw refused }

        let account = try await db.value.first(
            Account.self, "select id, password_hash as passwordHash from users where username = ?", username)
        guard let account else {
            // The same work as a real check, then the same answer.
            if decoy.value.value == nil {
                decoy.value.value = try await Passwords.hash(Tokens.random(), iterations: iterations)
            }
            _ = try await Passwords.verify(body.value.password, against: decoy.value.value!)
            throw refused
        }
        guard try await Passwords.verify(body.value.password, against: account.passwordHash) else {
            throw refused
        }
        // Stored with fewer iterations than asked for now: upgrade it while
        // the password is at hand.
        if Passwords.needsRehash(account.passwordHash, iterations: iterations) {
            let upgraded = try await Passwords.hash(body.value.password, iterations: iterations)
            try await db.value.execute("update users set password_hash = ? where id = ?", upgraded, account.id)
        }

        let token = Tokens.random()
        let now = Timestamp.now
        let expires = now.adding(seconds: sessionSeconds)
        try await db.value.transaction { tx in
            // Expired sessions are cleared as new ones are made.
            try await tx.execute("delete from sessions where expires_at <= ?", now)
            try await tx.execute("insert into sessions (token_digest, user_id, expires_at) values (?, ?, ?)",
                                 Tokens.digest(token), account.id, expires)
        }
        return JSON(Session(token: token, expiresAt: expires))
    }

    app.group("/") {
        app.authenticate(bearer: CurrentUser.self, state: SQLiteDatabase.self) { token, db in
            try await db.first(
                User.self,
                """
                select users.id, users.username from sessions join users on users.id = sessions.user_id
                where sessions.token_digest = ? and sessions.expires_at > ?
                """,
                Tokens.digest(token), Timestamp.now)
        }

        app.get("/me") { (user: Context<CurrentUser>) in
            JSON(user.value)
        }

        app.post("/logout") { (token: BearerToken, db: State<SQLiteDatabase>) async throws -> HTTPStatus in
            try await db.value.execute("delete from sessions where token_digest = ?", Tokens.digest(token.token))
            return .noContent
        }
    }

    return app
}
