//===----------------------------------------------------------------------===//
// Redis connections on the worker's poller.
//
// The protocol is GarudaRedis's: replies parsed and commands written there,
// with no socket in sight. This file only moves bytes -- opens the connection,
// puts TLS on it, runs the handshake, and writes commands and reads their
// replies. Works with Redis 6 and later over RESP3, older servers over RESP2,
// and Valkey.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
// Its values and commands are part of this API, so `import Garuda` is enough.
@_exported import GarudaRedis

/// Where a Redis server is and how to reach it.
public struct RedisConfiguration: Sendable {
    public enum TLS: Sendable {
        /// Plaintext. For a server on this machine, or a network nobody else is on.
        case disable
        /// Encrypted and verified, or not at all.
        case require
    }

    public var host: String
    public var port: UInt16
    /// A unix socket to connect to instead of `host` and `port`.
    public var unixSocketPath: String?
    /// An ACL user. Nil authenticates as `default` when there is a password.
    public var username: String?
    public var password: String?
    public var database: Int = 0
    /// `.require` unless changed, as for PostgreSQL: a client that falls back
    /// to plaintext when TLS is refused lets anyone on the path refuse it.
    public var tls: TLS = .require
    /// A trust store for `.require`. Empty means the system's.
    public var caFile = ""
    /// The name `CLIENT LIST` shows for this server's connections.
    public var clientName: String? = nil
    /// How long connecting, and each command, may take.
    public var timeoutMilliseconds: UInt64 = 10_000
    /// The largest string a reply may carry, and the most elements in one.
    public var maxBulkBytes = 64 * 1024 * 1024
    public var maxReplyElements = 1_000_000

    public init(host: String, port: UInt16 = 6379, password: String? = nil) {
        self.host = host
        self.port = port
        self.password = password
    }

    public init(unixSocketPath: String, password: String? = nil) {
        self.host = unixSocketPath
        self.port = 0
        self.unixSocketPath = unixSocketPath
        self.password = password
        self.tls = .disable
    }

    var limits: RedisParser.Limits {
        var limits = RedisParser.Limits()
        limits.maxBulkBytes = maxBulkBytes
        limits.maxElements = maxReplyElements
        return limits
    }
}

/// Why a Redis operation did not complete.
public enum RedisClientError: Error, Equatable {
    /// The connection could not be made.
    case connect(OutboundError)
    /// The server would not authenticate, or refused the database.
    case handshake(RedisHandshakeError)
    /// The server went away, or the connection can no longer be trusted.
    case closed
    case timedOut
    /// Every connection in the pool stayed in use for the pool's
    /// `acquireTimeoutMilliseconds`.
    case poolTimedOut
    case cancelled
    /// A reply that is not RESP, or past a limit.
    case protocolViolation(RedisProtocolError)
    /// The server refused the command: `WRONGTYPE`, `NOPERM`, `OOM`. The
    /// connection is fine.
    case server(RedisServerError)
    /// A reply that is not the shape the method asked for.
    case unexpectedReply(RedisValue)
    /// The connection failed with the command's bytes already written, so
    /// whether the server ran it is not known. A `SET` sent again would be
    /// the same `SET`; an `INCR` sent again would count twice, and a lost
    /// reply to `EXEC` does not mean the transaction was rolled back. So
    /// this is where a retry stops and the caller decides.
    indirect case unknownOutcome(RedisClientError)
    /// A batch failed part-way. `replies` holds the answer to each command
    /// that was answered, at its place in the batch, and nil for each that
    /// was not; the error is why the rest failed, `unknownOutcome` when they
    /// may have run. What was answered was settled -- run, or refused -- so
    /// sending the whole batch again would repeat it: send the rest, if
    /// anything.
    indirect case incomplete(replies: [RedisValue?], RedisClientError)
}

extension RedisClientError {
    /// What went wrong, with `unknownOutcome` taken off: the connection
    /// closed, or timed out, or whatever it was.
    public var cause: RedisClientError {
        switch self {
        case .unknownOutcome(let inner): return inner.cause
        case .incomplete(_, let inner): return inner.cause
        default: return self
        }
    }

