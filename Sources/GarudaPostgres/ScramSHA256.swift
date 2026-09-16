//===----------------------------------------------------------------------===//
// SCRAM-SHA-256 (RFC 5802, RFC 7677), the client half, as PostgreSQL uses it.
//
// Pure: messages in, messages out, and the nonce injectable so the RFC's own
// test vector can be checked byte for byte. Crypto is the shim's -- HMAC,
// SHA-256 and PBKDF2 from OpenSSL -- because a hand-rolled HMAC is the kind of
// code that passes every test and leaks through timing.
//
// Two things a server gets to decide here are bounded, because either could
// be a server that is not the one it claims to be:
//
//   * Its signature is checked, in constant time. SCRAM authenticates both
//     ends, and a client that does not check `v=` has authenticated nobody.
//   * Its iteration count is held between 4096 and 100 000. Below the floor
//     RFC 7677 sets, an impostor could ask for one iteration and make the
//     client proof it captures cheap to brute-force offline. Above the
//     ceiling, PBKDF2 runs on the worker thread long enough to stall every
//     request that worker is holding.
//
// Not done: SASLprep normalisation of the password. An ASCII password is
// unaffected; a password whose normalised form differs from its UTF-8 bytes
// will not authenticate. Said here so it is found here.
//===----------------------------------------------------------------------===//

import CGaruda

public enum ScramError: Error, Equatable, Sendable {
    /// A server message that is not the shape SCRAM gives it.
    case malformed
    /// The server's nonce does not begin with ours. It is answering some
    /// other exchange, or making one up.
    case nonceMismatch
    /// An iteration count outside what this client will spend.
    case iterationsOutOfRange(Int)
    /// A mandatory extension (`m=`) this client does not implement.
    case unsupportedExtension
    /// The server refused, with the reason it gave.
    case serverError(String)
    /// The server could not prove it knows the password. Whoever this is, it
    /// is not the database the password belongs to.
    case serverSignatureMismatch
    /// The crypto shim failed, which means no OpenSSL.
    case crypto
}

public struct ScramSHA256Client {
    public static let mechanism = "SCRAM-SHA-256"
    public static let minimumIterations = 4096
    public static let maximumIterations = 100_000

    let username: String
    let password: [UInt8]
    let clientNonce: String
    private(set) var clientFirstBare = ""
    private var authMessage: [UInt8] = []
    private var serverSignature: [UInt8] = []

    /// `username` is empty for PostgreSQL, which takes the user from the
    /// startup message and ignores this one.
    public init(username: String = "", password: String, nonce: String? = nil) {
        self.username = username
        self.password = Array(password.utf8)
        self.clientNonce = nonce ?? ScramSHA256Client.randomNonce()
        clientFirstBare = "n=\(ScramSHA256Client.escape(username)),r=\(clientNonce)"
    }

