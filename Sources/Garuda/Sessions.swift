//===----------------------------------------------------------------------===//
// Sessions: what the server keeps about a client between requests, in a
// store, found by a random ID the client holds in a cookie.
//
//     app.sessions(store: MemorySessionStore())
//
//     app.post("/login") { (session: Session, login: Form<Login>) in
//         let user = try await users.check(login.value)
//         try await session.renew()
//         try await session.set("user", user.id)
//         return HTTPStatus.noContent
//     }
//     app.get("/me") { (session: Session) in session["user"] ?? "nobody" }
//
// `sessions` is a middleware in the scope it is called in, in the order of
// `use`. A request whose cookie names a live session has it loaded, and its
// idle timeout pushed out, before the handler runs. A request without one
// starts with an empty session and costs the store nothing.
//
// A change is written to the store when it is made: `set`, `update`, `renew`
// and `destroy` return once the store holds it. A handler answers by writing,
// whenever it is done, so there is no point after it where the server could
// wait on a write before the response goes out; and a write made after the
// response could land after the client's next request had read the old data.
// The cookie is added as the response is sent, so change the session before
// answering.
//
// The ID is 32 random bytes and is never taken from the client: a cookie that
// names no live session is ignored, and the first change makes a new ID.
// `renew` moves the data to a new ID, which a login should do so that an ID
// planted in the browser before it does not carry the signed-in user.
//
// Each request loads its own copy of the session, so two requests from one
// client can each hold it. A change to a session another request has since
// destroyed or renewed away is refused rather than stored: storing it would
// make the old ID a live session again, signed in, after the logout that
// ended it. The store checks and writes in one step, and the request that
// lost is answered 409 with its session emptied.
//
// Each shard is a process, so a `MemorySessionStore` holds the sessions of
// one shard: with --shards above 1 a client's next request can reach a shard
// that never saw its session, which the server warns of as it starts. It is
// for one shard and tests; GarudaRedis and GarudaSQLite have stores for the
// rest.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import VegaCrypto

/// Where sessions are kept. The data is a map of strings; an ID is 43
/// characters of base64url.
public protocol SessionStore: Sendable {
    /// The data of session `id`, with its expiry moved to `ttlMilliseconds`
    /// from now, or nil when there is no such session or it has expired.
    func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]?

    /// Stores `data` as session `id`, replacing what it held, to expire
    /// `ttlMilliseconds` from now.
    func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws

    /// Removes session `id`, if there is one.
    func delete(id: String) async throws

    /// Stores `data` as session `id` only if the session is live, in one step
    /// with the check, pushing its expiry out to `ttlMilliseconds` from now.
    /// Returns whether it was stored.
    ///
    /// A change to a session the request loaded is written with this, so that
    /// a request still holding a session another request destroyed cannot
    /// write it back. The default loads and then saves, which another request
    /// can come between: a store of your own should do both at once.
    func replace(id: String, data: [String: String], ttlMilliseconds: Int) async throws -> Bool

    /// Removes session `id` and returns whether it was live, in one step.
    /// `renew` moves a session only when this finds it. The default loads and
    /// then deletes, which another request can come between.
    func remove(id: String) async throws -> Bool
}

extension SessionStore {
    public func replace(id: String, data: [String: String], ttlMilliseconds: Int) async throws -> Bool {
        guard try await load(id: id, ttlMilliseconds: ttlMilliseconds) != nil else { return false }
        try await save(id: id, data: data, ttlMilliseconds: ttlMilliseconds)
        return true
    }

    public func remove(id: String) async throws -> Bool {
        guard try await load(id: id, ttlMilliseconds: 1) != nil else { return false }
        try await delete(id: id)
        return true
    }
}

/// How sessions are found and how long they live.
public struct SessionConfiguration: Sendable {
    /// The cookie that carries the ID, whose value is ignored: its name,
    /// path, domain, SameSite and the rest. With a `maxAge`, the cookie is
    /// sent again on every request that loads the session, so it lasts as
    /// long as the session does; without one it ends with the browser.
    public var cookie: Cookie
    /// How long a session lives after the last request that loaded or
    /// changed it.
    public var idleTimeoutSeconds: Int

    public init(cookieName: String = "id", idleTimeoutSeconds: Int = 86_400) {
        precondition(isCookieName(cookieName), "a session cookie name is a token: \(cookieName)")
        precondition(idleTimeoutSeconds > 0, "a session's idle timeout is at least a second")
        cookie = Cookie(cookieName, "")
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }
}

/// The request's session: read it at once, change it with `await`.
///
/// Changes are written to the store before the call returns. Change the
/// session before answering: the cookie that carries a new ID is added as
/// the response is sent, and a response already sent does not get it.
public final class Session: RequestExtractor, @unchecked Sendable {
    enum CookieChange {
        case none, send, remove
    }

