#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda
@testable import GarudaPostgres
import GarudaRedis
@testable import GarudaSQLite
import GarudaSQL
import GarudaTesting
import InMemoryTracing
import Synchronization
import Testing
import Vega

// What Garuda adds to vega-db's drivers: its UUID and Timestamp as columns,
// JSON through its coder, and `@PostgresRow`. The drivers have their own
// suites in vega-db.
//
// The Postgres and Redis tests are opt-in, against the servers vega-db's
// scripts/postgres-test-server.sh and redis-test-servers.sh start:
//
//     GARUDA_POSTGRES=127.0.0.1:46432:vega:vega-secret:vega \
//     GARUDA_REDIS=127.0.0.1:46379:vega-secret swift test

enum DatabaseTestRuntime {
    static let shared = Runtime(workers: 2)
}

func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

let postgresTarget: PostgresConfiguration? = {
    guard let raw = environment("GARUDA_POSTGRES") else { return nil }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeout = .seconds(5)
    return configuration
}()

let redisTarget: RedisConfiguration? = {
    guard let raw = environment("GARUDA_REDIS") else { return nil }
    let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port,
                                           password: parts.count > 2 ? String(parts[2]) : nil)
    configuration.tls = .disable
    return configuration
}()

// MARK: - SQLite

struct Stamped: Codable, Equatable {
    let id: UUID
    let at: Timestamp
    let maybe: UUID?
}

@Suite("Garuda's types in SQLite")
struct SQLiteTypeTests {
    @Test func uuidsAndTimestampsRoundTrip() throws {
        let path = "/tmp/garuda-db-\(getpid())-types.sqlite"
        defer { unlink(path); unlink(path + "-wal"); unlink(path + "-shm") }
        let id = UUID.random()
        let instants = [Timestamp(microsecondsSinceEpoch: 1_789_591_223_196_123),
                        Timestamp(microsecondsSinceEpoch: 0),
                        Timestamp(microsecondsSinceEpoch: -1)]
        let read = try DatabaseTestRuntime.shared.block { () async throws -> [Stamped] in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            defer { db.close() }
            _ = try await db.execute("create table stamps (n integer, id text, at text, maybe text)")
            for (n, instant) in instants.enumerated() {
                _ = try await db.execute("insert into stamps values (?, ?, ?, ?)", n, id, instant, UUID?.none)
            }
            return try await db.query(Stamped.self, "select id, at, maybe from stamps order by n")
        }
        #expect(read == instants.map { Stamped(id: id, at: $0, maybe: nil) })
    }

    @Test func timestampsBindAsTextThatSorts() {
        let whole = Timestamp(secondsSinceEpoch: 1_789_000_000)
        let later = whole.adding(microseconds: 120_000)
        #expect(whole.sqliteText == "2026-09-10 00:26:40.000000")
        #expect(later.sqliteText == "2026-09-10 00:26:40.120000")
        // As text, the later instant sorts later -- which ISO 8601 with its
        // trailing zeros dropped would not: "40.12Z" < "40Z".
        #expect(whole.sqliteText < later.sqliteText)
        #expect(Timestamp(microsecondsSinceEpoch: -62_135_596_800_000_000).sqliteText == "0001-01-01 00:00:00.000000")
    }

    @Test func cellsConvertFromWhatSQLiteStored() throws {
        let id = UUID(high: 0x0123_4567_89ab_cdef, low: 0xfedc_ba98_7654_3210)
        #expect(try UUID(sqliteValue: .text(id.description)) == id)
        #expect(try UUID(sqliteValue: .blob(id.bytes)) == id)
        #expect(throws: SQLiteDecodingError.self) { try UUID(sqliteValue: .integer(7)) }
        #expect(try Timestamp(sqliteValue: .text("2026-09-17 06:19:31")) == Timestamp(secondsSinceEpoch: 1_789_625_971))
        #expect(try Timestamp(sqliteValue: .integer(1_789_625_971)) == Timestamp(secondsSinceEpoch: 1_789_625_971))
        #expect(throws: SQLiteDecodingError.self) { try Timestamp(sqliteValue: .text("soon")) }
    }
}

// MARK: - Postgres

