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
//     app.get("/me") { (jwt: JWT<UserClaims>) async in "user \(jwt.claims.sub)" }
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
    /// Whether this key can sign: an HMAC secret or a private key.
    public let canSign: Bool

    private init(algorithm: JWTAlgorithm, keyID: String?, secret: [UInt8], handle: OpaquePointer?, canSign: Bool) {
        self.algorithm = algorithm
        self.keyID = keyID
        self.secret = secret
        self.handle = handle
        self.canSign = canSign
    }

    deinit {
        if let handle { gjw_key_free(handle) }
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
            length = Int(gjw_hmac(algorithm.code, secret, secret.count, input, input.count, &out, out.count))
        } else {
            length = gjw_sign(handle, algorithm.code, input, input.count, &out, out.count)
        }
        guard length > 0 else { throw .cannotSign }
        return Array(out.prefix(length))
    }

    func verify(_ input: [UInt8], signature: [UInt8]) -> Bool {
        if algorithm.isHMAC {
            var mac = [UInt8](repeating: 0, count: 64)
            let length = Int(gjw_hmac(algorithm.code, secret, secret.count, input, input.count, &mac, mac.count))
            guard length > 0, signature.count == length else { return false }
            var difference: UInt8 = 0
            for i in 0..<length { difference |= mac[i] ^ signature[i] }
            return difference == 0
        }
        return gjw_verify(handle, algorithm.code, input, input.count, signature, signature.count) == 1
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

struct JWTHeader: Codable {
    var alg: String
    var typ: String?
    var kid: String?
    var crit: [String]?
}

/// The registered claims, read from any token to check them.
struct RegisteredClaims: Decodable {
    var exp: Double?
    var nbf: Double?
    var iss: String?
    var aud: Audience?

    struct Audience: Decodable {
        var values: [String]

        init(from decoder: any Decoder) throws {
            if let single = try? String(from: decoder) {
                values = [single]
            } else {
                values = try [String](from: decoder)
            }
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

    func check<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims {
        let parsed = try ParsedToken(token)
        guard let key = key(for: parsed.header) else { throw JWTError.unknownKey }
        return try parsed.claims(type, key: key, validation: validation, now: clock())
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
    let header: JWTHeader
    let signingInput: [UInt8]
    let payload: [UInt8]
    let signature: [UInt8]

    init(_ token: String) throws(JWTError) {
        guard token.utf8.count <= 16 * 1024 else { throw .malformed }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty,
              let headerBytes = base64Decode(String(parts[0])),
              let payload = base64Decode(String(parts[1])),
              let signature = base64Decode(String(parts[2])) else { throw .malformed }
        guard let header = try? JSONCoder.decode(JWTHeader.self, from: headerBytes) else { throw .malformed }
        if header.crit != nil { throw .unsupported("crit") }
        guard JWTAlgorithm(rawValue: header.alg) != nil else { throw .unsupported(header.alg) }
        self.header = header
        signingInput = Array(parts[0].utf8) + [0x2E] + Array(parts[1].utf8)
        self.payload = payload
        self.signature = signature
    }

    func claims<Claims: Decodable>(_ type: Claims.Type, key: JWTKey, validation: JWTValidation,
                                   now: Int64) throws -> Claims {
        guard key.verify(signingInput, signature: signature) else { throw JWTError.badSignature }
        guard let registered = try? JSONCoder.decode(RegisteredClaims.self, from: payload) else {
            throw JWTError.malformed
        }
        let leeway = Double(validation.leewaySeconds)
        if let exp = registered.exp {
            guard Double(now) < exp + leeway else { throw JWTError.expired }
        } else if validation.requireExpiration {
            throw JWTError.invalidClaim("exp")
        }
        if let nbf = registered.nbf, Double(now) + leeway < nbf { throw JWTError.notYetValid }
        if let issuer = validation.issuer, registered.iss != issuer { throw JWTError.invalidClaim("iss") }
        if let audience = validation.audience, !(registered.aud?.values.contains(audience) ?? false) {
            throw JWTError.invalidClaim("aud")
        }
        do {
            return try JSONCoder.decode(Claims.self, from: payload)
        } catch {
            throw JWTError.invalidClaim("claims")
        }
    }
}

// MARK: - In routes

enum JWTContextKey<Claims: Decodable>: RequestContextKey {
    typealias Value = JWT<Claims>
}

/// A verified token and its claims, from `Authorization: Bearer`, checked by
/// the verifier `app.jwtVerifier` registered.
/// A request without a valid token is answered 401.
public struct JWT<Claims: Decodable>: AsyncRequestExtractor {
    public let claims: Claims
    /// The token as it came.
    public let token: String

    public init(claims: Claims, token: String) {
        self.claims = claims
        self.token = token
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) async throws -> JWT {
        if let verified = request[context: JWTContextKey<Claims>.self] { return verified }
        let worker = request.worker
        let slot = request.slot
        let connection = request.connection
        let generation = connection.pointee.generation
        let requestId = connection.pointee.requestId
        guard let header = request.header("authorization"), let token = parseBearer(header) else {
            worker.pointee.addHeader(slot, "www-authenticate", "Bearer")
            throw HTTPError.unauthorized
        }
        let verifier = try request.state((any JWTVerifying).self)
        do {
            return JWT(claims: try await verifier.verify(token, as: Claims.self), token: token)
        } catch let error as JWTError where error.status == .unauthorized {
            if worker.pointee.stillHolds(slot, generation: generation, requestId: requestId) {
                worker.pointee.addHeader(slot, "www-authenticate", #"Bearer error="invalid_token""#)
            }
            throw error
        }
    }
}

/// What checks tokens for `JWT<Claims>` and `authenticate(jwt:)`: a `JWTKeys`
/// with its keys in hand, or a `JWKSVerifier` that fetches them.
public protocol JWTVerifying: AnyObject, Sendable {
    func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims
}

extension JWTKeys: JWTVerifying {
    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims {
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
                let verified = try await verifier.verify(token, as: Claims.self)
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
                let verified = try await verifier.verify(token, as: Claims.self)
                guard response.isActive else { throw HandlerWaitError.cancelled }
                request[context: JWTContextKey<Claims>.self] = JWT(claims: verified, token: token)
                return nil
            } catch let error as JWTError where error.status == .unauthorized {
                return Challenge(#"Bearer error="invalid_token""#)
            }
        }
    }
}
