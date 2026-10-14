//===----------------------------------------------------------------------===//
// JSON Web Tokens (RFC 7519): signed claims a client carries, checked without
// a lookup.
//
//     struct UserClaims: Codable, Sendable {
//         let sub: String
//         let exp: Int
//         let role: String
//     }
//
//     let keys = try JWTKeys([.hmac(secret, algorithm: .HS256)],
//                            validation: JWTValidation(issuer: "shop"))
//     app.jwtVerifier { _ in keys }
//
//     let token = try keys.sign(UserClaims(sub: "42", exp: now + 900, role: "admin"))
//     app.get("/me") { (jwt: JWT<UserClaims>) in "user \(jwt.claims.sub)" }
//
// A token is three base64url parts: a header naming the algorithm and key, the
// claims, and a signature over the first two. Verifying one checks, in order:
//
// - The shape, and a size under 16 KiB.
// - The header's `alg` is the algorithm of the key it names -- by `kid`, or
//   the only key there is. A key is bound to one algorithm, so `none`, and
//   the old trick of signing with HS256 and an RSA public key as the secret,
//   have nothing to match. A `crit` header is refused: nothing here
//   understands an extension it would have to.
// - The signature, with constant-time comparison for HMAC.
// - `exp` and `nbf` against the clock with `leewaySeconds` either side, and
//   `iss` and `aud` when the validation names them. A token without `exp` is
//   refused unless `requireExpiration` is off.
//
// Then the claims decode into your type. Anything that fails is a 401 with
// `WWW-Authenticate: Bearer error="invalid_token"`.
//
// Keys: HMAC secrets (HS256/384/512, at least as long as the hash), and RSA
// (RS and PS, 2048 bits and up), ECDSA (ES256/384/512) and Ed25519 (EdDSA)
// from PEM or JWK. `JWTKey.generate` makes one. Verifying needs only the
// public half; signing needs the private one. The cryptography is Vega's
// (VegaCrypto); nothing here computes a hash or a signature itself.
//
// A shard's threads share one verifier. What a verify reads is immutable
// once built -- the keys, the validation -- except the cache of headers seen
// before, which a reader scans without a lock (`JWTHeaderCache`).
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Synchronization
import VegaCrypto

/// The signature algorithms of RFC 7518 and RFC 8037, by their JWS names.
public enum JWTAlgorithm: String, Sendable, CaseIterable, Codable {
    case HS256, HS384, HS512
    case RS256, RS384, RS512
    case PS256, PS384, PS512
    case ES256, ES384, ES512
    case EdDSA

    /// Whether this is HS256, HS384 or HS512, signed with a shared secret.
    public var isHMAC: Bool { self == .HS256 || self == .HS384 || self == .HS512 }

    /// VegaCrypto's name for a public-key algorithm; nil for HMAC. The JWS
    /// names are the same.
    var signatureAlgorithm: SignatureAlgorithm? {
        isHMAC ? nil : SignatureAlgorithm(rawValue: rawValue)
    }

    /// The hash an HMAC algorithm uses.
    var hash: HashAlgorithm {
        switch self {
        case .HS384: .sha384
        case .HS512: .sha512
        default: .sha256
        }
    }

    var hashLength: Int { isHMAC ? hash.byteCount : 0 }
}

/// Why a token or a key was refused.
public enum JWTError: Error, Equatable, Sendable, ResponseError {
    /// Not three base64url parts of JSON, or too large.
    case malformed
    /// No key for the token's `kid`, or for its `alg`.
    case unknownKey
    /// The signature does not match.
    case badSignature
    case expired
    case notYetValid
    /// A claim the validation requires is absent, or not what it must be.
    case invalidClaim(String)
    /// The header carries `crit`, or an algorithm this does not accept.
    case unsupported(String)
    /// A key that cannot be used as given.
    case invalidKey(String)
    /// A key that verifies but cannot sign.
    case cannotSign
    /// The key set could not be fetched.
    case keySetUnavailable

    public var status: HTTPStatus {
        switch self {
        case .invalidKey, .cannotSign: .internalServerError
        case .keySetUnavailable: .serviceUnavailable
        default: .unauthorized
        }
    }

    /// Nothing that says which check failed: a client probing tokens learns
    /// only that this one is not accepted.
    public var reason: String? {
        switch self {
        case .invalidKey, .cannotSign, .keySetUnavailable: nil
        default: "invalid token"
        }
    }
}

