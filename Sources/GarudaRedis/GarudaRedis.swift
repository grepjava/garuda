//===----------------------------------------------------------------------===//
// GarudaRedis: Redis (or Valkey) for a Garuda application.
//
//     import Garuda
//     import GarudaRedis
//
//     let cache = app.state { _ in RedisPool(RedisConfiguration(host: "cache")) }
//     try await cache.setJSON("user:42", user, expireMilliseconds: 60_000)
//
// The driver is vega-db's VegaRedis, re-exported whole. What is here is
// values kept as JSON through Garuda's coder.
//===----------------------------------------------------------------------===//

@_exported import Garuda
@_exported import VegaRedis

extension RedisCommandSender {
    /// The value at `key` decoded from JSON, or nil when there is none.
    public func getJSON<T: Decodable>(_ type: T.Type, _ key: String) async throws -> T? {
        guard let bytes = try await getBytes(key) else { return nil }
        return try JSONCoder.decode(type, from: bytes)
    }

    /// Stores `value` as JSON at `key`.
    @discardableResult
    public func setJSON(_ key: String, _ value: some Encodable, expireMilliseconds: Int? = nil,
                        condition: RedisSetCondition = .always) async throws -> Bool {
        try await set(key, try JSONCoder.encode(value), expireMilliseconds: expireMilliseconds,
                      condition: condition)
    }
}

// MARK: - Sessions

/// Sessions in Redis, each a JSON string under `prefix` and its ID, expiring
/// with the server's own PX. Loading pushes the expiry out with GETEX, which
/// needs Redis 6.2 or Valkey.
public struct RedisSessionStore: SessionStore {
    public let redis: any RedisCommandSender
    public let prefix: String

    public init(_ redis: any RedisCommandSender, prefix: String = "session:") {
        self.redis = redis
        self.prefix = prefix
    }

    public func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]? {
        let reply = try await redis.send("GETEX", prefix + id, "PX", ttlMilliseconds)
        guard let bytes = reply.bytes else { return nil }
        return try? JSONCoder.decode([String: String].self, from: bytes)
    }

    public func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws {
        try await redis.set(prefix + id, try JSONCoder.encode(data), expireMilliseconds: ttlMilliseconds)
    }

    public func delete(id: String) async throws {
        _ = try await redis.del(prefix + id)
    }

    public func replace(id: String, data: [String: String], ttlMilliseconds: Int) async throws -> Bool {
        try await redis.set(prefix + id, try JSONCoder.encode(data), expireMilliseconds: ttlMilliseconds,
                            condition: .ifPresent)
    }

    public func remove(id: String) async throws -> Bool {
        try await redis.del(prefix + id) > 0
    }
}

// MARK: - Refresh tokens

/// Refresh tokens in Redis, each key expiring with what it describes:
/// `t:` a token's record, `u:` when it was spent (set with NX, so only one
/// request spends it), `f:` a family's state, and `s:` a subject's families.
public struct RedisRefreshTokenStore: RefreshTokenStore {
    public let redis: any RedisCommandSender
    public let prefix: String

    public init(_ redis: any RedisCommandSender, prefix: String = "refresh:") {
        self.redis = redis
        self.prefix = prefix
    }

    private func ttl(_ until: Int64) -> Int {
        max(1, Int(until - Timestamp.now.secondsSinceEpoch)) * 1000
    }

    public func createFamily(_ family: String, subject: String, expiresAt: Int64) async throws {
        let replies = try await redis.pipeline([
            RedisCommand("SET", prefix + "f:" + family, "active", "PX", ttl(expiresAt)),
            RedisCommand("SADD", prefix + "s:" + subject, family),
            // The index must outlive the family that ends last, so its expiry
            // only ever grows: two logins can reach Redis in either order, and
            // an index that went first would lose `revokeSubject` a family
            // that is still good. `PEXPIRE GT` says this in one word, but that
            // is Redis 7; this works on 6 as well, and is atomic either way.
            RedisCommand("EVAL", "local left = redis.call('PTTL', KEYS[1]) "
                + "local want = tonumber(ARGV[1]) "
                + "if left < want then redis.call('PEXPIRE', KEYS[1], want) end "
                + "return redis.call('PTTL', KEYS[1])",
                         1, prefix + "s:" + subject, ttl(expiresAt)),
        ])
        // A pipeline answers each command on its own, so one the server
        // refuses -- NOPERM on the index, OOM, WRONGTYPE -- comes back as a
        // value beside the ones that worked, and nothing is thrown. Ignoring
        // it would leave the family set and the subject's index without it,
        // and that index is what `revokeSubject` walks: a logout everywhere
        // that answers success and leaves the session running. The login is
        // failed instead, before a token is handed out against the family.
        for reply in replies {
            if case .error(let error) = reply { throw RedisClientError.server(error) }
        }
        // The script answers with the index's own TTL, so a non-positive one
        // says the key is not there and the `SADD` added nothing -- the same
        // unreachable family, without the server having called anything an
        // error. A sender answering something other than an integer is left
        // alone: what is read here is the script's own answer.
        if replies.count > 2, case .integer(let indexTTL) = replies[2], indexTTL <= 0 {
            throw RedisClientError.server(RedisServerError(
                "ERR the subject index did not take refresh family \(family)"))
        }
    }

    public func insert(_ record: RefreshTokenRecord) async throws {
        // Kept until the family ends, so a spent token is still recognised
        // when it is presented again.
        try await redis.set(prefix + "t:" + record.digest, try JSONCoder.encode(record),
                            expireMilliseconds: ttl(record.familyExpiresAt))
    }

    public func find(digest: String) async throws -> RefreshTokenRecord? {
        let replies = try await redis.pipeline([
            RedisCommand("GET", prefix + "t:" + digest),
            RedisCommand("GET", prefix + "u:" + digest),
        ])
        guard let bytes = replies[0].bytes, var record = try? JSONCoder.decode(RefreshTokenRecord.self, from: bytes)
        else { return nil }
        record.usedAt = replies[1].string.flatMap { Int64($0) }
        record.revoked = try await redis.get(prefix + "f:" + record.family) != "active"
        return record
    }

    public func markUsed(digest: String, at: Int64) async throws -> Bool {
        guard let bytes = try await redis.getBytes(prefix + "t:" + digest),
              let record = try? JSONCoder.decode(RefreshTokenRecord.self, from: bytes) else { return false }
        return try await redis.set(prefix + "u:" + digest, Int(at), expireMilliseconds: ttl(record.familyExpiresAt),
                                   condition: .ifAbsent)
    }

    public func revokeFamily(_ family: String) async throws {
        try await redis.send("SET", prefix + "f:" + family, "revoked", "XX", "KEEPTTL")
    }

    public func revokeSubject(_ subject: String) async throws {
        for family in try await redis.smembers(prefix + "s:" + subject) {
            try await revokeFamily(family)
        }
    }
}
