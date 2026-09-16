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

import CGaruda
import GarudaCore
import GarudaPostgres

// MARK: - Values

/// A value that can be bound to a `$n` placeholder.
///
/// Everything goes as text, which PostgreSQL parses into the placeholder's
/// type -- one format to get right rather than one per type. A value is never
/// written into the SQL itself, so none can become part of the statement.
public protocol PostgresBindable {
    /// The text PostgreSQL should parse, or nil for NULL.
    var postgresText: String? { get }
}

extension String: PostgresBindable { public var postgresText: String? { self } }
extension Substring: PostgresBindable { public var postgresText: String? { String(self) } }
extension Int: PostgresBindable { public var postgresText: String? { String(self) } }
extension Int8: PostgresBindable { public var postgresText: String? { String(self) } }
extension Int16: PostgresBindable { public var postgresText: String? { String(self) } }
extension Int32: PostgresBindable { public var postgresText: String? { String(self) } }
extension Int64: PostgresBindable { public var postgresText: String? { String(self) } }
extension UInt: PostgresBindable { public var postgresText: String? { String(self) } }
extension UInt8: PostgresBindable { public var postgresText: String? { String(self) } }
extension UInt16: PostgresBindable { public var postgresText: String? { String(self) } }
extension UInt32: PostgresBindable { public var postgresText: String? { String(self) } }
extension UInt64: PostgresBindable { public var postgresText: String? { String(self) } }
extension Double: PostgresBindable { public var postgresText: String? { String(self) } }
extension Float: PostgresBindable { public var postgresText: String? { String(self) } }
extension Bool: PostgresBindable { public var postgresText: String? { self ? "true" : "false" } }

extension Optional: PostgresBindable where Wrapped: PostgresBindable {
    public var postgresText: String? { self?.postgresText }
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

    private var idle: [PostgresConnection] = []
    /// Connections that exist, idle or in use -- including one being opened.
    private var open = 0
    private var waiting: [UnsafeContinuation<Void, Never>] = []

    public init(_ configuration: PostgresConfiguration, maxConnections: Int = 8) {
        precondition(maxConnections > 0, "a pool needs room for at least one connection")
        self.configuration = configuration
        self.maxConnections = maxConnections
    }

    /// Every row, decoded.
    public func query<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> [Row] {
        let rows = try await run(sql, values)
        return try decodeAll(type, rows)
    }

    /// The first row decoded, or nil if there were none.
    public func first<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any PostgresBindable...) async throws -> Row? {
        let rows = try await run(sql, values)
        guard rows.count > 0 else { return nil }
        return try decodeRow(type, rows, 0, columnIndex(rows))
    }

    /// Runs a statement and returns how many rows it affected.
    @discardableResult
    public func execute(_ sql: String, _ values: any PostgresBindable...) async throws -> Int {
        try await run(sql, values).affected
    }

    /// Closes every idle connection. For `app.state`'s shutdown.
    public func close() {
        for connection in idle { connection.close() }
        idle.removeAll()
        open = 0
    }

    // MARK: Connections

    private func run(_ sql: String, _ values: [any PostgresBindable]) async throws(PostgresClientError) -> PostgresRows {
        guard let worker = currentWorker else {
            // Only reachable by calling from a thread that is not a worker's,
            // which nothing in a handler can do.
            throw .cancelled
        }
        let connection = try await acquire(worker)
        do {
            let rows = try await connection.query(sql, values.map(\.postgresText))
            release(connection)
            return rows
        } catch {
            release(connection)
            throw error
        }
    }

    private func acquire(_ worker: UnsafeMutablePointer<Worker>) async throws(PostgresClientError) -> PostgresConnection {
        while true {
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
            // Full. Bounded by whoever holds a connection: each of their waits
            // has its own timeout, so a slot comes free eventually.
            await withUnsafeContinuation { waiting.append($0) }
        }
    }

    private func release(_ connection: PostgresConnection) {
        if connection.isOpen {
            idle.append(connection)
        } else {
            open -= 1
        }
        wakeOne()
    }

    private func wakeOne() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }

    /// For tests: how many connections exist, and how many are idle.
    var counts: (open: Int, idle: Int) { (open, idle.count) }
}

// MARK: - Decoding

private func columnIndex(_ rows: PostgresRows) -> [String: Int] {
    var index: [String: Int] = [:]
    for (i, column) in rows.columns.enumerated() where index[column.name] == nil {
        index[column.name] = i
    }
    return index
}

private func decodeAll<Row: Decodable>(_ type: Row.Type, _ rows: PostgresRows) throws -> [Row] {
    let index = columnIndex(rows)
    var out: [Row] = []
    out.reserveCapacity(rows.count)
    for r in 0..<rows.count { out.append(try decodeRow(type, rows, r, index)) }
    return out
}

private func decodeRow<Row: Decodable>(_ type: Row.Type, _ rows: PostgresRows, _ row: Int,
                                       _ index: [String: Int]) throws -> Row {
    try Row(from: PostgresRowDecoding(rows: rows, row: row, index: index))
}

/// Decodes one row: properties by column name, or a single scalar from a
/// result with one column.
struct PostgresRowDecoding: Decoder {
    let rows: PostgresRows
    let row: Int
    let index: [String: Int]
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
        guard rows.columns.count == 1 else {
            throw PostgresDecodingError.unsupported("a scalar from \(rows.columns.count) columns")
        }
        return PostgresCell(name: rows.columns[0].name, text: rows.text(row: row, column: 0))
    }
}

private struct PostgresRowKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let rows: PostgresRows
    let row: Int
    let index: [String: Int]
    var codingPath: [any CodingKey] = []
    var allKeys: [Key] { rows.columns.compactMap { Key(stringValue: $0.name) } }

    func contains(_ key: Key) -> Bool { index[key.stringValue] != nil }

    private func cell(_ key: Key) throws -> PostgresCell {
        guard let column = index[key.stringValue] else {
            throw PostgresDecodingError.missingColumn(key.stringValue)
        }
        return PostgresCell(name: key.stringValue, text: rows.text(row: row, column: column))
    }

    func decodeNil(forKey key: Key) throws -> Bool { try cell(key).text == nil }

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
        try T(from: try cell(key))
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

/// One column's text, as the scalar a property asks for.
private struct PostgresCell: Decoder, SingleValueDecodingContainer {
    let name: String
    let text: String?
    var codingPath: [any CodingKey] = []
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

    private func scalar<T: LosslessStringConvertible>(_ type: T.Type) throws -> T {
        let text = try required()
        guard let value = T(text) else {
            throw PostgresDecodingError.notConvertible(column: name, value: text, expected: "\(type)")
        }
        return value
    }

    func decodeNil() -> Bool { text == nil }

    func decode(_ type: Bool.Type) throws -> Bool {
        // PostgreSQL's text form of a boolean is t or f.
        switch try required() {
        case "t", "true": return true
        case "f", "false": return false
        case let other:
            throw PostgresDecodingError.notConvertible(column: name, value: other, expected: "Bool")
        }
    }

    func decode(_ type: String.Type) throws -> String { try required() }
    func decode(_ type: Double.Type) throws -> Double { try scalar(type) }
    func decode(_ type: Float.Type) throws -> Float { try scalar(type) }
    func decode(_ type: Int.Type) throws -> Int { try scalar(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try scalar(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try scalar(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try scalar(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try scalar(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try scalar(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try scalar(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try scalar(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try scalar(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try scalar(type) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: self) }
}
