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
    /// Statements each connection keeps prepared, by SQL, so a statement run
    /// again skips being parsed and planned. 0 prepares nothing, for a
    /// transaction-pooling proxy such as PgBouncer, where the next statement
    /// may reach a server session that never saw the first.
    public var statementCacheCapacity = 256

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
    /// Every connection in the pool stayed in use for the pool's
    /// `acquireTimeoutMilliseconds`.
    case poolTimedOut
    case cancelled
    /// The protocol, authentication or the server itself refused.
    case postgres(PostgresError)
}

/// One session with a PostgreSQL server.
///
/// A class, because it carries the one piece of session state the pool must
/// see after every statement: whether the session was left inside a
/// transaction.
final class PostgresConnection {
    let socket: OutboundSocket
    let configuration: PostgresConfiguration
    let parameters: [String: String]
    /// As the last ReadyForQuery reported it.
    private(set) var transactionStatus: PostgresTransactionStatus = .idle

    /// A statement kept prepared, by the SQL and the parameter types it was
    /// parsed with: the same SQL with a value of another declared type is
    /// another statement.
    struct StatementKey: Hashable {
        let sql: String
        let types: [UInt32]
    }

    struct PreparedStatement {
        let name: String
        /// The columns its last result described, for choosing formats.
        var columns: [PostgresColumn]
        /// When it was last used, for evicting the least recent.
        var used: UInt64
    }

    private(set) var prepared: [StatementKey: PreparedStatement] = [:]
    private var uses: UInt64 = 0
    private var nextStatement = 0
    /// Statements the server holds that the cache has let go of, closed with
    /// the next query.
    private var toClose: [String] = []

    init(socket: OutboundSocket, configuration: PostgresConfiguration,
         parameters: [String: String]) {
        self.socket = socket
        self.configuration = configuration
        self.parameters = parameters
    }

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

    /// Runs one statement, with text values sent beside it.
    func query(_ sql: String, _ values: [String?]) async throws(PostgresClientError) -> PostgresRows {
        try await query(sql, values: values.map { PostgresValue($0) })
    }

    /// Runs one statement, with its values sent beside it.
    ///
    /// A prepared statement the server no longer has, or can no longer run as
    /// planned, is dropped and the statement run once more from its SQL -- but
    /// only when it failed outside a transaction. There a failed statement has
    /// been rolled back whole, so running it again cannot do anything twice;
    /// inside one, the failure has already failed the transaction.
    func query(_ sql: String, values: [PostgresValue] = []) async throws(PostgresClientError) -> PostgresRows {
        do {
            return try await run(sql, values)
        } catch {
            guard reusedStaleStatement, transactionStatus == .idle else { throw error }
            return try await run(sql, values)
        }
    }

    /// Whether the last statement failed because the prepared statement it
    /// reused was stale: 26000, gone -- `DEALLOCATE`, `DISCARD ALL` -- or
    /// 0A000, which is what the server says when a table under a plan changed
    /// shape ("cached plan must not change result type"). By code, not by that
    /// message, which the server translates.
    private var reusedStaleStatement = false

    private func run(_ sql: String, _ values: [PostgresValue]) async throws(PostgresClientError) -> PostgresRows {
        let ms = configuration.timeoutMilliseconds
        let types = values.contains { $0.declaredType != 0 } ? values.map(\.declaredType) : []
        let key = StatementKey(sql: sql, types: types)
        var name = ""
        var prepare = true
        let formats: [Int16] = []
        uses &+= 1
        if configuration.statementCacheCapacity > 0 {
            if var statement = prepared[key] {
                name = statement.name
                prepare = false
                statement.used = uses
                prepared[key] = statement
            } else {
                if prepared.count >= configuration.statementCacheCapacity,
                   let oldest = prepared.min(by: { $0.value.used < $1.value.used }) {
                    toClose.append(oldest.value.name)
                    prepared.removeValue(forKey: oldest.key)
                }
                name = "garuda_\(nextStatement)"
                nextStatement &+= 1
            }
        }
        let closing = toClose
        toClose.removeAll()
        reusedStaleStatement = false
        var query = PostgresQuery(sql, values, maxRows: configuration.maxRows, statement: name,
                                  prepare: prepare, resultFormats: formats, closing: closing)
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
                    // Recorded whether the statement succeeded or not: a
                    // refused statement inside a transaction leaves it failed,
                    // and that is exactly what must not be handed on.
                    transactionStatus = query.transactionStatus
                    if !name.isEmpty { remember(key, name, prepare: prepare, query) }
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

    /// Keeps what a finished query taught the cache.
    private func remember(_ key: StatementKey, _ name: String, prepare: Bool, _ query: PostgresQuery) {
        if !prepare, case .failure(.server(let fields)) = query.result(),
           fields.code == "26000" || fields.code == "0A000" {
            // Gone, or unusable as planned. The 0A000 one still exists.
            prepared.removeValue(forKey: key)
            if fields.code == "0A000" { toClose.append(name) }
            reusedStaleStatement = true
            return
        }
        if prepare {
            // Refused before it was parsed -- a syntax error, a failed
            // transaction -- and there is nothing to keep.
            guard query.parsed else { return }
            prepared[key] = PreparedStatement(name: name, columns: query.rows.columns, used: uses)
        } else if !query.rows.columns.isEmpty {
            prepared[key]?.columns = query.rows.columns
        }
        // Statements the session dropped wholesale. Their names would each be
        // refused once and retried; forgetting them now saves the round trips.
        if case .success(let rows) = query.result(), rows.tag == "DISCARD ALL" || rows.tag == "DEALLOCATE ALL" {
            prepared.removeAll()
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
