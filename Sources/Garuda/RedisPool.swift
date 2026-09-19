//===----------------------------------------------------------------------===//
// Redis for handlers: a pool per worker, commands with their replies typed,
// pipelines and transactions in one round trip, and pub/sub.
//
//     app.state { _ in RedisPool(RedisConfiguration(host: "cache")) }
//
//     app.get("/visits/:page") { (page: Path<String>, redis: State<RedisPool>) async throws in
//         String(try await redis.value.incr("visits:\(page.value)"))
//     }
//
// A pool belongs to one worker, as PostgresPool does: built by `app.state`
// after the fork, and it finds its worker when used. A connection is handed on
// only as the handshake left it -- a transaction left open, a watch, another
// database or a subscription closes it instead, so the next request never
// runs inside somebody else's session.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaRedis

// MARK: - Commands

/// Something commands can be sent to: a pool, or one session taken from it.
public protocol RedisCommandSender: Sendable {
    /// Sends one command and returns its reply. A refusal from the server
    /// throws `RedisClientError.server`.
    func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue

    /// Sends several commands and returns a reply for each, in order. A
    /// command the server refused is an `.error` among them rather than a
    /// throw, so the others' replies are not lost with it.
    ///
    /// One write where one will do: a pool writes them all together, and a
    /// cluster writes one batch per slot, since a node answers only for the
    /// slots it owns.
    func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue]
}

/// How `set` treats a key that already exists.
public enum RedisSetCondition: Sendable {
    case always
    /// NX: only if the key does not exist.
    case ifAbsent
    /// XX: only if it does.
    case ifPresent
}

extension RedisCommandSender {
    /// Sends a command by name: `try await redis.send("ZADD", "board", 12, "ada")`.
    @discardableResult
    public func send(_ name: String, _ arguments: any RedisArgument...) async throws(RedisClientError) -> RedisValue {
        try await send(RedisCommand(name, arguments: arguments))
    }

    // Strings

    /// The value at `key` as text, or nil when there is none.
    public func get(_ key: String) async throws(RedisClientError) -> String? {
        try optional(try await send("GET", key)) { $0.string }
    }

    /// The value at `key` as bytes, or nil when there is none.
    public func getBytes(_ key: String) async throws(RedisClientError) -> [UInt8]? {
        try optional(try await send("GET", key)) { $0.bytes }
    }

    /// Stores `value` at `key`. With `expireMilliseconds` it expires; with a
    /// condition it may not be stored, which returns false.
    @discardableResult
    public func set(_ key: String, _ value: any RedisArgument, expireMilliseconds: Int? = nil,
                    condition: RedisSetCondition = .always) async throws(RedisClientError) -> Bool {
        var command = RedisCommand("SET", key, value)
        if let expireMilliseconds {
            command.append("PX")
            command.append(expireMilliseconds)
        }
        switch condition {
        case .always: break
        case .ifAbsent: command.append("NX")
        case .ifPresent: command.append("XX")
        }
        let reply = try await send(command)
        if reply.isNull { return false }
        guard reply.string == "OK" else { throw .unexpectedReply(reply) }
        return true
    }