/// Seconds since the epoch, by the system's clock: what `exp` and `nbf` are
/// compared with.
func epochSeconds() -> Int64 {
    Int64(time(nil))
}

// MARK: - Keys

/// A key for one algorithm: an HMAC secret, or a public or private key.
public final class JWTKey: Sendable {
    public let algorithm: JWTAlgorithm
    /// The `kid` a token names this key by, if any.
    public let keyID: String?
    /// An HMAC secret, keyed once for every token it checks.
    let mac: HMAC?
    /// The private key, when this key can sign with one.
    let signing: SigningKey?
    /// The public key; nil for an HMAC secret.
    let publicKey: PublicKey?

    /// Whether this key can sign: an HMAC secret or a private key.
    public var canSign: Bool { mac != nil || signing != nil }

    private init(algorithm: JWTAlgorithm, keyID: String?, mac: HMAC? = nil,
                 signing: SigningKey? = nil, publicKey: PublicKey? = nil) {
        self.algorithm = algorithm
        self.keyID = keyID
        self.mac = mac
        self.signing = signing
        self.publicKey = publicKey ?? signing?.publicKey
    }

    /// An HMAC secret, at least as many bytes as the algorithm's hash.
    public static func hmac(_ secret: [UInt8], algorithm: JWTAlgorithm = .HS256,
                            keyID: String? = nil) throws(JWTError) -> JWTKey {
        guard algorithm.isHMAC else { throw .invalidKey("\(algorithm) is not an HMAC algorithm") }
        guard secret.count >= algorithm.hashLength else {
            throw .invalidKey("an \(algorithm) secret is at least \(algorithm.hashLength) bytes")
        }
        let mac: HMAC
        do {
            mac = try HMAC(algorithm.hash, key: secret)
        } catch {
            throw .invalidKey("the secret could not be keyed: \(error)")
        }
        return JWTKey(algorithm: algorithm, keyID: keyID, mac: mac)
    }

    public static func hmac(_ secret: String, algorithm: JWTAlgorithm = .HS256,
                            keyID: String? = nil) throws(JWTError) -> JWTKey {
        try hmac(Array(secret.utf8), algorithm: algorithm, keyID: keyID)
    }

    /// A key from PEM: a public key or certificate, which verifies, or a
    /// private key, which also signs.
    public static func pem(_ pem: String, algorithm: JWTAlgorithm, keyID: String? = nil) throws(JWTError) -> JWTKey {
        guard !algorithm.isHMAC else { throw .invalidKey("an HMAC key is a secret, not PEM") }
        // A private key first, since a public key is all a private key's PEM
        // would give the other way round.
        if let signing = try? SigningKey(pem: pem) {
            try check(signing.publicKey, for: algorithm)
            return JWTKey(algorithm: algorithm, keyID: keyID, signing: signing)
        }
        let publicKey: PublicKey
        do {
            publicKey = try PublicKey(pem: pem)
        } catch {
            throw .invalidKey("not a public key, certificate or private key in PEM")
        }
        try check(publicKey, for: algorithm)
        return JWTKey(algorithm: algorithm, keyID: keyID, publicKey: publicKey)
    }

    /// A new private key for `algorithm`.
    public static func generate(_ algorithm: JWTAlgorithm, keyID: String? = nil) throws(JWTError) -> JWTKey {
        guard let signatureAlgorithm = algorithm.signatureAlgorithm else {
            return try hmac(SecureRandom.bytes(algorithm.hashLength), algorithm: algorithm, keyID: keyID)
        }
        do {
            let signing = try SigningKey.generate(signatureAlgorithm.keyType)
            return JWTKey(algorithm: algorithm, keyID: keyID, signing: signing)
        } catch {
            throw .invalidKey("a \(algorithm) key could not be made: \(error)")
        }
    }

