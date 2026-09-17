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
// -- a few hundred milliseconds of CPU -- so it runs on the worker's blocking
// pool, never on the worker. That makes a login endpoint something to rate
// limit (`--rate-limit`): each attempt holds a pool thread while it hashes.
//
// A session token is random bytes, not a hash of anything. Store only its
// digest: whoever reads the table then holds no token that works.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaPostgres

/// Why a password could not be hashed or checked.
public enum PasswordError: Error, Equatable, Sendable {
    /// The stored string is not a hash `Passwords.hash` makes.
    case malformedHash
    /// The system's randomness or OpenSSL's PBKDF2 failed.
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
        var salt = [UInt8](repeating: 0, count: saltBytes)
        guard salt.withUnsafeMutableBytes({ av_random_bytes($0.baseAddress, $0.count) }) == 0 else {
            throw PasswordError.unavailable
        }
        let fixedSalt = salt
        let derived = try await blocking { try derive(password, salt: fixedSalt, iterations: iterations) }
        return prefix + String(iterations) + "$" + unpadded(fixedSalt) + "$" + unpadded(derived)
    }

    /// Whether `password` is the one `stored` was made from. The comparison
    /// takes the same time wherever the hashes differ.
    public static func verify(_ password: String, against stored: String) async throws -> Bool {
        let parsed = try parse(stored)
        let derived = try await blocking { try derive(password, salt: parsed.salt, iterations: parsed.iterations) }
        return constantTimeEquals(derived, parsed.hash)
    }

    /// Whether `stored` was made with fewer iterations than `iterations`: hash
    /// the password again after it verifies, and store the new hash.
    public static func needsRehash(_ stored: String, iterations: Int = defaultIterations) -> Bool {
        guard let parsed = try? parse(stored) else { return true }
        return parsed.iterations < iterations
    }

    static func derive(_ password: String, salt: [UInt8], iterations: Int) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: hashBytes)
        let utf8 = Array(password.utf8)
        let rc = utf8.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                out.withUnsafeMutableBytes { o in
                    av_pbkdf2(Int32(AV_SHA256), p.baseAddress, p.count, s.baseAddress, s.count,
                              UInt32(iterations), o.baseAddress!.assumingMemoryBound(to: UInt8.self), o.count)
                }
            }
        }
        guard rc == 0 else { throw PasswordError.unavailable }
        return out
    }

    static func parse(_ stored: String) throws(PasswordError) -> (iterations: Int, salt: [UInt8], hash: [UInt8]) {
        guard stored.hasPrefix(prefix) else { throw .malformedHash }
        let parts = stored.dropFirst(prefix.utf8.count).split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].utf8.count <= 8, parts[0].utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let iterations = Int(parts[0]), iterations >= 1, iterations <= maxIterations,
              let salt = padded(parts[1]), salt.count >= 8, salt.count <= 64,
              let hash = padded(parts[2]), hash.count == hashBytes else {
            throw .malformedHash
        }
        return (iterations, salt, hash)
    }

    private static func unpadded(_ bytes: [UInt8]) -> String {
        var text = Base64.encode(bytes)
        while text.hasSuffix("=") { text.removeLast() }
        return text
    }

    private static func padded(_ text: Substring) -> [UInt8]? {
        guard !text.contains("=") else { return nil }
        var full = String(text)
        while full.utf8.count % 4 != 0 { full.append("=") }
        return Base64.decode(full)
    }
}

public enum Tokens {
    /// `bytes` random bytes in base64url without padding: 43 characters for
    /// the default 32, which is 256 bits no one guesses.
    public static func random(bytes: Int = 32) -> String {
        precondition(bytes >= 16 && bytes <= 1024, "a token needs 16 to 1024 bytes")
        var raw = [UInt8](repeating: 0, count: bytes)
        // The system's generator does not fail short of a broken system, and a
        // token of zeros would be a token anyone can guess.
        guard raw.withUnsafeMutableBytes({ av_random_bytes($0.baseAddress, $0.count) }) == 0 else {
            fatalError("the system's random number generator failed")
        }
        return urlSafe(Base64.encode(raw))
    }

    /// The SHA-256 of `token` in lowercase hex: what to store and look up in
    /// place of the token itself.
    public static func digest(_ token: String) -> String {
        var out = [UInt8](repeating: 0, count: 32)
        let utf8 = Array(token.utf8)
        let rc = utf8.withUnsafeBytes { t in
            out.withUnsafeMutableBytes { o in
                av_hash(Int32(AV_SHA256), t.baseAddress, t.count, o.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        precondition(rc == 32, "SHA-256 is unavailable")
        let hex = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in out {
            text.append(hex[Int(byte >> 4)])
            text.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }

    private static func urlSafe(_ base64: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(base64.utf8.count)
        for c in base64.utf8 {
            switch c {
            case UInt8(ascii: "+"): out.append(UInt8(ascii: "-"))
            case UInt8(ascii: "/"): out.append(UInt8(ascii: "_"))
            case UInt8(ascii: "="): break
            default: out.append(c)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Byte arrays compared in time that depends only on their lengths.
func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for i in 0..<a.count { difference |= a[i] ^ b[i] }
    return difference == 0
}
