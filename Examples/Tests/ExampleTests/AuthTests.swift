#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import GarudaSQLite
import GarudaTesting
@testable import AuthExample

@Suite("Auth example")
struct AuthExampleTests {
    /// Few iterations: the tests check the flow, not the cost.
    private func client() -> TestClient {
        authApp(databasePath: ":memory:", iterations: 1_000).test
    }

    private func login(_ client: TestClient, _ username: String, _ password: String) throws -> TestResponse {
        try client.post("/login", body: "{\"username\":\"\(username)\",\"password\":\"\(password)\"}")
    }

    @Test func signUpLogInUseAndLogOut() throws {
        let client = client()
        let signup = try client.post("/signup", body: #"{"username":"Ada","password":"correct horse"}"#)
        #expect(signup.status == .created)
        #expect(try signup.json(User.self) == User(id: 1, username: "ada"))

        let session = try login(client, "ada", "correct horse")
        #expect(session.status == .ok)
        struct Session: Decodable { let token: String; let expiresAt: Timestamp }
        let token = try session.json(Session.self).token
        #expect(token.utf8.count == 43)

        let bearer = [("authorization", "Bearer \(token)")]
        #expect(try client.get("/me", headers: bearer).json(User.self) == User(id: 1, username: "ada"))
        #expect(try client.get("/whoami", headers: bearer).text == "signed in as ada")
        #expect(try client.get("/whoami").text == "not signed in")
        #expect(try client.post("/logout", headers: bearer).status == .noContent)
        #expect(try client.get("/me", headers: bearer).status == .unauthorized)
        #expect(try client.get("/whoami", headers: bearer).text == "not signed in")
    }

    @Test func wrongCredentialsLookTheSame() throws {
        let client = client()
        _ = try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#)
        let wrongPassword = try login(client, "ada", "battery staple")
        let noSuchUser = try login(client, "grace", "battery staple")
        #expect(wrongPassword.status == .unauthorized)
        #expect(noSuchUser.status == .unauthorized)
        #expect(wrongPassword.text == noSuchUser.text)
    }

    @Test func protectedRoutesNeedAValidSession() throws {
        let client = client()
        let missing = try client.get("/me")
        #expect(missing.status == .unauthorized)
        #expect(missing.header("www-authenticate") == "Bearer")
        #expect(try client.get("/me", headers: [("authorization", "Bearer \(Tokens.random())")]).status == .unauthorized)
        // Sign-up and login are outside the group, and need none.
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status == .created)
    }

    @Test func signUpIsValidated() throws {
        let client = client()
        #expect(try client.post("/signup", body: #"{"username":"a","password":"correct horse"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada!","password":"correct horse"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"short"}"#).status
                == .unprocessableContent)
        #expect(try client.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status == .created)
        #expect(try client.post("/signup", body: #"{"username":"ADA","password":"another one"}"#).status == .conflict)
    }

    @Test func aWeakerHashIsUpgradedAtLogin() throws {
        // Signed up when the iteration count was lower; logging in under a
        // higher one stores a new hash.
        let path = "/tmp/garuda-auth-example-\(getpid()).db"
        defer { for suffix in ["", "-wal", "-shm"] { unlink(path + suffix) } }
        do {
            let before = authApp(databasePath: path, iterations: 1_000).test
            #expect(try before.post("/signup", body: #"{"username":"ada","password":"correct horse"}"#).status
                    == .created)
        }
        let after = authApp(databasePath: path, iterations: 2_000).test
        #expect(try login(after, "ada", "correct horse").status == .ok)
        #expect(try login(after, "ada", "correct horse").status == .ok)
        let hash = try hashOf("ada", path)
        #expect(hash.hasPrefix("$pbkdf2-sha256$i=2000$"))
    }

    private func hashOf(_ username: String, _ path: String) throws -> String {
        let app = Application()
        app.state { _ in try SQLiteDatabase(SQLiteConfiguration(path: path)) }
        app.get("/hash") { (db: State<SQLiteDatabase>) async throws -> String in
            try await db.value.first(String.self, "select password_hash from users where username = ?", username) ?? ""
        }
        return try app.test.get("/hash").text
    }
}