    /// A public key from a JWK: `kty` RSA with `n` and `e`, EC with `crv`, `x`
    /// and `y`, or OKP Ed25519 with `x`. The JWK's `alg`, when it has one,
    /// must be `algorithm`.
    public static func jwk(_ jwk: JWK, algorithm: JWTAlgorithm? = nil) throws(JWTError) -> JWTKey {
        let named = jwk.alg.flatMap(JWTAlgorithm.init(rawValue:))
        if let algorithm, let named, named != algorithm {
            throw .invalidKey("the JWK is for \(named), not \(algorithm)")
        }
        func bytes(_ member: String?, _ name: String) throws(JWTError) -> [UInt8] {
            guard let member, let decoded = tokenBase64Decode(member), !decoded.isEmpty else {
                throw .invalidKey("the JWK has no valid \(name)")
            }
            return decoded
        }
        let components: PublicKey.Components
        let chosen: JWTAlgorithm
        switch jwk.kty {
        case "RSA":
            let n = try bytes(jwk.n, "n")
            let e = try bytes(jwk.e, "e")
            guard let algorithm = algorithm ?? named else { throw .invalidKey("an RSA JWK needs an algorithm") }
            components = .rsa(modulus: n, exponent: e)
            chosen = algorithm
        case "EC":
            let (curve, curveAlgorithm): (KeyType, JWTAlgorithm) = switch jwk.crv {
            case "P-256": (.p256, .ES256)
            case "P-384": (.p384, .ES384)
            case "P-521": (.p521, .ES512)
            default: throw .invalidKey("an EC JWK's crv is P-256, P-384 or P-521")
            }
            components = .ec(curve: curve, x: try bytes(jwk.x, "x"), y: try bytes(jwk.y, "y"))
            chosen = algorithm ?? named ?? curveAlgorithm
        case "OKP":
            guard jwk.crv == "Ed25519" else { throw .invalidKey("an OKP JWK's crv is Ed25519") }
            components = .ed25519(x: try bytes(jwk.x, "x"))
            chosen = algorithm ?? .EdDSA
        case "oct":
            let k = try bytes(jwk.k, "k")
            guard let algorithm = algorithm ?? named else { throw .invalidKey("an oct JWK needs an algorithm") }
            return try hmac(k, algorithm: algorithm, keyID: jwk.kid)
        default:
            throw .invalidKey("a JWK's kty is RSA, EC, OKP or oct")
        }
        guard !chosen.isHMAC else { throw .invalidKey("a \(jwk.kty) JWK is not an HMAC secret") }
        let publicKey: PublicKey
        do {
            publicKey = try PublicKey(components)
        } catch {
            throw .invalidKey("the JWK's members are not a key")
        }
        try check(publicKey, for: chosen)
        return JWTKey(algorithm: chosen, keyID: jwk.kid, publicKey: publicKey)
    }

    /// Refuses a key that is not one for `algorithm`, or an RSA key too small
    /// to trust.
    private static func check(_ key: PublicKey, for algorithm: JWTAlgorithm) throws(JWTError) {
        guard let signatureAlgorithm = algorithm.signatureAlgorithm, key.type == signatureAlgorithm.keyType else {
            throw .invalidKey("the key is not a key for \(algorithm)")
        }
        if key.type == .rsa && key.bits < 2048 { throw .invalidKey("an RSA key is at least 2048 bits") }
    }

    /// The public key as PEM, or nil for an HMAC secret.
    public var publicPEM: String? { publicKey?.pem }

    /// The private key as PKCS #8 PEM, or nil when there is none.
    public var privatePEM: String? { signing?.pem }

    /// The public key as a JWK, for a key set others verify with. Nil for an
    /// HMAC secret, which is never published.
    public var publicJWK: JWK? {
        guard let publicKey else { return nil }
        var jwk = JWK(kty: "", kid: keyID, alg: algorithm.rawValue, use: "sig")
        switch publicKey.components {
        case let .rsa(n, e):
            jwk.kty = "RSA"
            jwk.n = tokenBase64URLEncode(n)
            jwk.e = tokenBase64URLEncode(e)
        case let .ec(curve, x, y):
            jwk.kty = "EC"
            jwk.crv = curve.curveName
            jwk.x = tokenBase64URLEncode(x)
            jwk.y = tokenBase64URLEncode(y)
        case let .ed25519(x):
            jwk.kty = "OKP"
            jwk.crv = "Ed25519"
            jwk.x = tokenBase64URLEncode(x)
        }
        return jwk
    }

    func sign(_ input: [UInt8]) throws(JWTError) -> [UInt8] {
        if let mac { return mac.authenticationCode(for: input) }
        guard let signing, let signatureAlgorithm = algorithm.signatureAlgorithm else { throw .cannotSign }
        do {
            return try signing.signature(for: input, algorithm: signatureAlgorithm)
        } catch {
            throw .cannotSign
        }
    }

    func verify(_ input: [UInt8], signature: [UInt8]) -> Bool {
        input.withUnsafeBufferPointer { input in
            signature.withUnsafeBufferPointer { verify(input, signature: $0) }
        }
    }