    /// Whether the command -- or any command of the batch -- may already have
    /// run. Nothing else is known about it: it is not that it did, and not
    /// that it did not. A batch part-answered may have run if anything in it
    /// was answered with other than a refusal.
    public var mayHaveRun: Bool {
        switch self {
        case .unknownOutcome:
            return true
        case .incomplete(let replies, let inner):
            if inner.mayHaveRun { return true }
            return replies.contains { reply in
                guard let reply else { return false }
                if case .error = reply { return false }
                return true
            }
        default:
            return false
        }
    }

    /// The failure without the part-answers, for a transaction: MULTI's OK
    /// and a QUEUED are not answers anyone asked for, and a transaction ran
    /// whole or not at all.
    var withoutReplies: RedisClientError {
        if case .incomplete(_, let inner) = self { return inner }
        return self
    }

    /// `error`, carrying `replies` if any of them were answered.
    static func settled(_ replies: [RedisValue?], _ error: RedisClientError) -> RedisClientError {
        guard replies.contains(where: { $0 != nil }) else { return error }
        return .incomplete(replies: replies, error)
    }

    /// The same failure, marked as having happened after the bytes went out
    /// -- if it is one where that makes the outcome unknowable.
    ///
    /// A connection that closed or timed out with the command written is the
    /// case this is for. A reply that could not be read, or one the server
    /// refused, is not: the server answered, so the command ran, and what is
    /// unknown is only what it said about it.
    func afterSending() -> RedisClientError {
        switch self {
        case .closed, .timedOut, .cancelled: return .unknownOutcome(self)
        default: return self
        }
    }
}

/// What may be sent again after a failure that leaves it unknown whether the
/// server ran the command.
///
/// This is only about the uncertain case. A command that never reached the
/// server -- the connection refused, the pool timed out, the write failed on
/// its first byte -- is always sent again, whatever this says, because
/// sending it again cannot repeat anything.
public enum RedisReplay: Sendable, Equatable {
    /// Commands that only read. A write whose outcome is unknown is reported
    /// as `unknownOutcome` rather than repeated. The default.
    case reads
    /// Everything, for a cache where doing a write twice costs nothing.
    case anything
    /// Nothing: any failure after the bytes went out is the caller's.
    case nothing
}

extension RedisReplay {
    /// Whether `commands` may be sent again after `error`.
    func allows(_ error: RedisClientError, _ commands: [RedisCommand]) -> Bool {
        guard error.mayHaveRun else { return true }
        switch self {
        case .anything: return true
        case .nothing: return false
        case .reads: return RedisReads.only(commands)
        }
    }
}

/// One connection to a Redis server.
final class RedisConnection {
    let socket: OutboundSocket
    let configuration: RedisConfiguration
    /// 3, or 2 for a server without HELLO.
    let protocolVersion: Int
    /// What HELLO said: `version`, `mode`, `role`.
    let server: [String: String]
    private var parser: RedisParser
    private var buffer: ByteBuffer

    /// Whether the session is as the handshake left it, and so fit for the
    /// next caller. Cleared by anything that changes what later commands mean:
    /// a transaction or watch left open, another database, subscribing.
    var reusable = true
    private var inMulti = false
    private var watching = false

    private init(socket: OutboundSocket, configuration: RedisConfiguration,
                 protocolVersion: Int, server: [String: String], parser: RedisParser, buffer: ByteBuffer) {
        self.socket = socket
        self.configuration = configuration
        self.protocolVersion = protocolVersion
        self.server = server
        self.parser = parser
        self.buffer = buffer
    }

    deinit {
        buffer.destroy()
    }

    var isOpen: Bool { socket.isOpen }

    /// Whether the session is outside any MULTI and WATCH.
    var isClean: Bool { reusable && !inMulti && !watching }

