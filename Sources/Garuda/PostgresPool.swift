//===----------------------------------------------------------------------===//
// PostgreSQL for handlers: a pool per worker, values bound beside the SQL, and
// rows decoded straight into types.
//
//     app.state { _ in PostgresPool(configuration) }
//
//     struct User: Decodable, Encodable { let id: Int; let name: String }
//
//     app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws in
//         JSON(try await db.value.first(User.self,
//                                       "select id, name from users where id = $1", id.value))
//     }
//
// A pool belongs to one worker, which is one process with one thread: it is
// built by `app.state` after the fork, and it finds its worker when used
// rather than being handed one, so a handler never holds an engine pointer.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaPostgres
import Tracing

// MARK: - Values

/// A value that can be bound to a `$n` placeholder.
///
/// Most values go as text, which PostgreSQL parses into the placeholder's type
/// -- one format to get right rather than one per type. Bytes go in binary,
/// where text would be hex at twice the size. A value is never written into
/// the SQL itself, so none can become part of the statement.
public protocol PostgresBindable {
    var postgresValue: PostgresValue { get }
}

extension String: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(self) } }
extension Substring: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Int: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Int8: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Int16: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Int32: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Int64: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension UInt: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension UInt8: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension UInt16: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension UInt32: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension UInt64: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Double: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Float: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(String(self)) } }
extension Bool: PostgresBindable { public var postgresValue: PostgresValue { PostgresValue(self ? "true" : "false") } }

extension Optional: PostgresBindable where Wrapped: PostgresBindable {
    public var postgresValue: PostgresValue { self?.postgresValue ?? .null }
}

// MARK: - Errors

extension PostgresClientError {
    /// The SQLSTATE the server refused a statement with -- `23505` for a
    /// unique violation -- or nil when the failure was not the server's
    /// answer. What to branch on, unlike the message, which is localised.
    public var sqlState: String? {
        if case .postgres(.server(let fields)) = self { return fields.code }
        return nil
    }

    /// Whether the server refused the statement for breaking a constraint:
    /// unique, not null, foreign key, check, exclusion -- class 23 of the
    /// SQLSTATE codes.
    public var isConstraintViolation: Bool {
        sqlState.map { $0.hasPrefix("23") } ?? false
    }
}

/// Why a row could not become the type asked for.
///
/// Not a `ResponseError`, deliberately: a column the type expects and the
/// query did not return is the program's mistake, not the client's, and is a
/// 500 and a log line like any other.
public enum PostgresDecodingError: Error, Equatable {
    case missingColumn(String)
    case notConvertible(column: String, value: String, expected: String)
    case null(column: String)
    case unsupported(String)
}

// MARK: - The pool

/// Connections to one PostgreSQL server, for one worker.
public final class PostgresPool: @unchecked Sendable {
    public let configuration: PostgresConfiguration
    public let maxConnections: Int
    /// How long a statement waits for a connection when every one is in use,
    /// before failing with `poolTimedOut`.
    public let acquireTimeoutMilliseconds: UInt64

    private var idle: [PostgresConnection] = []
    /// Connections that exist, idle or in use -- including one being opened.
    private var open = 0
    /// The statements waiting for a connection, and the connections released
    /// straight to them.
    private var waiting = PoolWaiters<PostgresConnection>()

    /// `acquireTimeoutMilliseconds` defaults to the configuration's timeout.
    public init(_ configuration: PostgresConfiguration, maxConnections: Int = 8,
                acquireTimeoutMilliseconds: UInt64? = nil) {
        precondition(maxConnections > 0, "a pool needs room for at least one connection")
        self.configuration = configuration
        self.maxConnections = maxConnections
        self.acquireTimeoutMilliseconds = acquireTimeoutMilliseconds ?? configuration.timeoutMilliseconds
    }

    // The statements run where their caller runs -- a handler, on its
    // worker's task -- rather than first asking the runtime to move them to
    // the generic executor, which for a task with an executor preference is
    // a lock taken per call: `nonisolated(nonsending)`, here and down the
    // connection.

