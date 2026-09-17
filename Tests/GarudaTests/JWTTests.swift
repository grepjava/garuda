import Testing
import CAvian
#if canImport(Glibc)
import Glibc
#endif
@testable import Garuda
import AvianHTTP

// JSON Web Tokens: every algorithm both ways, tokens another implementation
// made, the attacks a verifier must refuse, the registered claims, and the
// extractor and middleware in routes.

private struct PyClaims: Codable, Equatable {
    let sub: String
    let role: String
    let exp: Int
}

private struct UserClaims: Codable, Sendable {
    let sub: String
    let exp: Int
    var role: String = "user"
    var iss: String? = nil
    var aud: String? = nil
    var nbf: Int? = nil
}

private let now: Int64 = 1_900_000_000

private func keys(_ list: [JWTKey], _ validation: JWTValidation = JWTValidation()) throws -> JWTKeys {
    let keys = try JWTKeys(list, validation: validation)
    keys.clock = { now }
    return keys
}

private func jwk(_ parts: JWKParts) -> JWK {
    var jwk = JWK(kty: parts.kty)
    jwk.crv = parts.crv
    jwk.n = parts.n
    jwk.e = parts.e
    jwk.x = parts.x
    jwk.y = parts.y
    return jwk
}

/// `token` with the character at `index` of part `part` changed.
private func tampered(_ token: String, part: Int) -> String {
    var parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    var chars = Array(parts[part])
    let i = chars.count / 2
    chars[i] = chars[i] == "A" ? "B" : "A"
    parts[part] = String(chars)
    return parts.joined(separator: ".")
}

