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
//     let token = try keys.sign(UserClaims(sub: "42", exp: Timestamp.now.secondsSinceEpoch + 900, role: "admin"))
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
// public half; signing needs the private one.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization
import AvianCore
import AvianHTTP
import CGarudaJWT

/// The signature algorithms of RFC 7518 and RFC 8037, by their JWS names.
public enum JWTAlgorithm: String, Sendable, CaseIterable, Codable {
    case HS256, HS384, HS512
    case RS256, RS384, RS512
    case PS256, PS384, PS512
    case ES256, ES384, ES512
    case EdDSA

    var code: Int32 {
        switch self {
        case .HS256: GJW_HS256
        case .HS384: GJW_HS384
        case .HS512: GJW_HS512
        case .RS256: GJW_RS256
        case .RS384: GJW_RS384
        case .RS512: GJW_RS512
        case .PS256: GJW_PS256
        case .PS384: GJW_PS384
        case .PS512: GJW_PS512
        case .ES256: GJW_ES256
        case .ES384: GJW_ES384
        case .ES512: GJW_ES512
        case .EdDSA: GJW_EDDSA
        }
    }

    /// Whether this is HS256, HS384 or HS512, signed with a shared secret.
    public var isHMAC: Bool { self == .HS256 || self == .HS384 || self == .HS512 }

    /// The key type a key for this algorithm must be.
    var keyType: Int32 {
        switch self {
        case .HS256, .HS384, .HS512: 0
        case .RS256, .RS384, .RS512, .PS256, .PS384, .PS512: GJW_KEY_RSA
        case .ES256: GJW_KEY_EC_P256
        case .ES384: GJW_KEY_EC_P384
        case .ES512: GJW_KEY_EC_P521
        case .EdDSA: GJW_KEY_ED25519
        }
    }

    var hashLength: Int {
        switch self {
        case .HS256: 32
        case .HS384: 48
        case .HS512: 64
        default: 0
        }
    }
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

// MARK: - Keys

/// A key for one algorithm: an HMAC secret, or a public or private key.
public final class JWTKey: @unchecked Sendable {
    public let algorithm: JWTAlgorithm
    /// The `kid` a token names this key by, if any.
    public let keyID: String?
    let secret: [UInt8]
    let handle: OpaquePointer?
    /// An HMAC secret keyed once, for every token it checks.
    private let mac: OpaquePointer?
    /// Whether this key can sign: an HMAC secret or a private key.
    public let canSign: Bool

    private init(algorithm: JWTAlgorithm, keyID: String?, secret: [UInt8], handle: OpaquePointer?, canSign: Bool) {
        self.algorithm = algorithm
        self.keyID = keyID
        self.secret = secret
        self.handle = handle
        self.canSign = canSign
        mac = algorithm.isHMAC ? gjw_mac_new(algorithm.code, secret, secret.count) : nil
    }

    deinit {
        if let handle { gjw_key_free(handle) }
        if let mac { gjw_mac_free(mac) }
    }

    /// The MAC of `input` under this HMAC secret, or a negative length.
    private func hmac(_ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) -> Int {
        let data = input.baseAddress ?? UnsafePointer(bitPattern: 1)!
        if let mac { return Int(gjw_mac_compute(mac, data, input.count, out.baseAddress, out.count)) }
        return Int(gjw_hmac(algorithm.code, secret, secret.count, data, input.count, out.baseAddress, out.count))
    }

    /// An HMAC secret, at least as many bytes as the algorithm's hash.
    public static func hmac(_ secret: [UInt8], algorithm: JWTAlgorithm = .HS256,
                            keyID: String? = nil) throws(JWTError) -> JWTKey {
        guard algorithm.isHMAC else { throw .invalidKey("\(algorithm) is not an HMAC algorithm") }
        guard secret.count >= algorithm.hashLength else {
            throw .invalidKey("an \(algorithm) secret is at least \(algorithm.hashLength) bytes")
        }
        return JWTKey(algorithm: algorithm, keyID: keyID, secret: secret, handle: nil, canSign: true)
    }

    public static func hmac(_ secret: String, algorithm: JWTAlgorithm = .HS256,
                            keyID: String? = nil) throws(JWTError) -> JWTKey {
        try hmac(Array(secret.utf8), algorithm: algorithm, keyID: keyID)
    }