struct Metadata: Codable, Equatable, Sendable {
    var tags: [String]
    var size: Int
}

struct Document: Decodable, Equatable {
    let id: UUID
    let at: Timestamp
    let meta: PostgresJSON<Metadata>

    static func == (a: Document, b: Document) -> Bool {
        a.id == b.id && a.at == b.at && a.meta.value == b.meta.value
    }
}

@PostgresRow struct MacroPerson: Codable, Equatable {
    var id: Int
    var name: String
}

struct PlainPerson: Codable, Equatable {
    var id: Int
    var name: String
}

@PostgresRow struct MacroSparse: Codable, Equatable {
    var id: Int32
    var nickname: String?
    var score: Double?
}

@Suite("Garuda's types in PostgreSQL", .enabled(if: postgresTarget != nil, "set GARUDA_POSTGRES to run"))
struct PostgresTypeTests {
    func withPool<T: Sendable>(_ body: @escaping @Sendable (PostgresPool) async throws -> T) throws -> T {
        let configuration = postgresTarget!
        return try DatabaseTestRuntime.shared.block { () async throws -> T in
            let pool = PostgresPool(configuration, maxConnections: 2)
            defer { pool.close() }
            return try await body(pool)
        }
    }

    @Test func uuidsTimestampsAndJSONRoundTrip() throws {
        let id = UUID.random()
        let instants = [Timestamp(microsecondsSinceEpoch: 1_789_591_223_196_123),
                        Timestamp(microsecondsSinceEpoch: 0),
                        Timestamp(microsecondsSinceEpoch: -1),                        // before 1970
                        Timestamp(microsecondsSinceEpoch: -2_000_000_000_000_000),    // 1906, before 2000 too
                        Timestamp("0044-03-15 12:00:00+00 BC")!]
        let meta = Metadata(tags: ["a", "b\"c"], size: 3)
        let (first, second, check) = try withPool { pool in
            try await pool.transaction { tx in
                _ = try await tx.execute("create temporary table docs (n int, id uuid, at timestamptz, meta jsonb)")
                for (n, instant) in instants.enumerated() {
                    _ = try await tx.execute("insert into docs values ($1, $2, $3, $4)",
                                             n, id, instant, PostgresJSON(meta))
                }
                let sql = "select id, at, meta from docs order by n"
                // The second run of a statement is prepared and comes back in binary.
                let first = try await tx.query(Document.self, sql)
                let second = try await tx.query(Document.self, sql)
                let check = try await tx.first(String.self, "select $1::uuid::text || ' ' || extract(epoch from $2::timestamptz)::text",
                                               id, instants[0])
                return (first, second, check)
            }
        }
        let expected = instants.map { Document(id: id, at: $0, meta: PostgresJSON(meta)) }
        #expect(first == expected)
        #expect(second == expected)
        #expect(check == "\(id) 1789591223.196123")
    }

    @Test func infinityIsNotATimestamp() throws {
        struct At: Decodable { let at: Timestamp }
        let refused = try withPool { pool in
            var refused = 0
            for value in ["infinity", "-infinity", "infinity", "-infinity"] {
                do { _ = try await pool.first(At.self, "select '\(value)'::timestamptz as at") } catch { refused += 1 }
            }
            return refused
        }
        #expect(refused == 4)
    }

