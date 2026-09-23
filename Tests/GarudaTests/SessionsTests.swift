import Testing
import CAvian
import AvianCore
import CGarudaSQLite
@testable import Garuda

// Sessions: the cookie that carries the ID, loading, changing, renewing and
// destroying, expiry, and the memory, SQLite and Redis stores.

private struct Profile: Codable, Equatable {
    var name: String
    var admin: Bool
}

/// The ID in a Set-Cookie header for `name`, or nil.
private func sessionID(_ headers: [String], _ name: String = "id") -> String? {
    for header in headers where header.hasPrefix(name + "=") {
        let value = header.dropFirst(name.count + 1).prefix { $0 != ";" }
        return String(value)
    }
    return nil
}

private func sessionApp(_ store: MemorySessionStore,
                        _ configuration: SessionConfiguration = SessionConfiguration()) -> Application {
    let app = Application()
    app.group("/s") {
        app.sessions(configuration, store: store)
        app.get("/read") { (session: Session) in
            "\(session["user"] ?? "-") \(session.value(Profile.self, "profile")?.name ?? "-") \(session.isEmpty)"
        }
        app.post("/login") { (session: Session) async throws -> String in
            try await session.renew()
            try await session.update {
                $0["user"] = "ada"
                $0["visits"] = "1"
            }
            try await session.set("profile", json: Profile(name: "Ada", admin: true))
            return session.id ?? "none"
        }
        app.post("/visit") { (session: Session) async throws -> String in
            let visits = (Int(session["visits"] ?? "0") ?? 0) + 1
            try await session.set("visits", "\(visits)")
            return "\(visits)"
        }
        app.post("/renew") { (session: Session) async throws -> String in
            try await session.renew()
            return session.id ?? "none"
        }
        app.post("/logout") { (session: Session) async throws -> String in
            try await session.destroy()
            return "bye"
        }
        app.post("/clear") { (session: Session) async throws -> String in
            try await session.update { $0.removeAll() }
            return "\(session.id ?? "none")"
        }
    }
    app.get("/outside") { (session: Session) in session["user"] ?? "-" }
    return app
}

@Suite("Sessions", .serialized)
struct SessionsTests {

    @Test func aSessionIsMadeByItsFirstChangeAndReadBack() throws {
        let store = MemorySessionStore()
        let client = sessionApp(store).test

        // Nothing stored, nothing sent, nothing kept.
        let first = try client.get("/s/read")
        #expect(first.text == "- - true")
        #expect(first.headers(named: "set-cookie").isEmpty)
        #expect(store.count == 0)

        let login = try client.post("/s/login")
        let id = try #require(sessionID(login.headers(named: "set-cookie")))
        #expect(login.text == id)
        #expect(isSessionID(id))
        #expect(login.headers(named: "set-cookie") == ["id=\(id); Path=/; HttpOnly; SameSite=Lax"])
        #expect(store.count == 1)

        let cookie = [("cookie", "theme=dark; id=\(id)")]
        let read = try client.get("/s/read", headers: cookie)
        #expect(read.text == "ada Ada false")
        #expect(read.headers(named: "set-cookie").isEmpty)

        // A change to a session that has an ID keeps it, and sends no cookie.
        let visit = try client.post("/s/visit", headers: cookie)
        #expect(visit.text == "2")
        #expect(visit.headers(named: "set-cookie").isEmpty)
        #expect(try client.post("/s/visit", headers: cookie).text == "3")

        // A route outside the scope has no session to extract.
        #expect(try client.get("/outside", headers: cookie).status == 500)
    }

    @Test func anIDTheServerDidNotMakeIsNeverAdopted() throws {
        let store = MemorySessionStore()
        let client = sessionApp(store).test
        let planted = String(repeating: "A", count: 43)
        for value in [planted, "short", "has.dots.and-other/things", ""] {
            let response = try client.post("/s/visit", headers: [("cookie", "id=\(value)")])
            #expect(response.text == "1")
            let id = try #require(sessionID(response.headers(named: "set-cookie")))
            #expect(id != value)
            #expect(isSessionID(id))
        }
        // A forged cookie before the real one does not hide it.
        let id = try #require(sessionID(try client.post("/s/login").headers(named: "set-cookie")))
        #expect(try client.get("/s/read", headers: [("cookie", "id=\(planted); id=\(id)")]).text == "ada Ada false")
    }

