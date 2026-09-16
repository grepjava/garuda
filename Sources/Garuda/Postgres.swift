//===----------------------------------------------------------------------===//
// PostgreSQL connections on the worker's poller.
//
// The protocol is GarudaPostgres's: messages framed and interpreted there,
// with no socket in sight. This file only moves bytes -- opens the connection,
// negotiates TLS, and hands each whole message to whichever machine is in
// progress, writing what it says to write.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaPostgres

/// Where a PostgreSQL server is and how to reach it.
public struct PostgresConfiguration: Sendable {
    public enum TLS: Sendable {
        /// Plaintext. For a server on this machine, or a network nobody else is on.
        case disable
        /// Encrypted and verified, or not at all.
        case require
    }

    public var host: String
    public var port: UInt16
    public var user: String
    public var password: String
    public var database: String?
    /// `.require` unless changed. There is no "prefer": trying TLS and falling
    /// back to plaintext when the server declines lets anyone on the path
    /// decline for it.
    public var tls: TLS = .require
    /// A trust store for `.require`. Empty means the system's.
    public var caFile = ""
    /// Allows a cleartext password -- over TLS only, whatever this says.
    public var allowCleartextPassword = false
    public var timeoutMilliseconds: UInt64 = 10_000
    /// Rows a single result may hold before the query fails.
    public var maxRows = 1_000_000
    /// The largest single message the server may send.
    public var maxMessageBytes = 64 * 1024 * 1024

    public init(host: String, port: UInt16 = 5432, user: String, password: String,
                database: String? = nil) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
    }
}

/// Why a PostgreSQL operation did not complete.
public enum PostgresClientError: Error, Equatable {
    /// The connection could not be made.
    case connect(OutboundError)
    /// TLS was required and the server does not offer it.
    case tlsUnavailable
    /// The server went away, or sent something after which the connection
    /// cannot be trusted.
    case closed
    case timedOut
    case cancelled
    /// The protocol, authentication or the server itself refused.
    case postgres(PostgresError)
}

/// One session with a PostgreSQL server.
///
/// Internal while the pool and the public query API settle on top of it.
struct PostgresConnection {
    let socket: OutboundSocket
    let configuration: PostgresConfiguration
    let parameters: [String: String]

    /// Connects, negotiates TLS if required, and authenticates.
    static func connect(_ worker: UnsafeMutablePointer<Worker>,
                        _ configuration: PostgresConfiguration) async throws(PostgresClientError) -> PostgresConnection {
        let ms = configuration.timeoutMilliseconds
        let socket: OutboundSocket
        do {
            // Keyed apart from every HTTP connection to the same place.
            socket = try await Worker.connect(worker, name: configuration.host,
                                              port: configuration.port,
                                              tls: "\u{0}postgres", milliseconds: ms)
        } catch {
            throw .connect(error)
        }

        do {
            var encrypted = false
            if configuration.tls == .require {
                var out = ByteBuffer(capacity: 16)
                PostgresFrontend.sslRequest(into: &out)
                let request = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
                out.destroy()
                try await writeAll(socket, request, ms)
                // One byte, and exactly one. CVE-2021-23222 was a client
                // buffering whatever followed the S and later treating it as
                // if it had come through TLS. Reading a single byte leaves
                // anything injected after it for the handshake to reject.
                let answer = try await readByte(socket, ms)
                guard answer == UInt8(ascii: "S") else { throw PostgresClientError.tlsUnavailable }
                do {
                    // PostgreSQL 17 and later refuse an ALPN protocol other
                    // than their own.
                    try await socket.startTLS(hostname: configuration.host,
                                              caFile: configuration.caFile,
                                              alpn: "postgresql", milliseconds: ms)
                } catch {
                    throw PostgresClientError.connect(error)
                }
                encrypted = true
            }

            var policy = PostgresStartup.Policy()
            policy.allowCleartext = configuration.allowCleartextPassword
            policy.encrypted = encrypted
            var startup = PostgresStartup(user: configuration.user, password: configuration.password,
                                          database: configuration.database, policy: policy)
            let first: [UInt8]
            do { first = try startup.start() } catch { throw PostgresClientError.postgres(error) }
            try await writeAll(socket, first, ms)

            var buffer = ByteBuffer(capacity: 4096)
            defer { buffer.destroy() }
            while true {
                let (type, reader) = try await nextMessage(socket, &buffer, configuration)
                let step: PostgresStep
                do {
                    step = try startup.receive(type, reader)
                } catch {
                    throw PostgresClientError.postgres(error)
                }
                buffer.consume(5 + reader.count)
                switch step {
                case .wait: continue
                case .send(let bytes): try await writeAll(socket, bytes, ms)
                case .ready:
                    // Nothing may follow ReadyForQuery unasked. Bytes left
                    // over would be read as the start of the first query's
                    // answer.
                    guard buffer.readableBytes == 0 else {
                        throw PostgresClientError.postgres(.unexpectedMessage(buffer.readPointer[0]))
                    }
                    return PostgresConnection(socket: socket, configuration: configuration,
                                              parameters: startup.parameters)
                }
            }
        } catch let error as PostgresClientError {
            socket.close()
            throw error
        } catch {
            socket.close()
            throw .closed
        }
    }

