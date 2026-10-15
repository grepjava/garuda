@testable import Garuda
import GarudaTesting
import Synchronization
import Testing

// Verifying with keys fetched from a JWK Set: caching, rotation, a provider
// that is down, which keys are trusted, one fetch for requests that arrive
// together, and a route that waits for the keys.

private struct Claims: Codable, Sendable {
    let sub: String
    let exp: Int
}

private let farFuture = 4_102_444_800

/// A clock the tests move, safe to read from the verifier.
private final class TestClock: Sendable {
    private let now = Atomic<Int64>(1_000)
    var seconds: Int64 {
        get { now.load(ordering: .relaxed) }
        set { now.store(newValue, ordering: .relaxed) }
    }
}

/// What a fake provider serves, which a test may change.
private final class Served: @unchecked Sendable {
    private let body = Mutex<@Sendable () throws -> [UInt8]>({ [] })
    func set(_ make: @escaping @Sendable () throws -> [UInt8]) { body.withLock { $0 = make } }
    func bytes() throws -> [UInt8] { try body.withLock { $0 }() }
}

private func set(_ keys: [JWTKey]) throws -> [UInt8] {
    try JSONCoder.encode(JWKSet(keys: keys.compactMap(\.publicJWK)))
}

private func token(_ key: JWTKey, _ subject: String = "ada") throws -> String {
    try JWTKeys([key]).sign(Claims(sub: subject, exp: farFuture))
}

@Suite("JWKS verifier", .serialized)
struct JWKSTests {
    /// A verifier over what `served` serves, with its clock.
    private func verifier(_ served: Served) -> (JWKSVerifier, TestClock) {
        let clock = TestClock()
        let verifier = JWKSVerifier(url: "https://idp.example/jwks", maxAgeSeconds: 3600, minimumRefetchSeconds: 60,
                                    fetch: { _ in try served.bytes() })
        verifier.clock = { clock.seconds }
        return (verifier, clock)
    }

    private func verifier(_ body: @escaping @Sendable () throws -> [UInt8]) -> (JWKSVerifier, TestClock, Served) {
        let served = Served()
        served.set(body)
        let (verifier, clock) = verifier(served)
        return (verifier, clock, served)
    }

    @Test func keysAreFetchedOnceAndKeptUntilTheyAge() async throws {
        let first = try JWTKey.generate(.ES256, keyID: "a")
        let (verifier, clock, _) = verifier { try set([first]) }
        #expect(try await verifier.verify(try token(first), as: Claims.self).sub == "ada")
        #expect(try await verifier.verify(try token(first, "grace"), as: Claims.self).sub == "grace")
        #expect(verifier.fetches == 1)
        clock.seconds += 3599
        _ = try await verifier.verify(try token(first), as: Claims.self)
        #expect(verifier.fetches == 1)
        clock.seconds += 1
        _ = try await verifier.verify(try token(first), as: Claims.self)
        #expect(verifier.fetches == 2)
    }

    @Test func aNewKeyIDFetchesAgainButNotTooOften() async throws {
        let old = try JWTKey.generate(.RS256, keyID: "old")
        let rotated = try JWTKey.generate(.RS256, keyID: "new")
        let (verifier, clock, served) = verifier { try set([old]) }
        _ = try await verifier.verify(try token(old), as: Claims.self)
        served.set { try set([old, rotated]) }

        // Too soon after the last fetch: refused without asking.
        await #expect(throws: JWTError.unknownKey) { try await verifier.verify(try token(rotated), as: Claims.self) }
        #expect(verifier.fetches == 1)
        clock.seconds += 60
        #expect(try await verifier.verify(try token(rotated), as: Claims.self).sub == "ada")
        #expect(verifier.fetches == 2)

        // A made-up key ID asks at most once a minute.
        let stranger = try JWTKey.generate(.RS256, keyID: "made-up")
        for _ in 0..<5 {
            await #expect(throws: JWTError.unknownKey) { try await verifier.verify(try token(stranger), as: Claims.self) }
        }
        #expect(verifier.fetches == 2)
    }

