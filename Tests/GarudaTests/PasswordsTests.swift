@testable import Garuda
import GarudaTesting
import Testing

// Password hashes and session tokens.

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

    @Test func aHashMadeElsewhereVerifies() async throws {
        // The format is Garuda 1's, so a user table from it carries over: "pw"
        // with the salt "saltsaltsaltsalt", 1,000 iterations, made by Python's
        // hashlib.pbkdf2_hmac.
        let stored = "$pbkdf2-sha256$i=1000$c2FsdHNhbHRzYWx0c2FsdA$T7epWfxBHiKQQGlNJ3+9CM17dQuKVeWu++anuIAf6vg"
        #expect(try await Passwords.verify("pw", against: stored))
        #expect(try await !Passwords.verify("pW", against: stored))
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

    @Test func hashingRunsOffTheWorkers() throws {
        let app = Application()
        app.get("/hash") { () async throws -> String in
            let stored = try await Passwords.hash("pw", iterations: 1_000)
            return try await Passwords.verify("pw", against: stored) ? "verified" : "refused"
        }
        #expect(try app.test.get("/hash").text == "verified")
    }
}