    /// A key from PEM: a public key or certificate, which verifies, or a
    /// private key, which also signs.
    public static func pem(_ pem: String, algorithm: JWTAlgorithm, keyID: String? = nil) throws(JWTError) -> JWTKey {
        guard !algorithm.isHMAC else { throw .invalidKey("an HMAC key is a secret, not PEM") }
        var hasPrivate: Int32 = 0
        var text = pem
        let handle = text.withUTF8 { bytes in
            bytes.withMemoryRebound(to: CChar.self) { gjw_key_from_pem($0.baseAddress, $0.count, &hasPrivate) }
        }
        return try wrap(handle, algorithm: algorithm, keyID: keyID, canSign: hasPrivate != 0)
    }

    /// A new private key for `algorithm`.
    public static func generate(_ algorithm: JWTAlgorithm, keyID: String? = nil) throws(JWTError) -> JWTKey {
        if algorithm.isHMAC {
            return try hmac(randomBytes(algorithm.hashLength), algorithm: algorithm, keyID: keyID)
        }
        return try wrap(gjw_key_generate(algorithm.keyType, 2048), algorithm: algorithm, keyID: keyID, canSign: true)
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
            guard let member, let decoded = base64Decode(member), !decoded.isEmpty else {
                throw .invalidKey("the JWK has no valid \(name)")
            }
            return decoded
        }
        switch jwk.kty {
        case "RSA":
            let n = try bytes(jwk.n, "n")
            let e = try bytes(jwk.e, "e")
            guard let chosen = algorithm ?? named else { throw .invalidKey("an RSA JWK needs an algorithm") }
            return try wrap(gjw_key_from_rsa(n, n.count, e, e.count), algorithm: chosen, keyID: jwk.kid, canSign: false)
        case "EC":
            let (type, curveAlgorithm): (Int32, JWTAlgorithm) = switch jwk.crv {
            case "P-256": (GJW_KEY_EC_P256, .ES256)
            case "P-384": (GJW_KEY_EC_P384, .ES384)
            case "P-521": (GJW_KEY_EC_P521, .ES512)
            default: throw .invalidKey("an EC JWK's crv is P-256, P-384 or P-521")
            }
            let x = try bytes(jwk.x, "x")
            let y = try bytes(jwk.y, "y")
            return try wrap(gjw_key_from_ec(type, x, x.count, y, y.count), algorithm: algorithm ?? named ?? curveAlgorithm,
                            keyID: jwk.kid, canSign: false)
        case "OKP":
            guard jwk.crv == "Ed25519" else { throw .invalidKey("an OKP JWK's crv is Ed25519") }
            let x = try bytes(jwk.x, "x")
            return try wrap(gjw_key_from_ed25519(x, x.count), algorithm: algorithm ?? .EdDSA, keyID: jwk.kid, canSign: false)
        case "oct":
            let k = try bytes(jwk.k, "k")
            guard let chosen = algorithm ?? named else { throw .invalidKey("an oct JWK needs an algorithm") }
            return try hmac(k, algorithm: chosen, keyID: jwk.kid)
        default:
            throw .invalidKey("a JWK's kty is RSA, EC, OKP or oct")
        }
    }

    private static func wrap(_ handle: OpaquePointer?, algorithm: JWTAlgorithm, keyID: String?,
                             canSign: Bool) throws(JWTError) -> JWTKey {
        guard let handle else { throw .invalidKey("not a key libcrypto accepts, or an RSA key under 2048 bits") }
        guard gjw_key_type(handle) == algorithm.keyType else {
            gjw_key_free(handle)
            throw .invalidKey("the key is not a key for \(algorithm)")
        }
        return JWTKey(algorithm: algorithm, keyID: keyID, secret: [], handle: handle, canSign: canSign)
    }

    /// The public key as PEM, or nil for an HMAC secret.
    public var publicPEM: String? { pem(privateKey: false) }

    /// The private key as PKCS #8 PEM, or nil when there is none.
    public var privatePEM: String? { canSign ? pem(privateKey: true) : nil }