    let store: any SessionStore
    let ttlMilliseconds: Int
    /// The ID the client sent, whether or not a session was found under it.
    var cookieSent = false
    var cookieChange = CookieChange.none

    /// The session's ID, or nil for a session nothing has been stored in.
    public internal(set) var id: String? = nil
    /// Everything the session holds.
    public internal(set) var values: [String: String] = [:]

    init(store: any SessionStore, ttlMilliseconds: Int) {
        self.store = store
        self.ttlMilliseconds = ttlMilliseconds
    }

    public static func extract(from request: borrowing Request, parameter: inout Int) throws -> Session {
        guard let session = request[context: SessionKey.self] else {
            throw HTTPError(.internalServerError, "no app.sessions covers this route")
        }
        return session
    }

    /// The value under `key`, or nil.
    public subscript(key: String) -> String? { values[key] }

    /// The value under `key` decoded from JSON, or nil when there is none or
    /// it does not decode as `type`.
    public func value<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let text = values[key] else { return nil }
        return try? JSONCoder.decode(type, from: Array(text.utf8))
    }

    /// Whether the session holds nothing.
    public var isEmpty: Bool { values.isEmpty }

    /// Stores `value` under `key`, or removes the key for nil.
    public func set(_ key: String, _ value: String?) async throws {
        try await update { $0[key] = value }
    }

    /// Stores `value` under `key` as JSON.
    public func set<T: Encodable>(_ key: String, json value: T) async throws {
        let text = String(decoding: try JSONCoder.encode(value), as: UTF8.self)
        try await update { $0[key] = text }
    }

    /// Makes any number of changes and stores them with one write. A session
    /// left empty is deleted; an empty session that had no ID stays without
    /// one, costing nothing.
    ///
    /// Throws 409 Conflict, and leaves the session empty, when another request
    /// has destroyed or renewed the session since this one loaded it.
    public func update(_ change: (inout [String: String]) throws -> Void) async throws {
        var changed = values
        try change(&changed)
        if changed.isEmpty {
            // Emptied is deleted, but only if it is still there: a session
            // another request renewed lives on under the new ID, and a removal
            // sent from here would take the client's renewed cookie with it.
            if let old = id {
                guard try await store.remove(id: old) else { throw ended() }
                id = nil
                values = [:]
                if cookieSent || cookieChange == .send { cookieChange = .remove }
            }
            return
        }
        if let id {
            guard try await store.replace(id: id, data: changed, ttlMilliseconds: ttlMilliseconds) else {
                throw ended()
            }
        } else {
            let fresh = newSessionID()
            try await store.save(id: fresh, data: changed, ttlMilliseconds: ttlMilliseconds)
            id = fresh
            cookieChange = .send
        }
        values = changed
    }

    /// Moves the session to a new ID, keeping its data, and deletes the old
    /// one. Call it when the client signs in or its rights change.
    ///
    /// Throws 409 Conflict, and leaves the session empty, when another request
    /// has destroyed or renewed the session since this one loaded it.
    public func renew() async throws {
        guard let old = id else { return }
        // The old ID goes first, and only a session that was still there
        // moves: saving first would give a destroyed session a new ID.
        guard try await store.remove(id: old) else { throw ended() }
        id = nil
        cookieChange = cookieSent ? .remove : .none
        let fresh = newSessionID()
        try await store.save(id: fresh, data: values, ttlMilliseconds: ttlMilliseconds)
        id = fresh
        cookieChange = .send
    }

    /// Deletes the session and tells the client to forget its cookie.
    public func destroy() async throws {
        if let old = id { try await store.delete(id: old) }
        id = nil
        values = [:]
        if cookieSent || cookieChange == .send { cookieChange = .remove }
    }

    /// Empties a session another request ended, and returns the error that
    /// says so. The cookie is left alone: the request that ended the session
    /// has already said what the client should hold, perhaps a renewed ID,
    /// and a removal sent now would take that with it.
    private func ended() -> HTTPError {
        id = nil
        values = [:]
        cookieChange = .none
        return HTTPError(.conflict, "the session ended while this request was using it")
    }
}

enum SessionKey: RequestContextKey {
    typealias Value = Session
}

/// 32 random bytes, as 43 characters of base64url.
func newSessionID() -> String {
    base64URLEncode(SecureRandom.bytes(32))
}

/// Whether `text` could be an ID `newSessionID` made.
func isSessionID(_ text: String) -> Bool {
    text.utf8.count == 43 && text.utf8.allSatisfy { c in
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
    }
}

extension RouteBuilder {
    /// Gives every route in the current scope a `Session`, kept in `store`.
    public func sessions(_ configuration: SessionConfiguration = SessionConfiguration(),
                         store: some SessionStore) {
        let store: any SessionStore = store
        sessions(configuration) { _ in store }
    }