    /// Whether `signature` is this key's over `input`, read where they lie.
    func verify(_ input: UnsafeBufferPointer<UInt8>, signature: UnsafeBufferPointer<UInt8>) -> Bool {
        if let mac {
            let code = mac.authenticationCode(for: UnsafeRawBufferPointer(input))
            guard signature.count == code.count else { return false }
            // Every byte compared whichever differs: how long this takes says
            // nothing about how much of a forged MAC was right.
            var difference: UInt8 = 0
            for i in 0..<code.count { difference |= code[i] ^ signature[i] }
            return difference == 0
        }
        guard let publicKey, let signatureAlgorithm = algorithm.signatureAlgorithm else { return false }
        return publicKey.isValidSignature(Array(signature), for: Array(input), algorithm: signatureAlgorithm)
    }
}

/// A JSON Web Key (RFC 7517), as a key set publishes it.
public struct JWK: Codable, Sendable, Equatable {
    public var kty: String
    public var kid: String?
    public var alg: String?
    public var use: String?
    public var n: String?
    public var e: String?
    public var crv: String?
    public var x: String?
    public var y: String?
    public var k: String?

    public init(kty: String, kid: String? = nil, alg: String? = nil, use: String? = nil) {
        self.kty = kty
        self.kid = kid
        self.alg = alg
        self.use = use
    }
}

/// A JWK Set: what `/.well-known/jwks.json` serves.
public struct JWKSet: Codable, Sendable, Equatable {
    public var keys: [JWK]

    public init(keys: [JWK]) {
        self.keys = keys
    }
}

// MARK: - Validation

/// What a verified token's claims must say, besides being signed.
public struct JWTValidation: Sendable {
    /// `iss` must be this, when set.
    public var issuer: String?
    /// `aud` must be, or contain, this, when set.
    public var audience: String?
    /// How far `exp` and `nbf` may be off, for clocks that disagree.
    public var leewaySeconds: Int64
    /// A token without `exp` is refused.
    public var requireExpiration: Bool

    public init(issuer: String? = nil, audience: String? = nil, leewaySeconds: Int64 = 60,
                requireExpiration: Bool = true) {
        self.issuer = issuer
        self.audience = audience
        self.leewaySeconds = leewaySeconds
        self.requireExpiration = requireExpiration
    }
}

struct JWTHeader: Codable, Sendable {
    var alg: String
    var typ: String?
    var kid: String?
    var crit: [String]?
}

/// The registered claims, read from any token to check them.
struct RegisteredClaims {
    var exp: Double?
    var nbf: Double?
    var iss: String?
    /// `aud`: one string, or an array of them.
    var aud: [String]?

    /// Read from the claims' JSON as it lies, without a decoder: only the
    /// four members checked here are read, and a whole-number time --
    /// which every issuer writes -- is read without `strtod`. The first of
    /// two members with the same name counts, as it does for the decoder the
    /// claims themselves go through. Throws `malformed` for anything that is
    /// not a JSON object, or a registered claim of the wrong type.
    init(json: UnsafeBufferPointer<UInt8>) throws(JWTError) {
        guard let base = json.baseAddress, json.count > 0 else { throw .malformed }
        let count = json.count
        var scanner = JSONScanner(base: base, count: count)
        do {
            try scanner.skipValue()
            let end = scanner.index
            scanner.skipWhitespace()
            guard scanner.index == count else { throw JWTError.malformed }
            scanner = JSONScanner(base: base, count: end)
            scanner.skipWhitespace()
            guard scanner.peek() == 0x7B else { throw JWTError.malformed }
            scanner.index += 1
            scanner.skipWhitespace()
            if scanner.peek() == 0x7D { return }
            var seen: UInt8 = 0
            while true {
                scanner.skipWhitespace()
                let keyStart = scanner.index
                try scanner.skipString()
                let keyEnd = scanner.index
                scanner.skipWhitespace()
                scanner.index += 1  // :
                scanner.skipWhitespace()
                let value = scanner.index
                // Compared as bytes. A name written with escapes -- which no
                // issuer does -- is decoded first, as the decoder would.
                var name: (UInt8, UInt8, UInt8)? = nil
                let length = keyEnd - keyStart - 2
                if length == 3 {
                    name = (base[keyStart + 1], base[keyStart + 2], base[keyStart + 3])
                } else if length > 3,
                          UnsafeBufferPointer(start: base + keyStart + 1, count: length).contains(0x5C) {
                    let text = Array(try JSONValue.text(base, from: keyStart, to: keyEnd).utf8)
                    if text.count == 3 { name = (text[0], text[1], text[2]) }
                }
                if let (a, b, c) = name {
                    switch (a, b, c) {
                    case (0x65, 0x78, 0x70) where seen & 1 == 0:  // exp
                        seen |= 1
                        exp = try RegisteredClaims.time(base, end, value)
                    case (0x6E, 0x62, 0x66) where seen & 2 == 0:  // nbf
                        seen |= 2
                        nbf = try RegisteredClaims.time(base, end, value)
                    case (0x69, 0x73, 0x73) where seen & 4 == 0:  // iss
                        seen |= 4
                        if !JSONValue.isNull(base, end, at: value) {
                            iss = try JSONValue.string(base, end, at: value, [])
                        }
                    case (0x61, 0x75, 0x64) where seen & 8 == 0:  // aud
                        seen |= 8
                        aud = try RegisteredClaims.audience(base, end, value)
                    default:
                        break
                    }
                }
                try scanner.skipValue()
                scanner.skipWhitespace()
                guard let byte = scanner.peek(), byte == 0x2C else { return }
                scanner.index += 1
            }
        } catch {
            throw .malformed
        }
    }