    private func pem(privateKey: Bool) -> String? {
        guard let handle else { return nil }
        let length = gjw_key_pem(handle, privateKey ? 1 : 0, nil, 0)
        guard length > 0 else { return nil }
        var out = [CChar](repeating: 0, count: length)
        guard gjw_key_pem(handle, privateKey ? 1 : 0, &out, out.count) == length else { return nil }
        return String(decoding: out.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The public key as a JWK, for a key set others verify with. Nil for an
    /// HMAC secret, which is never published.
    public var publicJWK: JWK? {
        guard let handle else { return nil }
        var jwk = JWK(kty: "", kid: keyID, alg: algorithm.rawValue, use: "sig")
        switch gjw_key_type(handle) {
        case GJW_KEY_RSA:
            var n = [UInt8](repeating: 0, count: 1024)
            var e = [UInt8](repeating: 0, count: 16)
            var nLength = n.count
            var eLength = e.count
            guard gjw_key_rsa_numbers(handle, &n, &nLength, &e, &eLength) == 0 else { return nil }
            jwk.kty = "RSA"
            jwk.n = base64URLEncode(Array(n.prefix(nLength)))
            jwk.e = base64URLEncode(Array(e.prefix(eLength)))
        case GJW_KEY_EC_P256, GJW_KEY_EC_P384, GJW_KEY_EC_P521:
            var x = [UInt8](repeating: 0, count: 66)
            var y = [UInt8](repeating: 0, count: 66)
            var xLength = x.count
            var yLength = y.count
            guard gjw_key_ec_point(handle, &x, &xLength, &y, &yLength) == 0 else { return nil }
            jwk.kty = "EC"
            jwk.crv = algorithm == .ES256 ? "P-256" : algorithm == .ES384 ? "P-384" : "P-521"
            jwk.x = base64URLEncode(Array(x.prefix(xLength)))
            jwk.y = base64URLEncode(Array(y.prefix(yLength)))
        case GJW_KEY_ED25519:
            var x = [UInt8](repeating: 0, count: 32)
            var length = x.count
            guard gjw_key_raw_public(handle, &x, &length) == 0 else { return nil }
            jwk.kty = "OKP"
            jwk.crv = "Ed25519"
            jwk.x = base64URLEncode(Array(x.prefix(length)))
        default:
            return nil
        }
        return jwk
    }

    func sign(_ input: [UInt8]) throws(JWTError) -> [UInt8] {
        guard canSign else { throw .cannotSign }
        var out = [UInt8](repeating: 0, count: 1024)
        let length: Int
        if algorithm.isHMAC {
            length = input.withUnsafeBufferPointer { data in
                out.withUnsafeMutableBufferPointer { hmac(data, into: $0) }
            }
        } else {
            length = gjw_sign(handle, algorithm.code, input, input.count, &out, out.count)
        }
        guard length > 0 else { throw .cannotSign }
        return Array(out.prefix(length))
    }

    func verify(_ input: [UInt8], signature: [UInt8]) -> Bool {
        input.withUnsafeBufferPointer { input in
            signature.withUnsafeBufferPointer { verify(input, signature: $0) }
        }
    }

    /// Whether `signature` is this key's over `input`, read where they lie.
    func verify(_ input: UnsafeBufferPointer<UInt8>, signature: UnsafeBufferPointer<UInt8>) -> Bool {
        if algorithm.isHMAC {
            return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { mac in
                let length = hmac(input, into: mac)
                guard length > 0, signature.count == length else { return false }
                var difference: UInt8 = 0
                for i in 0..<length { difference |= mac[i] ^ signature[i] }
                return difference == 0
            }
        }
        let data = input.baseAddress ?? UnsafePointer(bitPattern: 1)!
        let signed = signature.baseAddress ?? UnsafePointer(bitPattern: 1)!
        return gjw_verify(handle, algorithm.code, data, input.count, signed, signature.count) == 1
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
    /// Seconds since the epoch; tests set their own.
    var clock: @Sendable () -> Int64 = { Timestamp.now.secondsSinceEpoch }
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
        let input = base64URLEncode(try JSONCoder.encode(header)) + "." + base64URLEncode(try JSONCoder.encode(claims))
        let signature = try key.sign(Array(input.utf8))
        return input + "." + base64URLEncode(signature)
    }

    /// The claims of `token` when it is signed by one of these keys and its
    /// claims pass the validation; throws `JWTError` otherwise.
    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type = Claims.self) throws -> Claims {
        try check(token, as: type)
    }

    /// Everything read where it lies in the token's bytes: the header and
    /// its key from the cache when seen before, the signature checked over
    /// the first two parts in place, and the claims decoded from a scratch
    /// buffer on the stack. Nothing is allocated but the claims themselves.
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
                headers.keep(header, key: key, for: headerPart)
            }
            guard let key else { throw JWTError.unknownKey }
            let payloadPart = UnsafeBufferPointer(rebasing: all[(first + 1)..<second])
            let signaturePart = UnsafeBufferPointer(rebasing: all[(second + 1)...])
            let verified = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: signaturePart.count) { signature in
                guard let length = base64URLDecode(signaturePart, into: signature) else { return false }
                return key.verify(UnsafeBufferPointer(rebasing: all[0..<second]),
                                  signature: UnsafeBufferPointer(rebasing: signature[0..<length]))
            }
            guard verified else { throw JWTError.badSignature }
            return try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: payloadPart.count) { scratch in
                guard let length = base64URLDecode(payloadPart, into: scratch) else { throw JWTError.malformed }
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
                guard let payload = base64URLDecode(UnsafeBufferPointer(rebasing: all[(first + 1)..<second])),
                      let signature = base64URLDecode(UnsafeBufferPointer(rebasing: all[(second + 1)...])) else {
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
        guard let bytes = base64URLDecode(part),
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
final class JWTHeaderCache: Sendable {
    struct Entry: Sendable {
        let bytes: [UInt8]
        let header: JWTHeader
        let key: JWTKey?
    }

    private let entries = Mutex<[Entry]>([])
    static let capacity = 8

    func entry(for bytes: UnsafeBufferPointer<UInt8>) -> Entry? {
        entries.withLock { entries in
            for entry in entries where entry.bytes.count == bytes.count {
                let same = entry.bytes.withUnsafeBufferPointer {
                    memcmp($0.baseAddress!, bytes.baseAddress!, bytes.count) == 0
                }
                if same { return entry }
            }
            return nil
        }
    }

    func keep(_ header: JWTHeader, key: JWTKey?, for bytes: UnsafeBufferPointer<UInt8>) {
        entries.withLock { entries in
            // Full, the cache stays as it is: headers that vary without end
            // are decoded each time rather than churning it.
            guard entries.count < JWTHeaderCache.capacity else { return }
            entries.append(Entry(bytes: Array(bytes), header: header, key: key))
        }
    }
}

/// base64url as JWS writes it -- no padding, though padding is let through --
/// decoded from bytes. The standard alphabet's + and / are taken too.
func base64URLDecode(_ input: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
    var failed = false
    let out = [UInt8](unsafeUninitializedCapacity: input.count) { buffer, written in
        if let length = base64URLDecode(input, into: buffer) {
            written = length
        } else {
            failed = true
        }
    }
    return failed ? nil : out
}

/// The same, into `out`, which has room for at least `input.count` bytes.
/// Returns how many were written, or nil.
func base64URLDecode(_ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) -> Int? {
    var count = input.count
    while count > 0 && input[count - 1] == UInt8(ascii: "=") { count -= 1 }
    if count % 4 == 1 { return nil }
    var written = 0
    var accumulated: UInt32 = 0
    var bits = 0
    for i in 0..<count {
        let byte = input[i]
        let value: UInt8
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte &- UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte &- UInt8(ascii: "a") &+ 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte &- UInt8(ascii: "0") &+ 52
        case UInt8(ascii: "-"), UInt8(ascii: "+"): value = 62
        case UInt8(ascii: "_"), UInt8(ascii: "/"): value = 63
        default: return nil
        }
        accumulated = (accumulated << 6) | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            out[written] = UInt8(truncatingIfNeeded: accumulated >> UInt32(bits))
            written += 1
        }
    }
    return written
}

