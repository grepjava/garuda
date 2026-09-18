#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import Garuda
@testable import StarterExample

// The starter application end to end, through `app.test`: the real engine,
// the real PostgreSQL, its own migrations.
//
// Opt-in, because it needs a database it may drop tables in:
//
//     STARTER_DATABASE_URL=postgres://garuda:garuda-secret@127.0.0.1:55432/postgres?sslmode=disable \
//         swift test

private let databaseURL: String? = {
    guard let raw = getenv("STARTER_DATABASE_URL") else { return nil }
    let url = String(cString: raw)
    return url.isEmpty ? nil : url
}()

/// A configuration for tests: quick tokens, no documentation routes.
private func testConfiguration() -> StarterConfiguration {
    var configuration = StarterConfiguration(mode: .development, databaseURL: databaseURL!)
    configuration.databasePoolSize = 4
    configuration.accessTokenSeconds = 60
    configuration.refreshTokenDays = 1
    configuration.sessionDays = 2
    return configuration
}

/// An empty database: the migrations then build the schema from nothing, as
/// they do on a new deployment.
private func emptySchema() throws {
    let app = starterApp(testConfiguration())
    try app.runOnce { start in
        let pool = try start.state(Services.self).pool
        for table in ["notes", "users", "garuda_refresh_tokens", "garuda_refresh_tokens_families",
                      "garuda_schema_version"] {
            try await pool.execute("drop table if exists \(table) cascade")
        }
    }
}