    @Test func aProviderThatIsDown() async throws {
        let key = try JWTKey.generate(.EdDSA, keyID: "k")
        let down: @Sendable () throws -> [UInt8] = { throw JWTError.keySetUnavailable }
        let (verifier, clock, served) = verifier(down)
        await #expect(throws: JWTError.keySetUnavailable) { try await verifier.verify(try token(key), as: Claims.self) }
        await #expect(throws: JWTError.keySetUnavailable) { try await verifier.verify(try token(key), as: Claims.self) }
        #expect(verifier.fetches == 1)
        served.set { try set([key]) }
        clock.seconds += 60
        _ = try await verifier.verify(try token(key), as: Claims.self)
        #expect(verifier.fetches == 2)

        // Down again once the keys age: the ones in hand keep working.
        served.set(down)
        clock.seconds += 7200
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")
        #expect(verifier.fetches == 3)
    }

    @Test func anEmptySetWithdrawsKeysThatHaveAged() async throws {
        // A provider answering with no keys is not a provider that is down. It
        // is one saying there is nothing to trust, which is what pulling a
        // compromised key looks like -- and keys held past their age on the
        // strength of it would verify tokens for as long as the process lived,
        // making the withdrawal mean nothing.
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let full: @Sendable () throws -> [UInt8] = { try JSONCoder.encode(JWKSet(keys: [key.publicJWK!])) }
        let empty: @Sendable () throws -> [UInt8] = { try JSONCoder.encode(JWKSet(keys: [])) }
        let (verifier, clock, served) = verifier(full)
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")

        // Still inside their age, so they stand: this fetch is one any client
        // can prompt with a `kid` nobody has, and a provider blinking should
        // not cost the keys the operator said to trust for an hour.
        served.set(empty)
        clock.seconds += 60
        await #expect(throws: JWTError.unknownKey) {
            try await verifier.verify(try token(try JWTKey.generate(.ES256, keyID: "other")),
                                      as: Claims.self)
        }
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")

