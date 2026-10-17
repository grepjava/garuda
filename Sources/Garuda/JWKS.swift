//===----------------------------------------------------------------------===//
// Tokens signed by someone else: an identity provider's keys, from its JWK Set
// (RFC 7517), kept fresh.
//
//     app.jwtVerifier { _ in
//         JWKSVerifier(url: "https://auth.example.com/.well-known/jwks.json",
//                      validation: JWTValidation(issuer: "https://auth.example.com/", audience: "shop"))
//     }
//     app.get("/me") { (jwt: JWT<UserClaims>) in jwt.claims.sub }
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
// A set that arrives and holds no key this verifier can use is not a fetch that
// failed -- it is the provider saying there is nothing to trust, which is what
// pulling a compromised key looks like. Keys already past `maxAgeSeconds` are
// dropped on such an answer, so tokens are refused rather than verified against
// a set the provider has withdrawn. Keys still inside their age are kept, since
// that is the window they were to be trusted for and an unknown `kid` from any
// client can prompt this fetch; they are not carried past it.
//
// Only the algorithms in `algorithms` are accepted, and never an HMAC secret:
// a key set is public, so an `oct` key in one is something to ignore, not
// trust. A key marked `use: enc` is skipped. An RSA key without `alg` is taken
// as RS256.
//
// Each shard has its own verifier and its own copy of the keys, built with its
// state, and the shard's threads share it: what changes -- the keys, when they
// were fetched, who waits -- is behind a lock held for a few loads and stores,
// never across the fetch or a signature check.
//
// The fetch goes out on Garuda's HTTP client, with the trust store and the
// timeout given, and takes a 200 of at most a megabyte. A `fetch` of the
// application's own -- the bytes at a URL -- replaces it.
//===----------------------------------------------------------------------===//

import Synchronization

/// The body at `url`: what a `JWKSVerifier` fetches its key set with. Throws,
/// or answers whatever the provider said, for anything but a 200.
public typealias JWKSFetch = @Sendable (_ url: String) async throws -> [UInt8]

/// Verifies tokens with keys fetched from a JWK Set URL.
public final class JWKSVerifier: JWTVerifying, @unchecked Sendable {
    public let url: String
    public let validation: JWTValidation
    public let algorithms: Set<JWTAlgorithm>
    public let maxAgeSeconds: Int64
    public let minimumRefetchSeconds: Int64
    /// What the set is fetched with.
    let fetch: JWKSFetch

    /// Seconds on a clock that only moves forward; tests set their own,
    /// before the verifier is shared.
    var clock: @Sendable () -> Int64 = { Int64(monotonicNanos() / 1_000_000_000) }

    private struct State {
        var keys: JWTKeys? = nil
        var fetchedAt: Int64 = 0
        var lastAttempt: Int64? = nil
        var fetching = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        /// How many fetches have been made, for tests.
        var fetches = 0
    }

    private let state = Mutex(State())

    /// The keys in hand, if any.
    var keys: JWTKeys? { state.withLock { $0.keys } }

    /// How many fetches have been made.
    var fetches: Int { state.withLock { $0.fetches } }

    public init(url: String, validation: JWTValidation = JWTValidation(),
                algorithms: [JWTAlgorithm] = JWTAlgorithm.allCases.filter { !$0.isHMAC },
                maxAgeSeconds: Int64 = 3600, minimumRefetchSeconds: Int64 = 60,
                caFile: String = "", timeout: Duration = .seconds(10),
                fetch: JWKSFetch? = nil) {
        precondition(!algorithms.contains(where: \.isHMAC), "a key set never holds an HMAC secret worth trusting")
        self.url = url
        self.validation = validation
        self.algorithms = Set(algorithms)
        self.maxAgeSeconds = maxAgeSeconds
        self.minimumRefetchSeconds = minimumRefetchSeconds
        self.fetch = fetch ?? JWKSVerifier.overHTTP(caFile: caFile, timeout: timeout)
    }

    /// Fetches with the HTTP client: a 200 of at most a megabyte, over the
    /// trust store in `caFile` (the system's when empty).
    static func overHTTP(caFile: String, timeout: Duration) -> JWKSFetch {
        { url in
            var client = HTTPClient()
            client.caFile = caFile
            client.timeout = timeout
            client.totalTimeout = timeout
            client.maxBodyBytes = 1024 * 1024
            let response = try await client.get(url, headers: [("Accept", "application/json")])
            guard response.status == 200 else { throw JWTError.keySetUnavailable }
            return response.body
        }
    }

