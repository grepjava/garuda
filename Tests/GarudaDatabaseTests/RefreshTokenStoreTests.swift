#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Garuda
import GarudaPostgres
import GarudaRedis
import GarudaSQLite
import Testing

// The refresh-token stores over each database, held to what every store must
// do (RefreshTokensTests.swift has the memory store's run).

/// What every store must do, run against one.
private func exerciseStore(_ store: any RefreshTokenStore) async throws -> String {
    let now = Timestamp.now.secondsSinceEpoch
    let unique = Tokens.random(bytes: 16)
    let family = "family-\(unique)"
    let subject = "subject-\(unique)"
    try await store.createFamily(family, subject: subject, expiresAt: now + 3600)
    try await store.createFamily(family + "-2", subject: subject, expiresAt: now + 3600)
    let record = RefreshTokenRecord(digest: Tokens.digest("a" + unique), family: family, subject: subject,
                                    issuedAt: now, expiresAt: now + 600, familyExpiresAt: now + 3600)
    let second = RefreshTokenRecord(digest: Tokens.digest("b" + unique), family: family + "-2", subject: subject,
                                    issuedAt: now, expiresAt: now + 600, familyExpiresAt: now + 3600)
    try await store.insert(record)
    try await store.insert(second)
    var out: [String] = []
    out.append("\(try await store.find(digest: record.digest) == record)")
    out.append("\(try await store.find(digest: "missing") == nil)")
    out.append("\(try await store.markUsed(digest: record.digest, at: now + 5))")
    out.append("\(try await store.markUsed(digest: record.digest, at: now + 6))")
    out.append("\(try await store.find(digest: record.digest)?.usedAt ?? -1 == now + 5)")
    try await store.revokeFamily(family)
    out.append("\(try await store.find(digest: record.digest)?.revoked ?? false)")
    out.append("\(try await store.find(digest: second.digest)?.revoked ?? true)")
    try await store.revokeSubject(subject)
    out.append("\(try await store.find(digest: second.digest)?.revoked ?? false)")
    return out.joined(separator: " ")
}

private let storeExpectation = "true true true false true true false true"

/// A server that takes the family and refuses to index it, as a Redis ACL
/// without `SADD` on the subject keys does.
private struct IndexRefusingRedis: RedisCommandSender {
    func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue { .simpleString("OK") }
    func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        [.simpleString("OK"), .error(RedisServerError("NOPERM no permissions for SADD")), .integer(-2)]
    }
}

/// The same refusal without the server calling it one: the `SADD` answers
/// and adds nothing, so the script finds no index key to read a TTL from.
private struct IndexLosingRedis: RedisCommandSender {
    func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue { .simpleString("OK") }
    func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        [.simpleString("OK"), .integer(0), .integer(-2)]
    }
}

@Suite("Refresh token stores in databases", .serialized)
struct RefreshTokenDatabaseStoreTests {
    @Test func aRedisFamilyTheSubjectIndexDidNotTakeIsNotALogin() async throws {
        for store in [RedisRefreshTokenStore(IndexRefusingRedis()), RedisRefreshTokenStore(IndexLosingRedis())] {
            var refused = false
            do {
                try await store.createFamily("family", subject: "ada", expiresAt: Timestamp.now.secondsSinceEpoch + 3600)
            } catch { refused = true }
            #expect(refused)
        }
    }

    @Test func sqlite() throws {
        let path = "\(temporaryDirectory)/garuda-db-\(getpid())-refresh.sqlite"
        defer { unlink(path); unlink(path + "-wal"); unlink(path + "-shm") }
        let text = try DatabaseTestRuntime.shared.block { () async throws -> String in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            defer { db.close() }
            let store = SQLiteRefreshTokenStore(db)
            try await store.createTables()
            let result = try await exerciseStore(store)
            _ = try await store.deleteExpired()
            return result
        }
        #expect(text == storeExpectation)
    }

    @Test(.enabled(if: postgresTarget != nil, "set GARUDA_POSTGRES to run"))
    func postgres() throws {
        let configuration = postgresTarget!
        let text = try DatabaseTestRuntime.shared.block { () async throws -> String in
            let pool = PostgresPool(configuration, maxConnections: 2)
            defer { pool.close() }
            let table = "garuda_test_refresh"
            let store = PostgresRefreshTokenStore(pool, table: table)
            for statement in ["drop table if exists \(table)", "drop table if exists \(table)_families"] {
                _ = try await pool.execute(statement)
            }
            try await store.createTables()
            let result = try await exerciseStore(store)
            _ = try await store.deleteExpired()
            for statement in ["drop table if exists \(table)", "drop table if exists \(table)_families"] {
                _ = try await pool.execute(statement)
            }
            return result
        }
        #expect(text == storeExpectation)
    }

    @Test(.enabled(if: redisTarget != nil, "set GARUDA_REDIS to run"))
    func redis() throws {
        let configuration = redisTarget!
        let text = try DatabaseTestRuntime.shared.block { () async throws -> String in
            let redis = RedisPool(configuration, maxConnections: 2)
            defer { redis.close() }
            let prefix = "garuda-test:refresh:"
            let store = RedisRefreshTokenStore(redis, prefix: prefix)
            let result = try await exerciseStore(store)
            // A second login with less of a session left must not shorten
            // the subject's index: `revokeSubject` reads it while the first
            // family is still good.
            let now = Timestamp.now.secondsSinceEpoch
            let subject = "ttl-" + Tokens.random(bytes: 16)
            try await store.createFamily("long-" + subject, subject: subject, expiresAt: now + 3600)
            try await store.createFamily("short-" + subject, subject: subject, expiresAt: now + 30)
            let left = try await redis.send("PTTL", prefix + "s:" + subject).string.flatMap { Int64($0) }
            return result + " \((left ?? -1) > 3_000_000)"
        }
        #expect(text == storeExpectation + " true")
    }
}
