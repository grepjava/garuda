//===----------------------------------------------------------------------===//
// Reading a query string into a type.
//
// `?kind=books&page=3&tag=a&tag=b` decodes into a struct with `kind`, `page`
// and `tags`: scalars by name, arrays from a name that repeats, and an
// Optional for one that may be absent. Percent-escapes are undone and `+` is
// a space, as an HTML form sends it.
//
// The pairs are read once into a small array rather than scanned per key: a
// query is short, and a handler that asks for one usually wants most of it.
//===----------------------------------------------------------------------===//

import GarudaCore

/// Why a query string could not become the type asked for.
public enum QueryError: Error, Equatable {
    /// No item of that name, and the type is not Optional.
    case missing(name: String)
    /// An item that is not the type asked for.
    case notConvertible(name: String, value: String, expected: String)
    /// A shape a query string cannot hold, such as a nested object.
    case unsupported(String)
}

/// A query string is the client's to get right, so a failure is a 400 that
/// says which item is at fault.
extension QueryError: ResponseError {
    public var status: HTTPStatus { .badRequest }

    public var reason: String? {
        switch self {
        case .missing(let name):
            return "\(name) is missing"
        case .notConvertible(let name, let value, let expected):
            return "\(name)=\(value) is not \(expected)"
        case .unsupported(let what):
            return "a query string cannot hold \(what)"
        }
    }
}

enum QueryString {
    /// The name and value of every item, in order, percent-decoded.
    static func items(_ bytes: UnsafePointer<UInt8>, _ count: Int) -> [(name: String, value: String)] {
        var items: [(name: String, value: String)] = []
        var start = 0
        while start <= count {
            var end = start
            while end < count && bytes[end] != 0x26 { end += 1 }  // &
            if end > start {
                var separator = start
                while separator < end && bytes[separator] != 0x3D { separator += 1 }  // =
                let name = decoded(bytes, start, separator)
                let value = separator < end ? decoded(bytes, separator + 1, end) : ""
                items.append((name, value))
            }
            if end >= count { break }
            start = end + 1
        }
        return items
    }