    /// Every row, decoded.
    nonisolated(nonsending)
    public func query<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> [Row] {
        let rows = try await run(sql, values)
        return try decodeAll(type, rows)
    }

    /// The first row decoded, or nil if there were none.
    nonisolated(nonsending)
    public func first<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> Row? {
        let rows = try await run(sql, values)
        guard rows.count > 0 else { return nil }
        return try decodeRow(type, rows, 0, columnIndex(rows), PostgresRowShape(type, rows))
    }

    /// Runs a statement and returns how many rows it affected.
    @discardableResult
    nonisolated(nonsending)
    public func execute(_ sql: String, _ values: any PostgresBindable...) async throws -> Int {
        try await run(sql, values).affected
    }

    /// Runs `body` in a transaction on one connection: committed if `body`
    /// returns, rolled back if it throws.
    ///
    /// ```
    /// try await db.value.transaction { tx in
    ///     try await tx.execute("update accounts set balance = balance - $1 where id = $2", amount, from)
    ///     try await tx.execute("update accounts set balance = balance + $1 where id = $2", amount, to)
    /// }
    /// ```
    ///
    /// A transaction a statement has already failed is rolled back and
    /// reported, never committed -- even if `body` caught the error and
    /// returned normally. PostgreSQL answers COMMIT on a failed transaction by
    /// rolling it back and saying ROLLBACK, not by failing, so a caller that
    /// swallowed one error would otherwise believe work was saved that was not.
    nonisolated(nonsending)
    public func transaction<Result>(_ body: (PostgresTransaction) async throws -> Result) async throws -> Result {
        let connection = try await acquire()
        // Tracked rather than inferred from the error. An earlier draft let
        // errors carrying 25P02 through untouched, meaning its own -- but
        // PostgreSQL raises 25P02 itself for any statement in an aborted
        // transaction, and that one would have skipped the rollback and the
        // release and lost a pool slot for good.
        var released = false
        do {
            _ = try await connection.query("begin")
            let result = try await body(PostgresTransaction(connection: connection))
            // A failed transaction needs no check of its own here. COMMIT on
            // one comes back tagged ROLLBACK, and the tag is checked below --
            // a separate pre-check survived mutation testing with nothing
            // failing, because that tag check caught every case it did.
            let rows = try await connection.query("commit")
            release(connection)
            released = true
            guard rows.tag == "COMMIT" else {
                var fields = PostgresErrorFields()
                fields.code = "25P02"
                fields.message = "the server rolled the transaction back instead of committing it"
                throw PostgresClientError.postgres(.server(fields))
            }
            return result
        } catch {
            if !released {
                if connection.isOpen && connection.transactionStatus != .idle {
                    _ = try? await connection.query("rollback")
                }
                release(connection)
            }
            throw error
        }
    }

    /// Closes every idle connection. For `app.state`'s shutdown.
    public func close() {
        for connection in idle { connection.close() }
        idle.removeAll()
        for connection in waiting.takeAllHandedOver() { connection.close() }
        open = 0
    }

    // MARK: Connections

    private nonisolated(nonsending) func run(_ sql: String, _ values: [any PostgresBindable])
        async throws(PostgresClientError) -> PostgresRows {
        guard currentWorker != nil else {
            // Only reachable by calling from a thread that is not a worker's,
            // which nothing in a handler can do.
            throw .cancelled
        }
        // Opened before the wait for a connection, which is part of what the
        // statement cost its caller.
        let span = startPostgresSpan(sql, configuration)
        // An idle connection is taken without an await: through `acquire` it
        // was an async frame for what is almost always a pop off a list.
        let connection: PostgresConnection
        if let ready = takeIdle() {
            connection = ready
        } else {
            do throws(PostgresClientError) {
                connection = try await acquire()
            } catch {
                span?.fail(error)
                throw error
            }
        }
        do throws(PostgresClientError) {
            let rows = try await connection.untracedQuery(sql, values: values.map(\.postgresValue))
            release(connection)
            span?.end()
            return rows
        } catch {
            release(connection)
            span?.fail(error)
            throw error
        }
    }