    /// A NumericDate: seconds, whole or not. Null is absent.
    private static func time(_ base: UnsafePointer<UInt8>, _ count: Int, _ at: Int) throws -> Double? {
        if JSONValue.isNull(base, count, at: at) { return nil }
        if let (magnitude, negative) = try? JSONValue.integer(base, count, at: at, [], expected: "Int"),
           magnitude <= 1 << 53 {
            return negative ? -Double(magnitude) : Double(magnitude)
        }
        return try JSONValue.double(base, count, at: at, [])
    }

    private static func audience(_ base: UnsafePointer<UInt8>, _ count: Int, _ at: Int) throws -> [String]? {
        switch base[at] {
        case 0x6E:
            return JSONValue.isNull(base, count, at: at) ? nil : try [JSONValue.string(base, count, at: at, [])]
        case 0x22:
            return [try JSONValue.string(base, count, at: at, [])]
        case 0x5B:
            var values: [String] = []
            var scanner = JSONScanner(base: base, count: count, at: at + 1)
            scanner.skipWhitespace()
            if scanner.peek() == 0x5D { return values }
            while true {
                scanner.skipWhitespace()
                values.append(try JSONValue.string(base, count, at: scanner.index, []))
                try scanner.skipValue()
                scanner.skipWhitespace()
                guard let byte = scanner.peek(), byte == 0x2C else { return values }
                scanner.index += 1
            }
        default:
            throw JWTError.malformed
        }
    }
}

// MARK: - Signing and verifying

/// The keys an application signs and verifies tokens with, and what their
/// claims must say.
public final class JWTKeys: @unchecked Sendable {
    public let keys: [JWTKey]
    public let validation: JWTValidation
    /// Seconds since the epoch; tests set their own, before the keys are
    /// shared.
    var clock: @Sendable () -> Int64 = { epochSeconds() }
    /// Headers already decoded: an issuer writes the same one on every token.
    let headers = JWTHeaderCache()

    /// Keys as given, unchecked: a published set may repeat or omit a `kid`,
    /// and the first key that matches a token is the one tried.
    init(uncheckedKeys keys: [JWTKey], validation: JWTValidation) {
        self.keys = keys
        self.validation = validation
    }

    public convenience init(_ keys: [JWTKey], validation: JWTValidation = JWTValidation()) throws(JWTError) {
        guard !keys.isEmpty else { throw .invalidKey("a key set needs a key") }
        var seen: Set<String> = []
        for key in keys {
            if let id = key.keyID, !seen.insert(id).inserted { throw .invalidKey("two keys have kid \(id)") }
        }
        if keys.count > 1 && keys.contains(where: { $0.keyID == nil }) {
            throw .invalidKey("with more than one key, every key needs a kid")
        }
        self.init(uncheckedKeys: keys, validation: validation)
    }

    /// The public keys as a JWK Set, for other services to verify with.
    public var publicJWKS: JWKSet {
        JWKSet(keys: keys.compactMap(\.publicJWK))
    }

    /// Signs `claims` with the key named `keyID`, or the first key that can
    /// sign. The header carries the key's `kid`.
    public func sign<Claims: Encodable>(_ claims: Claims, keyID: String? = nil) throws -> String {
        guard let key = keys.first(where: { $0.canSign && (keyID == nil || $0.keyID == keyID) }) else {
            throw JWTError.cannotSign
        }
        return try JWTKeys.sign(claims, with: key)
    }

