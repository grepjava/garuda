//===----------------------------------------------------------------------===//
// Arrays: `text[]`, `int[]`, and an array of any other type the driver reads.
//
//     struct Note: Decodable {
//         let id: Int
//         let tags: [String]          // text[]
//         let scores: [Int]?          // int[], or nil when the column is NULL
//         let seen: [Timestamp?]      // timestamptz[] with NULLs among it
//     }
//
//     try await pool.query(Note.self, "select id, tags, scores, seen from notes")
//     try await pool.execute("insert into notes (tags) values ($1)", ["swift", "http"])
//     try await pool.query(Note.self, "select * from notes where $1 = any(tags)", tag)
//
// A list binds as PostgreSQL's array literal and reads back from it, so one
// format covers every element type: an element is the server's own text for
// whatever it is, read by the same reader a text cell uses. Bytes stay the
// exception they were -- `[UInt8]` is a `bytea`, not an array of numbers --
// and `[[UInt8]]` is a `bytea[]`.
//
// One dimension. PostgreSQL's arrays are rectangular and of any dimension,
// which Swift's nested arrays are not, so `{{1,2},{3,4}}` is refused rather
// than flattened into a list that was never one.
//===----------------------------------------------------------------------===//

import GarudaPostgres

// MARK: - Reading

/// What the row decoder uses to build a list from an array column's text.
protocol PostgresArrayColumn {
    static func decodePostgresArray(_ text: String, element: UInt32, column: String) throws -> Self
}

extension Array: PostgresArrayColumn where Element: Decodable {
    static func decodePostgresArray(_ text: String, element: UInt32,
                                    column: String) throws -> [Element] {
        guard let items = PostgresArrayText.parse(text) else {
            throw PostgresDecodingError.notConvertible(column: column, value: text,
                                                       expected: "[\(Element.self)]")
        }
        var out: [Element] = []
        out.reserveCapacity(items.count)
        for item in items {
            // Each element decodes as a cell of the element's type would: a
            // NULL among them is only readable into an Optional, and an
            // element that is not what the type asks for names its column.
            // Through `decode`, not `Element(from:)`: the types that are one
            // column rather than an object -- a date, a UUID, bytes -- are
            // read there, exactly as they are in a cell.
            out.append(try PostgresTextValue(text: item, name: column,
                                             typeOID: element).decode(Element.self))
        }
        return out
    }
}

/// One value that came as text -- a cell the server sent as text, or one
/// element of an array -- as the scalar a property asks for.
///
/// The one text reader: `PostgresCell` reads the binary forms and hands
/// everything else here, so an element of an array and a cell of the same type
/// are read by the same code.
struct PostgresTextValue: Decoder, SingleValueDecodingContainer {
    /// The value's text, or nil for NULL.
    let text: String?
    /// The column it came from, for what an error names.
    let name: String
    /// Its own type, which tells a `bytea`'s hex from text that is text and
    /// an array from a value.
    let typeOID: UInt32

    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw PostgresDecodingError.unsupported("an object in column \(name)")
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw PostgresDecodingError.unsupported("a list in column \(name)")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer { self }

    func required() throws -> String {
        // NULL into a type that is not Optional is refused rather than read as
        // zero or empty: a missing value and a zero are different answers.
        guard let text else { throw PostgresDecodingError.null(column: name) }
        return text
    }

    func notConvertible<T>(_ type: T.Type) -> PostgresDecodingError {
        .notConvertible(column: name, value: text ?? "null", expected: "\(type)")
    }

    func scalar<T: LosslessStringConvertible>(_ type: T.Type) throws -> T {
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

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // An array of arrays would land here, from an element that is itself a
        // list: refused by the element's type, since one dimension is what a
        // Swift list holds.
        if let element = PostgresType.elementType(of: typeOID),
           let list = T.self as? any PostgresArrayColumn.Type {
            return try list.decodePostgresArray(try required(), element: element, column: name) as! T
        }
        if T.self == [UInt8].self { return try decodeBytes() as! T }
        if T.self == UUID.self {
            guard let value = UUID(try required()) else { throw notConvertible(UUID.self) }
            return value as! T
        }
        if T.self == Timestamp.self {
            guard let value = Timestamp(try required()) else { throw notConvertible(Timestamp.self) }
            return value as! T
        }
        if T.self == PostgresDate.self {
            guard let value = PostgresDate(try required()) else { throw notConvertible(PostgresDate.self) }
            return value as! T
        }
        if T.self == PostgresTime.self {
            guard let value = PostgresTime(try required()) else { throw notConvertible(PostgresTime.self) }
            return value as! T
        }
        if T.self == PostgresInterval.self {
            guard let value = PostgresInterval(try required()) else {
                throw notConvertible(PostgresInterval.self)
            }
            return value as! T
        }
        if T.self == PostgresNumeric.self {
            guard let value = PostgresNumeric(try required()) else {
                throw notConvertible(PostgresNumeric.self)
            }
            return value as! T
        }
        if let column = T.self as? any PostgresJSONColumn.Type {
            return try column.fromJSONBytes(Array(try required().utf8)) as! T
        }
        return try T(from: self)
    }

    /// The value as bytes: a `bytea`'s own bytes from its hex, and anything
    /// else's text as UTF-8.
    func decodeBytes() throws -> [UInt8] {
        let text = try required()
        guard typeOID == PostgresType.bytea else { return Array(text.utf8) }
        guard let decoded = PostgresBytea.decodeHex(Array(text.utf8)[...]) else {
            throw PostgresDecodingError.notConvertible(column: name, value: String(text.prefix(32)),
                                                       expected: "bytea in hex")
        }
        return decoded
    }
}

// MARK: - Binding

/// A list, bound as PostgreSQL's array literal, which the server parses into
/// whatever array type the placeholder has.
///
/// `[UInt8]` is the exception, and stays a `bytea` in binary: bytes are a
/// value, not a list of numbers. An array of `smallint` is `[Int16]`.
extension Array: PostgresBindable where Element: PostgresBindable {
    public var postgresValue: PostgresValue {
        // The element type, not a cast: an empty array casts to `[UInt8]`
        // whatever its elements would have been, and an empty list of
        // anything is not an empty bytea.
        if Element.self == UInt8.self {
            return .binary(self as! [UInt8], type: PostgresType.bytea)
        }
        return PostgresValue(PostgresArrayText.format(map { element in
            switch element.postgresValue {
            case .null: return nil
            case .text(let bytes): return String(decoding: bytes, as: UTF8.self)
            // A value that binds in binary -- bytes, a UUID, a timestamp --
            // goes in as the text the server would have written for the same
            // bytes, which is what an array literal takes. A binary form with
            // no text to write falls back to hex, which the server refuses
            // rather than reading as something else.
            case .binary(let bytes, let type):
                return PostgresBinary.text(bytes[...], type: type) ?? PostgresBytea.encodeHex(bytes)
            }
        }))
    }
}