    /// Deletes keys and returns how many existed.
    @discardableResult
    public func del(_ keys: String...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("DEL", arguments: keys)))
    }

    /// How many of `keys` exist, counting a key named twice twice.
    public func exists(_ keys: String...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("EXISTS", arguments: keys)))
    }

    /// Sets `key` to expire, and returns whether the key exists.
    @discardableResult
    public func pexpire(_ key: String, milliseconds: Int) async throws(RedisClientError) -> Bool {
        try integer(try await send("PEXPIRE", key, milliseconds)) == 1
    }

    /// Milliseconds until `key` expires: nil when there is no such key, and
    /// -1 when it never does.
    public func pttl(_ key: String) async throws(RedisClientError) -> Int? {
        let ms = try integer(try await send("PTTL", key))
        return ms == -2 ? nil : ms
    }

    /// Adds `amount` to the integer at `key`, from 0, and returns the result.
    @discardableResult
    public func incr(_ key: String, by amount: Int = 1) async throws(RedisClientError) -> Int {
        try integer(try await send("INCRBY", key, amount))
    }

    // Hashes

    /// Sets fields of the hash at `key`, and returns how many were new.
    @discardableResult
    public func hset(_ key: String, _ fields: [(String, any RedisArgument)]) async throws(RedisClientError) -> Int {
        var command = RedisCommand("HSET", key)
        for (field, value) in fields {
            command.append(field)
            command.append(value)
        }
        return try integer(try await send(command))
    }

    public func hget(_ key: String, _ field: String) async throws(RedisClientError) -> String? {
        try optional(try await send("HGET", key, field)) { $0.string }
    }

    /// Every field of the hash at `key`, empty when there is none.
    public func hgetall(_ key: String) async throws(RedisClientError) -> [String: String] {
        let reply = try await send("HGETALL", key)
        guard let pairs = reply.pairs else { throw .unexpectedReply(reply) }
        var out: [String: String] = [:]
        for pair in pairs {
            guard let field = pair.key.string, let value = pair.value.string else { throw .unexpectedReply(reply) }
            out[field] = value
        }
        return out
    }

    @discardableResult
    public func hdel(_ key: String, _ fields: String...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("HDEL", arguments: [key] + fields)))
    }

    // Lists

    /// Pushes onto the head of the list at `key`, and returns its length.
    @discardableResult
    public func lpush(_ key: String, _ values: any RedisArgument...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("LPUSH", arguments: [key] + values)))
    }

    /// Pushes onto the tail of the list at `key`, and returns its length.
    @discardableResult
    public func rpush(_ key: String, _ values: any RedisArgument...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("RPUSH", arguments: [key] + values)))
    }

    public func lpop(_ key: String) async throws(RedisClientError) -> String? {
        try optional(try await send("LPOP", key)) { $0.string }
    }

    public func rpop(_ key: String) async throws(RedisClientError) -> String? {
        try optional(try await send("RPOP", key)) { $0.string }
    }

    /// Elements `start` to `stop` inclusive; negative counts from the end.
    public func lrange(_ key: String, _ start: Int, _ stop: Int) async throws(RedisClientError) -> [String] {
        try strings(try await send("LRANGE", key, start, stop))
    }

    // Sets

    @discardableResult
    public func sadd(_ key: String, _ members: any RedisArgument...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("SADD", arguments: [key] + members)))
    }

    @discardableResult
    public func srem(_ key: String, _ members: any RedisArgument...) async throws(RedisClientError) -> Int {
        try integer(try await send(RedisCommand("SREM", arguments: [key] + members)))
    }

    public func smembers(_ key: String) async throws(RedisClientError) -> [String] {
        try strings(try await send("SMEMBERS", key))
    }

    // JSON

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

    // Pub/sub

    /// Publishes `message` on `channel`, and returns how many subscribers
    /// received it.
    @discardableResult
    public func publish(_ channel: String, _ message: any RedisArgument) async throws(RedisClientError) -> Int {
        try integer(try await send("PUBLISH", channel, message))
    }

    /// Publishes `message` on a sharded `channel`, and returns how many
    /// subscribers received it.
    ///
    /// A sharded channel belongs to a slot, as a key does, so in a cluster it
    /// travels no further than the shard that owns it.
    @discardableResult
    public func spublish(_ channel: String, _ message: any RedisArgument) async throws(RedisClientError) -> Int {
        try integer(try await send("SPUBLISH", channel, message))
    }

    // Replies

    private func integer(_ reply: RedisValue) throws(RedisClientError) -> Int {
        guard case .integer(let value) = reply, let int = Int(exactly: value) else { throw .unexpectedReply(reply) }
        return int
    }

    private func optional<T>(_ reply: RedisValue, _ read: (RedisValue) -> T?) throws(RedisClientError) -> T? {
        if reply.isNull { return nil }
        guard let value = read(reply) else { throw .unexpectedReply(reply) }
        return value
    }

    private func strings(_ reply: RedisValue) throws(RedisClientError) -> [String] {
        guard let elements = reply.array else { throw .unexpectedReply(reply) }
        var out: [String] = []
        out.reserveCapacity(elements.count)
        for element in elements {
            guard let text = element.string else { throw .unexpectedReply(reply) }
            out.append(text)
        }
        return out
    }
}