    public func verify<Claims: Decodable>(_ token: String, as type: Claims.Type) async throws -> Claims {
        let parsed = try ParsedToken(token)
        guard let algorithm = JWTAlgorithm(rawValue: parsed.header.alg), algorithms.contains(algorithm) else {
            throw JWTError.unsupported(parsed.header.alg)
        }
        let now = clock()
        let mustFetch = state.withLock { state in
            // No fetch more often than `minimumRefetchSeconds`, whatever
            // prompts it: a provider that is down is not asked again on every
            // request. A fetch under way, whatever the clock says, is worth
            // waiting for.
            let due = state.lastAttempt.map { now - $0 >= minimumRefetchSeconds } ?? true
            return state.fetching || (due && (state.keys == nil || now - state.fetchedAt >= maxAgeSeconds))
        }
        if mustFetch { await refresh(now) }
        if let keys, let key = keys.key(for: parsed.header) {
            return try parsed.claims(type, key: key, validation: validation, now: keys.clock())
        }
        // A key ID the set does not have: perhaps the provider has rotated.
        let again = state.withLock { state in
            state.keys != nil && (state.lastAttempt.map { now - $0 >= minimumRefetchSeconds } ?? true)
        }
        if again {
            await refresh(now)
            if let keys, let key = keys.key(for: parsed.header) {
                return try parsed.claims(type, key: key, validation: validation, now: keys.clock())
            }
        }
        throw keys == nil ? JWTError.keySetUnavailable : JWTError.unknownKey
    }

    /// The claims when the keys are in hand and fresh enough that `verify`
    /// would not fetch; nil when it would.
    public func verifyNow<Claims: Decodable>(_ token: String, as type: Claims.Type) throws -> Claims? {
        let now = clock()
        let (keys, due, wouldFetch) = state.withLock { state in
            let due = state.lastAttempt.map { now - $0 >= minimumRefetchSeconds } ?? true
            return (state.keys, due,
                    state.fetching || (due && (state.keys == nil || now - state.fetchedAt >= maxAgeSeconds)))
        }
        if wouldFetch { return nil }
        let parsed = try ParsedToken(token)
        guard let algorithm = JWTAlgorithm(rawValue: parsed.header.alg), algorithms.contains(algorithm) else {
            throw JWTError.unsupported(parsed.header.alg)
        }
        guard let keys else { throw JWTError.keySetUnavailable }
        if let key = keys.key(for: parsed.header) {
            return try parsed.claims(type, key: key, validation: validation, now: keys.clock())
        }
        // A key ID the set does not have: `verify` fetches again if it may.
        if due { return nil }
        throw JWTError.unknownKey
    }

    /// Fetches the set once, however many requests ask at the same time.
    private func refresh(_ now: Int64) async {
        let leads = state.withLock { state in
            guard !state.fetching else { return false }
            state.fetching = true
            state.lastAttempt = now
            state.fetches += 1
            return true
        }
        guard leads else { return await waitForFetch() }
        // Outside the lock: the other threads keep verifying with the keys in
        // hand while this one waits on the provider.
        var usable: [JWTKey]? = nil
        if let fetched = try? await fetch(url), let set = try? JSONCoder.decode(JWKSet.self, from: fetched) {
            usable = set.keys.compactMap(usableKey)
        }
        let waiting = state.withLock { state in
            if let usable {
                if !usable.isEmpty {
                    state.keys = JWTKeys(uncheckedKeys: usable, validation: validation)
                    state.fetchedAt = now
                } else if now - state.fetchedAt >= maxAgeSeconds {
                    // The provider answered, and what it published holds
                    // nothing this verifier can use. Keeping keys past their
                    // age on the strength of that would make a withdrawn key
                    // verify for as long as the process lives. A fetch that
                    // *failed* is the other case, and lands in neither
                    // branch: those keys stay.
                    state.keys = nil
                }
            }
            state.fetching = false
            let waiting = state.waiters
            state.waiters = []
            return waiting
        }
        for waiter in waiting { waiter.resume() }
    }

    /// Waits for the fetch under way, if it still is. Not inlined: a
    /// continuation's wait inlined into a function holding a lock is what
    /// Swift 6.3's optimizer has miscompiled.
    @inline(never)
    private func waitForFetch() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state in
                guard state.fetching else { return false }
                state.waiters.append(waiter)
                return true
            }
            if !waits { waiter.resume() }
        }
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