    @Test func aStatementInATracedRequestIsASpanUnderIt() throws {
        let tracer = InMemoryTracer()
        let configuration = postgresTarget!
        let app = Application()
        app.tracing { _ in tracer }
        // Made in the shard, once tracing is installed: traced without being told.
        app.state { _ in PostgresPool(configuration, maxConnections: 1) }
        app.get("/answer") { (db: State<PostgresPool>) in
            String(try await db.value.first(Int.self, "select 41 + 1") ?? 0)
        }
        #expect(try app.test.get("/answer").text == "42")
        let spans = tracer.finishedSpans
        let request = try #require(spans.first { $0.operationName == "GET /answer" })
        // Tests running alongside are traced too while tracing is installed:
        // find this one's statement by its text.
        let select = try #require(spans.first {
            $0.operationName == "SELECT" && $0.attributes.get("db.query.text") == .string("select 41 + 1")
        })
        #expect(select.parentSpanID == request.spanID)
        #expect(select.attributes.get("db.system.name") == .string("postgresql"))
        #expect(select.attributes.get("db.query.text") == .string("select 41 + 1"))
        DatabaseTracing.installed = nil
    }

    @Test func thePostgresRowMacroReadsWhatCodableReads() throws {
        let (mine, plain, sparse, narrow) = try withPool { pool in
            let sql = "select 7 as id, 'ana' as name union all select 8, 'bo' order by id"
            let mine = try await pool.query(MacroPerson.self, sql)
            let plain = try await pool.query(PlainPerson.self, sql)
            let sparse = try await pool.first(MacroSparse.self, "select 1::int4 as id, null::text as nickname, null::float8 as score")
            let narrow = try await pool.first(MacroSparse.self, "select 2::int4 as id")
            return (mine, plain, sparse, narrow)
        }
        #expect(mine == [MacroPerson(id: 7, name: "ana"), MacroPerson(id: 8, name: "bo")])
        #expect(mine.map(\.id) == plain.map(\.id) && mine.map(\.name) == plain.map(\.name))
        #expect(sparse == MacroSparse(id: 1, nickname: nil, score: nil))
        #expect(narrow == MacroSparse(id: 2, nickname: nil, score: nil))
    }
}

// MARK: - Redis

@Suite("JSON in Redis", .enabled(if: redisTarget != nil, "set GARUDA_REDIS to run"))
struct RedisJSONTests {
    @Test func aValueIsKeptAsJSON() throws {
        let configuration = redisTarget!
        let key = "garuda:test:json:\(getpid())"
        let (stored, read, raw, missing) = try DatabaseTestRuntime.shared.block { () async throws -> (Bool, Metadata?, String?, Metadata?) in
            let pool = RedisPool(configuration)
            defer { pool.close() }
            let stored = try await pool.setJSON(key, Metadata(tags: ["x"], size: 1), expireMilliseconds: 10_000)
            let read = try await pool.getJSON(Metadata.self, key)
            let raw = try await pool.get(key)
            _ = try await pool.del(key)
            let missing = try await pool.getJSON(Metadata.self, key)
            return (stored, read, raw, missing)
        }
        #expect(stored)
        #expect(read == Metadata(tags: ["x"], size: 1))
        #expect(raw == #"{"tags":["x"],"size":1}"#)
        #expect(missing == nil)
    }
}

// MARK: - Session stores

/// The ID in a Set-Cookie header for `name`, or nil.
private func sessionID(_ headers: [String], _ name: String = "id") -> String? {
    for header in headers where header.hasPrefix(name + "=") {
        return String(header.dropFirst(name.count + 1).prefix { $0 != ";" })
    }
    return nil
}

private func visitingApp(_ store: @escaping @Sendable (borrowing Request) throws -> any SessionStore,
                         configuration: SessionConfiguration = SessionConfiguration()) -> Application {
    let app = Application()
    app.group("/s") {
        app.sessions(configuration, store: store)
        app.post("/visit") { (session: Session) async throws -> String in
            let visits = (Int(session["visits"] ?? "0") ?? 0) + 1
            try await session.set("visits", "\(visits)")
            return "\(visits)"
        }
        app.post("/logout") { (session: Session) async throws -> String in
            try await session.destroy()
            return "bye"
        }
    }
    return app
}

private func written(_ data: [String: String]?) -> String {
    guard let data else { return "-" }
    return data.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
}