    @Test func renewMovesTheDataAndDestroyForgetsIt() throws {
        let store = MemorySessionStore()
        let client = sessionApp(store).test
        let old = try #require(sessionID(try client.post("/s/login").headers(named: "set-cookie")))

        let renewed = try client.post("/s/renew", headers: [("cookie", "id=\(old)")])
        let fresh = try #require(sessionID(renewed.headers(named: "set-cookie")))
        #expect(renewed.text == fresh)
        #expect(fresh != old)
        #expect(store.count == 1)
        #expect(try client.get("/s/read", headers: [("cookie", "id=\(old)")]).text == "- - true")
        #expect(try client.get("/s/read", headers: [("cookie", "id=\(fresh)")]).text == "ada Ada false")

        let logout = try client.post("/s/logout", headers: [("cookie", "id=\(fresh)")])
        #expect(logout.headers(named: "set-cookie")
            == ["id=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax"])
        #expect(store.count == 0)
        #expect(try client.get("/s/read", headers: [("cookie", "id=\(fresh)")]).text == "- - true")

        // Renewing or destroying a session that has none sends nothing.
        #expect(try client.post("/s/renew").headers(named: "set-cookie").isEmpty)
        #expect(try client.post("/s/logout").headers(named: "set-cookie").isEmpty)

        // Emptying a session deletes it.
        let again = try #require(sessionID(try client.post("/s/login").headers(named: "set-cookie")))
        let cleared = try client.post("/s/clear", headers: [("cookie", "id=\(again)")])
        #expect(cleared.text == "none")
        #expect(cleared.headers(named: "set-cookie").count == 1)
        #expect(cleared.headers(named: "set-cookie").first?.contains("Max-Age=0") == true)
        #expect(store.count == 0)
    }

    @Test func theCookieFollowsTheConfiguration() throws {
        var configuration = SessionConfiguration(cookieName: "sid", idleTimeoutSeconds: 600)
        configuration.cookie.maxAge = 600
        configuration.cookie.sameSite = .strict
        configuration.cookie.path = "/s"
        let client = sessionApp(MemorySessionStore(), configuration).test
        let login = try client.post("/s/login")
        let id = try #require(sessionID(login.headers(named: "set-cookie"), "sid"))
        #expect(login.headers(named: "set-cookie") == ["sid=\(id); Path=/s; Max-Age=600; HttpOnly; SameSite=Strict"])
        // With a Max-Age the cookie is sent again each time the session loads.
        let read = try client.get("/s/read", headers: [("cookie", "sid=\(id)")])
        #expect(read.text == "ada Ada false")
        #expect(read.headers(named: "set-cookie") == ["sid=\(id); Path=/s; Max-Age=600; HttpOnly; SameSite=Strict"])
        #expect(try client.get("/s/read", headers: [("cookie", "id=\(id)")]).text == "- - true")
    }

    @Test func aRequestStillHoldingADestroyedSessionCannotBringItBack() async throws {
        let store = MemorySessionStore()
        try await store.save(id: "old", data: ["user": "ada"], ttlMilliseconds: 60_000)
        // Two requests from one client, each with its own copy.
        let stale = Session(store: store, ttlMilliseconds: 60_000)
        let other = Session(store: store, ttlMilliseconds: 60_000)
        for session in [stale, other] {
            session.cookieSent = true
            session.id = "old"
            session.values = ["user": "ada"]
        }
        try await other.destroy()

        await #expect(throws: HTTPError.self) { try await stale.set("theme", "dark") }
        #expect(try await store.load(id: "old", ttlMilliseconds: 60_000) == nil)
        #expect(stale.id == nil && stale.isEmpty)
        // The cookie is left to the request that ended it.
        #expect(stale.cookieChange == .none)
        #expect(store.count == 0)
    }

    @Test func aRequestStillHoldingARenewedSessionCannotRenewOrChangeIt() async throws {
        let store = MemorySessionStore()
        try await store.save(id: "old", data: ["user": "ada"], ttlMilliseconds: 60_000)
        let stale = Session(store: store, ttlMilliseconds: 60_000)
        let other = Session(store: store, ttlMilliseconds: 60_000)
        for session in [stale, other] {
            session.cookieSent = true
            session.id = "old"
            session.values = ["user": "ada"]
        }
        try await other.renew()
        let moved = try #require(other.id)

        await #expect(throws: HTTPError.self) { try await stale.renew() }
        #expect(stale.id == nil && stale.isEmpty)
        #expect(store.count == 1)
        stale.id = "old"
        stale.values = ["user": "ada"]
        await #expect(throws: HTTPError.self) { try await stale.set("theme", "dark") }
        #expect(try await store.load(id: "old", ttlMilliseconds: 60_000) == nil)
        #expect(try await store.load(id: moved, ttlMilliseconds: 60_000) == ["user": "ada"])

        // Emptying it is refused the same way, and leaves the renewed cookie
        // the other request sent alone.
        stale.id = "old"
        stale.values = ["user": "ada"]
        await #expect(throws: HTTPError.self) { try await stale.update { $0.removeAll() } }
        #expect(stale.cookieChange == .none)
        #expect(try await store.load(id: moved, ttlMilliseconds: 60_000) == ["user": "ada"])
    }

    @Test func theMemoryStoreReplacesAndRemovesOnlyLiveSessions() async throws {
        let store = MemorySessionStore()
        nonisolated(unsafe) var now: UInt64 = 1_000_000
        store.clock = { now }
        #expect(try await !store.replace(id: "a", data: ["k": "v"], ttlMilliseconds: 150))
        #expect(store.count == 0)
        try await store.save(id: "a", data: ["k": "v"], ttlMilliseconds: 150)
        #expect(try await store.replace(id: "a", data: ["k": "w"], ttlMilliseconds: 150))
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "w"])
        now += 200_000
        #expect(try await !store.replace(id: "a", data: ["k": "x"], ttlMilliseconds: 150))
        #expect(try await !store.remove(id: "a"))
        try await store.save(id: "b", data: ["k": "v"], ttlMilliseconds: 150)
        #expect(try await store.remove(id: "b"))
        #expect(try await !store.remove(id: "b"))
    }

    @Test func theMemoryStoreExpiresIdleSessions() async throws {
        let store = MemorySessionStore()
        nonisolated(unsafe) var now: UInt64 = 1_000_000
        store.clock = { now }
        try await store.save(id: "a", data: ["k": "v"], ttlMilliseconds: 150)
        try await store.save(id: "b", data: ["k": "w"], ttlMilliseconds: 150)
        now += 100_000
        // Loading "a" moves its expiry; "b" is left to run out.
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "v"])
        now += 100_000
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "v"])
        #expect(try await store.load(id: "b", ttlMilliseconds: 150) == nil)
        try await store.delete(id: "a")
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == nil)
        #expect(store.count == 0)
    }
}