    static func connect(_ worker: UnsafeMutablePointer<Worker>,
                        _ configuration: RedisConfiguration) async throws(RedisClientError) -> RedisConnection {
        let ms = configuration.timeoutMilliseconds
        let socket: OutboundSocket
        do {
            // Keyed apart from every HTTP connection to the same place.
            if let path = configuration.unixSocketPath {
                socket = try await Worker.connect(worker, path: path, tls: "\u{0}redis", milliseconds: ms)
            } else {
                socket = try await Worker.connect(worker, name: configuration.host, port: configuration.port,
                                                  tls: "\u{0}redis", milliseconds: ms)
            }
        } catch {
            throw .connect(error)
        }
        do throws(RedisClientError) {
            if configuration.tls == .require {
                do {
                    try await socket.startTLS(hostname: configuration.host, caFile: configuration.caFile,
                                              alpn: "", milliseconds: ms)
                } catch {
                    throw RedisClientError.connect(error)
                }
            }
            var parser = RedisParser(limits: configuration.limits)
            var buffer = ByteBuffer(capacity: 4096)
            var handshake = RedisHandshake(username: configuration.username, password: configuration.password,
                                           clientName: configuration.clientName,
                                           database: configuration.database)
            var command = handshake.start()
            do throws(RedisClientError) {
                while true {
                    try await writeAll(socket, command.bytes(), ms)
                    let reply = try await readValue(socket, &parser, &buffer, ms)
                    let step: RedisStep
                    do {
                        step = try handshake.receive(reply)
                    } catch {
                        throw RedisClientError.handshake(error)
                    }
                    switch step {
                    case .send(let next):
                        command = next
                    case .ready:
                        // Nothing may follow unasked: bytes left over would be
                        // read as the first command's reply.
                        guard buffer.readableBytes == 0, !parser.isMidReply else {
                            throw RedisClientError.protocolViolation(.badValue)
                        }
                        return RedisConnection(socket: socket, configuration: configuration,
                                               protocolVersion: handshake.protocolVersion,
                                               server: handshake.server, parser: parser, buffer: buffer)
                    }
                }
            } catch {
                buffer.destroy()
                throw error
            }
        } catch {
            socket.close()
            throw error
        }
    }

    /// Writes every command at once, then reads a reply for each, in order.
    /// A command the server refused is an `.error` among the replies; only a
    /// failure of the connection throws.
    ///
    /// A failure with bytes already written throws `unknownOutcome`, because
    /// from here the command having run and its reply having been lost look
    /// the same. A failure before the first byte throws plainly: that one the
    /// server never saw.
    func send(_ commands: [RedisCommand], milliseconds: UInt64? = nil) async throws(RedisClientError) -> [RedisValue] {
        guard !commands.isEmpty else { return [] }
        let ms = milliseconds ?? configuration.timeoutMilliseconds
        var out = ByteBuffer(capacity: 256)
        for command in commands { command.write(into: &out) }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        var sent = 0
        var replies: [RedisValue] = []
        do {
            try await RedisConnection.writeAll(socket, bytes, ms, sent: &sent)
            replies.reserveCapacity(commands.count)
            while replies.count < commands.count {
                let reply = try await next(ms)
                // Out of band -- a tracking invalidation -- and not the answer
                // to anything sent.
                if case .push = reply { continue }
                note(commands[replies.count], reply)
                replies.append(reply)
            }
            return replies
        } catch {
            // A command half answered leaves a stream nobody can pick up.
            close()
            let failure = sent > 0 ? error.afterSending() : error
            // What was read before it failed was answered, and is the
            // caller's: those commands ran or were refused, and saying only
            // "unknown" would have them sent again.
            guard !replies.isEmpty else { throw failure }
            let answered = replies.map { Optional($0) }
            throw .incomplete(replies: answered + Array(repeating: nil, count: commands.count - replies.count),
                              failure)
        }
    }

    /// The next value the server sends, whatever it is.
    func next(_ milliseconds: UInt64) async throws(RedisClientError) -> RedisValue {
        try await RedisConnection.readValue(socket, &parser, &buffer, milliseconds)
    }

    /// Writes bytes without reading anything back.
    func write(_ commands: [RedisCommand]) async throws(RedisClientError) {
        var out = ByteBuffer(capacity: 128)
        for command in commands { command.write(into: &out) }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        var sent = 0
        do {
            try await RedisConnection.writeAll(socket, bytes, configuration.timeoutMilliseconds, sent: &sent)
        } catch {
            close()
            throw sent > 0 ? error.afterSending() : error
        }
    }

