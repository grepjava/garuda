//===----------------------------------------------------------------------===//
// PostgreSQL connections on the worker's poller.
//
// The protocol is GarudaPostgres's: messages framed and interpreted there,
// with no socket in sight. This file only moves bytes -- opens the connection,
// negotiates TLS, and hands each whole message to whichever machine is in
// progress, writing what it says to write.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
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
    /// A unix socket to connect to instead of `host` and `port`: either the
    /// socket itself, or the directory PostgreSQL keeps it in, which is what
    /// `unix_socket_directories` names and what libpq's `host=/...` means.
    public var unixSocketPath: String?
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

    /// A server on this machine, over a unix socket.
    ///
    /// TLS is `.disable`, as it is for libpq: a socket has no network for
    /// anyone to be on. `peer` and `trust` authentication need no password,
    /// so it is empty unless given.
    public init(unixSocketPath: String, user: String, password: String = "",
                database: String? = nil, port: UInt16 = 5432) {
        self.host = unixSocketPath
        self.port = port
        self.unixSocketPath = unixSocketPath
        self.user = user
        self.password = password
        self.database = database
        self.tls = .disable
    }

    /// The socket to connect to: the path as given when it names the socket
    /// itself, and the directory's `.s.PGSQL.<port>` when it names a
    /// directory -- which is how PostgreSQL names its own.
    var socketPath: String? {
        guard let path = unixSocketPath else { return nil }
        if path.contains(".s.PGSQL.") { return path }
        let base = path.hasSuffix("/") ? String(path.dropLast()) : path
        return "\(base)/.s.PGSQL.\(port)"
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
    /// The server's process ID for this session, from BackendKeyData: what a
    /// notification this session sent carries as its sender.
    let processID: Int32
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
        var columns: [PostgresColumn] {
            didSet { formats = PostgresBinary.resultFormats(columns) }
        }
        /// That RowDescription as it came on the wire. The next one that is
        /// the same is these columns again (`PostgresQuery.knownDescription`).
        var description: [UInt8]
        /// The format to ask for each column in, worked out once from
        /// `columns` rather than for every run.
        private(set) var formats: [Int16]
        /// When it was last used, for evicting the least recent.
        var used: UInt64

        init(name: String, columns: [PostgresColumn], description: [UInt8], used: UInt64) {
            self.name = name
            self.columns = columns
            self.description = description
            self.formats = PostgresBinary.resultFormats(columns)
            self.used = used
        }
    }

    private(set) var prepared: [StatementKey: PreparedStatement] = [:]
    /// Set by a listener, which is the only owner with somewhere to put a
    /// notification. A pooled connection drops them: whoever ran `LISTEN` on
    /// one has already handed it back.
    var collectsNotifications = false
    private var notifications: [PostgresNotification] = []
    /// Where a listener reads asynchronous messages, kept between calls so
    /// that whatever arrived beyond the message just handled is not lost.
    /// Allocated on first use, which is never for a pooled connection.
    private var listening = ByteBuffer()
    /// What a statement is written into and its answer read from, kept from
    /// one statement to the next instead of allocated for each.
    private var sending = ByteBuffer()
    private var receiving = ByteBuffer()
    private var uses: UInt64 = 0
    private var nextStatement = 0
    /// Statements the server holds that the cache has let go of, closed with
    /// the next query.
    private var toClose: [String] = []

    init(socket: OutboundSocket, configuration: PostgresConfiguration,
         parameters: [String: String], processID: Int32 = 0) {
        self.socket = socket
        self.configuration = configuration
        self.parameters = parameters
        self.processID = processID
    }

    /// Connects, negotiates TLS if required, and authenticates.
    static func connect(_ worker: UnsafeMutablePointer<Worker>,
                        _ configuration: PostgresConfiguration) async throws(PostgresClientError) -> PostgresConnection {
        let ms = configuration.timeoutMilliseconds
        let socket: OutboundSocket
        do {
            // Keyed apart from every HTTP connection to the same place.
            if let path = configuration.socketPath {
                // A socket carries no TLS: there is no network on it to
                // encrypt, and PostgreSQL will not negotiate it there.
                guard configuration.tls == .disable else { throw PostgresClientError.tlsUnavailable }
                socket = try await Worker.connect(worker, path: path, tls: "\u{0}postgres",
                                                  milliseconds: ms)
            } else {
                socket = try await Worker.connect(worker, name: configuration.host,
                                                  port: configuration.port,
                                                  tls: "\u{0}postgres", milliseconds: ms)
            }
        } catch let error as PostgresClientError {
            throw error
        } catch let error as OutboundError {
            throw .connect(error)
        } catch {
            throw .closed
        }

        do {
            var encrypted = false
            if configuration.tls == .require, configuration.socketPath == nil {
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
                                              parameters: startup.parameters,
                                              processID: startup.processID)
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
        var formats: [Int16] = []
        var knownDescription: [UInt8] = []
        var knownColumns: [PostgresColumn] = []
        uses &+= 1
        if configuration.statementCacheCapacity > 0 {
            // Looked up once, and updated through the index: the SQL is
            // hashed for the lookup and not again.
            if let found = prepared.index(forKey: key) {
                let statement = prepared.values[found]
                name = statement.name
                prepare = false
                // The types its last result had. Should they have changed,
                // the server refuses the plan (0A000) before sending a row, so
                // a format chosen for the old type never meets the new one.
                formats = statement.formats
                knownDescription = statement.description
                knownColumns = statement.columns
                prepared.values[found].used = uses
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
                                  prepare: prepare, resultFormats: formats, closing: closing,
                                  knownDescription: knownDescription, knownColumns: knownColumns)
        // Moved out and back rather than used in place across the awaits
        // below: one owner of each allocation at a time.
        var out = sending
        sending = ByteBuffer()
        var buffer = receiving
        receiving = ByteBuffer()
        defer {
            out.clear()
            sending = out
            buffer.clear()
            receiving = buffer
        }
        do { try query.write(into: &out) } catch { throw .postgres(error) }
        do {
            try await PostgresConnection.writeAll(socket, &out, ms)
            buffer.reserve(8192)
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
                    if collectsNotifications {
                        // Kept whether the statement succeeded or not: a
                        // notification that arrived while it ran was still
                        // sent.
                        notifications.append(contentsOf: query.notifications)
                        // And what came after ReadyForQuery in the same read,
                        // which on a listening connection is a notification
                        // the server sent as the statement ended -- not a
                        // reply nobody asked for. Refusing it here would end
                        // a listener for being told something a moment too
                        // late.
                        keepForListener(&buffer)
                    }
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
            prepared[key] = PreparedStatement(name: name, columns: query.rows.columns,
                                              description: query.freshDescription ?? [], used: uses)
        } else if let description = query.freshDescription {
            // Only when the description changed: the same one again is the
            // columns already kept.
            prepared[key]?.columns = query.rows.columns
            prepared[key]?.description = description
        }
        // Statements the session dropped wholesale. Their names would each be
        // refused once and retried; forgetting them now saves the round trips.
        if case .success(let rows) = query.result(), rows.tag == "DISCARD ALL" || rows.tag == "DEALLOCATE ALL" {
            prepared.removeAll()
        }
    }

    /// What arrived while this connection's own statements ran, in order,
    /// and clears it. For a listener, which has nowhere else to look.
    func takeNotifications() -> [PostgresNotification] {
        defer { notifications.removeAll(keepingCapacity: true) }
        return notifications
    }

    /// Moves what is left of a query's buffer to where a listener reads, in
    /// order, after the notifications the query itself collected.
    private func keepForListener(_ buffer: inout ByteBuffer) {
        let count = buffer.readableBytes
        guard count > 0 else { return }
        listening.reserve(count)
        UnsafeMutableRawBufferPointer(start: listening.writePointer, count: count)
            .copyMemory(from: UnsafeRawBufferPointer(start: buffer.readPointer, count: count))
        listening.advanceWriter(count)
        buffer.consume(count)
    }

    /// Waits for the server to say something unasked -- a notification -- and
    /// returns it, or nil when nothing came within `milliseconds`.
    ///
    /// For a listener, whose connection has nothing else in flight. A notice
    /// or a changed setting is passed over and the wait goes on; anything else
    /// is a server sending a reply to a statement nobody ran, after which the
    /// connection is not to be trusted.
    func nextNotification(milliseconds: UInt64) async throws(PostgresClientError) -> PostgresNotification? {
        let deadline = av_monotonic_ms() + milliseconds
        // Moved out and back rather than passed as `inout` across an await:
        // one owner of the allocation at a time.
        var buffer = listening
        listening = ByteBuffer()
        defer { listening = buffer }
        while true {
            // What is already buffered first: several notifications can
            // arrive in one read, and the buffer holds nothing at all until
            // the first one does.
            var framed: (type: UInt8, reader: PostgresReader)? = nil
            if buffer.readableBytes > 0 {
                switch PostgresBackend.frame(buffer.readPointer, buffer.readableBytes,
                                             maxLength: configuration.maxMessageBytes) {
                case .frame(let frame):
                    framed = (frame.type, PostgresReader(buffer.readPointer + frame.bodyOffset,
                                                         frame.bodyLength))
                case .failure(let error):
                    socket.close()
                    throw .postgres(.protocolViolation(error))
                case .incomplete:
                    break
                }
            }
            guard let (type, reader) = framed else {
                let now = av_monotonic_ms()
                guard now < deadline else { return nil }
                do {
                    try await PostgresConnection.readMore(socket, &buffer, deadline - now)
                } catch .timedOut {
                    return nil
                } catch {
                    socket.close()
                    throw error
                }
                continue
            }
            var notification: PostgresNotification? = nil
            var failure: PostgresError? = nil
            switch type {
            case UInt8(ascii: "A"):
                do { notification = try PostgresBackend.notification(reader) }
                catch { failure = .protocolViolation(error) }
            // A notice -- a warning, a raised message -- or a setting that
            // changed under the session. Neither ends it.
            case UInt8(ascii: "N"), UInt8(ascii: "S"):
                break
            default:
                failure = .unexpectedMessage(type)
            }
            buffer.consume(5 + reader.count)
            if let failure {
                socket.close()
                throw .postgres(failure)
            }
            if let notification { return notification }
        }
    }

    func close() {
        listening.destroy()
        sending.destroy()
        receiving.destroy()
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

    static func readMore(_ socket: OutboundSocket, _ buffer: inout ByteBuffer,
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

    /// Sends everything in `out`, consuming it as it goes.
    private static func writeAll(_ socket: OutboundSocket, _ out: inout ByteBuffer,
                                 _ ms: UInt64) async throws(PostgresClientError) {
        while out.readableBytes > 0 {
            let n: Int
            do {
                n = try socket.write(UnsafeRawBufferPointer(start: out.readPointer,
                                                            count: out.readableBytes))
            } catch {
                throw map(error)
            }
            out.consume(n)
            if out.readableBytes > 0 {
                do {
                    try await socket.writable(milliseconds: ms)
                } catch {
                    throw map(error)
                }
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

extension PostgresConnection {
    /// Runs a `COPY ... TO STDOUT` and hands each chunk of it to `chunk` as it
    /// arrives.
    ///
    /// A chunk is not a row: the server sends a byte stream and splits it
    /// where it likes. `PostgresCopyText.rows` makes rows of it, or
    /// `copyOut(_:rows:)` does that for you.
    ///
    /// A `chunk` that throws ends the copy by closing the connection: a COPY
    /// out cannot be stopped politely, and reading a table to its end to be
    /// tidy about it would be worse.
    @discardableResult
    func copyOut(_ sql: String, _ chunk: (ArraySlice<UInt8>) throws -> Void) async throws -> Int {
        var copy = PostgresCopy(sql)
        let ms = configuration.timeoutMilliseconds
        let bytes: [UInt8]
        do { bytes = try copy.messages() } catch { throw PostgresClientError.postgres(error) }
        var thrown: (any Error)? = nil
        do {
            try await PostgresConnection.writeAll(socket, bytes, ms)
            var buffer = ByteBuffer(capacity: 16_384)
            defer { buffer.destroy() }
            while true {
                let (type, reader) = try await PostgresConnection.nextMessage(socket, &buffer, configuration)
                let step: PostgresCopyStep
                do {
                    step = try copy.receive(type, reader)
                } catch {
                    throw PostgresClientError.postgres(error)
                }
                if case .data(let range) = step, thrown == nil {
                    // The reader's bytes belong to the buffer, which the next
                    // read may move: the closure sees them before then.
                    let raw = UnsafeBufferPointer(start: reader.base + range.lowerBound,
                                                  count: range.count)
                    do {
                        try chunk(ArraySlice(raw))
                    } catch {
                        thrown = error
                    }
                }
                buffer.consume(5 + reader.count)
                if thrown != nil {
                    // Nothing can be said to stop it, so the connection goes.
                    socket.close()
                    break
                }
                if step == .finished {
                    transactionStatus = copy.transactionStatus
                    if collectsNotifications { notifications.append(contentsOf: copy.notifications) }
                    guard buffer.readableBytes == 0 else {
                        throw PostgresClientError.postgres(.unexpectedMessage(buffer.readPointer[0]))
                    }
                    switch copy.result() {
                    case .success: return copy.copied
                    case .failure(let error): throw PostgresClientError.postgres(error)
                    }
                }
            }
        } catch let error as PostgresClientError {
            if case .postgres(.server) = error {} else { socket.close() }
            throw error
        } catch {
            socket.close()
            throw error
        }
        throw thrown ?? PostgresClientError.closed
    }

    /// Runs a `COPY ... FROM STDIN`, asking `next` for data until it returns
    /// nil, and returns how many rows the server took.
    ///
    /// A `next` that throws tells the server so with CopyFail, which makes it
    /// refuse the whole load rather than keep half of it, and then the error
    /// is thrown on.
    @discardableResult
    func copyIn(_ sql: String, _ next: () throws -> [UInt8]?) async throws -> Int {
        var copy = PostgresCopy(sql)
        let ms = configuration.timeoutMilliseconds
        let bytes: [UInt8]
        do { bytes = try copy.messages() } catch { throw PostgresClientError.postgres(error) }
        var thrown: (any Error)? = nil
        do {
            try await PostgresConnection.writeAll(socket, bytes, ms)
            var buffer = ByteBuffer(capacity: 8_192)
            defer { buffer.destroy() }
            while true {
                let (type, reader) = try await PostgresConnection.nextMessage(socket, &buffer, configuration)
                let step: PostgresCopyStep
                do {
                    step = try copy.receive(type, reader)
                } catch {
                    throw PostgresClientError.postgres(error)
                }
                buffer.consume(5 + reader.count)
                switch step {
                case .ready:
                    // The server is taking data. Whatever `next` gives goes in
                    // one message at a time, and its size is the caller's
                    // choice: a row, a batch, a file's worth.
                    var out = ByteBuffer(capacity: 16_384)
                    defer { out.destroy() }
                    while true {
                        let piece: [UInt8]?
                        do {
                            piece = try next()
                        } catch {
                            thrown = error
                            break
                        }
                        guard let piece, !piece.isEmpty else { break }
                        out.clear()
                        PostgresFrontend.copyData(piece, into: &out)
                        try await PostgresConnection.writeAll(
                            socket,
                            Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes)),
                            ms)
                    }
                    out.clear()
                    if let thrown {
                        // Said out loud, so the server discards the load
                        // rather than committing what arrived before the
                        // trouble.
                        _ = PostgresFrontend.copyFail("the client stopped: \(thrown)", into: &out)
                    } else {
                        PostgresFrontend.copyDone(into: &out)
                    }
                    try await PostgresConnection.writeAll(
                        socket,
                        Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes)), ms)
                case .finished:
                    transactionStatus = copy.transactionStatus
                    if collectsNotifications { notifications.append(contentsOf: copy.notifications) }
                    guard buffer.readableBytes == 0 else {
                        throw PostgresClientError.postgres(.unexpectedMessage(buffer.readPointer[0]))
                    }
                    if let thrown { throw thrown }
                    switch copy.result() {
                    case .success: return copy.copied
                    case .failure(let error): throw PostgresClientError.postgres(error)
                    }
                case .wait, .data, .done:
                    continue
                }
            }
        } catch let error as PostgresClientError {
            if case .postgres(.server) = error {} else { socket.close() }
            throw error
        } catch {
            // A CopyFail was sent and the server's answer read, so the
            // connection is fine; it is the caller's error that is thrown.
            throw error
        }
    }
}