    /// Runs one statement, with its values sent beside it.
    func query(_ sql: String, _ values: [String?] = []) async throws(PostgresClientError) -> PostgresRows {
        let ms = configuration.timeoutMilliseconds
        var query = PostgresQuery(sql, values, maxRows: configuration.maxRows)
        let bytes: [UInt8]
        do { bytes = try query.messages() } catch { throw .postgres(error) }
        do {
            try await writeAll(socket, bytes, ms)
            var buffer = ByteBuffer(capacity: 8192)
            defer { buffer.destroy() }
            while true {
                let (type, reader) = try await nextMessage(socket, &buffer, configuration)
                let finished: Bool
                do {
                    finished = try query.receive(type, reader)
                } catch {
                    throw PostgresClientError.postgres(error)
                }
                buffer.consume(5 + reader.count)
                if finished {
                    guard buffer.readableBytes == 0 else {
                        throw PostgresClientError.postgres(.unexpectedMessage(buffer.readPointer[0]))
                    }
                    switch query.result() {
                    case .success(let rows): return rows
                    // The server refused this statement and is ready for the
                    // next: the connection is fine, the query is not.
                    case .failure(let error): throw PostgresClientError.postgres(error)
                    }
                }
            }
        } catch let error as PostgresClientError {
            // Anything but the server refusing the statement leaves the
            // connection in a state nobody should use.
            if case .postgres(.server) = error {} else { socket.close() }
            throw error
        } catch {
            socket.close()
            throw .closed
        }
    }

    func close() {
        var out = ByteBuffer(capacity: 8)
        PostgresFrontend.terminate(into: &out)
        let bytes = Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        _ = try? bytes.withUnsafeBytes { try socket.write($0) }
        socket.close()
    }

    var isOpen: Bool { socket.isOpen }

    // MARK: Bytes

    /// Reads until a whole message is buffered, and returns its type and body.
    /// The caller consumes it once it has been handled.
    private static func nextMessage(_ socket: OutboundSocket, _ buffer: inout ByteBuffer,
                                    _ configuration: PostgresConfiguration)
        async throws(PostgresClientError) -> (UInt8, PostgresReader) {
        while true {
            switch PostgresBackend.frame(buffer.readPointer, buffer.readableBytes,
                                         maxLength: configuration.maxMessageBytes) {
            case .frame(let frame):
                return (frame.type, PostgresReader(buffer.readPointer + frame.bodyOffset,
                                                   frame.bodyLength))
            case .failure(let error):
                throw .postgres(.protocolViolation(error))
            case .incomplete:
                try await readMore(socket, &buffer, configuration.timeoutMilliseconds)
            }
        }
    }

    private func nextMessage(_ socket: OutboundSocket, _ buffer: inout ByteBuffer,
                             _ configuration: PostgresConfiguration)
        async throws(PostgresClientError) -> (UInt8, PostgresReader) {
        try await PostgresConnection.nextMessage(socket, &buffer, configuration)
    }

    private static func readMore(_ socket: OutboundSocket, _ buffer: inout ByteBuffer,
                                 _ ms: UInt64) async throws(PostgresClientError) {
        while true {
            if !socket.hasBufferedInput {
                do {
                    try await socket.readable(milliseconds: ms)
                } catch {
                    throw map(error)
                }
            }
            buffer.reserve(8192)
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
            // Readable with nothing to hand over: over TLS a session ticket,
            // not a close -- the read throws for that.
        }
    }

    private static func readByte(_ socket: OutboundSocket, _ ms: UInt64) async throws(PostgresClientError) -> UInt8 {
        var byte: UInt8 = 0
        while true {
            do {
                try await socket.readable(milliseconds: ms)
                let n = try withUnsafeMutableBytes(of: &byte) { try socket.read(into: $0) }
                if n == 1 { return byte }
            } catch {
                throw map((error as? OutboundError) ?? .failed(0))
            }
        }
    }

    private static func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8],
                                 _ ms: UInt64) async throws(PostgresClientError) {
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

    private func writeAll(_ socket: OutboundSocket, _ bytes: [UInt8],
                          _ ms: UInt64) async throws(PostgresClientError) {
        try await PostgresConnection.writeAll(socket, bytes, ms)
    }

    private static func map(_ error: OutboundError) -> PostgresClientError {
        switch error {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        default: return .closed
        }
    }
}
