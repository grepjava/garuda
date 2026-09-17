import Testing
import CAvian
import AvianCore
@testable import Garuda
import AvianHTTP

// Verifying with keys fetched from a JWK Set: caching, rotation, a provider
// that is down, which keys are trusted, one fetch for requests that arrive
// together, and a fetch over a real connection.

private struct Claims: Codable, Sendable {
    let sub: String
    let exp: Int
}

private let farFuture = 4_102_444_800

/// A clock the tests move, safe to read from the verifier.
private final class TestClock: @unchecked Sendable {
    var seconds: Int64 = 1_000
}

private func set(_ keys: [JWTKey]) throws -> [UInt8] {
    try JSONCoder.encode(JWKSet(keys: keys.compactMap(\.publicJWK)))
}

private func token(_ key: JWTKey, _ subject: String = "ada") throws -> String {
    try JWTKeys([key]).sign(Claims(sub: subject, exp: farFuture))
}

@Suite("JWKS verifier", .serialized)
struct JWKSTests {
    /// A verifier over `served`, which a test may change, with its clock.
    private func verifier(_ served: @escaping () throws -> [UInt8]) -> (JWKSVerifier, TestClock) {
        let clock = TestClock()
        let verifier = JWKSVerifier(url: "https://idp.example/jwks", maxAgeSeconds: 3600, minimumRefetchSeconds: 60)
        verifier.clock = { clock.seconds }
        verifier.fetcher = { _ in try served() }
        return (verifier, clock)
    }

    @Test func keysAreFetchedOnceAndKeptUntilTheyAge() async throws {
        let first = try JWTKey.generate(.ES256, keyID: "a")
        let (verifier, clock) = verifier { try set([first]) }
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
        var published = [old]
        let (verifier, clock) = verifier { try set(published) }
        _ = try await verifier.verify(try token(old), as: Claims.self)
        published = [old, rotated]

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
        var up = false
        let (verifier, clock) = verifier {
            guard up else { throw JWTError.keySetUnavailable }
            return try set([key])
        }
        await #expect(throws: JWTError.keySetUnavailable) { try await verifier.verify(try token(key), as: Claims.self) }
        await #expect(throws: JWTError.keySetUnavailable) { try await verifier.verify(try token(key), as: Claims.self) }
        #expect(verifier.fetches == 1)
        up = true
        clock.seconds += 60
        _ = try await verifier.verify(try token(key), as: Claims.self)
        #expect(verifier.fetches == 2)

        // Down again once the keys age: the ones in hand keep working.
        up = false
        clock.seconds += 7200
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")
        #expect(try await verifier.verify(try token(key), as: Claims.self).sub == "ada")
        #expect(verifier.fetches == 3)
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
        let (verifier, _) = verifier { body }

        #expect(try await verifier.verify(try token(rsa), as: Claims.self).sub == "ada")
        await #expect(throws: JWTError.unknownKey) { try await verifier.verify(try token(ec), as: Claims.self) }
        // An HS256 token is refused before any key is looked for.
        let hmac = try JWTKey.hmac([UInt8](repeating: 1, count: 32), algorithm: .HS256, keyID: "hs")
        await #expect(throws: JWTError.unsupported("HS256")) { try await verifier.verify(try token(hmac), as: Claims.self) }

        // Algorithms can be narrowed further.
        let narrow = JWKSVerifier(url: "https://idp.example/jwks", algorithms: [.ES384])
        narrow.fetcher = { _ in try set([rsa, ec]) }
        await #expect(throws: JWTError.unsupported("RS256")) { try await narrow.verify(try token(rsa), as: Claims.self) }
        #expect(try await narrow.verify(try token(ec), as: Claims.self).sub == "ada")
    }

    @Test func requestsThatArriveTogetherShareOneFetch() throws {
        let key = try JWTKey.generate(.ES256, keyID: "k")
        let body = try set([key])
        let verifier = JWKSVerifier(url: "https://idp.example/jwks")
        verifier.fetcher = { _ in
            _ = await Worker.waitTimed(currentWorker!, milliseconds: 20) { _ in }
            return body
        }
        let signed = try token(key)
        let app = Application()
        app.get("/together") { () async -> String in
            let subjects = await withTaskGroup(of: String.self) { group in
                for _ in 0..<5 {
                    group.addTask { (try? await verifier.verify(signed, as: Claims.self).sub) ?? "refused" }
                }
                var all: [String] = []
                for await subject in group { all.append(subject) }
                return all
            }
            return "\(subjects.filter { $0 == "ada" }.count) \(verifier.fetches)"
        }
        let client = app.test
        client.timeoutMillis = 10_000
        let together = try client.get("/together")
        #expect(together.text == "5 1", "\(together.status) \(together.text)")
    }

    /// GARUDA_JWKS_URL=https://... fetches a real provider's set over HTTPS
    /// and checks that its keys load.
    @Test(.enabled(if: av_getenv("GARUDA_JWKS_URL") != nil, "set GARUDA_JWKS_URL to run"))
    func aRealProvidersSetLoads() throws {
        let url = String(cString: av_getenv("GARUDA_JWKS_URL")!)
        let verifier = JWKSVerifier(url: url)
        let app = Application()
        app.get("/load") { () async -> String in
            // A token naming no key makes the verifier fetch the set.
            let stranger = (try? JWTKey.generate(.RS256, keyID: "not-theirs")).flatMap { try? token($0) } ?? ""
            _ = try? await verifier.verify(stranger, as: Claims.self)
            let keys = verifier.keys?.keys ?? []
            return "\(keys.count) \(keys.map { "\($0.algorithm):\($0.keyID ?? "-")" }.joined(separator: ","))"
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let loaded = try client.get("/load").text
        #expect(!loaded.hasPrefix("0"), "\(loaded)")
        print("JWKS from \(url): \(loaded)")
    }

    @Test func theSetIsFetchedOverTheNetwork() throws {
        let key = try JWTKey.generate(.PS256, keyID: "net")
        let body = try set([key])
        let origin = try #require(JWKSOrigin())
        origin.response = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body

        let verifier = JWKSVerifier(url: origin.url + "/.well-known/jwks.json")
        let app = Application()
        app.jwtVerifier { _ in verifier }
        app.get("/me") { (jwt: JWT<Claims>) async in jwt.claims.sub }
        let client = app.test
        let wire = try TestWire(client)
        wire.send("GET /me HTTP/1.1\r\nHost: test\r\nAuthorization: Bearer \(try token(key))\r\n\r\n")
        var answer: String? = nil
        _ = wire.turn(until: {
            origin.pump()
            answer = wire.receive(turns: 1)
            return answer != nil
        }, turns: 20_000)
        #expect(answer?.hasSuffix("ada") == true)
        #expect(origin.requests.first?.hasPrefix("GET /.well-known/jwks.json HTTP/1.1") == true)
    }
}

/// An origin that answers every request with `response`, pumped on the
/// worker's thread.
private final class JWKSOrigin {
    let fd: Int32
    let port: UInt16
    var response: [UInt8] = []
    private(set) var requests: [String] = []
    private var open: [Int32] = []

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = av_local_port(opened)
        guard got != 0 else { _ = av_close(opened); return nil }
        fd = opened
        port = got
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        _ = av_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 { open.append(peer) }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            requests.append(String(decoding: buffer.prefix(got), as: UTF8.self))
            _ = response.withUnsafeBytes { av_write(peer, $0.baseAddress, $0.count) }
        }
    }
}