    static func sign<Claims: Encodable>(_ claims: Claims, with key: JWTKey) throws -> String {
        let header = JWTHeader(alg: key.algorithm.rawValue, typ: "JWT", kid: key.keyID, crit: nil)
        let input = tokenBase64URLEncode(try JSONCoder.encode(header)) + "." + tokenBase64URLEncode(try JSONCoder.encode(claims))
        let signature = try key.sign(Array(input.utf8))
        return input + "." + tokenBase64URLEncode(signature)
    }

    /// The claims of `token` when it is signed by one of these keys and its
    /// claims pass the validation; throws `JWTError` otherwise.
    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type = Claims.self) throws -> Claims {
        try check(token, as: type)
    }

    /// Everything read where it lies in the token's bytes: the header and
    /// its key from the cache when seen before, the signature checked over
    /// the first two parts in place, and the claims decoded from a scratch
    /// buffer on the stack.
    func check<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims {
        guard token.utf8.count <= ParsedToken.maxBytes else { throw JWTError.malformed }
        var text = token
        return try text.withUTF8 { all throws -> Claims in
            let (first, second) = try ParsedToken.dots(all)
            let headerPart = UnsafeBufferPointer(rebasing: all[0..<first])
            let key: JWTKey?
            if let known = headers.entry(for: headerPart) {
                key = known.key
            } else {
                let header = try ParsedToken.header(headerPart)
                key = self.key(for: header)
                headers.keep(key, for: headerPart)
            }
            guard let key else { throw JWTError.unknownKey }
            let payloadPart = UnsafeBufferPointer(rebasing: all[(first + 1)..<second])
            let signaturePart = UnsafeBufferPointer(rebasing: all[(second + 1)...])
            let verified = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: signaturePart.count) { signature in
                guard let length = tokenBase64URLDecode(signaturePart, into: signature) else { return false }
                return key.verify(UnsafeBufferPointer(rebasing: all[0..<second]),
                                  signature: UnsafeBufferPointer(rebasing: signature[0..<length]))
            }
            guard verified else { throw JWTError.badSignature }
            return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: payloadPart.count) { scratch in
                guard let length = tokenBase64URLDecode(payloadPart, into: scratch) else { throw JWTError.malformed }
                return try ParsedToken.validClaims(type, UnsafeBufferPointer(rebasing: scratch[0..<length]),
                                                   validation: validation, now: clock())
            }
        }
    }

    func key(for header: JWTHeader) -> JWTKey? {
        guard let algorithm = JWTAlgorithm(rawValue: header.alg) else { return nil }
        if let kid = header.kid {
            return keys.first { $0.keyID == kid && $0.algorithm == algorithm }
        }
        let candidates = keys.filter { $0.algorithm == algorithm }
        return candidates.count == 1 ? candidates[0] : nil
    }
}

/// A token split and decoded, not yet trusted.
struct ParsedToken {
    static let maxBytes = 16 * 1024

    let header: JWTHeader
    let signingInput: [UInt8]
    let payload: [UInt8]
    let signature: [UInt8]

    /// Read from the token's bytes, as they are: the two dots found, each
    /// part decoded from base64url where it lies, and what is signed -- the
    /// first two parts and the dot between -- taken as one slice.
    init(_ token: String) throws(JWTError) {
        guard token.utf8.count <= ParsedToken.maxBytes else { throw .malformed }
        var text = token
        let read: Result<(JWTHeader, [UInt8], [UInt8], [UInt8]), JWTError> = text.withUTF8 { all in
            do throws(JWTError) {
                let (first, second) = try ParsedToken.dots(all)
                let header = try ParsedToken.header(UnsafeBufferPointer(rebasing: all[0..<first]))
                guard let payload = tokenBase64URLDecode(UnsafeBufferPointer(rebasing: all[(first + 1)..<second])),
                      let signature = tokenBase64URLDecode(UnsafeBufferPointer(rebasing: all[(second + 1)...])) else {
                    return .failure(.malformed)
                }
                return .success((header, Array(all[0..<second]), payload, signature))
            } catch {
                return .failure(error)
            }
        }
        switch read {
        case .success(let (header, signingInput, payload, signature)):
            self.header = header
            self.signingInput = signingInput
            self.payload = payload
            self.signature = signature
        case .failure(let error):
            throw error
        }
    }

