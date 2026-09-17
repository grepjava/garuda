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
    func send(_ commands: [RedisCommand], milliseconds: UInt64? = nil) async throws(RedisClientError) -> [RedisValue] {
        guard !commands.isEmpty else { return [] }
        let ms = milliseconds ?? configuration.timeoutMilliseconds
        var out = ByteBuffer(capacity: 256)
        for command in commands { command.write(into: &out) }
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        do {
            try await RedisConnection.writeAll(socket, bytes, ms)
            var replies: [RedisValue] = []
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
            throw error
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
        do {
            try await RedisConnection.writeAll(socket, bytes, configuration.timeoutMilliseconds)
        } catch {
            close()
            throw error
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
