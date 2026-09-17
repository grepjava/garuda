//===----------------------------------------------------------------------===//
// Tokens signed by someone else: an identity provider's keys, fetched from its
// JWK Set (RFC 7517) and kept fresh.
//
//     app.jwtVerifier { _ in
//         JWKSVerifier(url: "https://auth.example.com/.well-known/jwks.json",
//                      validation: JWTValidation(issuer: "https://auth.example.com/", audience: "shop"))
//     }
//     app.get("/me") { (jwt: JWT<UserClaims>) async in jwt.claims.sub }
//
// The set is fetched on the first token, kept for `maxAgeSeconds`, and fetched
// again after that. A token naming a `kid` the set does not have is how a
// provider's rotation shows, so it fetches again then -- but no more often than
// `minimumRefetchSeconds`, or a client sending made-up key IDs could make the
// server hammer the provider. Requests that arrive while a fetch is under way
// wait for that one fetch rather than starting their own. When a fetch fails,
// the keys already in hand keep working; with none, the request is 503, and
// the next attempt waits `minimumRefetchSeconds` too.
//
// Only the algorithms in `algorithms` are accepted, and never an HMAC secret:
// a key set is public, so an `oct` key in one is something to ignore, not
// trust. A key marked `use: enc` is skipped. An RSA key without `alg` is taken
// as RS256.
//
// Each worker has its own verifier and its own copy of the keys, built after
// the fork, so the fetches go out on that worker's own HTTP client.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore

/// Verifies tokens with keys fetched from a JWK Set URL.
public final class JWKSVerifier: JWTVerifying, @unchecked Sendable {
    public let url: String
    public let validation: JWTValidation
    public let algorithms: Set<JWTAlgorithm>
    public let maxAgeSeconds: Int64
    public let minimumRefetchSeconds: Int64
    /// A trust store for an https URL. Empty means the system's.
    public var caFile = ""
    public var timeoutMilliseconds: UInt64 = 5_000

    /// Seconds on a clock that only moves forward; tests set their own.
    var clock: @Sendable () -> Int64 = { Int64(av_monotonic_us() / 1_000_000) }
    /// What a test's fetch goes through instead of the network.
    var fetcher: ((String) async throws -> [UInt8])? = nil

    private(set) var keys: JWTKeys? = nil
    private var fetchedAt: Int64 = 0
    private var lastAttempt: Int64? = nil
    private var fetching = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// How many fetches have been made, for tests.
    private(set) var fetches = 0

    public init(url: String, validation: JWTValidation = JWTValidation(),
                algorithms: [JWTAlgorithm] = JWTAlgorithm.allCases.filter { !$0.isHMAC },
                maxAgeSeconds: Int64 = 3600, minimumRefetchSeconds: Int64 = 60) {
        precondition(!algorithms.contains(where: \.isHMAC), "a key set never holds an HMAC secret worth trusting")
        self.url = url
        self.validation = validation
        self.algorithms = Set(algorithms)
        self.maxAgeSeconds = maxAgeSeconds
        self.minimumRefetchSeconds = minimumRefetchSeconds
    }

    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims {
        let parsed = try ParsedToken(token)
        guard let algorithm = JWTAlgorithm(rawValue: parsed.header.alg), algorithms.contains(algorithm) else {
            throw JWTError.unsupported(parsed.header.alg)
        }
        let now = clock()
        // No fetch more often than `minimumRefetchSeconds`, whatever prompts
        // it: a provider that is down is not asked again on every request.
        let due = lastAttempt.map { now - $0 >= minimumRefetchSeconds } ?? true
        if fetching {
            // Whatever the clock says, a fetch under way is worth waiting for.
            await refresh(now)
        } else if due && (keys == nil || now - fetchedAt >= maxAgeSeconds) {
            await refresh(now)
        }
        if let keys, let key = keys.key(for: parsed.header) {
            return try parsed.claims(type, key: key, validation: validation, now: keys.clock())
        }
        // A key ID the set does not have: perhaps the provider has rotated.
        if keys != nil, lastAttempt.map({ now - $0 >= minimumRefetchSeconds }) ?? true {
            await refresh(now)
            if let keys, let key = keys.key(for: parsed.header) {
                return try parsed.claims(type, key: key, validation: validation, now: keys.clock())
            }
        }
        throw keys == nil ? JWTError.keySetUnavailable : JWTError.unknownKey
    }

    /// Fetches the set once, however many requests ask at the same time.
    private func refresh(_ now: Int64) async {
        if fetching {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        fetching = true
        lastAttempt = now
        fetches += 1
        if let fetched = try? await fetch(), let set = try? JSONCoder.decode(JWKSet.self, from: fetched) {
            let usable = set.keys.compactMap(usableKey)
            if !usable.isEmpty {
                keys = JWTKeys(uncheckedKeys: usable, validation: validation)
                fetchedAt = now
            }
        }
        fetching = false
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume() }
    }

    private func fetch() async throws -> [UInt8] {
        if let fetcher { return try await fetcher(url) }
        guard let worker = currentWorker else { throw JWTError.keySetUnavailable }
        var client = HTTPClient(worker: worker)
        client.caFile = caFile
        client.timeoutMilliseconds = timeoutMilliseconds
        client.maxBodyBytes = 1024 * 1024
        let response = try await client.get(url, headers: [("Accept", "application/json")])
        guard response.status == 200 else { throw JWTError.keySetUnavailable }
        return response.body
    }

    private func usableKey(_ jwk: JWK) -> JWTKey? {
        guard jwk.kty != "oct", jwk.use == nil || jwk.use == "sig" else { return nil }
        let algorithm: JWTAlgorithm
        if let named = jwk.alg {
            guard let known = JWTAlgorithm(rawValue: named) else { return nil }
            algorithm = known
        } else {
            switch (jwk.kty, jwk.crv) {
            case ("RSA", _): algorithm = .RS256
            case ("EC", "P-256"): algorithm = .ES256
            case ("EC", "P-384"): algorithm = .ES384
            case ("EC", "P-521"): algorithm = .ES512
            case ("OKP", "Ed25519"): algorithm = .EdDSA
            default: return nil
            }
        }
        guard algorithms.contains(algorithm) else { return nil }
        return try? JWTKey.jwk(jwk, algorithm: algorithm)
    }
}