/// The replies to MULTI, the commands and EXEC: the commands' own, or nil
/// when a watched key changed and none of them ran.
func transactionReplies(_ replies: [RedisValue], commands: Int) throws(RedisClientError) -> [RedisValue]? {
    guard replies.count == commands + 2 else { throw .unexpectedReply(.array(replies)) }
    if case .error(let error) = replies[0] { throw .server(error) }
    let exec = replies[replies.count - 1]
    if case .error(let error) = exec {
        // EXECABORT: a command was refused as it was queued, and nothing ran.
        // Its own error says which and why.
        for queued in replies[1..<replies.count - 1] {
            if case .error(let refused) = queued { throw .server(refused) }
        }
        throw .server(error)
    }
    if exec.isNull { return nil }
    guard let results = exec.array, results.count == commands else { throw .unexpectedReply(exec) }
    return results
}

// MARK: - The pool

/// Connections to one Redis server, for one worker.
public final class RedisPool: RedisCommandSender, @unchecked Sendable {
    public let configuration: RedisConfiguration
    public let maxConnections: Int
    /// How long a command waits for a connection when every one is in use,
    /// before failing with `poolTimedOut`.
    public let acquireTimeoutMilliseconds: UInt64

    private var idle: [RedisConnection] = []
    private var open = 0
    /// The commands waiting for a connection, and the connections released
    /// straight to them.
    private var waiting = PoolWaiters<RedisConnection>()

    public init(_ configuration: RedisConfiguration, maxConnections: Int = 8,
                acquireTimeoutMilliseconds: UInt64? = nil) {
        precondition(maxConnections > 0, "a pool needs room for at least one connection")
        self.configuration = configuration
        self.maxConnections = maxConnections
        self.acquireTimeoutMilliseconds = acquireTimeoutMilliseconds ?? configuration.timeoutMilliseconds
    }

    public func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue {
        try await send(command, timeoutMilliseconds: nil)
    }

    /// Sends one command, waiting up to `timeoutMilliseconds` for its reply:
    /// for BLPOP and the other commands that block, whose wait has to fit.
    public func send(_ command: RedisCommand, timeoutMilliseconds: UInt64?) async throws(RedisClientError) -> RedisValue {
        let reply = try await withConnection { connection throws(RedisClientError) in
            try await connection.send([command], milliseconds: timeoutMilliseconds)[0]
        }
        if case .error(let error) = reply { throw .server(error) }
        return reply
    }

