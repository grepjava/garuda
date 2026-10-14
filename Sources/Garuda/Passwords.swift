//===----------------------------------------------------------------------===//
// Password hashes and session tokens.
//
//     let stored = try await Passwords.hash(password)           // at sign-up
//     guard try await Passwords.verify(password, against: stored) else { ... }
//
//     let token = Tokens.random()                               // to the client
//     try await db.execute("insert into sessions values (?, ?)", Tokens.digest(token), user)
//
// A password is hashed with PBKDF2-HMAC-SHA256 (RFC 8018), 600,000 iterations
// by default, as OWASP recommends for it, with a random 16-byte salt. The
// result is one string that carries its own parameters, so the iteration
// count can rise later without invalidating what is stored:
//
//     $pbkdf2-sha256$i=600000$<salt>$<hash>
//
// with salt and hash in base64 without padding. Hashing is deliberately slow
// -- a few hundred milliseconds of CPU -- so it runs on Vega's blocking pool
// (`Runtime.blocking`), never on one of the shard's worker threads. That makes
// a login endpoint something to rate limit: each attempt holds a pool thread
// while it hashes.
//
// A session token is random bytes, not a hash of anything. Store only its
// digest: whoever reads the table then holds no token that works.
//
// PBKDF2, SHA-256 and the random bytes are VegaCrypto's.
//===----------------------------------------------------------------------===//

import Vega
import VegaCrypto

/// Why a password could not be hashed or checked.
public enum PasswordError: Error, Equatable, Sendable {
    /// The stored string is not a hash `Passwords.hash` makes.
    case malformedHash
    /// PBKDF2 failed.
    case unavailable
}

public enum Passwords {
    /// OWASP's recommendation for PBKDF2-HMAC-SHA256.
    public static let defaultIterations = 600_000

    /// Stored hashes asking for more are refused, so a corrupted row cannot
    /// hold a thread for minutes.
    static let maxIterations = 10_000_000
    static let saltBytes = 16
    static let hashBytes = 32
    static let prefix = "$pbkdf2-sha256$i="

    /// A new hash of `password` with a fresh salt, computed on the blocking
    /// pool.
    public static func hash(_ password: String, iterations: Int = defaultIterations) async throws -> String {
        precondition(iterations >= 1 && iterations <= maxIterations, "iterations out of range")
        let salt = SecureRandom.bytes(saltBytes)
        let derived = try await Runtime.blocking { () throws(PasswordError) -> [UInt8] in
            try derive(password, salt: salt, iterations: iterations)
        }
        return prefix + String(iterations) + "$" + unpadded(salt) + "$" + unpadded(derived)
    }

    /// Whether `password` is the one `stored` was made from. The comparison
    /// takes the same time wherever the hashes differ.
    public static func verify(_ password: String, against stored: String) async throws -> Bool {
        let parsed = try parse(stored)
        let derived = try await Runtime.blocking { () throws(PasswordError) -> [UInt8] in
            try derive(password, salt: parsed.salt, iterations: parsed.iterations)
        }
        return ConstantTime.equals(derived, parsed.hash)
    }

    /// Whether `stored` was made with fewer iterations than `iterations`: hash
    /// the password again after it verifies, and store the new hash.
    public static func needsRehash(_ stored: String, iterations: Int = defaultIterations) -> Bool {
        guard let parsed = try? parse(stored) else { return true }
        return parsed.iterations < iterations
    }

    static func derive(_ password: String, salt: [UInt8], iterations: Int) throws(PasswordError) -> [UInt8] {
        do {
            return try PBKDF2.deriveKey(.sha256, password: Array(password.utf8), salt: salt,
                                        iterations: iterations, length: hashBytes)
        } catch {
            throw .unavailable
        }
    }

    static func parse(_ stored: String) throws(PasswordError) -> (iterations: Int, salt: [UInt8], hash: [UInt8]) {
        guard stored.hasPrefix(prefix) else { throw .malformedHash }
        let parts = stored.dropFirst(prefix.utf8.count).split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].utf8.count <= 8, parts[0].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let iterations = Int(parts[0]), iterations >= 1, iterations <= maxIterations,
              let salt = unpaddedDecode(parts[1]), salt.count >= 8, salt.count <= 64,
              let hash = unpaddedDecode(parts[2]), hash.count == hashBytes else {
            throw .malformedHash
        }
        return (iterations, salt, hash)
    }

    private static func unpadded(_ bytes: [UInt8]) -> String {
        var text = StandardBase64.encode(bytes)
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    /// Base64 as `unpadded` writes it: padding is not let in.
    private static func unpaddedDecode(_ text: Substring) -> [UInt8]? {
        guard !text.contains("=") else { return nil }
        return StandardBase64.decode(String(text))
    }
}

public enum Tokens {
    /// `bytes` random bytes in base64url without padding: 43 characters for
    /// the default 32, which is 256 bits no one guesses.
    public static func random(bytes: Int = 32) -> String {
        precondition(bytes >= 16 && bytes <= 1024, "a token needs 16 to 1024 bytes")
        // The generator does not fail short of a broken system, and stops
        // the program if it does: a token of zeros would be one anyone can
        // guess.
        return tokenBase64URLEncode(SecureRandom.bytes(bytes))
    }

    /// The SHA-256 of `token` in lowercase hex: what to store and look up in
    /// place of the token itself.
    public static func digest(_ token: String) -> String {
        let digest = Hash.sha256(Array(token.utf8))
        let hex: StaticString = "0123456789abcdef"
        return String(unsafeUninitializedCapacity: digest.count * 2) { out in
            for (i, byte) in digest.enumerated() {
                out[2 * i] = hex.utf8Start[Int(byte >> 4)]
                out[2 * i + 1] = hex.utf8Start[Int(byte & 0x0F)]
            }
            return digest.count * 2
        }
    }
}