private func signUp(_ client: TestClient, _ email: String, _ password: String = "correct horse battery") throws
    -> TestResponse {
    try client.post("/auth/signup", body: #"{"email":"\#(email)","password":"\#(password)"}"#)
}

private func logIn(_ client: TestClient, _ email: String,
                   _ password: String = "correct horse battery") throws -> TokenPair {
    let response = try client.post("/auth/login", body: #"{"email":"\#(email)","password":"\#(password)"}"#)
    #expect(response.status == .ok, "\(response.status) \(response.text)")
    return try response.json(TokenPair.self)
}

private func bearer(_ pair: TokenPair) -> [(String, String)] {
    [("authorization", "Bearer \(pair.accessToken)")]
}

@Suite("Starter example", .serialized)
struct StarterExampleTests {
    @Test(.enabled(if: databaseURL != nil, "set STARTER_DATABASE_URL to run"))
    func accountsAndSessions() throws {
        try emptySchema()
        let client = starterApp(testConfiguration()).test
        client.timeoutMillis = 30_000

        // Signing up, and what is refused.
        let created = try signUp(client, "Ada@Example.com ")
        #expect(created.status == .created, "\(created.status) \(created.text)")
        let account = try created.json(Account.self)
        #expect(account.email == "ada@example.com", "the address is trimmed and lowercased")
        #expect(try signUp(client, "ada@example.com").status == .conflict)
        #expect(try signUp(client, "not-an-address").status == .unprocessableContent)
        #expect(try signUp(client, "grace@example.com", "short").status == .unprocessableContent)

        // Logging in, and what does not.
        let pair = try logIn(client, "ada@example.com")
        #expect(pair.tokenType == "Bearer" && pair.expiresIn == 60)
        #expect(try client.post("/auth/login",
                                body: #"{"email":"ada@example.com","password":"wrong one entirely"}"#).status
                    == .unauthorized)
        #expect(try client.post("/auth/login",
                                body: #"{"email":"nobody@example.com","password":"correct horse battery"}"#).status
                    == .unauthorized)

        // The access token says who it belongs to; without one, 401.
        let me = try client.get("/auth/me", headers: bearer(pair))
        #expect(try me.json(Account.self) == account)
        #expect(try client.get("/auth/me").status == .unauthorized)
        #expect(try client.get("/auth/me", headers: [("authorization", "Bearer nonsense")]).status == .unauthorized)

        // Refreshing rotates the refresh token, and the spent one is refused.
        let refreshed = try client.post("/auth/refresh", body: #"{"refresh_token":"\#(pair.refreshToken)"}"#)
        #expect(refreshed.status == .ok, "\(refreshed.status) \(refreshed.text)")
        let second = try refreshed.json(TokenPair.self)
        #expect(second.refreshToken != pair.refreshToken)
        let reused = try client.post("/auth/refresh", body: #"{"refresh_token":"\#(pair.refreshToken)"}"#)
        #expect(reused.status == .badRequest)
        #expect(reused.text == #"{"error":"invalid_grant"}"#)

        // Logging out ends that session, and repeating it is not an error.
        #expect(try client.post("/auth/logout", body: #"{"refresh_token":"\#(second.refreshToken)"}"#).status
                    == .noContent)
        #expect(try client.post("/auth/logout", body: #"{"refresh_token":"\#(second.refreshToken)"}"#).status
                    == .noContent)
        #expect(try client.post("/auth/refresh", body: #"{"refresh_token":"\#(second.refreshToken)"}"#).status
                    == .badRequest)

        // Logging out everywhere ends the sessions of every device.
        let phone = try logIn(client, "ada@example.com")
        let laptop = try logIn(client, "ada@example.com")
        #expect(try client.post("/auth/logout-all", headers: bearer(phone)).status == .noContent)
        for ended in [phone, laptop] {
            #expect(try client.post("/auth/refresh", body: #"{"refresh_token":"\#(ended.refreshToken)"}"#).status
                        == .badRequest)
        }
    }

    @Test(.enabled(if: databaseURL != nil, "set STARTER_DATABASE_URL to run"))
    func notesBelongToTheirAccount() throws {
        try emptySchema()
        let client = starterApp(testConfiguration()).test
        client.timeoutMillis = 30_000
        _ = try signUp(client, "ada@example.com")
        _ = try signUp(client, "grace@example.com")
        let ada = try logIn(client, "ada@example.com")
        let grace = try logIn(client, "grace@example.com")

        // Writing, reading, changing and deleting.
        let written = try client.post("/notes", body: #"{"title":"  First  ","body":"hello"}"#, headers: bearer(ada))
        #expect(written.status == .created, "\(written.status) \(written.text)")
        let note = try written.json(Note.self)
        #expect(note.title == "First" && note.body == "hello")
        #expect(try client.get("/notes/\(note.id)", headers: bearer(ada)).json(Note.self) == note)
        let changed = try client.request("PATCH", "/notes/\(note.id)", headers: bearer(ada),
                                         body: Array(#"{"body":"hello again"}"#.utf8))
        #expect(try changed.json(Note.self).body == "hello again")
        #expect(try changed.json(Note.self).title == "First", "what was left out is kept")

        // Another account cannot see it, change it or delete it, and is told
        // it is not there rather than that it is not theirs.
        #expect(try client.get("/notes/\(note.id)", headers: bearer(grace)).status == .notFound)
        #expect(try client.request("PATCH", "/notes/\(note.id)", headers: bearer(grace),
                                   body: Array(#"{"title":"mine"}"#.utf8)).status == .notFound)
        #expect(try client.delete("/notes/\(note.id)", headers: bearer(grace)).status == .notFound)
        #expect(try client.get("/notes", headers: bearer(grace)).json(NotePage.self).notes.isEmpty)

        // A note needs a token at all.
        #expect(try client.get("/notes").status == .unauthorized)
        // And a title.
        #expect(try client.post("/notes", body: #"{"title":"   "}"#, headers: bearer(ada)).status
                    == .unprocessableContent)
        #expect(try client.request("PATCH", "/notes/\(note.id)", headers: bearer(ada),
                                   body: Array("{}".utf8)).status == .unprocessableContent)

        // Paging: newest first, and a cursor to the next page.
        for i in 2...5 {
            #expect(try client.post("/notes", body: #"{"title":"Note \#(i)"}"#, headers: bearer(ada)).status
                        == .created)
        }
        let first = try client.get("/notes?limit=2", headers: bearer(ada)).json(NotePage.self)
        #expect(first.notes.map(\.title) == ["Note 5", "Note 4"])
        let next = try #require(first.nextBefore)
        let page = try client.get("/notes?limit=2&before=\(next)", headers: bearer(ada)).json(NotePage.self)
        #expect(page.notes.map(\.title) == ["Note 3", "Note 2"])
        let last = try client.get("/notes?limit=2&before=\(try #require(page.nextBefore))",
                                  headers: bearer(ada)).json(NotePage.self)
        #expect(last.notes.map(\.title) == ["First"])
        #expect(last.nextBefore == nil, "a short page is the end")

        #expect(try client.delete("/notes/\(note.id)", headers: bearer(ada)).status == .noContent)
        #expect(try client.delete("/notes/\(note.id)", headers: bearer(ada)).status == .notFound)
    }

    @Test(.enabled(if: databaseURL != nil, "set STARTER_DATABASE_URL to run"))
    func healthReadinessAndDocumentation() throws {
        try emptySchema()
        var configuration = testConfiguration()
        configuration.documentationPath = "/docs"
        let client = starterApp(configuration).test
        client.timeoutMillis = 30_000

        #expect(try client.get("/health").text == "ok")
        #expect(try client.get("/ready").text == "ready")

        let document = try client.get("/docs/openapi.json")
        #expect(document.status == .ok)
        #expect(document.text.contains("\"/notes\""))
        #expect(document.text.contains("\"/auth/login\""))
        #expect(document.text.contains("Sign in and take a token pair"))
        #expect(try client.get("/docs").text.contains("swagger-ui"))
    }

    @Test(.enabled(if: databaseURL != nil, "set STARTER_DATABASE_URL to run"))
    func migrationsRunOnceAndAreSafeToRepeat() throws {
        try emptySchema()
        // A worker migrates as it starts, so the first request already has a
        // schema; a second application over the same database finds nothing
        // to do.
        let first = starterApp(testConfiguration()).test
        #expect(try first.get("/health").status == .ok)
        let applied = starterApp(testConfiguration())
        final class Count: @unchecked Sendable { var value = -1 }
        let count = Count()
        try applied.runOnce { start in
            count.value = try await start.state(Services.self).pool.migrate(starterMigrations)
        }
        #expect(count.value == 0)
    }
}

