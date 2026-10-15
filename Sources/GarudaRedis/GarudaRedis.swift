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