// MARK: - SQLite

nonisolated(unsafe) private var sessionFileCounter = 0

private func sessionDatabasePath() -> String {
    sessionFileCounter += 1
    return "/tmp/garuda-sessions-\(av_getpid())-\(sessionFileCounter).db"
}

private func removeDatabase(_ path: String) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        _ = (path + suffix).withCString { av_unlink($0) }
    }
}

private func written(_ data: [String: String]?) -> String {
    guard let data else { return "-" }
    return data.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
}

private struct Expiry: Decodable {
    var expires: Int64
}

@Suite("Sessions in SQLite", .serialized, .enabled(if: gsq_available() != 0, "no libsqlite3"))
struct SQLiteSessionsTests {
    @Test func theStoreSavesLoadsExpiresAndDeletes() throws {
        let path = sessionDatabasePath()
        defer { removeDatabase(path) }
        let app = Application()
        app.state { _ in try SQLiteDatabase(SQLiteConfiguration(path: path)) }
        app.get("/run") { (db: State<SQLiteDatabase>) async -> String in
            do {
                let store = SQLiteSessionStore(db.value, table: "web_sessions")
                try await store.createTable()
                var out: [String] = []
                try await store.save(id: "one", data: ["user": "ada", "quote": "a \"b\" é"], ttlMilliseconds: 60_000)
                try await store.save(id: "gone", data: ["k": "v"], ttlMilliseconds: 1)
                out.append(written(try await store.load(id: "one", ttlMilliseconds: 60_000)))
                _ = await Worker.waitTimed(currentWorker!, milliseconds: 20) { _ in }
                out.append(written(try await store.load(id: "gone", ttlMilliseconds: 60_000)))
                out.append("\(try await store.deleteExpired())")
                try await store.save(id: "one", data: ["user": "grace"], ttlMilliseconds: 60_000)
                out.append(written(try await store.load(id: "one", ttlMilliseconds: 60_000)))

                // A load moves the expiry only once half the timeout has gone.
                let before = try await db.value.first(Expiry.self, "SELECT expires FROM web_sessions WHERE id = 'one'")?.expires
                _ = try await store.load(id: "one", ttlMilliseconds: 100_000)
                let unchanged = try await db.value.first(Expiry.self, "SELECT expires FROM web_sessions WHERE id = 'one'")?.expires
                _ = try await store.load(id: "one", ttlMilliseconds: 200_000)
                let moved = try await db.value.first(Expiry.self, "SELECT expires FROM web_sessions WHERE id = 'one'")?.expires
                out.append("\(before == unchanged) \((moved ?? 0) > (before ?? 0) + 100_000)")

                try await store.delete(id: "one")
                out.append(written(try await store.load(id: "one", ttlMilliseconds: 60_000)))

                // Only a live session is replaced or removed.
                let absent = try await store.replace(id: "one", data: ["k": "v"], ttlMilliseconds: 60_000)
                try await store.save(id: "two", data: ["k": "v"], ttlMilliseconds: 60_000)
                let present = try await store.replace(id: "two", data: ["k": "w"], ttlMilliseconds: 60_000)
                out.append("\(absent) \(present) \(written(try await store.load(id: "two", ttlMilliseconds: 60_000)))")
                try await store.save(id: "brief", data: ["k": "v"], ttlMilliseconds: 1)
                _ = await Worker.waitTimed(currentWorker!, milliseconds: 20) { _ in }
                let expired = try await store.replace(id: "brief", data: ["k": "w"], ttlMilliseconds: 60_000)
                let removedExpired = try await store.remove(id: "brief")
                let removed = try await store.remove(id: "two")
                let again = try await store.remove(id: "two")
                out.append("\(expired) \(removedExpired) \(removed) \(again)")
                return out.joined(separator: " | ")
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 15_000
        #expect(try client.get("/run").text
            == #"quote=a "b" é,user=ada | - | 1 | user=grace | true true | - | false true k=w | false false true false"#)
    }

    @Test func sessionsWorkOverTheSQLiteStore() throws {
        let path = sessionDatabasePath()
        defer { removeDatabase(path) }
        let app = Application()
        app.state { _ in try SQLiteDatabase(SQLiteConfiguration(path: path)) }
        app.get("/setup") { (db: State<SQLiteDatabase>) async throws -> String in
            try await SQLiteSessionStore(db.value).createTable()
            return "ok"
        }
        app.group("/s") {
            app.sessions { request in SQLiteSessionStore(try request.state(SQLiteDatabase.self)) }
            app.post("/visit") { (session: Session) async throws -> String in
                let visits = (Int(session["visits"] ?? "0") ?? 0) + 1
                try await session.set("visits", "\(visits)")
                return "\(visits)"
            }
        }
        let client = app.test
        client.timeoutMillis = 15_000
        #expect(try client.get("/setup").text == "ok")
        let first = try client.post("/s/visit")
        #expect(first.text == "1")
        let id = try #require(sessionID(first.headers(named: "set-cookie")))
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "2")
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "3")
    }
}