// MARK: - In routes

enum JWTContextKey<Claims: Decodable>: RequestContextKey {
    typealias Value = JWT<Claims>
}

/// A verified token and its claims, from `Authorization: Bearer`, checked by
/// the verifier `app.jwtVerifier` registered.
/// A request without a valid token is answered 401.
///
/// A synchronous route may take one: with `JWTKeys`, or a `JWKSVerifier`
/// whose keys are in hand, a token is checked without awaiting anything. A
/// synchronous route that finds a `JWKSVerifier` still to fetch its keys
/// answers 503 and starts the fetch; an async route waits for it instead.
public struct JWT<Claims: Decodable>: AsyncRequestExtractor {
    public let claims: Claims
    /// The token as it came.
    public let token: String

    public init(claims: Claims, token: String) {
        self.claims = claims
        self.token = token
    }

    public static var extractsSynchronously: Bool { true }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> JWT {
        if let verified = request[context: JWTContextKey<Claims>.self] { return verified }
        let token = try bearer(request)
        let verifier = try request.state((any JWTVerifying).self)
        do {
            if let claims = try verifier.verifyNow(token, as: Claims.self) {
                return JWT(claims: claims, token: token)
            }
        } catch let error as JWTError where error.status == .unauthorized {
            request.worker.pointee.addHeader(request.slot, "www-authenticate", #"Bearer error="invalid_token""#)
            throw error
        }
        // The verifier has to wait for something first -- its keys -- which
        // a synchronous route cannot. It is started now, for the requests
        // after this one.
        let worker = request.worker
        let pool = worker.pointee.handlerTasks ?? worker.pointee.makeHandlerTasks()
        Task(executorPreference: pool.executor) {
            _ = try? await verifier.verify(token, as: AnyClaims.self)
        }
        throw JWTError.keySetUnavailable
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> JWT {
        if let verified = request[context: JWTContextKey<Claims>.self] { return verified }
        let worker = request.worker
        let slot = request.slot
        let connection = request.connection
        let generation = connection.pointee.generation
        let requestId = connection.pointee.requestId
        let token = try bearer(request)
        let verifier = try request.state((any JWTVerifying).self)
        do {
            if let claims = try verifier.verifyNow(token, as: Claims.self) {
                return JWT(claims: claims, token: token)
            }
            return JWT(claims: try await verifier.verify(token, as: Claims.self), token: token)
        } catch let error as JWTError where error.status == .unauthorized {
            if worker.pointee.stillHolds(slot, generation: generation, requestId: requestId) {
                worker.pointee.addHeader(slot, "www-authenticate", #"Bearer error="invalid_token""#)
            }
            throw error
        }
    }

    /// The token of `Authorization: Bearer`, or a 401 with the challenge.
    private static func bearer(_ request: borrowing Request) throws -> String {
        guard let header = request.header("authorization"), let token = parseBearer(header) else {
            request.worker.pointee.addHeader(request.slot, "www-authenticate", "Bearer")
            throw HTTPError.unauthorized
        }
        return token
    }
}

/// Claims read for nothing: what a fetch started for a synchronous route
/// checks its token as.
private struct AnyClaims: Decodable {
    init(from decoder: any Decoder) throws {}
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
    /// Registers what `JWT<Claims>` checks tokens with, built in each worker:
    ///
    ///     app.jwtVerifier { _ in keys }
    public func jwtVerifier(_ make: @escaping (_ worker: Int) throws -> any JWTVerifying) {
        state(make)
    }
}

extension RouteBuilder {
    /// Requires a valid bearer JWT of every request in the current scope,
    /// checked by `verifier`, and keeps it for handlers that take
    /// `JWT<Claims>`. A request without one is answered 401 with the
    /// challenge RFC 6750 describes.
    /// `authenticate(jwt:verifier:)` with the verifier `app.jwtVerifier`
    /// registered, found in the worker rather than passed in -- so a `Router`
    /// built on its own can guard its routes without being handed the keys.
    public func authenticate<Claims: Decodable>(jwt claims: Claims.Type) {
        describeBearerScope(format: "JWT")
        use { request, response async throws -> (any ResponseConvertible)? in
            guard let header = request.header("authorization"), let token = parseBearer(header) else {
                return Challenge("Bearer")
            }
            let verifier = try request.state((any JWTVerifying).self)
            do {
                let verified: Claims
                if let now = try verifier.verifyNow(token, as: Claims.self) {
                    verified = now
                } else {
                    verified = try await verifier.verify(token, as: Claims.self)
                }
                guard response.isActive else { throw HandlerWaitError.cancelled }
                request[context: JWTContextKey<Claims>.self] = JWT(claims: verified, token: token)
                return nil
            } catch let error as JWTError where error.status == .unauthorized {
                return Challenge(#"Bearer error="invalid_token""#)
            }
        }
    }

    public func authenticate<Claims: Decodable>(jwt claims: Claims.Type, verifier: any JWTVerifying) {
        describeBearerScope(format: "JWT")
        use { request, response async throws -> (any ResponseConvertible)? in
            guard let header = request.header("authorization"), let token = parseBearer(header) else {
                return Challenge("Bearer")
            }
            do {
                let verified: Claims
                if let now = try verifier.verifyNow(token, as: Claims.self) {
                    verified = now
                } else {
                    verified = try await verifier.verify(token, as: Claims.self)
                }
                guard response.isActive else { throw HandlerWaitError.cancelled }
                request[context: JWTContextKey<Claims>.self] = JWT(claims: verified, token: token)
                return nil
            } catch let error as JWTError where error.status == .unauthorized {
                return Challenge(#"Bearer error="invalid_token""#)
            }
        }
    }
}
