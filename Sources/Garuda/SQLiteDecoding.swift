//===----------------------------------------------------------------------===//
// SQLite rows into Decodable types: properties by column name, or a single
// scalar from a result with one column.
//
// SQLite stores a value in one of five classes whatever the column says, so a
// property is decoded from the class the value actually has. Conversions that
// lose nothing are made -- an integer into a Double, a REAL that is a whole
// number into an Int -- and the rest are refused rather than guessed at: text
// that looks like a number stays text.
//===----------------------------------------------------------------------===//

import AvianCore

func sqliteColumnIndex(_ rows: SQLiteRows) -> [String: Int] {
    var index: [String: Int] = [:]
    for (i, column) in rows.columns.enumerated() where index[column] == nil {
        index[column] = i
    }
    return index
}

func decodeAllSQLite<Row: Decodable>(_ type: Row.Type, _ rows: SQLiteRows) throws -> [Row] {
    let index = sqliteColumnIndex(rows)
    var out: [Row] = []
    out.reserveCapacity(rows.count)
    for r in 0..<rows.count { out.append(try decodeSQLiteRow(type, rows, r, index)) }
    return out
}

func decodeSQLiteRow<Row: Decodable>(_ type: Row.Type, _ rows: SQLiteRows, _ row: Int,
                                     _ index: [String: Int]) throws -> Row {
    let decoding = SQLiteRowDecoding(rows: rows, row: row, index: index)
    // Bytes, a UUID and a Timestamp are scalars here, not what their own
    // Decodable conformances would read.
    if Row.self == [UInt8].self || Row.self == UUID.self || Row.self == Timestamp.self {
        return try decoding.onlyCell().decode(Row.self)
    }
    return try Row(from: decoding)
}

struct SQLiteRowDecoding: Decoder {
    let rows: SQLiteRows
    let row: Int
    let index: [String: Int]
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(SQLiteRowKeyed<Key>(rows: rows, row: row, index: index))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw SQLiteDecodingError.unsupported("a row as a list")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        try onlyCell()
    }

    func onlyCell() throws -> SQLiteCell {
        guard rows.columns.count == 1 else {
            throw SQLiteDecodingError.unsupported("a scalar from \(rows.columns.count) columns")
        }
        return SQLiteCell(name: rows.columns[0], value: rows.value(row: row, column: 0))
    }
}

private struct SQLiteRowKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let rows: SQLiteRows
    let row: Int
    let index: [String: Int]
    var codingPath: [any CodingKey] = []
    var allKeys: [Key] { rows.columns.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { index[key.stringValue] != nil }

    private func cell(_ key: Key) throws -> SQLiteCell {
        guard let column = index[key.stringValue] else {
            throw SQLiteDecodingError.missingColumn(key.stringValue)
        }
        return SQLiteCell(name: rows.columns[column], value: rows.value(row: row, column: column))
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
        try cell(key).decode(type)
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type,
                                               forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        throw SQLiteDecodingError.unsupported("a nested object in column \(key.stringValue)")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw SQLiteDecodingError.unsupported("a list in column \(key.stringValue)")
    }

    func superDecoder() throws -> any Decoder {
        throw SQLiteDecodingError.unsupported("a superclass")
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        throw SQLiteDecodingError.unsupported("a superclass")
    }
}

/// One cell, as the scalar a property asks for.
struct SQLiteCell: Decoder, SingleValueDecodingContainer {
    let name: String
    let value: SQLiteValue
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    init(name: String, value: SQLiteValue) {
        self.name = name
        self.value = value
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw SQLiteDecodingError.unsupported("an object in column \(name)")
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw SQLiteDecodingError.unsupported("a list in column \(name)")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    private var shown: String {
        switch value {
        case .null: return "null"
        case .integer(let n): return String(n)
        case .real(let d): return String(d)
        case .text(let s): return s.count > 64 ? String(s.prefix(64)) + "…" : s
        case .blob(let b): return "\(b.count) bytes"
        }
    }

    private func notConvertible<T>(_ type: T.Type) -> SQLiteDecodingError {
        if case .null = value { return .null(column: name) }
        return .notConvertible(column: name, value: shown, expected: "\(type)")
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        switch value {
        case .integer(let n):
            if let exact = T(exactly: n) { return exact }
        case .real(let d):
            // `avg`, `sum` over REAL columns and arithmetic with a REAL give a
            // REAL even when it is whole.
            if let exact = T(exactly: d) { return exact }
        default:
            break
        }
        throw notConvertible(type)
    }

    func decodeNil() -> Bool {
        if case .null = value { return true }
        return false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        // SQLite has no boolean: true and false are stored as 1 and 0.
        if case .integer(let n) = value, n == 0 || n == 1 { return n == 1 }
        throw notConvertible(type)
    }

    func decode(_ type: String.Type) throws -> String {
        switch value {
        case .text(let s): return s
        case .integer(let n): return String(n)
        default: throw notConvertible(type)
        }
    }

    func decode(_ type: Double.Type) throws -> Double {
        switch value {
        case .real(let d): return d
        case .integer(let n):
            if let exact = Double(exactly: n) { return exact }
        default: break
        }
        throw notConvertible(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        switch value {
        case .real(let d):
            // Through its shortest decimal form, the way a Float binds.
            if d.isFinite, let f = Float(String(d)), f.isFinite { return f }
            if !d.isFinite { return Float(d) }
        case .integer(let n):
            if let exact = Float(exactly: n) { return exact }
        default: break
        }
        throw notConvertible(type)
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
        if T.self == [UInt8].self { return try bytes() as! T }
        if T.self == UUID.self { return try uuid() as! T }
        if T.self == Timestamp.self { return try timestamp() as! T }
        return try T(from: self)
    }

    /// A blob's bytes, or text's UTF-8.
    private func bytes() throws -> [UInt8] {
        switch value {
        case .blob(let b): return b
        case .text(let s): return Array(s.utf8)
        default: throw notConvertible([UInt8].self)
        }
    }

    /// From text, or from the 16 bytes of a blob.
    private func uuid() throws -> UUID {
        switch value {
        case .text(let s):
            if let id = UUID(s) { return id }
        case .blob(let b):
            if let id = UUID(bytes: b) { return id }
        default: break
        }
        throw notConvertible(UUID.self)
    }

    /// From text -- as a Timestamp binds, as `CURRENT_TIMESTAMP` writes, or
    /// ISO 8601 -- or from an integer of seconds since 1970, as `unixepoch()`
    /// returns.
    private func timestamp() throws -> Timestamp {
        switch value {
        case .text(let s):
            if let t = Timestamp(s) { return t }
        case .integer(let n):
            let (micros, overflow) = n.multipliedReportingOverflow(by: 1_000_000)
            if !overflow { return Timestamp(microsecondsSinceEpoch: micros) }
        default: break
        }
        throw notConvertible(Timestamp.self)
    }
}