    /// Sends every command in one write and reads every reply, in order. A
    /// command the server refused is an `.error` among them rather than a
    /// throw, so the others' replies are not lost with it.
    public func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        try await pipeline(commands, timeoutMilliseconds: nil)
    }

    /// Sends every command in one write, waiting up to `timeoutMilliseconds`
    /// for the replies.
    public func pipeline(_ commands: [RedisCommand],
                         timeoutMilliseconds: UInt64?) async throws(RedisClientError) -> [RedisValue] {
        try await withConnection { connection throws(RedisClientError) in
            try await connection.send(commands, milliseconds: timeoutMilliseconds)
        }
    }

    /// Where this pool's server is, as `host:port` -- or the socket path --
    /// which is what a cluster keys its nodes by.
    public var address: String {
        configuration.unixSocketPath ?? "\(configuration.host):\(configuration.port)"
    }

    /// Runs the commands as one transaction -- MULTI, the commands, EXEC -- in
    /// one round trip, and returns their replies. A command refused while it
    /// was queued throws, and none of them ran; one that fails as it runs is
    /// an `.error` among the replies, and the others still ran, as Redis does.
    public func transaction(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        let replies = try await withConnection { connection throws(RedisClientError) in
            do throws(RedisClientError) {
                return try await connection.send([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")])
            } catch {
                throw error.withoutReplies
            }
        }
        // Nothing was watched, so EXEC always runs.
        guard let results = try transactionReplies(replies, commands: commands.count) else {
            throw .unexpectedReply(.null)
        }
        return results
    }

    /// Runs `body` with one connection to itself: for WATCH, then reading,
    /// then a transaction that only runs if nothing watched changed.
    ///
    /// ```
    /// let done = try await redis.value.session { s in
    ///     try await s.watch("stock:42")
    ///     let stock = Int(try await s.get("stock:42") ?? "0") ?? 0
    ///     guard stock > 0 else { return false }
    ///     return try await s.transaction([RedisCommand("DECR", "stock:42")]) != nil
    /// }
    /// ```
    public func session<Result>(_ body: (RedisSession) async throws -> Result) async throws -> Result {
        guard let worker = currentWorker else { throw RedisClientError.cancelled }
        let connection = try await acquire(worker)
        do {
            let result = try await body(RedisSession(connection: connection))
            release(connection)
            return result
        } catch {
            release(connection)
            throw error
        }
    }

    /// Subscribes to channels and patterns on a connection of its own, which
    /// the pool does not count: a subscription holds its connection for as
    /// long as it lasts. The initial subscriptions are confirmed before this
    /// returns.
    public func subscribe(channels: [String] = [], patterns: [String] = []) async throws(RedisClientError) -> RedisSubscription {
        precondition(!channels.isEmpty || !patterns.isEmpty, "subscribe to at least one channel or pattern")
        return try await subscribing(channels: channels, patterns: patterns, sharded: [])
    }

    /// Subscribes to sharded channels, which belong to slots as keys do: in a
    /// cluster a sharded message reaches only the shard that owns it, and
    /// `RedisCluster` subscribes on that shard's node.
    public func subscribeSharded(channels: [String]) async throws(RedisClientError) -> RedisSubscription {
        precondition(!channels.isEmpty, "subscribe to at least one channel")
        return try await subscribing(channels: [], patterns: [], sharded: channels)
    }

    private func subscribing(channels: [String], patterns: [String],
                             sharded: [String]) async throws(RedisClientError) -> RedisSubscription {
        guard let worker = currentWorker else { throw .cancelled }
        let connection = try await RedisConnection.connect(worker, configuration)
        connection.reusable = false
        let subscription = RedisSubscription(connection: connection)
        do {
            try await subscription.start(channels: channels, patterns: patterns, sharded: sharded)
        } catch {
            connection.close()
            throw error
        }
        return subscription
    }

    /// Closes every idle connection. For `app.state`'s shutdown.
    public func close() {
        for connection in idle { connection.close() }
        idle.removeAll()
        for connection in waiting.takeAllHandedOver() { connection.close() }
        open = 0
    }

    // MARK: Connections

    private func withConnection<R>(_ body: (RedisConnection) async throws(RedisClientError) -> R) async throws(RedisClientError) -> R {
        guard let worker = currentWorker else { throw .cancelled }
        let connection = try await acquire(worker)
        do {
            let result = try await body(connection)
            release(connection)
            return result
        } catch {
            release(connection)
            throw error
        }
    }

    private func acquire(_ worker: UnsafeMutablePointer<Worker>) async throws(RedisClientError) -> RedisConnection {
        while true {
            while let connection = idle.popLast() {
                // Redis says nothing unasked. Anything waiting on an idle
                // connection is it going away -- a timeout, a restart --
                // found now rather than after a command is written into it.
                if connection.isOpen && !connection.socket.hasPendingInput { return connection }
                connection.close()
                open -= 1
            }
            if open < maxConnections {
                open += 1
                do {
                    return try await RedisConnection.connect(worker, configuration)
                } catch {
                    open -= 1
                    wakeOne()
                    throw error
                }
            }
            var id: Int32 = -1
            let outcome = await Worker.waitTimed(worker, milliseconds: acquireTimeoutMilliseconds) {
                id = $0
                waiting.add($0)
            }
            switch outcome {
            case .woken:
                // Handed over by the release that woke this wait, so nobody
                // who arrived since can have taken it first (PoolWaiters).
                if let connection = waiting.take(id) { return connection }
                continue
            case .timedOut:
                waiting.remove(id)
                throw .poolTimedOut
            case .cancelled:
                throw .cancelled
            }
        }
    }

    private func release(_ connection: RedisConnection) {
        if connection.isOpen && connection.isClean {
            // Straight to the oldest wait, if there is one (PoolWaiters).
            if let worker = currentWorker, waiting.handOver(connection, on: worker) { return }
            idle.append(connection)
        } else {
            // Closing is what discards a MULTI or a WATCH left behind: the
            // server drops both with the connection.
            if connection.isOpen { connection.close() }
            open -= 1
            wakeOne()
        }
    }

    private func wakeOne() {
        guard let worker = currentWorker else { return }
        waiting.wakeOldest(on: worker)
    }

    /// For tests: how many connections exist, and how many are idle.
    var counts: (open: Int, idle: Int) { (open, idle.count) }
    var waitingCount: Int { waiting.count }
}

/// One connection, for commands that belong together.
/// `@unchecked Sendable` on the same ground as the pool it came from: it
/// belongs to the worker that took it, whose one thread is the only one that
/// ever touches the connection.
public struct RedisSession: RedisCommandSender, @unchecked Sendable {
    let connection: RedisConnection

    /// The protocol the server speaks on this connection: 3, or 2.
    public var protocolVersion: Int { connection.protocolVersion }

    public func send(_ command: RedisCommand) async throws(RedisClientError) -> RedisValue {
        let reply = try await connection.send([command])[0]
        if case .error(let error) = reply { throw .server(error) }
        return reply
    }

    public func pipeline(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue] {
        try await connection.send(commands)
    }

    /// Watches keys: a transaction on this session after this runs only if
    /// none of them has changed.
    public func watch(_ keys: String...) async throws(RedisClientError) {
        _ = try await send(RedisCommand("WATCH", arguments: keys))
    }

    /// MULTI, the commands and EXEC in one round trip. Nil when a watched key
    /// changed and none of them ran.
    public func transaction(_ commands: [RedisCommand]) async throws(RedisClientError) -> [RedisValue]? {
        let replies: [RedisValue]
        do throws(RedisClientError) {
            replies = try await connection.send([RedisCommand("MULTI")] + commands + [RedisCommand("EXEC")])
        } catch {
            throw error.withoutReplies
        }
        return try transactionReplies(replies, commands: commands.count)
    }
}

// MARK: - Pub/sub

/// A message published on a channel this subscription listens to.
public struct RedisMessage: Sendable, Equatable {
    public let channel: String
    /// The pattern it matched, for a pattern subscription.
    public let pattern: String?
    public let payload: [UInt8]

    public var text: String { String(decoding: payload, as: UTF8.self) }
}

/// Channels and patterns being listened to, on a connection of their own.
///
/// Belongs to the handler that made it, on its worker. `next` waits at most
/// the time it is given, so a handler streaming messages to a client can
/// check the client is still there between waits.
public final class RedisSubscription: @unchecked Sendable {
    let connection: RedisConnection
    private var pending: [RedisMessage] = []
    private var pendingHead = 0

    init(connection: RedisConnection) {
        self.connection = connection
    }

    deinit {
        if av_worker_current() == UnsafeMutableRawPointer(connection.socket.worker) {
            connection.close()
        }
    }

    public var isOpen: Bool { connection.isOpen }

    func start(channels: [String], patterns: [String], sharded: [String] = []) async throws(RedisClientError) {
        var commands: [RedisCommand] = []
        if !channels.isEmpty { commands.append(RedisCommand("SUBSCRIBE", arguments: channels)) }
        if !patterns.isEmpty { commands.append(RedisCommand("PSUBSCRIBE", arguments: patterns)) }
        if !sharded.isEmpty { commands.append(RedisCommand("SSUBSCRIBE", arguments: sharded)) }
        try await connection.write(commands)
        var confirmed = 0
        let expected = channels.count + patterns.count + sharded.count
        let deadline = av_monotonic_ms() + connection.configuration.timeoutMilliseconds
        while confirmed < expected {
            let now = av_monotonic_ms()
            guard now < deadline else {
                connection.close()
                throw .timedOut
            }
            let value = try await read(deadline - now)
            if case .error(let error) = value {
                connection.close()
                throw .server(error)
            }
            switch classify(value) {
            case .message(let message): pending.append(message)
            case .confirmation(let kind):
                if kind == "subscribe" || kind == "psubscribe" || kind == "ssubscribe" { confirmed += 1 }
            case .other: continue
            }
        }
    }

    /// The next message, waiting at most `timeoutMilliseconds`; nil when none
    /// came in time. Throws once the connection has gone.
    public func next(timeoutMilliseconds: UInt64 = 1_000) async throws(RedisClientError) -> RedisMessage? {
        if pendingHead < pending.count {
            let message = pending[pendingHead]
            pendingHead += 1
            if pendingHead == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingHead = 0
            }
            return message
        }
        let deadline = av_monotonic_ms() + timeoutMilliseconds
        while true {
            let now = av_monotonic_ms()
            guard now < deadline else { return nil }
            let value: RedisValue
            do {
                value = try await read(deadline - now)
            } catch .timedOut {
                return nil
            }
            if case .error(let error) = value { throw .server(error) }
            if case .message(let message) = classify(value) { return message }
        }
    }

    /// Listens to more channels. Confirmed as messages go by, not here.
    public func subscribe(_ channels: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("SUBSCRIBE", arguments: channels)])
    }

    public func unsubscribe(_ channels: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("UNSUBSCRIBE", arguments: channels)])
    }

    public func psubscribe(_ patterns: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("PSUBSCRIBE", arguments: patterns)])
    }

    /// Listens to more sharded channels. In a cluster they have to be in the
    /// slot this subscription's node owns.
    public func ssubscribe(_ channels: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("SSUBSCRIBE", arguments: channels)])
    }

    public func sunsubscribe(_ channels: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("SUNSUBSCRIBE", arguments: channels)])
    }

    public func punsubscribe(_ patterns: String...) async throws(RedisClientError) {
        try await connection.write([RedisCommand("PUNSUBSCRIBE", arguments: patterns)])
    }

    /// Ends the subscription and closes its connection.
    public func close() {
        connection.close()
    }

    private func read(_ milliseconds: UInt64) async throws(RedisClientError) -> RedisValue {
        do {
            return try await connection.next(milliseconds)
        } catch .timedOut {
            throw .timedOut
        } catch {
            // Anything but a quiet channel ends the subscription.
            connection.close()
            throw error
        }
    }

    private enum Kind {
        case message(RedisMessage)
        case confirmation(String)
        case other
    }

    /// A push over RESP3, an array over RESP2: `message channel payload`,
    /// `pmessage pattern channel payload`, or a confirmation.
    private func classify(_ value: RedisValue) -> Kind {
        guard let elements = value.array, let first = elements.first?.string else { return .other }
        let kind = first.lowercased()
        switch kind {
        case "message", "smessage":
            guard elements.count == 3, let channel = elements[1].string, let payload = elements[2].bytes else {
                return .other
            }
            return .message(RedisMessage(channel: channel, pattern: nil, payload: payload))
        case "pmessage":
            guard elements.count == 4, let pattern = elements[1].string, let channel = elements[2].string,
                  let payload = elements[3].bytes else { return .other }
            return .message(RedisMessage(channel: channel, pattern: pattern, payload: payload))
        case "subscribe", "psubscribe", "unsubscribe", "punsubscribe", "ssubscribe", "sunsubscribe":
            return .confirmation(kind)
        default:
            return .other
        }
    }
}