// MARK: - Redis

private let redisTarget: RedisConfiguration? = {
    guard let raw = av_getenv("GARUDA_REDIS") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count >= 2, let port = UInt16(parts[1]) else { return nil }
    var configuration = RedisConfiguration(host: String(parts[0]), port: port,
                                           password: parts.count > 2 && !parts[2].isEmpty ? String(parts[2]) : nil)
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 3_000
    return configuration
}()

@Suite("Sessions in Redis", .serialized, .enabled(if: redisTarget != nil, "set GARUDA_REDIS to run"))
struct RedisSessionsTests {
    @Test func sessionsWorkOverTheRedisStore() throws {
        let settled = redisTarget!
        let prefix = "garuda-test:session:\(av_monotonic_us()):"
        let app = Application()
        app.state { _ in RedisPool(settled, maxConnections: 2) }
        app.group("/s") {
            app.sessions(SessionConfiguration(idleTimeoutSeconds: 30)) { request in
                RedisSessionStore(try request.state(RedisPool.self), prefix: prefix)
            }
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
        app.get("/stale/:id") { (id: Path<String>, redis: State<RedisPool>) async throws -> String in
            let store = RedisSessionStore(redis.value, prefix: prefix)
            let replaced = try await store.replace(id: id.value, data: ["k": "v"], ttlMilliseconds: 30_000)
            let removed = try await store.remove(id: id.value)
            return "\(replaced) \(removed) \(try await redis.value.pttl(prefix + id.value) ?? -9)"
        }
        app.get("/ttl/:id") { (id: Path<String>, redis: State<RedisPool>) async throws -> String in
            "\(try await redis.value.pttl(prefix + id.value) ?? -9)"
        }
        let client = app.test
        client.timeoutMillis = 15_000
        let first = try client.post("/s/visit")
        #expect(first.text == "1")
        let id = try #require(sessionID(first.headers(named: "set-cookie")))
        let ttl = Int(try client.get("/ttl/\(id)").text) ?? -9
        #expect(ttl > 25_000 && ttl <= 30_000)
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "2")
        #expect(try client.post("/s/logout", headers: [("cookie", "id=\(id)")]).text == "bye")
        #expect(try client.get("/ttl/\(id)").text == "-9")
        #expect(try client.get("/stale/\(id)").text == "false false -9")
        #expect(try client.post("/s/visit", headers: [("cookie", "id=\(id)")]).text == "1")
    }
}