    /// Where the token's two dots are: three non-empty parts, no more.
    static func dots(_ all: UnsafeBufferPointer<UInt8>) throws(JWTError) -> (Int, Int) {
        let dot = UInt8(ascii: ".")
        guard let first = all.firstIndex(of: dot),
              let second = all[(first + 1)...].firstIndex(of: dot),
              !all[(second + 1)...].contains(dot),
              first > 0, second > first + 1, second + 1 < all.count else { throw .malformed }
        return (first, second)
    }

    /// The header part decoded and checked: an algorithm this knows, and no
    /// `crit`.
    static func header(_ part: UnsafeBufferPointer<UInt8>) throws(JWTError) -> JWTHeader {
        guard let bytes = tokenBase64URLDecode(part),
              let decoded = try? JSONCoder.decode(JWTHeader.self, from: bytes) else { throw .malformed }
        if decoded.crit != nil { throw .unsupported("crit") }
        guard JWTAlgorithm(rawValue: decoded.alg) != nil else { throw .unsupported(decoded.alg) }
        return decoded
    }

    func claims<Claims: Decodable>(_ type: Claims.Type, key: JWTKey, validation: JWTValidation,
                                   now: Int64) throws -> Claims {
        guard key.verify(signingInput, signature: signature) else { throw JWTError.badSignature }
        return try payload.withUnsafeBufferPointer {
            try ParsedToken.validClaims(type, $0, validation: validation, now: now)
        }
    }

    /// The claims of a signed token, once its registered claims pass.
    static func validClaims<Claims: Decodable>(_ type: Claims.Type, _ payload: UnsafeBufferPointer<UInt8>,
                                               validation: JWTValidation, now: Int64) throws -> Claims {
        let registered = try RegisteredClaims(json: payload)
        let leeway = Double(validation.leewaySeconds)
        if let exp = registered.exp {
            guard Double(now) < exp + leeway else { throw JWTError.expired }
        } else if validation.requireExpiration {
            throw JWTError.invalidClaim("exp")
        }
        if let nbf = registered.nbf, Double(now) + leeway < nbf { throw JWTError.notYetValid }
        if let issuer = validation.issuer, registered.iss != issuer { throw JWTError.invalidClaim("iss") }
        if let audience = validation.audience, !(registered.aud?.contains(audience) ?? false) {
            throw JWTError.invalidClaim("aud")
        }
        do {
            return try JSONCoder.decode(Claims.self, from: payload.baseAddress, count: payload.count)
        } catch {
            throw JWTError.invalidClaim("claims")
        }
    }
}

/// Headers a key set has decoded and found usable, by their bytes, with the
/// key each one names -- or none, for a header naming a key the set does not
/// have. A handful at most: one per issuer and key, in practice.
///
/// Read on every verify, from any of the shard's threads, and written almost
/// never. So an entry, once published, never changes: a reader loads how many
/// there are and scans that many, without a lock. Writers take one between
/// themselves, and the cache only grows, to `capacity`.
final class JWTHeaderCache: @unchecked Sendable {
    struct Entry {
        let bytes: [UInt8]
        let key: JWTKey?
    }

    static let capacity = 8

    private let entries = UnsafeMutablePointer<Entry>.allocate(capacity: JWTHeaderCache.capacity)
    /// How many entries are published; each below it is initialized.
    private let published = Atomic<Int>(0)
    private let writing = Mutex<Void>(())

    deinit {
        entries.deinitialize(count: published.load(ordering: .acquiring))
        entries.deallocate()
    }

    func entry(for bytes: UnsafeBufferPointer<UInt8>) -> Entry? {
        let count = published.load(ordering: .acquiring)
        var i = 0
        while i < count {
            if Self.same(entries[i].bytes, bytes) { return entries[i] }
            i &+= 1
        }
        return nil
    }

    func keep(_ key: JWTKey?, for bytes: UnsafeBufferPointer<UInt8>) {
        writing.withLock { _ in
            let count = published.load(ordering: .relaxed)
            // Full, the cache stays as it is: headers that vary without end
            // are decoded each time rather than churning it.
            guard count < JWTHeaderCache.capacity else { return }
            // Another thread may have kept the same header since this one
            // looked.
            for i in 0..<count where Self.same(entries[i].bytes, bytes) { return }
            (entries + count).initialize(to: Entry(bytes: Array(bytes), key: key))
            published.store(count + 1, ordering: .releasing)
        }
    }