    /// 18 random bytes in base64: printable, and never a comma, which is what
    /// separates attributes.
    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        _ = bytes.withUnsafeMutableBytes { pg_random_bytes($0.baseAddress, 18) }
        return Base64.encode(bytes)
    }

    /// The first message: no channel binding, then the bare part.
    public var clientFirstMessage: [UInt8] {
        Array(("n,," + clientFirstBare).utf8)
    }

    /// Reads the server's first message and returns the client's final one.
    public mutating func respond(toServerFirst message: [UInt8]) throws(ScramError) -> [UInt8] {
        guard let text = String(validating: message, as: UTF8.self) else { throw .malformed }
        if text.hasPrefix("m=") { throw .unsupportedExtension }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0].hasPrefix("r="), parts[1].hasPrefix("s="), parts[2].hasPrefix("i=") else {
            throw .malformed
        }
        let nonce = String(parts[0].dropFirst(2))
        // Longer than ours as well as starting with it: a server that echoes
        // our nonce back unchanged contributed no randomness of its own.
        guard nonce.hasPrefix(clientNonce), nonce.count > clientNonce.count else {
            throw .nonceMismatch
        }
        guard let salt = Base64.decode(String(parts[1].dropFirst(2))), !salt.isEmpty else {
            throw .malformed
        }
        guard let iterations = Int(parts[2].dropFirst(2)) else { throw .malformed }
        guard iterations >= ScramSHA256Client.minimumIterations,
              iterations <= ScramSHA256Client.maximumIterations else {
            throw .iterationsOutOfRange(iterations)
        }

        let saltedPassword = try pbkdf2(password, salt: salt, iterations: iterations)
        let clientKey = try hmac(saltedPassword, Array("Client Key".utf8))
        let storedKey = try sha256(clientKey)
        let finalWithoutProof = "c=biws,r=\(nonce)"
        authMessage = Array("\(clientFirstBare),\(text),\(finalWithoutProof)".utf8)
        let clientSignature = try hmac(storedKey, authMessage)
        var proof = clientKey
        for i in proof.indices { proof[i] ^= clientSignature[i] }
        let serverKey = try hmac(saltedPassword, Array("Server Key".utf8))
        serverSignature = try hmac(serverKey, authMessage)
        return Array("\(finalWithoutProof),p=\(Base64.encode(proof))".utf8)
    }

    /// Checks the server's final message. Returns only if the server proved it
    /// knows the password.
    public func verify(serverFinal message: [UInt8]) throws(ScramError) {
        guard let text = String(validating: message, as: UTF8.self) else { throw .malformed }
        if text.hasPrefix("e=") { throw .serverError(String(text.dropFirst(2))) }
        guard !serverSignature.isEmpty else { throw .malformed }
        guard text.hasPrefix("v="),
              let claimed = Base64.decode(String(text.dropFirst(2).prefix { $0 != "," })) else {
            throw .malformed
        }
        guard ScramSHA256Client.constantTimeEqual(claimed, serverSignature) else {
            throw .serverSignatureMismatch
        }
    }

    // MARK: Pieces

    /// `,` and `=` in a user name, escaped as RFC 5802 section 5.1 requires.
    static func escape(_ name: String) -> String {
        var out = ""
        for c in name {
            switch c {
            case "=": out += "=3D"
            case ",": out += "=2C"
            default: out.append(c)
            }
        }
        return out
    }

    /// Compares every byte whatever it finds, so the time taken says nothing
    /// about how much of a forged signature was right.
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }

    private func hmac(_ key: [UInt8], _ data: [UInt8]) throws(ScramError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let n = key.withUnsafeBytes { k in
            data.withUnsafeBytes { d in
                out.withUnsafeMutableBytes { o in
                    pg_hmac(PG_SHA256, k.baseAddress, k.count, d.baseAddress, d.count,
                            o.baseAddress!.assumingMemoryBound(to: UInt8.self))
                }
            }
        }
        guard n == 32 else { throw .crypto }
        return out
    }

    private func sha256(_ data: [UInt8]) throws(ScramError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let n = data.withUnsafeBytes { d in
            out.withUnsafeMutableBytes { o in
                pg_hash(PG_SHA256, d.baseAddress, d.count,
                        o.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
        }
        guard n == 32 else { throw .crypto }
        return out
    }

    private func pbkdf2(_ password: [UInt8], salt: [UInt8],
                        iterations: Int) throws(ScramError) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let ok = password.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                out.withUnsafeMutableBytes { o in
                    pg_pbkdf2(PG_SHA256, p.baseAddress, p.count, s.baseAddress, s.count,
                              UInt32(iterations),
                              o.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard ok == 0 else { throw .crypto }
        return out
    }
}

/// Base64 with the standard alphabet and required padding.
///
/// Strict on the way in. What gets decoded here came from a server -- a salt,
/// a signature -- and a decoder that skipped characters it did not recognise
/// would compare a signature the server never sent.
public enum Base64 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    public static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= bytes.count {
            let v = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            out.append(alphabet[Int(v >> 18 & 63)])
            out.append(alphabet[Int(v >> 12 & 63)])
            out.append(alphabet[Int(v >> 6 & 63)])
            out.append(alphabet[Int(v & 63)])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let v = UInt32(bytes[i]) << 16
            out.append(alphabet[Int(v >> 18 & 63)])
            out.append(alphabet[Int(v >> 12 & 63)])
            out.append(UInt8(ascii: "="))
            out.append(UInt8(ascii: "="))
        } else if rest == 2 {
            let v = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
            out.append(alphabet[Int(v >> 18 & 63)])
            out.append(alphabet[Int(v >> 12 & 63)])
            out.append(alphabet[Int(v >> 6 & 63)])
            out.append(UInt8(ascii: "="))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Nil for anything that is not canonical base64: a length that is not a
    /// multiple of four, a character outside the alphabet, padding anywhere
    /// but the end.
    public static func decode(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 4 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 4 * 3)
        var i = 0
        while i < chars.count {
            let last = i + 4 == chars.count
            var values = [UInt32](repeating: 0, count: 4)
            var padding = 0
            for j in 0..<4 {
                let c = chars[i + j]
                if c == UInt8(ascii: "=") {
                    // Only in the last group, only at its end.
                    guard last, j >= 2 else { return nil }
                    padding += 1
                    continue
                }
                guard padding == 0, let v = value(c) else { return nil }
                values[j] = v
            }
            let n = values[0] << 18 | values[1] << 12 | values[2] << 6 | values[3]
            out.append(UInt8(truncatingIfNeeded: n >> 16))
            if padding < 2 { out.append(UInt8(truncatingIfNeeded: n >> 8)) }
            if padding < 1 { out.append(UInt8(truncatingIfNeeded: n)) }
            i += 4
        }
        return out
    }

    private static func value(_ c: UInt8) -> UInt32? {
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return UInt32(c - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return UInt32(c - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(c - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): return 62
        case UInt8(ascii: "/"): return 63
        default: return nil
        }
    }
}
