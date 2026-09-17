import Testing
import GarudaPostgres
@testable import Garuda

// Password hashes, session tokens, and state reached from middleware.

@Suite("Passwords and tokens")
struct PasswordsTests {
    @Test func pbkdf2MatchesTheRFCVector() throws {
        // RFC 7914 section 11: PBKDF2-HMAC-SHA256, "passwd", "salt", c = 1;
        // the first 32 bytes of its 64.
        let derived = try Passwords.derive("passwd", salt: Array("salt".utf8), iterations: 1)
        #expect(derived.map { String($0, radix: 16).count == 1 ? "0" + String($0, radix: 16) : String($0, radix: 16) }
                    .joined() == "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    }

    @Test func aHashVerifiesItsPasswordAndNoOther() async throws {
        let stored = try await Passwords.hash("correct horse", iterations: 1_000)
        #expect(stored.hasPrefix("$pbkdf2-sha256$i=1000$"))
        // 16 bytes of salt and 32 of hash, in unpadded base64.
        let parts = stored.split(separator: "$")
        #expect(parts.count == 4 && parts[2].count == 22 && parts[3].count == 43)
        #expect(try await Passwords.verify("correct horse", against: stored))
        #expect(try await !Passwords.verify("correct horsE", against: stored))
        #expect(try await !Passwords.verify("", against: stored))
        // A fresh salt every time.
        #expect(try await Passwords.hash("correct horse", iterations: 1_000) != stored)
    }

    @Test func aStoredHashCarriesItsIterations() async throws {
        let weak = try await Passwords.hash("pw", iterations: 1_000)
        #expect(Passwords.needsRehash(weak, iterations: 2_000))
        #expect(!Passwords.needsRehash(weak, iterations: 1_000))
        #expect(try await Passwords.verify("pw", against: weak))
        #expect(Passwords.needsRehash("not a hash"))
    }

    @Test func malformedHashesAreRefused() async throws {
        let good = try await Passwords.hash("pw", iterations: 1)
        let parts = good.split(separator: "$", omittingEmptySubsequences: false).map(String.init)
        let salt = parts[3], hash = parts[4]
        for bad in [
            "",
            "$pbkdf2-sha1$i=1$\(salt)$\(hash)",
            "$pbkdf2-sha256$i=0$\(salt)$\(hash)",
            "$pbkdf2-sha256$i=-1$\(salt)$\(hash)",
            "$pbkdf2-sha256$i=99999999$\(salt)$\(hash)",
            "$pbkdf2-sha256$i=1$\(salt)",
            "$pbkdf2-sha256$i=1$\(salt)$\(hash)$",
            "$pbkdf2-sha256$i=1$\(salt)=$\(hash)",
            "$pbkdf2-sha256$i=1$\(salt)$\(hash.dropLast())",
            "$pbkdf2-sha256$i=1$*$\(hash)",
        ] {
            await #expect(throws: PasswordError.malformedHash, "\(bad)") {
                try await Passwords.verify("pw", against: bad)
            }
        }
        #expect(try await Passwords.verify("pw", against: good))
    }

    @Test func tokensAreRandomAndURLSafe() {
        let a = Tokens.random(), b = Tokens.random()
        #expect(a != b)
        #expect(a.utf8.count == 43)
        #expect(Tokens.random(bytes: 16).utf8.count == 22)
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)
        #expect((0..<200).allSatisfy { _ in Tokens.random().utf8.allSatisfy(safe.contains) })
    }

    @Test func aDigestIsSHA256InHex() {
        #expect(Tokens.digest("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(Tokens.digest("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func hashingRunsOffTheWorker() throws {
        let app = Application()
        app.get("/hash") { () async throws -> String in
            let stored = try await Passwords.hash("pw", iterations: 1_000)
            return try await Passwords.verify("pw", against: stored) ? "verified" : "refused"
        }
        #expect(try app.test.get("/hash").text == "verified")
    }
}

@Suite("State from middleware")
struct StateFromMiddlewareTests {
    final class Sessions: @unchecked Sendable {
        let tokens: [String: String]
        init(_ tokens: [String: String]) { self.tokens = tokens }
    }

    enum Who: RequestContextKey { typealias Value = String }

    @Test func authenticateHandsTheWorkersStateToItsCheck() throws {
        let app = Application()
        app.state { _ in Sessions(["t0k3n": "ada"]) }
        app.group("/api") {
            app.authenticate(bearer: Who.self, state: Sessions.self) { token, sessions in
                sessions.tokens[token]
            }
            app.get("/me") { (who: Context<Who>) in who.value }
        }
        app.group("/admin") {
            app.authenticate(basic: Who.self, realm: "admin", state: Sessions.self) { user, password, sessions in
                sessions.tokens[password] == user ? user : nil
            }
            app.get("/") { (who: Context<Who>) in "admin \(who.value)" }
        }
        let client = app.test
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer t0k3n")]).text == "ada")
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer other")]).status == .unauthorized)
        let missing = try client.get("/api/me")
        #expect(missing.status == .unauthorized)
        #expect(missing.header("www-authenticate") == "Bearer")
        let basic = "Basic " + Base64.encode(Array("ada:t0k3n".utf8))
        #expect(try client.get("/admin", headers: [("authorization", basic)]).text == "admin ada")
        #expect(try client.get("/admin").header("www-authenticate")?.hasPrefix("Basic realm=\"admin\"") == true)
    }

    @Test func middlewareReadsStateAndAMissingOneIsAServerFault() throws {
        let app = Application()
        app.state { _ in Sessions(["x": "y"]) }
        app.use { request, _ in
            let sessions = try request.state(Sessions.self)
            return sessions.tokens.count == 1 ? nil : HTTPStatus.serviceUnavailable
        }
        app.get("/ok") { () in "ok" }
        #expect(try app.test.get("/ok").text == "ok")

        let bare = Application()
        bare.use { request, _ in
            _ = try request.state(Sessions.self)
            return nil
        }
        bare.get("/ok") { () in "ok" }
        #expect(try bare.test.get("/ok").status == .internalServerError)
    }
}