    /// An idle connection still fit to use, if there is one.
    private func takeIdle() -> PostgresConnection? {
        while let connection = idle.popLast() {
            // Anything arriving on a connection nobody was using is almost
            // always the server going away: an idle timeout, a restart.
            // Found out now, it costs a reconnect. Found out after the
            // statement is written, it costs not knowing whether the
            // statement ran.
            if connection.isOpen && !connection.socket.hasPendingInput { return connection }
            connection.close()
            open -= 1
        }
        return nil
    }

    /// Waits for a connection, or opens one. Not `nonsending`: opening one
    /// goes through the engine's own async functions.
    private func acquire() async throws(PostgresClientError) -> PostgresConnection {
        guard let worker = currentWorker else { throw .cancelled }
        while true {
            if let connection = takeIdle() { return connection }
            if open < maxConnections {
                open += 1
                do {
                    return try await PostgresConnection.connect(worker, configuration)
                } catch {
                    open -= 1
                    wakeOne()
                    throw error
                }
            }
            // Full. Whoever holds a connection bounds each wait on the server,
            // but not what they do between statements: a transaction can
            // await anything. So this wait has a deadline of its own.
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
                // Gone from the queue now, rather than when a release reaches
                // it: with every connection stuck, none may come.
                waiting.remove(id)
                throw .poolTimedOut
            case .cancelled:
                throw .cancelled
            }
        }
    }

    private func release(_ connection: PostgresConnection) {
        // Kept only if the session is back outside any transaction. A handler
        // that ran `begin` itself and returned would otherwise hand its open
        // transaction to the next request, whose statements would run inside
        // it -- seeing, and committing or rolling back, work that was never
        // theirs. Closing it makes the server roll back.
        if connection.isOpen && connection.transactionStatus == .idle {
            // Straight to the oldest wait, if there is one (PoolWaiters).
            if let worker = currentWorker, waiting.handOver(connection, on: worker) { return }
            idle.append(connection)
        } else {
            if connection.isOpen { connection.close() }
            open -= 1
            wakeOne()
        }
    }

    private func wakeOne() {
        guard let worker = currentWorker else { return }
        waiting.wakeOldest(on: worker)
    }

    /// Lends one connection for as long as a `COPY` takes: the stream is the
    /// connection's, so nothing else may have it until the copy is over.
    nonisolated(nonsending)
    func withConnectionForCopy<R>(_ body: (PostgresConnection) async throws -> R) async throws -> R {
        let connection = try await acquire()
        do {
            let result = try await body(connection)
            release(connection)
            return result
        } catch {
            release(connection)
            throw error
        }
    }

    /// For tests: how many connections exist, and how many are idle.
    var counts: (open: Int, idle: Int) { (open, idle.count) }
    /// For tests: how many statements are queued for a connection.
    var waitingCount: Int { waiting.count }
}

/// Statements inside one transaction, all on the same connection.
public struct PostgresTransaction {
    let connection: PostgresConnection

    nonisolated(nonsending)
    public func query<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> [Row] {
        try decodeAll(type, try await connection.query(sql, values: values.map(\.postgresValue)))
    }

    nonisolated(nonsending)
    public func first<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> Row? {
        let rows = try await connection.query(sql, values: values.map(\.postgresValue))
        guard rows.count > 0 else { return nil }
        return try decodeRow(type, rows, 0, columnIndex(rows), PostgresRowShape(type, rows))
    }

    @discardableResult
    nonisolated(nonsending)
    public func execute(_ sql: String, _ values: any PostgresBindable...) async throws -> Int {
        try await connection.query(sql, values: values.map(\.postgresValue)).affected
    }
}

// MARK: - Decoding

private func columnIndex(_ rows: PostgresRows) -> PostgresColumnIndex {
    PostgresColumnIndex(rows.columns)
}

