//===----------------------------------------------------------------------===//
// Sessions: what the server keeps about a client between requests, in a
// store, found by a random ID the client holds in a cookie.
//
//     app.sessions(store: MemorySessionStore())
//
//     app.post("/login") { (session: Session, login: Form<Login>) async throws in
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
// Each worker is a process, so a `MemorySessionStore` holds the sessions of
// one worker: with --workers above 1 a client's next request can reach a
// worker that never saw its session. It is for --workers 1 and tests; use
// Redis or SQLite for the rest.
//===----------------------------------------------------------------------===//

import AvianCore
import CAvian
import GarudaRedis

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
    public func update(_ change: (inout [String: String]) throws -> Void) async throws {
        var changed = values
        try change(&changed)
        if changed.isEmpty {
            if id != nil { try await destroy() }
            return
        }
        let target = id ?? newSessionID()
        try await store.save(id: target, data: changed, ttlMilliseconds: ttlMilliseconds)
        if id == nil {
            id = target
            cookieChange = .send
        }
        values = changed
    }

    /// Moves the session to a new ID, keeping its data, and deletes the old
    /// one. Call it when the client signs in or its rights change.
    public func renew() async throws {
        guard let old = id else { return }
        let fresh = newSessionID()
        try await store.save(id: fresh, data: values, ttlMilliseconds: ttlMilliseconds)
        id = fresh
        cookieChange = .send
        try await store.delete(id: old)
    }

    /// Deletes the session and tells the client to forget its cookie.
    public func destroy() async throws {
        if let old = id { try await store.delete(id: old) }
        id = nil
        values = [:]
        if cookieSent || cookieChange == .send { cookieChange = .remove }
    }
}

enum SessionKey: RequestContextKey {
    typealias Value = Session
}

/// 32 random bytes, as 43 characters of base64url.
func newSessionID() -> String {
    base64URLEncode(randomBytes(32))
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
    /// worker, as a pool must be made after the fork.
    ///
    ///     app.state { _ in RedisPool(configuration) }
    ///     app.sessions { request in RedisSessionStore(try request.state(RedisPool.self)) }
    public func sessions(_ configuration: SessionConfiguration = SessionConfiguration(),
                         store: @escaping (borrowing Request) throws -> any SessionStore) {
        let template = configuration.cookie
        let ttl = configuration.idleTimeoutSeconds * 1000
        nonisolated(unsafe) let store = store
        use { request, response async throws -> (any ResponseConvertible)? in
            // Everything the request and response are asked for is asked
            // before the store is awaited.
            let session = Session(store: try store(request), ttlMilliseconds: ttl)
            request[context: SessionKey.self] = session
            let https = String(describing: request.scheme) == "https"
            response.onSend { outgoing in
                switch session.cookieChange {
                case .none:
                    return
                case .send:
                    var cookie = template
                    guard let id = session.id else { return }
                    cookie.value = id
                    if let header = setCookieHeader(cookie, value: id, https: https) {
                        outgoing.addHeader("set-cookie", header)
                    }
                case .remove:
                    var cookie = template
                    cookie.maxAge = 0
                    cookie.expires = Timestamp(secondsSinceEpoch: 0)
                    if let header = setCookieHeader(cookie, value: "", https: https) {
                        outgoing.addHeader("set-cookie", header)
                    }
                }
            }
            var candidates: [String] = []
            request.forEachCookie { name, value in
                if name == template.name { candidates.append(value) }
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
            return nil
        }
    }
}

// MARK: - Stores

/// Sessions in the worker's memory. Each worker process has its own, so this
/// is for --workers 1 and tests.
public final class MemorySessionStore: SessionStore, @unchecked Sendable {
    // A worker runs its handlers on its one thread, so nothing here is shared
    // between threads.
    private var sessions: [String: (data: [String: String], expires: UInt64)] = [:]
    private var savesSinceSweep = 0
    /// Microseconds on a clock that only moves forward; tests set their own.
    var clock: () -> UInt64 = { av_monotonic_us() }

    public init() {}

    /// How many sessions are held, expired ones not yet swept included.
    public var count: Int { sessions.count }

    public func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]? {
        let now = clock()
        guard let entry = sessions[id] else { return nil }
        guard entry.expires > now else {
            sessions[id] = nil
            return nil
        }
        sessions[id] = (entry.data, now + UInt64(ttlMilliseconds) * 1000)
        return entry.data
    }

    public func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws {
        let now = clock()
        sessions[id] = (data, now + UInt64(ttlMilliseconds) * 1000)
        savesSinceSweep += 1
        if savesSinceSweep >= 1024 {
            savesSinceSweep = 0
            sessions = sessions.filter { $0.value.expires > now }
        }
    }

    public func delete(id: String) async throws {
        sessions[id] = nil
    }
}

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
}

/// Sessions in an SQLite table of `id`, `data` (JSON) and `expires`
/// (milliseconds since the epoch). A load moves the expiry only once half of
/// the timeout has gone, so reading a session rarely writes. Make the table
/// with `createTable`, or with `schema` in a migration, and clear expired rows
/// now and then with `deleteExpired`.
public struct SQLiteSessionStore: SessionStore {
    public let database: SQLiteDatabase
    public let table: String

    public init(_ database: SQLiteDatabase, table: String = "garuda_sessions") {
        precondition(!table.isEmpty && table.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
        } && !(table.utf8.first! >= 0x30 && table.utf8.first! <= 0x39),
                     "a session table's name is letters, digits and underscores: \(table)")
        self.database = database
        self.table = table
    }

    /// The statement that makes the table.
    public static func schema(table: String = "garuda_sessions") -> String {
        "CREATE TABLE IF NOT EXISTS \(table) (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL, "
            + "expires INTEGER NOT NULL) WITHOUT ROWID"
    }

    public func createTable() async throws {
        try await database.execute(Self.schema(table: table))
    }

    /// Deletes every expired session, and returns how many.
    @discardableResult
    public func deleteExpired() async throws -> Int {
        try await database.execute("DELETE FROM \(table) WHERE expires <= ?", nowMilliseconds())
    }

    private struct Row: Decodable {
        var data: String
        var expires: Int64
    }

    public func load(id: String, ttlMilliseconds: Int) async throws -> [String: String]? {
        let now = nowMilliseconds()
        guard let row = try await database.first(Row.self, "SELECT data, expires FROM \(table) WHERE id = ?", id),
              row.expires > now else { return nil }
        guard let data = try? JSONCoder.decode([String: String].self, from: Array(row.data.utf8)) else {
            return nil
        }
        if row.expires - now < Int64(ttlMilliseconds) / 2 {
            try await database.execute("UPDATE \(table) SET expires = ? WHERE id = ?",
                                       now + Int64(ttlMilliseconds), id)
        }
        return data
    }

    public func save(id: String, data: [String: String], ttlMilliseconds: Int) async throws {
        let text = String(decoding: try JSONCoder.encode(data), as: UTF8.self)
        try await database.execute(
            "INSERT INTO \(table) (id, data, expires) VALUES (?, ?, ?) "
                + "ON CONFLICT(id) DO UPDATE SET data = excluded.data, expires = excluded.expires",
            id, text, nowMilliseconds() + Int64(ttlMilliseconds))
    }

    public func delete(id: String) async throws {
        try await database.execute("DELETE FROM \(table) WHERE id = ?", id)
    }

    private func nowMilliseconds() -> Int64 {
        Timestamp.now.microsecondsSinceEpoch / 1000
    }
}