    /// Keeps track of what a command did to the session.
    private func note(_ command: RedisCommand, _ reply: RedisValue) {
        let failed: Bool
        if case .error = reply { failed = true } else { failed = false }
        switch command.name {
        case "MULTI":
            if !failed { inMulti = true }
        case "EXEC", "DISCARD":
            // Either way the transaction is over, and so is any watch.
            inMulti = false
            watching = false
        case "WATCH":
            if !failed { watching = true }
        case "UNWATCH":
            if !failed { watching = false }
        case "SELECT", "SUBSCRIBE", "PSUBSCRIBE", "SSUBSCRIBE", "MONITOR", "HELLO",
             "AUTH", "RESET", "QUIT", "READONLY", "READWRITE":
            // What later commands mean, or whether they are answered, may have
            // changed. Not worth modelling: the connection is simply not
            // handed on.
            reusable = false
        case "CLIENT":
            // CLIENT ID, INFO, LIST and KILL only look. These change the
            // session: whether replies come, what is tracked, its name.
            guard command.arguments.count > 1 else { break }
            let sub = String(decoding: command.arguments[1].map { $0 >= 97 && $0 <= 122 ? $0 - 32 : $0 },
                             as: UTF8.self)
            if ["REPLY", "TRACKING", "CACHING", "SETNAME", "SETINFO", "NO-EVICT", "NO-TOUCH"].contains(sub) {
                reusable = false
            }
        default:
            break
        }
    }

    func close() {
        socket.close()
    }

    // MARK: Bytes

    private static func readValue(_ socket: OutboundSocket, _ parser: inout RedisParser,
                                  _ buffer: inout ByteBuffer, _ ms: UInt64) async throws(RedisClientError) -> RedisValue {
        while true {
            if buffer.readableBytes > 0 {
                let outcome: RedisParser.Outcome
                let consumed: Int
                do {
                    (outcome, consumed) = try parser.parse(buffer.readPointer, buffer.readableBytes)
                } catch {
                    throw .protocolViolation(error)
                }
                buffer.consume(consumed)
                if case .value(let value) = outcome { return value }
            }
            try await readMore(socket, &buffer, ms)
        }
    }

    private static func readMore(_ socket: OutboundSocket, _ buffer: inout ByteBuffer,
                                 _ ms: UInt64) async throws(RedisClientError) {
        while true {
            if !socket.hasBufferedInput {
                do {
                    try await socket.readable(milliseconds: ms)
                } catch {
                    throw map(error)
                }
            }
            buffer.reserve(16384)
            let n: Int
            do {
                n = try socket.read(into: UnsafeMutableRawBufferPointer(
                    start: buffer.writePointer, count: buffer.writableBytes))
            } catch {
                throw map(error)
            }
            if n > 0 {
                buffer.advanceWriter(n)
                return
            }
        }
    }

    private static func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8],
                                 _ ms: UInt64) async throws(RedisClientError) {
        var sent = 0
        try await writeAll(socket, bytes, ms, sent: &sent)
    }

    /// The same, reporting how many bytes reached the kernel before it
    /// failed. Nothing reaching it is the one case where the server certainly
    /// did not see the command; past that the answer is not knowable here.
    private static func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8],
                                 _ ms: UInt64, sent: inout Int) async throws(RedisClientError) {
        while sent < bytes.count {
            let n: Int
            do {
                n = try bytes.withUnsafeBytes { raw in
                    try socket.write(UnsafeRawBufferPointer(rebasing: raw[sent...]))
                }
            } catch {
                throw map((error as? OutboundError) ?? .failed(0))
            }
            sent += n
            if sent < bytes.count {
                do {
                    try await socket.writable(milliseconds: ms)
                } catch {
                    throw map(error)
                }
            }
        }
    }

    private static func map(_ error: OutboundError) -> RedisClientError {
        switch error {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default: return .closed
        }
    }
}