/// Finds a result's column by name; the first of that name, if two share it.
///
/// A result of a few columns is searched in order: hashing every name into a
/// dictionary, and every property's name again to look it up, cost more than
/// the comparisons for the handful of columns a row usually has. A wide
/// result gets the dictionary.
struct PostgresColumnIndex {
    /// The result's own array, shared rather than copied.
    private let columns: [PostgresColumn]
    private let table: [String: Int]?

    static let searchedInOrder = 16

    init(_ columns: [PostgresColumn]) {
        self.columns = columns
        if columns.count > PostgresColumnIndex.searchedInOrder {
            var table: [String: Int] = [:]
            for (i, column) in columns.enumerated() where table[column.name] == nil {
                table[column.name] = i
            }
            self.table = table
        } else {
            table = nil
        }
    }

    subscript(_ name: String) -> Int? {
        if let table { return table[name] }
        var i = 0
        while i < columns.count {
            if columns[i].name == name { return i }
            i += 1
        }
        return nil
    }
}

func decodeAll<Row: Decodable>(_ type: Row.Type, _ rows: PostgresRows) throws -> [Row] {
    let index = columnIndex(rows)
    let shape = PostgresRowShape(type, rows)
    var out: [Row] = []
    out.reserveCapacity(rows.count)
    for r in 0..<rows.count { out.append(try decodeRow(type, rows, r, index, shape)) }
    return out
}

/// What a result's rows are, which depends on the type asked for and on the
/// columns -- never on which row. Worked out once for a result and then used
/// for every row of it, so that a thousand rows do not ask the runtime a
/// thousand times what one answer covers.
enum PostgresRowShape {
    /// A `[UInt8]` is a scalar here, not the list of numbers Decodable makes.
    case bytes
    /// `query([String].self, "select tags from notes")`: one array column
    /// asked for as a list is that column, not a row of columns.
    case onlyCell
    case keyed

    init<Row: Decodable>(_ type: Row.Type, _ rows: PostgresRows) {
        if Row.self == [UInt8].self { self = .bytes; return }
        // The column count first: it is free, where asking the runtime
        // whether a type conforms costs about half a microsecond whether the
        // answer is yes or no, so it is asked once a type and remembered.
        if rows.columns.count == 1, isArrayColumn.holds(Row.self),
           PostgresType.elementType(of: rows.columns[0].typeOID) != nil {
            self = .onlyCell
            return
        }
        self = .keyed
    }
}

private let isArrayColumn = ConformanceCache { $0 is any PostgresArrayColumn.Type }

private func decodeRow<Row: Decodable>(_ type: Row.Type, _ rows: PostgresRows, _ row: Int,
                                       _ index: PostgresColumnIndex,
                                       _ shape: PostgresRowShape) throws -> Row {
    let decoding = PostgresRowDecoding(rows: rows, row: row, index: index)
    switch shape {
    case .bytes: return try decoding.onlyCell().decode([UInt8].self) as! Row
    case .onlyCell: return try decoding.onlyCell().decode(Row.self)
    case .keyed: return try Row(from: decoding)
    }
}

/// Decodes one row: properties by column name, or a single scalar from a
/// result with one column.
struct PostgresRowDecoding: Decoder {
    let rows: PostgresRows
    let row: Int
    let index: PostgresColumnIndex
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(PostgresRowKeyed<Key>(rows: rows, row: row, index: index))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw PostgresDecodingError.unsupported("a row as a list")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        // `query(Int.self, "select count(*) from users")`: a scalar is the one
        // column there is. More than one would mean guessing which.
        try onlyCell()
    }

    func onlyCell() throws -> PostgresCell {
        guard rows.columns.count == 1 else {
            throw PostgresDecodingError.unsupported("a scalar from \(rows.columns.count) columns")
        }
        return PostgresCell(rows: rows, row: row, column: 0)
    }
}

