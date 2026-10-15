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