    /// Gives every route in the current scope a `Session`, kept in the store
    /// `store` returns for the request: one over what `app.state` built in the
    /// shard, as a pool must be made in the shard that uses it.
    ///
    ///     app.state { _ in RedisPool(configuration) }
    ///     app.sessions { request in RedisSessionStore(try request.state(RedisPool.self)) }
    public func sessions(_ configuration: SessionConfiguration = SessionConfiguration(),
                         store: @escaping @Sendable (borrowing Request) throws -> any SessionStore) {
        let template = configuration.cookie
        let ttl = configuration.idleTimeoutSeconds * 1000
        use { request, response, next in
            // Everything the request and response are asked for is asked
            // before the store is awaited.
            let session = Session(store: try store(request), ttlMilliseconds: ttl)
            request[context: SessionKey.self] = session
            let https = request.arrivedOverHTTPS
            response.onSend { outgoing in
                switch session.cookieChange {
                case .none:
                    return
                case .send:
                    guard let id = session.id,
                          let header = setCookieHeader(template, value: id, https: https) else { return }
                    _ = outgoing.addHeader("set-cookie", header)
                case .remove:
                    var cookie = template
                    cookie.maxAge = 0
                    cookie.expires = 0
                    if let header = setCookieHeader(cookie, value: "", https: https) {
                        _ = outgoing.addHeader("set-cookie", header)
                    }
                }
            }
            var candidates: [String] = []
            let name = template.name
            request.exchange.pointee.forEachCookie { cookieName, value in
                if cookieName.string == name { candidates.append(value.string) }
                return true
            }
            for id in candidates where isSessionID(id) {
                session.cookieSent = true
                if let data = try await session.store.load(id: id, ttlMilliseconds: ttl) {
                    session.id = id
                    session.values = data
                    if template.maxAge != nil { session.cookieChange = .send }
                    break
                }
            }
            try await next()
        }
    }
}

// MARK: - The memory store

/// Sessions in the shard's memory. Each shard process has its own, so this is
/// for one shard and tests.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private struct State {
        var sessions: [String: (data: [String: String], expires: UInt64)] = [:]
        var savesSinceSweep = 0
    }

    private let state = Mutex(State())
    /// Microseconds on a clock that only moves forward; tests set their own,
    /// before the store is used. The one thing here not behind the lock.
    var clock: @Sendable () -> UInt64 = { monotonicNanos() / 1000 }

    public init() {
        MemoryStores.made("MemorySessionStore")
    }

    /// How many sessions are held, expired ones not yet swept included.
    public var count: Int { state.withLock { $0.sessions.count } }

    public func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]? {
        let now = clock()
        return state.withLock { state in
            guard let entry = state.sessions[id] else { return nil }
            guard entry.expires > now else {
                state.sessions[id] = nil
                return nil
            }
            state.sessions[id] = (entry.data, now + UInt64(ttlMilliseconds) * 1000)
            return entry.data
        }
    }

    public func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws {
        let now = clock()
        state.withLock { state in
            state.sessions[id] = (data, now + UInt64(ttlMilliseconds) * 1000)
            state.savesSinceSweep += 1
            if state.savesSinceSweep >= 1024 {
                state.savesSinceSweep = 0
                state.sessions = state.sessions.filter { $0.value.expires > now }
            }
        }
    }

    public func delete(id: String) async throws {
        state.withLock { $0.sessions[id] = nil }
    }

    public func replace(id: String, data: [String: String], ttlMilliseconds: Int) async throws -> Bool {
        let now = clock()
        return state.withLock { state in
            guard let entry = state.sessions[id], entry.expires > now else { return false }
            state.sessions[id] = (data, now + UInt64(ttlMilliseconds) * 1000)
            return true
        }
    }

    public func remove(id: String) async throws -> Bool {
        let now = clock()
        return state.withLock { state in
            guard let entry = state.sessions.removeValue(forKey: id) else { return false }
            return entry.expires > now
        }
    }
}

/// The stores that keep what they hold in one shard's memory, by name, as an
/// application makes them: with more than one shard, the server says so as it
/// starts (`problems()` would refuse to start, and one shard is a fine way to
/// run them).
enum MemoryStores {
    private static let names = Mutex<Set<String>>([])

    static func made(_ name: String) {
        names.withLock { _ = $0.insert(name) }
    }

    /// Warns, once per server, about each store made, when there is more than
    /// one shard to keep apart.
    static func warnIfSharded(_ shard: ShardInfo) {
        guard shard.count > 1, shard.index == 0 else { return }
        for name in names.withLock({ $0 }).sorted() {
            Log.warning("\(name) keeps what it holds in each shard's own memory: with \(shard.count) shards, "
                        + "a client's next request may reach a shard that never saw it. Use a store in "
                        + "Redis or SQLite, or --shards 1.")
        }
    }
}