    private static func same(_ kept: [UInt8], _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard kept.count == bytes.count else { return false }
        return kept.withUnsafeBufferPointer { kept in
            var i = 0
            while i < kept.count {
                if kept[i] != bytes[i] { return false }
                i &+= 1
            }
            return true
        }
    }
}

// MARK: - In routes

enum JWTContextKey<Claims: Decodable>: RequestContextKey {
    typealias Value = JWT<Claims>
}

/// The challenge for a token that was presented and refused (RFC 6750 3.1).
let invalidTokenChallenge = #"Bearer error="invalid_token""#

/// A verified token and its claims, from `Authorization: Bearer`, checked by
/// the verifier `app.jwtVerifier` registered -- or, behind
/// `authenticate(jwt:)`, the token that middleware already checked. A request
/// without a valid token is answered 401.
public struct JWT<Claims: Decodable>: RequestExtractor {
    public let claims: Claims
    /// The token as it came.
    public let token: String

    public init(claims: Claims, token: String) {
        self.claims = claims
        self.token = token
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> JWT {
        if let verified = request[context: JWTContextKey<Claims>.self] { return verified }
        guard let token = bearerToken(request) else { throw Unauthenticated(challenge: "Bearer") }
        let verifier = try request.state((any JWTVerifying).self)
        do {
            if let claims = try verifier.verifyNow(token, as: Claims.self) {
                return JWT(claims: claims, token: token)
            }
            return JWT(claims: try await verifier.verify(token, as: Claims.self), token: token)
        } catch let error as JWTError where error.status == .unauthorized {
            throw Unauthenticated(challenge: invalidTokenChallenge, reason: error.reason)
        }
    }
}

/// What checks tokens for `JWT<Claims>` and `authenticate(jwt:)`: a `JWTKeys`
/// with its keys in hand, or a `JWKSVerifier` that fetches them.
public protocol JWTVerifying: AnyObject, Sendable {
    func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims
    /// The claims of `token`, checked without awaiting, or nil when this
    /// verifier would first have to wait for something -- keys still to be
    /// fetched, say. Throws what `verify` would. The default always waits.
    func verifyNow<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims?
}

extension JWTVerifying {
    public func verifyNow<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims? {
        nil
    }
}

extension JWTKeys: JWTVerifying {
    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims {
        try check(token, as: type)
    }

    public func verifyNow<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims? {
        try check(token, as: type)
    }
}

extension Application {
    /// Registers what `JWT<Claims>` and `authenticate(jwt:)` check tokens
    /// with, built in each shard as its state:
    ///
    ///     app.jwtVerifier { _ in keys }
    public func jwtVerifier(_ make: @escaping @Sendable (_ start: ShardContext) async throws -> any JWTVerifying) {
        state(make)
    }
}

/// `authenticate(jwt:)`: a bearer JWT checked, and kept in the context.
struct JWTAuthentication<Claims: Decodable>: Middleware {
    /// Nil: the one `app.jwtVerifier` registered, found in the shard.
    let verifier: (any JWTVerifying)?

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard let token = bearerToken(request) else { return challenge(response, "Bearer") }
        let verifier = try self.verifier ?? request.state((any JWTVerifying).self)
        let claims: Claims
        do {
            if let now = try verifier.verifyNow(token, as: Claims.self) {
                claims = now
            } else {
                claims = try await verifier.verify(token, as: Claims.self)
            }
        } catch let error as JWTError where error.status == .unauthorized {
            return challenge(response, invalidTokenChallenge)
        }
        request[context: JWTContextKey<Claims>.self] = JWT(claims: claims, token: token)
        try await next()
    }
}

extension RouteBuilder {
    /// Requires a valid bearer JWT of every request in the current scope,
    /// checked by the verifier `app.jwtVerifier` registered -- found in the
    /// shard rather than passed in, so a `Router` built on its own can guard
    /// its routes without being handed the keys -- and keeps it for handlers
    /// that take `JWT<Claims>`. A request without one is answered 401 with
    /// the challenge RFC 6750 describes.
    public func authenticate<Claims: Decodable>(jwt claims: Claims.Type) {
        use(JWTAuthentication<Claims>(verifier: nil))
    }

    /// `authenticate(jwt:)` with the verifier given here.
    public func authenticate<Claims: Decodable>(jwt claims: Claims.Type, verifier: any JWTVerifying) {
        use(JWTAuthentication<Claims>(verifier: verifier))
    }
}

extension JWT: Sendable where Claims: Sendable {}