private struct PostgresRowKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let rows: PostgresRows
    let row: Int
    let index: PostgresColumnIndex
    var codingPath: [any CodingKey] = []
    var allKeys: [Key] { rows.columns.compactMap { Key(stringValue: $0.name) } }

    func contains(_ key: Key) -> Bool { index[key.stringValue] != nil }

    private func cell(_ key: Key) throws -> PostgresCell {
        guard let column = index[key.stringValue] else {
            throw PostgresDecodingError.missingColumn(key.stringValue)
        }
        return PostgresCell(rows: rows, row: row, column: column)
    }

    func decodeNil(forKey key: Key) throws -> Bool { try cell(key).decodeNil() }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try cell(key).decode(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try cell(key).decode(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try cell(key).decode(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try cell(key).decode(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try cell(key).decode(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try cell(key).decode(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try cell(key).decode(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try cell(key).decode(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try cell(key).decode(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try cell(key).decode(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try cell(key).decode(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try cell(key).decode(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try cell(key).decode(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try cell(key).decode(type) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        // A type of its own over one column -- a String-backed enum, say --
        // decodes from that column's text.
        try cell(key).decode(type)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                               forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw PostgresDecodingError.unsupported("a nested object in column \(key.stringValue)")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw PostgresDecodingError.unsupported("a list in column \(key.stringValue)")
    }

    func superDecoder() throws -> any Decoder {
        throw PostgresDecodingError.unsupported("a superclass")
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw PostgresDecodingError.unsupported("a superclass")
    }
}

/// One cell, as the scalar a property asks for.
struct PostgresCell: Decoder, SingleValueDecodingContainer {
    let rows: PostgresRows
    let row: Int
    let column: Int
    var codingPath: [any CodingKey] = []

    init(rows: PostgresRows, row: Int, column: Int) {
        self.rows = rows
        self.row = row
        self.column = column
    }

    var name: String { rows.columns[column].name }
    var text: String? { rows.text(row: row, column: column) }
    /// The same cell as text, which is what reads every type the server did
    /// not send in binary -- and every element of an array.
    var asText: PostgresTextValue {
        PostgresTextValue(text: text, name: name, typeOID: rows.columns[column].typeOID)
    }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw PostgresDecodingError.unsupported("an object in column \(name)")
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw PostgresDecodingError.unsupported("a list in column \(name)")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    private func required() throws -> String {
        // NULL into a type that is not Optional is refused rather than read as
        // zero or empty: a missing value and a zero are different answers.
        guard let text else { throw PostgresDecodingError.null(column: name) }
        return text
    }

    /// The cell's bytes when it came in binary as one of `types`, else nil --
    /// which sends the caller down the text path.
    private func binary(_ types: UInt32...) throws -> ArraySlice<UInt8>? {
        let description = rows.columns[column]
        guard description.binary, types.contains(description.typeOID) else { return nil }
        guard let raw = rows.bytes(row: row, column: column) else {
            throw PostgresDecodingError.null(column: name)
        }
        return raw
    }

    private func notConvertible<T>(_ type: T.Type) -> PostgresDecodingError {
        .notConvertible(column: name, value: text ?? "null", expected: "\(type)")
    }

    private func integer<T: FixedWidthInteger & LosslessStringConvertible>(_ type: T.Type) throws -> T {
        if let raw = try binary(PostgresType.int2, PostgresType.int4, PostgresType.int8) {
            guard let wide = PostgresBinary.integer(raw), let value = T(exactly: wide) else {
                throw notConvertible(type)
            }
            return value
        }
        return try scalar(type)
    }

    private func scalar<T: LosslessStringConvertible>(_ type: T.Type) throws -> T {
        try asText.scalar(type)
    }

    func decodeNil() -> Bool { text == nil }

    func decode(_ type: Bool.Type) throws -> Bool {
        if let raw = try binary(PostgresType.bool) {
            guard let value = PostgresBinary.bool(raw) else { throw notConvertible(type) }
            return value
        }
        return try asText.decode(Bool.self)
    }

    func decode(_ type: String.Type) throws -> String { try required() }
    func decode(_ type: Double.Type) throws -> Double {
        if let raw = try binary(PostgresType.float8) {
            guard let value = PostgresBinary.float8(raw) else { throw notConvertible(type) }
            return value
        }
        // A float4 goes through its text, as it would have come: widening the
        // Float itself would turn 0.1 into 0.10000000149011612.
        return try scalar(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        if let raw = try binary(PostgresType.float4) {
            guard let value = PostgresBinary.float4(raw) else { throw notConvertible(type) }
            return value
        }
        return try scalar(type)
    }

    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // An array column into a list, whatever its elements are. Before the
        // bytes below, so `[UInt8]` from a `smallint[]` is its numbers while
        // `[UInt8]` from a `bytea` stays its bytes.
        if let element = PostgresType.elementType(of: rows.columns[column].typeOID),
           let list = T.self as? any PostgresArrayColumn.Type {
            return try list.decodePostgresArray(try required(), element: element, column: name) as! T
        }
        if T.self == [UInt8].self { return try bytes() as! T }
        if T.self == UUID.self { return try uuid() as! T }
        if T.self == Timestamp.self { return try timestamp() as! T }
        if T.self == PostgresDate.self { return try date() as! T }
        if T.self == PostgresTime.self { return try time() as! T }
        if T.self == PostgresInterval.self { return try interval() as! T }
        if T.self == PostgresNumeric.self { return try numeric() as! T }
        // A json or jsonb column, decoded into what PostgresJSON wraps.
        if let column = T.self as? any PostgresJSONColumn.Type {
            return try column.fromJSONBytes(Array(try required().utf8)) as! T
        }
        return try T(from: self)
    }

    private func date() throws -> PostgresDate {
        if let raw = try binary(PostgresType.date) {
            guard let days = PostgresBinary.dateDays(raw) else { throw notConvertible(PostgresDate.self) }
            return PostgresDate(daysSince2000: days)
        }
        return try asText.decode(PostgresDate.self)
    }

    private func time() throws -> PostgresTime {
        if let raw = try binary(PostgresType.time) {
            guard let micros = PostgresBinary.timeMicroseconds(raw),
                  let value = PostgresTime(microsecondsSinceMidnight: micros) else {
                throw notConvertible(PostgresTime.self)
            }
            return value
        }
        return try asText.decode(PostgresTime.self)
    }

    private func interval() throws -> PostgresInterval {
        if let raw = try binary(PostgresType.interval) {
            guard let parts = PostgresBinary.interval(raw) else { throw notConvertible(PostgresInterval.self) }
            return PostgresInterval(months: parts.months, days: parts.days, microseconds: parts.microseconds)
        }
        return try asText.decode(PostgresInterval.self)
    }

    private func numeric() throws -> PostgresNumeric {
        if let raw = try binary(PostgresType.numeric) {
            guard let parts = PostgresBinary.numeric(raw),
                  let value = PostgresNumeric(parts) else { throw notConvertible(PostgresNumeric.self) }
            return value
        }
        return try asText.decode(PostgresNumeric.self)
    }

    private func uuid() throws -> UUID {
        if let raw = try binary(PostgresType.uuid) {
            guard let value = UUID(bytes: Array(raw)) else { throw notConvertible(UUID.self) }
            return value
        }
        return try asText.decode(UUID.self)
    }

    /// From a timestamptz or timestamp column, or text in either layout.
    /// Infinity has no instant, and is refused.
    private func timestamp() throws -> Timestamp {
        if let raw = try binary(PostgresType.timestamptz, PostgresType.timestamp) {
            guard let micros = PostgresBinary.timestampMicroseconds(raw) else {
                throw notConvertible(Timestamp.self)
            }
            return Timestamp(microsecondsSinceEpoch: micros)
        }
        return try asText.decode(Timestamp.self)
    }

    /// The cell as bytes: a bytea's own bytes, in whichever format it came,
    /// and any other column's text as UTF-8.
    private func bytes() throws -> [UInt8] {
        let description = rows.columns[column]
        if description.typeOID == PostgresType.bytea && description.binary {
            guard let raw = rows.bytes(row: row, column: column) else {
                throw PostgresDecodingError.null(column: name)
            }
            return Array(raw)
        }
        // A bytea as text is its hex; any other column is its text, whichever
        // format it came in.
        return try asText.decodeBytes()
    }
}