@Suite("JWT")
struct JWTTests {
    @Test(arguments: JWTAlgorithm.allCases)
    func everyAlgorithmSignsAndVerifies(algorithm: JWTAlgorithm) throws {
        let key = try JWTKey.generate(algorithm, keyID: "k1")
        let set = try keys([key])
        let token = try set.sign(UserClaims(sub: "ada", exp: Int(now) + 60))
        #expect(token.split(separator: ".").count == 3)
        #expect(try set.verify(token, as: UserClaims.self).sub == "ada")
        #expect(throws: JWTError.badSignature) { try set.verify(tampered(token, part: 2), as: UserClaims.self) }
        #expect(throws: JWTError.self) { try set.verify(tampered(token, part: 1), as: UserClaims.self) }

        // Verifying needs only the public key, which cannot sign.
        if !algorithm.isHMAC {
            let publicOnly = try keys([try JWTKey.pem(key.publicPEM!, algorithm: algorithm, keyID: "k1")])
            #expect(try publicOnly.verify(token, as: UserClaims.self).sub == "ada")
            #expect(throws: JWTError.cannotSign) { try publicOnly.sign(UserClaims(sub: "x", exp: 1)) }
            let fromJWK = try keys([try JWTKey.jwk(key.publicJWK!)])
            #expect(try fromJWK.verify(token, as: UserClaims.self).sub == "ada")
            let reloaded = try JWTKey.pem(key.privatePEM!, algorithm: algorithm, keyID: "k1")
            #expect(reloaded.canSign)
            #expect(try set.verify(try keys([reloaded]).sign(UserClaims(sub: "b", exp: Int(now) + 5)),
                                   as: UserClaims.self).sub == "b")
        }
    }

    /// GARUDA_JWT_OUT=path writes a token of every algorithm and its public
    /// key, as JSON, for another implementation to verify.
    @Test func tokensForAnotherImplementation() throws {
        guard let out = av_getenv("GARUDA_JWT_OUT") else { return }
        var entries: [[String: String]] = []
        for algorithm in JWTAlgorithm.allCases {
            let key = algorithm.isHMAC
                ? try JWTKey.hmac([UInt8](repeating: 0x6B, count: 64), algorithm: algorithm)
                : try JWTKey.generate(algorithm)
            let token = try JWTKeys([key]).sign(UserClaims(sub: "garuda", exp: 4_102_444_800, role: "admin"))
            entries.append(["alg": algorithm.rawValue, "token": token, "key": key.publicPEM ?? ""])
        }
        let json = try JSONCoder.encode(entries)
        let file = fopen(out, "w")!
        _ = json.withUnsafeBufferPointer { fwrite($0.baseAddress, 1, $0.count, file) }
        fclose(file)
    }

    @Test func tokensPyJWTSignedVerify() throws {
        let validation = JWTValidation(issuer: "pyjwt", audience: "shop")
        let expected = PyClaims(sub: "42", role: "admin", exp: 4_102_444_800)
        let rsa = PyJWTVectors.rsaPublic
        let cases: [(String, JWTKey)] = [
            (PyJWTVectors.RS256, try .pem(rsa, algorithm: .RS256)),
            (PyJWTVectors.RS384, try .pem(rsa, algorithm: .RS384)),
            (PyJWTVectors.RS512, try .pem(rsa, algorithm: .RS512)),
            (PyJWTVectors.PS256, try .pem(rsa, algorithm: .PS256)),
            (PyJWTVectors.PS384, try .pem(rsa, algorithm: .PS384)),
            (PyJWTVectors.PS512, try .pem(rsa, algorithm: .PS512)),
            (PyJWTVectors.ES256, try .pem(PyJWTVectors.ec256Public, algorithm: .ES256)),
            (PyJWTVectors.ES384, try .pem(PyJWTVectors.ec384Public, algorithm: .ES384)),
            (PyJWTVectors.ES512, try .pem(PyJWTVectors.ec521Public, algorithm: .ES512)),
            (PyJWTVectors.EdDSA, try .pem(PyJWTVectors.edPublic, algorithm: .EdDSA)),
            (PyJWTVectors.HS256, try .hmac([UInt8](repeating: 0x6B, count: 64), algorithm: .HS256, keyID: "shared")),
            (PyJWTVectors.HS384, try .hmac([UInt8](repeating: 0x6B, count: 64), algorithm: .HS384, keyID: "shared")),
            (PyJWTVectors.HS512, try .hmac([UInt8](repeating: 0x6B, count: 64), algorithm: .HS512, keyID: "shared")),
            (PyJWTVectors.RS256, try .jwk(jwk(PyJWTVectors.rsaJWK), algorithm: .RS256)),
            (PyJWTVectors.ES256, try .jwk(jwk(PyJWTVectors.ec256JWK))),
            (PyJWTVectors.EdDSA, try .jwk(jwk(PyJWTVectors.edJWK))),
        ]
        for (token, key) in cases {
            #expect(try keys([key], validation).verify(token, as: PyClaims.self) == expected, "\(key.algorithm)")
        }
    }

    @Test func theAttacksAVerifierMustRefuse() throws {
        let rsa = try JWTKey.pem(PyJWTVectors.rsaPublic, algorithm: .RS256)
        let set = try keys([rsa])
        func token(_ header: String, _ payload: String, _ signature: [UInt8]) -> String {
            base64URLEncode(Array(header.utf8)) + "." + base64URLEncode(Array(payload.utf8)) + "."
                + base64URLEncode(signature)
        }
        let payload = #"{"sub":"root","exp":4102444800}"#

        // alg none, with or without a signature.
        let none = base64URLEncode(Array(#"{"alg":"none"}"#.utf8)) + "." + base64URLEncode(Array(payload.utf8)) + "."
        #expect(throws: JWTError.self) { try set.verify(none, as: UserClaims.self) }
        #expect(throws: JWTError.unsupported("none")) { try set.verify(token(#"{"alg":"none"}"#, payload, [1]), as: UserClaims.self) }

        // HS256 with the RSA public key's PEM as the secret.
        let input = base64URLEncode(Array(#"{"alg":"HS256","typ":"JWT"}"#.utf8)) + "." + base64URLEncode(Array(payload.utf8))
        let forged = try JWTKey.hmac(Array(PyJWTVectors.rsaPublic.utf8), algorithm: .HS256)
        let confused = input + "." + base64URLEncode(try forged.sign(Array(input.utf8)))
        #expect(throws: JWTError.unknownKey) { try set.verify(confused, as: UserClaims.self) }
        // The same, naming the RSA key by its kid.
        let named = try keys([try JWTKey.pem(PyJWTVectors.rsaPublic, algorithm: .RS256, keyID: "rsa")])
        let namedInput = base64URLEncode(Array(#"{"alg":"HS256","kid":"rsa"}"#.utf8)) + "." + base64URLEncode(Array(payload.utf8))
        let namedForgery = namedInput + "." + base64URLEncode(try forged.sign(Array(namedInput.utf8)))
        #expect(throws: JWTError.unknownKey) { try named.verify(namedForgery, as: UserClaims.self) }

        // An HMAC signature cut short, or empty.
        let hmacSet = try keys([try JWTKey.hmac([UInt8](repeating: 3, count: 32))])
        let real = try hmacSet.sign(UserClaims(sub: "a", exp: Int(now) + 60))
        let realParts = real.split(separator: ".").map(String.init)
        let cut = realParts[0] + "." + realParts[1] + "." + base64URLEncode(Array(base64Decode(realParts[2])!.prefix(16)))
        #expect(throws: JWTError.badSignature) { try hmacSet.verify(cut, as: UserClaims.self) }
        #expect(throws: JWTError.self) { try hmacSet.verify(realParts[0] + "." + realParts[1] + ".", as: UserClaims.self) }

        // A token signed by another key, a crit header, junk and a huge token.
        let other = try JWTKey.generate(.RS256)
        #expect(throws: JWTError.badSignature) {
            try set.verify(try keys([other]).sign(UserClaims(sub: "x", exp: Int(now) + 60)), as: UserClaims.self)
        }
        #expect(throws: JWTError.unsupported("crit")) {
            try set.verify(token(#"{"alg":"RS256","crit":["b64"]}"#, payload, [1]), as: UserClaims.self)
        }
        for junk in ["", "a.b", "a.b.c.d", "!!.@@.##", "e30.e30.", String(repeating: "a", count: 20_000)] {
            #expect(throws: JWTError.self) { try set.verify(junk, as: UserClaims.self) }
        }

        // Keys that should not be trusted at all.
        #expect(throws: JWTError.self) { try JWTKey.pem(PyJWTVectors.smallRSAPublic, algorithm: .RS256) }
        #expect(throws: JWTError.self) { try JWTKey.pem(PyJWTVectors.rsaPublic, algorithm: .ES256) }
        #expect(throws: JWTError.self) { try JWTKey.hmac("too short", algorithm: .HS256) }
        #expect(throws: JWTError.self) { try JWTKey.hmac([UInt8](repeating: 1, count: 48), algorithm: .HS512) }
        #expect(throws: JWTError.self) { try JWTKey.pem("not a key", algorithm: .RS256) }
        #expect(throws: JWTError.self) { try JWTKeys([]) }
    }

    @Test func registeredClaimsAreChecked() throws {
        let secret = [UInt8](repeating: 7, count: 32)
        let set = try keys([try .hmac(secret)], JWTValidation(issuer: "shop", audience: "api", leewaySeconds: 30))
        func sign(_ claims: UserClaims) throws -> String { try set.sign(claims) }
        let good = UserClaims(sub: "a", exp: Int(now) + 10, iss: "shop", aud: "api")
        #expect(try set.verify(try sign(good), as: UserClaims.self).sub == "a")

        var expired = good
        expired.nbf = nil
        expired = UserClaims(sub: "a", exp: Int(now) - 31, iss: "shop", aud: "api")
        #expect(throws: JWTError.expired) { try set.verify(try sign(expired), as: UserClaims.self) }
        let withinLeeway = UserClaims(sub: "a", exp: Int(now) - 29, iss: "shop", aud: "api")
        #expect(try set.verify(try sign(withinLeeway), as: UserClaims.self).sub == "a")
        var early = good
        early.nbf = Int(now) + 31
        #expect(throws: JWTError.notYetValid) { try set.verify(try sign(early), as: UserClaims.self) }
        var wrongIssuer = good
        wrongIssuer.iss = "elsewhere"
        #expect(throws: JWTError.invalidClaim("iss")) { try set.verify(try sign(wrongIssuer), as: UserClaims.self) }
        var wrongAudience = good
        wrongAudience.aud = "admin"
        #expect(throws: JWTError.invalidClaim("aud")) { try set.verify(try sign(wrongAudience), as: UserClaims.self) }

        // No exp at all, and claims that do not fit the type.
        struct NoExpiry: Codable { let sub: String; let iss: String; let aud: [String] }
        let forever = try set.sign(NoExpiry(sub: "a", iss: "shop", aud: ["web", "api"]))
        #expect(throws: JWTError.invalidClaim("exp")) { try set.verify(forever, as: NoExpiry.self) }
        let lenient = try keys([try .hmac(secret)], JWTValidation(issuer: "shop", audience: "api", requireExpiration: false))
        #expect(try lenient.verify(forever, as: NoExpiry.self).aud == ["web", "api"])
        struct Needs: Decodable { let tenant: String }
        #expect(throws: JWTError.invalidClaim("claims")) { try set.verify(try sign(good), as: Needs.self) }
    }

    @Test func keysAreChosenByKidAndAlgorithm() throws {
        let old = try JWTKey.generate(.ES256, keyID: "2025")
        let current = try JWTKey.generate(.EdDSA, keyID: "2026")
        let set = try keys([current, old])
        let claims = UserClaims(sub: "a", exp: Int(now) + 60)
        let signedOld = try keys([old]).sign(claims)
        #expect(try set.verify(signedOld, as: UserClaims.self).sub == "a")
        #expect(try set.verify(try set.sign(claims), as: UserClaims.self).sub == "a")
        #expect(try set.verify(try set.sign(claims, keyID: "2025"), as: UserClaims.self).sub == "a")
        #expect(set.publicJWKS.keys.map(\.kid) == ["2026", "2025"])
        #expect(set.publicJWKS.keys.map(\.kty) == ["OKP", "EC"])
        // Two keys, one without a kid, cannot be told apart.
        #expect(throws: JWTError.self) { try JWTKeys([old, try JWTKey.generate(.HS256)]) }
        #expect(throws: JWTError.self) { try JWTKeys([old, try JWTKey.generate(.ES256, keyID: "2025")]) }
        // An HMAC secret is never published.
        #expect(try keys([try JWTKey.generate(.HS256)]).publicJWKS.keys.isEmpty)
    }

    private func app(_ set: JWTKeys) -> Application {
        let app = Application()
        app.jwtVerifier { _ in set }
        app.get("/me") { (jwt: JWT<UserClaims>) async in "\(jwt.claims.sub) \(jwt.claims.role)" }
        app.group("/admin") {
            app.authenticate(jwt: UserClaims.self, verifier: set)
            app.use { request, _ in
                request.header("x-deny") != nil ? HTTPStatus.forbidden : nil
            }
            app.get("/stats") { (jwt: JWT<UserClaims>) async in "stats for \(jwt.claims.sub)" }
        }
        return app
    }

    @Test func theExtractorAndTheMiddleware() throws {
        let set = try keys([try JWTKey.generate(.ES256, keyID: "k")])
        let client = app(set).test
        let token = try set.sign(UserClaims(sub: "ada", exp: Int(now) + 60, role: "admin"))
        let bearer = [("authorization", "Bearer \(token)")]

        #expect(try client.get("/me", headers: bearer).text == "ada admin")
        let missing = try client.get("/me")
        #expect(missing.status == 401)
        #expect(missing.header("www-authenticate") == "Bearer")
        let invalid = try client.get("/me", headers: [("authorization", "Bearer \(tampered(token, part: 2))")])
        #expect(invalid.status == 401)
        #expect(invalid.header("www-authenticate") == #"Bearer error="invalid_token""#)
        #expect(invalid.text == #"{"error":"invalid token"}"#)
        let expired = try set.sign(UserClaims(sub: "ada", exp: Int(now) - 3600))
        #expect(try client.get("/me", headers: [("authorization", "Bearer \(expired)")]).status == 401)

        #expect(try client.get("/admin/stats", headers: bearer).text == "stats for ada")
        let refused = try client.get("/admin/stats", headers: [("authorization", "Bearer nonsense")])
        #expect(refused.status == 401)
        #expect(refused.header("www-authenticate") == #"Bearer error="invalid_token""#)
        #expect(try client.get("/admin/stats").header("www-authenticate") == "Bearer")
        #expect(try client.get("/admin/stats", headers: bearer + [("x-deny", "1")]).status == 403)
    }
}