    /// One item, with `+` as a space and `%XX` undone. Invalid UTF-8 is
    /// repaired rather than refused: it is someone's search box, not a
    /// protocol element.
    private static func decoded(_ bytes: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(end - start)
        var i = start
        while i < end {
            let byte = bytes[i]
            if byte == 0x2B {  // +
                out.append(0x20)
                i += 1
            } else if byte == cPercent, i + 2 < end,
                      case let high = hexValue(bytes[i + 1]), high >= 0,
                      case let low = hexValue(bytes[i + 2]), low >= 0 {
                out.append(UInt8(high << 4 | low))
                i += 3
            } else {
                out.append(byte)
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Decodes a type from the items of a query string.
struct QueryDecoding: Decoder {
    let items: [(name: String, value: String)]
    var codingPath: [any CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(QueryKeyedDecoding<Key>(items: items, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw QueryError.unsupported("a list at the top level")
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw QueryError.unsupported("a single value at the top level")
    }
}

/// One item's value, as the scalar the type asked for.
private struct QueryValue {
    let name: String
    let text: String

    func scalar<T: LosslessStringConvertible>(_ type: T.Type) throws -> T {
        guard let value = T(text) else {
            throw QueryError.notConvertible(name: name, value: text, expected: "\(type)")
        }
        return value
    }

    /// A flag may be written `?ready`, with no value at all.
    func boolean() throws -> Bool {
        switch text {
        case "true", "1", "yes", "on", "": return true
        case "false", "0", "no", "off": return false
        default:
            throw QueryError.notConvertible(name: name, value: text, expected: "Bool")
        }
    }
}

private struct QueryKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let items: [(name: String, value: String)]
    var codingPath: [any CodingKey]

    var allKeys: [Key] { items.compactMap { Key(stringValue: $0.name) } }

    func contains(_ key: Key) -> Bool {
        items.contains { $0.name == key.stringValue }
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        !contains(key)
    }

    private func value(_ key: Key) throws -> QueryValue {
        guard let item = items.first(where: { $0.name == key.stringValue }) else {
            throw QueryError.missing(name: key.stringValue)
        }
        return QueryValue(name: key.stringValue, text: item.value)
    }

    private func values(_ key: Key) -> [String] {
        items.filter { $0.name == key.stringValue }.map(\.value)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try value(key).boolean() }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try value(key).text }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try value(key).scalar(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try value(key).scalar(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try value(key).scalar(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try value(key).scalar(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try value(key).scalar(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try value(key).scalar(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try value(key).scalar(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try value(key).scalar(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try value(key).scalar(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try value(key).scalar(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try value(key).scalar(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try value(key).scalar(type) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        // A name that repeats is a list; anything else a type asks for here is
        // a shape a query string does not have.
        let decoder = QueryItemDecoding(name: key.stringValue, values: values(key),
                                        codingPath: codingPath + [key])
        return try T(from: decoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw QueryError.unsupported("an object under \(key.stringValue)")
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        QueryListDecoding(name: key.stringValue, values: values(key),
                          codingPath: codingPath + [key])
    }

    func superDecoder() throws -> any Decoder {
        QueryDecoding(items: items, codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        QueryDecoding(items: items, codingPath: codingPath + [key])
    }
}

/// One name's values: a scalar when the type wants one, a list when it wants
/// a list, and nil when the name is absent.
private struct QueryItemDecoding: Decoder {
    let name: String
    let values: [String]
    var codingPath: [any CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw QueryError.unsupported("an object under \(name)")
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        QueryListDecoding(name: name, values: values, codingPath: codingPath)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        QuerySingleDecoding(name: name, values: values, codingPath: codingPath)
    }
}

private struct QuerySingleDecoding: SingleValueDecodingContainer {
    let name: String
    let values: [String]
    var codingPath: [any CodingKey]

    private func only() throws -> QueryValue {
        guard let text = values.first else { throw QueryError.missing(name: name) }
        return QueryValue(name: name, text: text)
    }

    func decodeNil() -> Bool { values.isEmpty }
    func decode(_ type: Bool.Type) throws -> Bool { try only().boolean() }
    func decode(_ type: String.Type) throws -> String { try only().text }
    func decode(_ type: Double.Type) throws -> Double { try only().scalar(type) }
    func decode(_ type: Float.Type) throws -> Float { try only().scalar(type) }
    func decode(_ type: Int.Type) throws -> Int { try only().scalar(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try only().scalar(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try only().scalar(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try only().scalar(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try only().scalar(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try only().scalar(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try only().scalar(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try only().scalar(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try only().scalar(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try only().scalar(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: QueryItemDecoding(name: name, values: values, codingPath: codingPath))
    }
}

private struct QueryListDecoding: UnkeyedDecodingContainer {
    let name: String
    let values: [String]
    var codingPath: [any CodingKey]
    var currentIndex = 0
    var count: Int? { values.count }
    var isAtEnd: Bool { currentIndex >= values.count }

    private mutating func next() throws -> QueryValue {
        guard currentIndex < values.count else { throw QueryError.missing(name: name) }
        let text = values[currentIndex]
        currentIndex += 1
        return QueryValue(name: name, text: text)
    }

    mutating func decodeNil() throws -> Bool { false }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try next().boolean() }
    mutating func decode(_ type: String.Type) throws -> String { try next().text }
    mutating func decode(_ type: Double.Type) throws -> Double { try next().scalar(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try next().scalar(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try next().scalar(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().scalar(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().scalar(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().scalar(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().scalar(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next().scalar(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next().scalar(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().scalar(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().scalar(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().scalar(type) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let value = try next()
        return try T(from: QueryItemDecoding(name: name, values: [value.text],
                                             codingPath: codingPath))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw QueryError.unsupported("an object inside \(name)")
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw QueryError.unsupported("a list inside \(name)")
    }

    mutating func superDecoder() throws -> any Decoder {
        QueryItemDecoding(name: name, values: values, codingPath: codingPath)
    }
}