@Suite("Session stores")
struct SessionStoreTests {
    @Test func theSQLiteStoreSavesLoadsExpiresAndReplacesOnlyLiveSessions() throws {
        let path = "/tmp/garuda-db-\(getpid())-sessions.sqlite"
        defer { unlink(path); unlink(path + "-wal"); unlink(path + "-shm") }
        let out = try DatabaseTestRuntime.shared.block { () async throws -> String in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            defer { db.close() }
            let store = SQLiteSessionStore(db, table: "web_sessions")
            try await store.createTable()
            var out: [String] = []
            try await store.save(id: "one", data: ["user": "ada", "quote": "a \"b\" é"], ttlMilliseconds: 60_000)
            try await store.save(id: "gone", data: ["k": "v"], ttlMilliseconds: 1)
            out.append(written(try await store.load(id: "one", ttlMilliseconds: 60_000)))
            try await Runtime.sleep(for: .milliseconds(20))
            out.append(written(try await store.load(id: "gone", ttlMilliseconds: 60_000)))
            out.append("\(try await store.deleteExpired())")
            let absent = try await store.replace(id: "none", data: ["k": "v"], ttlMilliseconds: 60_000)
            let present = try await store.replace(id: "one", data: ["k": "w"], ttlMilliseconds: 60_000)
            out.append("\(absent) \(present) \(written(try await store.load(id: "one", ttlMilliseconds: 60_000)))")
            let removed = try await store.remove(id: "one")
            let again = try await store.remove(id: "one")
            out.append("\(removed) \(again)")
            return out.joined(separator: " | ")
        }
        #expect(out == #"quote=a "b" é,user=ada | - | 1 | false true k=w | true false"#)
    }

    @Test func sessionsWorkOverTheSQLiteStore() throws {
        let path = "/tmp/garuda-db-\(getpid())-web.sqlite"
        defer { unlink(path); unlink(path + "-wal"); unlink(path + "-shm") }
        let app = visitingApp { request in SQLiteSessionStore(try request.state(SQLiteDatabase.self)) }
        app.state { _ in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            try await SQLiteSessionStore(db).createTable()
            return db
        }
        let client = app.test
        let first = try client.post("/s/visit")
        #expect(first.text == "1")
        let id = try #require(sessionID(first.headers(named: "set-cookie")))
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "2")
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "3")
        #expect(try client.post("/s/logout", headers: [("cookie", "id=\(id)")]).text == "bye")
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "1")
    }

    @Test(.enabled(if: redisTarget != nil, "set GARUDA_REDIS to run"))
    func sessionsWorkOverTheRedisStore() throws {
        let configuration = redisTarget!
        let prefix = "garuda-test:session:\(getpid()):"
        let app = visitingApp({ request in RedisSessionStore(try request.state(RedisPool.self), prefix: prefix) },
                              configuration: SessionConfiguration(idleTimeoutSeconds: 30))
        app.state { _ in RedisPool(configuration, maxConnections: 2) }
        let client = app.test
        let first = try client.post("/s/visit")
        #expect(first.text == "1")
        let id = try #require(sessionID(first.headers(named: "set-cookie")))
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "2")
        #expect(try client.post("/s/logout", headers: [("cookie", "id=\(id)")]).text == "bye")
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "1")
    }
}

// MARK: - Listening

@Suite("app.listen", .enabled(if: postgresTarget != nil, "set GARUDA_POSTGRES to run"))
struct ListenTests {
    @Test func aNotificationReachesTheShardsHandler() throws {
        let configuration = postgresTarget!
        let heard = Mutex<[String]>([])
        let listening = Mutex(0)
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.listen("garuda_test", whenListening: { _ in listening.withLock { $0 += 1 } }) { notification, _ in
            heard.withLock { $0.append(notification.payload) }
        }
        app.post("/notify") { (db: State<PostgresPool>) async throws -> String in
            _ = try await db.value.execute("select pg_notify('garuda_test', 'hello')")
            return "sent"
        }
        app.get("/ping") { _, response in response.send("pong") }
        let client = app.test
        // The first request starts the shard, and its listener with it.
        #expect(try client.get("/ping").text == "pong")
        let until = ContinuousClock.now + .seconds(5)
        while listening.withLock({ $0 }) == 0 && ContinuousClock.now < until {
            _ = try DatabaseTestRuntime.shared.block { () async throws -> Int in
                try await Runtime.sleep(for: .milliseconds(10))
                return 0
            }
        }
        #expect(try client.post("/notify").text == "sent")
        while heard.withLock({ $0 }).isEmpty && ContinuousClock.now < until {
            _ = try DatabaseTestRuntime.shared.block { () async throws -> Int in
                try await Runtime.sleep(for: .milliseconds(10))
                return 0
            }
        }
        #expect(heard.withLock { $0 } == ["hello"])
    }
}
