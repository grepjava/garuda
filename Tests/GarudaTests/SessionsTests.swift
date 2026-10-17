import Synchronization
import Testing
@testable import Garuda
import GarudaTesting

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
        let clock = SessionClock()
        store.clock = { clock.now.load(ordering: .relaxed) }
        #expect(try await !store.replace(id: "a", data: ["k": "v"], ttlMilliseconds: 150))
        #expect(store.count == 0)
        try await store.save(id: "a", data: ["k": "v"], ttlMilliseconds: 150)
        #expect(try await store.replace(id: "a", data: ["k": "w"], ttlMilliseconds: 150))
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "w"])
        clock.advance(200_000)
        #expect(try await !store.replace(id: "a", data: ["k": "x"], ttlMilliseconds: 150))
        #expect(try await !store.remove(id: "a"))
        try await store.save(id: "b", data: ["k": "v"], ttlMilliseconds: 150)
        #expect(try await store.remove(id: "b"))
        #expect(try await !store.remove(id: "b"))
    }

    @Test func theMemoryStoreExpiresIdleSessions() async throws {
        let store = MemorySessionStore()
        let clock = SessionClock()
        store.clock = { clock.now.load(ordering: .relaxed) }
        try await store.save(id: "a", data: ["k": "v"], ttlMilliseconds: 150)
        try await store.save(id: "b", data: ["k": "w"], ttlMilliseconds: 150)
        clock.advance(100_000)
        // Loading "a" moves its expiry; "b" is left to run out.
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "v"])
        clock.advance(100_000)
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == ["k": "v"])
        #expect(try await store.load(id: "b", ttlMilliseconds: 150) == nil)
        try await store.delete(id: "a")
        #expect(try await store.load(id: "a", ttlMilliseconds: 150) == nil)
        #expect(store.count == 0)
    }

    @Test func theMemoryStoreTakesWritesFromManyThreadsAtOnce() async throws {
        // It is Sendable, so nothing stops two threads sharing one. Before
        // the lock this crashed in Dictionary within a few thousand saves.
        let store = MemorySessionStore()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for task in 0..<16 {
                group.addTask {
                    for i in 0..<500 {
                        let id = "\(task)-\(i)"
                        try await store.save(id: id, data: ["n": "\(i)"], ttlMilliseconds: 60_000)
                        _ = try await store.load(id: id, ttlMilliseconds: 60_000)
                        if i % 2 == 0 { try await store.delete(id: id) }
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(store.count == 16 * 250)
    }
}

/// A clock a test moves by hand.
final class SessionClock: Sendable {
    let now = Atomic<UInt64>(1_000_000)
    func advance(_ micros: UInt64) { now.add(micros, ordering: .relaxed) }
}