@Suite("Starter configuration")
struct StarterConfigurationTests {
    /// An environment as a dictionary, so the reading is tested without
    /// touching the process's own.
    private func read(_ values: [String: String]) -> (String) -> String? {
        { values[$0] }
    }

    @Test func developmentNeedsNothing() throws {
        let configuration = try StarterConfiguration.fromEnvironment(read([:]))
        #expect(configuration.mode == .development)
        #expect(configuration.signingKeyPEM == nil, "a key is made up for the run")
        #expect(configuration.accessTokenSeconds == 900)
        #expect(configuration.signUpsOpen)
        #expect(configuration.documentationPath == "/docs")
    }

    @Test func productionMustBeToldEverything() throws {
        do {
            _ = try StarterConfiguration.fromEnvironment(read(["APP_ENV": "production"]))
            Issue.record("production with nothing set should not be usable")
        } catch let error as ConfigurationError {
            // Every problem at once, not one per restart.
            #expect(error.problems.count == 2, "\(error)")
            #expect(error.problems.contains { $0.contains("DATABASE_URL") })
            #expect(error.problems.contains { $0.contains("JWT_PRIVATE_KEY") })
        }
    }

    @Test func productionRefusesAPlaintextDatabase() throws {
        let key = try #require(try JWTKey.generate(.ES256).privatePEM)
        do {
            _ = try StarterConfiguration.fromEnvironment(read([
                "APP_ENV": "production",
                "DATABASE_URL": "postgres://app:secret@db/shop?sslmode=disable",
                "JWT_PRIVATE_KEY": key,
            ]))
            Issue.record("sslmode=disable should not pass in production")
        } catch let error as ConfigurationError {
            #expect(error.problems.count == 1)
            #expect(error.problems[0].contains("sslmode=disable"))
        }
    }

    @Test func whatIsRefusedInAnyMode() throws {
        do {
            _ = try StarterConfiguration.fromEnvironment(read([
                "APP_ENV": "staging",
                "ACCESS_TOKEN_SECONDS": "0",
                "REFRESH_TOKEN_DAYS": "not a number",
                "SIGNUPS_OPEN": "maybe",
                "DOCS_PATH": "docs",
                "JWT_PRIVATE_KEY": "not a key",
            ]))
            Issue.record("none of that should pass")
        } catch let error as ConfigurationError {
            #expect(error.problems.count == 6, "\(error)")
        }
    }

    @Test func lifetimesMustMakeSenseTogether() throws {
        do {
            _ = try StarterConfiguration.fromEnvironment(read([
                "ACCESS_TOKEN_SECONDS": "604800",  // a week
                "REFRESH_TOKEN_DAYS": "1",
            ]))
            Issue.record("an access token outliving its refresh token is not usable")
        } catch let error as ConfigurationError {
            #expect(error.problems.count == 1, "\(error)")
            #expect(error.problems[0].contains("ACCESS_TOKEN_SECONDS"))
        }
        do {
            _ = try StarterConfiguration.fromEnvironment(read([
                "REFRESH_TOKEN_DAYS": "30",
                "SESSION_DAYS": "7",
            ]))
            Issue.record("a refresh token outliving its session is not usable")
        } catch let error as ConfigurationError {
            #expect(error.problems[0].contains("SESSION_DAYS"))
        }
    }

    @Test func aKeyCanComeFromAFile() throws {
        let path = "/tmp/starter-key-\(getpid()).pem"
        let pem = try #require(try JWTKey.generate(.ES256).privatePEM)
        #expect(pem.withCString { text in
            guard let file = fopen(path, "wb") else { return false }
            defer { fclose(file) }
            return fwrite(text, 1, strlen(text), file) > 0
        })
        defer { unlink(path) }
        let configuration = try StarterConfiguration.fromEnvironment(read(["JWT_PRIVATE_KEY_FILE": path]))
        #expect(configuration.signingKeyPEM == pem)

        do {
            _ = try StarterConfiguration.fromEnvironment(read(["JWT_PRIVATE_KEY_FILE": "/tmp/nothing-here.pem"]))
            Issue.record("a key file that cannot be read should not pass")
        } catch let error as ConfigurationError {
            #expect(error.problems[0].contains("cannot be read"))
        }
    }
}