        // Past it, and the set has said there is nothing: refused.
        clock.seconds += 3600
        await #expect(throws: JWTError.keySetUnavailable) {
            try await verifier.verify(try token(key), as: Claims.self)
        }
        // And back once the provider publishes again.
        served.set(full)
        clock.seconds += 60
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")
    }

    @Test func anEmptySetFromTheFirstFetchIsRefused() async throws {
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let (verifier, _, _) = verifier { try JSONCoder.encode(JWKSet(keys: [])) }
        await #expect(throws: JWTError.keySetUnavailable) {
            try await verifier.verify(try token(key), as: Claims.self)
        }
    }

    @Test func onlyKeysWorthTrustingAreKept() async throws {
        let rsa = try JWTKey.generate(.RS256, keyID: "rsa")
        let ec = try JWTKey.generate(.ES384, keyID: "ec")
        var rsaWithoutAlg = rsa.publicJWK!
        rsaWithoutAlg.alg = nil
        var encryption = ec.publicJWK!
        encryption.use = "enc"
        var secret = JWK(kty: "oct", kid: "hs", alg: "HS256")
        secret.k = base64URLEncode([UInt8](repeating: 1, count: 32))
        let body = try JSONCoder.encode(JWKSet(keys: [rsaWithoutAlg, encryption, secret]))
        let (verifier, _, _) = verifier { body }

        #expect(try await verifier.verify(try token(rsa), as: Claims.self).sub == "ada")
        await #expect(throws: JWTError.unknownKey) { try await verifier.verify(try token(ec), as: Claims.self) }
        // An HS256 token is refused before any key is looked for.
        let hmac = try JWTKey.hmac([UInt8](repeating: 1, count: 32), algorithm: .HS256, keyID: "hs")
        await #expect(throws: JWTError.unsupported("HS256")) { try await verifier.verify(try token(hmac), as: Claims.self) }

        // Algorithms can be narrowed further.
        let both = try set([rsa, ec])
        let narrow = JWKSVerifier(url: "https://idp.example/jwks", algorithms: [.ES384], fetch: { _ in both })
        await #expect(throws: JWTError.unsupported("RS256")) { try await narrow.verify(try token(rsa), as: Claims.self) }
        #expect(try await narrow.verify(try token(ec), as: Claims.self).sub == "ada")
    }

    @Test func verifyNowAnswersOnlyWhatItCanWithoutFetching() async throws {
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let (verifier, clock, _) = verifier { try set([key]) }
        // Nothing fetched yet: that is verify's to do.
        #expect(try verifier.verifyNow(try token(key), as: Claims.self)?.sub == nil)
        #expect(verifier.fetches == 0)
        _ = try await verifier.verify(try token(key), as: Claims.self)
        #expect(try verifier.verifyNow(try token(key, "grace"), as: Claims.self)?.sub == "grace")
        #expect(verifier.fetches == 1)
        // Refused as verify would refuse it: signed by another key with the same kid.
        let impostor = try JWTKey.generate(.ES256, keyID: "k")
        #expect(throws: JWTError.badSignature) { try verifier.verifyNow(try token(impostor), as: Claims.self) }
        // A key ID the set does not have: refused while asking again is not
        // yet due, left to verify once it is.
        let stranger = try JWTKey.generate(.ES256, keyID: "made-up")
        #expect(throws: JWTError.unknownKey) { try verifier.verifyNow(try token(stranger), as: Claims.self) }
        clock.seconds += 60
        #expect(try verifier.verifyNow(try token(stranger), as: Claims.self)?.sub == nil)
        // Aged: verify would fetch.
        clock.seconds += 3600
        #expect(try verifier.verifyNow(try token(key), as: Claims.self)?.sub == nil)
        #expect(verifier.fetches == 1)
    }

    @Test func aRouteWaitsForTheFirstFetch() throws {
        // Garuda 1 answered a synchronous route 503 until the keys were in;
        // every route can await now, so the first request waits for them.
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let body = try set([key])
        let fetched = Counter()
        let app = Application()
        app.jwtVerifier { _ in
            JWKSVerifier(url: "https://idp.example/jwks", fetch: { _ in
                fetched.increment()
                await Task.yield()
                return body
            })
        }
        app.get("/me") { (jwt: JWT<Claims>) in jwt.claims.sub }
        app.group("/guarded") {
            app.authenticate(jwt: Claims.self)
            app.get("/me") { (jwt: JWT<Claims>) in "guarded \(jwt.claims.sub)" }
        }
        let client = app.test
        let bearer = [("authorization", "Bearer \(try token(key))")]
        #expect(try client.get("/me", headers: bearer).text == "ada")
        #expect(try client.get("/guarded/me", headers: bearer).text == "guarded ada")
        #expect(fetched.value == 1)
        // A provider that cannot be reached is 503, not 401: the token may be
        // fine.
        let down = Application()
        down.jwtVerifier { _ in
            JWKSVerifier(url: "https://idp.example/jwks", fetch: { _ in throw JWTError.keySetUnavailable })
        }
        down.get("/me") { (jwt: JWT<Claims>) in jwt.claims.sub }
        #expect(try down.test.get("/me", headers: bearer).status == 503)
    }

    @Test func requestsThatArriveTogetherShareOneFetch() async throws {
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let body = try set([key])
        let verifier = JWKSVerifier(url: "https://idp.example/jwks", fetch: { _ in
            try await Task.sleep(for: .milliseconds(20))
            return body
        })
        let signed = try token(key)
        let subjects = await withTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { (try? await verifier.verify(signed, as: Claims.self).sub) ?? "refused" }
            }
            var all: [String] = []
            for await subject in group { all.append(subject) }
            return all
        }
        #expect(subjects == Array(repeating: "ada", count: 5))
        #expect(verifier.fetches == 1)
    }
}

@Suite("JWKS over HTTP")
struct JWKSOverHTTPTests {
    @Test func theSetIsFetchedWithTheHTTPClientAndARefusalIsNoKeys() throws {
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let body = try set([key])
        let signed = try token(key)
        let (subject, refused) = try onRuntime {
            let provider = Application()
            provider.get("/jwks") { _, response in response.send(bytes: body, contentType: "application/json") }
            let server = try LoopbackServer.start(provider)
            defer { Task { await server.stop() } }
            let verifier = JWKSVerifier(url: server.url + "/jwks")
            let subject = try await verifier.verify(signed, as: Claims.self).sub
            let missing = JWKSVerifier(url: server.url + "/nowhere")
            let refused: JWTError?
            do {
                _ = try await missing.verify(signed, as: Claims.self)
                refused = nil
            } catch let error as JWTError {
                refused = error
            }
            return (subject, refused)
        }
        #expect(subject == "ada")
        #expect(refused == .keySetUnavailable)
    }
}
