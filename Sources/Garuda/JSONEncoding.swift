//===----------------------------------------------------------------------===//
// The `Encoder` side of Garuda's JSON coder.
//
// One `JSONWriter` is shared by every encoder and container of an `encode`,
// and each of them knows two things: the level of the container it writes
// into, and the key to write first, if that container is an object. That is
// enough to stream the document out in order, with no tree in between.
//
// The `Encoder` protocol's container methods cannot throw, so a failure they
// find -- nesting too deep, a non-finite Double -- is recorded on the writer
// and thrown by `finish`.
//===----------------------------------------------------------------------===//

/// An encoder for one value: written into the container at `level`, under
/// `key` when that container is an object.
struct JSONEncoding: Encoder {
    let writer: JSONWriter
    let level: Int
    let key: String?
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let inner = writer.begin(.object, level: level, key: key)
        return KeyedEncodingContainer(
            JSONKeyedEncoding<Key>(writer: writer, level: inner, path: path))
    }

    func unkeyedContainer() -> any UnkeyedEncodingContainer {
        let inner = writer.begin(.array, level: level, key: key)
        return JSONUnkeyedEncoding(writer: writer, level: inner, path: path)
    }

    func singleValueContainer() -> any SingleValueEncodingContainer {
        JSONSingleValueEncoding(writer: writer, level: level, key: key, path: path)
    }
}

/// Encodes `value` into the container at `level` under `key`. A value that
/// writes nothing at all still owes its parent one, and gets an empty object.
///
/// The standard library's scalars are written directly. `Array` and
/// `Optional` encode their elements through the generic `encode<T>`, never
/// the overload for the element's own type, so without this every string in
/// an array paid for a path, an encoder and a boxed single-value container
/// of its own -- most of what encoding `[String]` cost.
private func encodeValue<T: Encodable>(_ value: T, writer: JSONWriter, level: Int,
                                       key: String?, path: @autoclosure () -> JSONPath) throws {
    if T.self == String.self {
        writer.write(unsafeBitCast(value, to: String.self), level: level, key: key)
        return
    }
    if T.self == Int.self {
        writer.write(Int64(unsafeBitCast(value, to: Int.self)), level: level, key: key)
        return
    }
    if T.self == Bool.self {
        writer.write(unsafeBitCast(value, to: Bool.self), level: level, key: key)
        return
    }
    if T.self == Double.self {
        writer.write(unsafeBitCast(value, to: Double.self), level: level, key: key,
                     path: describe(path().keys))
        return
    }
    if T.self == Int64.self {
        writer.write(unsafeBitCast(value, to: Int64.self), level: level, key: key)
        return
    }
    if T.self == Int32.self {
        writer.write(Int64(unsafeBitCast(value, to: Int32.self)), level: level, key: key)
        return
    }
    if T.self == UInt64.self {
        writer.write(unsafeBitCast(value, to: UInt64.self), level: level, key: key)
        return
    }
    if T.self == UInt.self {
        writer.write(UInt64(unsafeBitCast(value, to: UInt.self)), level: level, key: key)
        return
    }
    let before = writer.isEmpty
    let mark = writer.currentLevel
    try value.encode(to: JSONEncoding(writer: writer, level: level, key: key, path: path()))
    if before && writer.isEmpty && mark == writer.currentLevel {
        writer.begin(.object, level: level, key: key)
    }
}

private struct JSONKeyedEncoding<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let writer: JSONWriter
    let level: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }

    private func path(_ key: Key) -> JSONPath { path.appending(.key(key)) }

    mutating func encodeNil(forKey key: Key) throws {
        writer.writeNull(level: level, key: key.stringValue)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        writer.write(value, level: level, key: key.stringValue)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        writer.write(value, level: level, key: key.stringValue)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        writer.write(value, level: level, key: key.stringValue,
                     path: describe(path(key).keys))
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try encode(Double(value), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        writer.write(Int64(value), level: level, key: key.stringValue)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws { try encode(Int(value), forKey: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { try encode(Int(value), forKey: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { try encode(Int(value), forKey: key) }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        writer.write(value, level: level, key: key.stringValue)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        writer.write(UInt64(value), level: level, key: key.stringValue)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws { try encode(UInt(value), forKey: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { try encode(UInt(value), forKey: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { try encode(UInt(value), forKey: key) }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        writer.write(value, level: level, key: key.stringValue)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try encodeValue(value, writer: writer, level: level, key: key.stringValue,
                        path: path(key))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type, forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let inner = writer.begin(.object, level: level, key: key.stringValue)
        return KeyedEncodingContainer(
            JSONKeyedEncoding<NestedKey>(writer: writer, level: inner, path: path(key)))
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let inner = writer.begin(.array, level: level, key: key.stringValue)
        return JSONUnkeyedEncoding(writer: writer, level: inner, path: path(key))
    }

    mutating func superEncoder() -> any Encoder {
        JSONEncoding(writer: writer, level: level, key: "super", path: path)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        JSONEncoding(writer: writer, level: level, key: key.stringValue, path: path(key))
    }
}

private struct JSONUnkeyedEncoding: UnkeyedEncodingContainer {
    let writer: JSONWriter
    let level: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }
    private(set) var count = 0

    /// The path of the element about to be written, which is then counted.
    /// Only asked for when the element needs one: a scalar never does.
    private mutating func counted() -> JSONPath {
        let element = path.appending(.index(count))
        count += 1
        return element
    }

    mutating func encodeNil() throws {
        count += 1
        writer.writeNull(level: level, key: nil)
    }

    mutating func encode(_ value: Bool) throws {
        count += 1
        writer.write(value, level: level, key: nil)
    }

    mutating func encode(_ value: String) throws {
        count += 1
        writer.write(value, level: level, key: nil)
    }

    mutating func encode(_ value: Double) throws {
        let element = counted()
        writer.write(value, level: level, key: nil, path: describe(element.keys))
    }

    mutating func encode(_ value: Float) throws { try encode(Double(value)) }

    mutating func encode(_ value: Int) throws {
        count += 1
        writer.write(Int64(value), level: level, key: nil)
    }

    mutating func encode(_ value: Int8) throws { try encode(Int(value)) }
    mutating func encode(_ value: Int16) throws { try encode(Int(value)) }
    mutating func encode(_ value: Int32) throws { try encode(Int(value)) }

    mutating func encode(_ value: Int64) throws {
        count += 1
        writer.write(value, level: level, key: nil)
    }

    mutating func encode(_ value: UInt) throws {
        count += 1
        writer.write(UInt64(value), level: level, key: nil)
    }

    mutating func encode(_ value: UInt8) throws { try encode(UInt(value)) }
    mutating func encode(_ value: UInt16) throws { try encode(UInt(value)) }
    mutating func encode(_ value: UInt32) throws { try encode(UInt(value)) }

    mutating func encode(_ value: UInt64) throws {
        count += 1
        writer.write(value, level: level, key: nil)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let index = count
        count += 1
        try encodeValue(value, writer: writer, level: level, key: nil,
                        path: path.appending(.index(index)))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let element = counted()
        let inner = writer.begin(.object, level: level, key: nil)
        return KeyedEncodingContainer(
            JSONKeyedEncoding<NestedKey>(writer: writer, level: inner, path: element))
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let element = counted()
        let inner = writer.begin(.array, level: level, key: nil)
        return JSONUnkeyedEncoding(writer: writer, level: inner, path: element)
    }

    mutating func superEncoder() -> any Encoder {
        JSONEncoding(writer: writer, level: level, key: nil, path: counted())
    }
}

private struct JSONSingleValueEncoding: SingleValueEncodingContainer {
    let writer: JSONWriter
    let level: Int
    let key: String?
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }

    mutating func encodeNil() throws { writer.writeNull(level: level, key: key) }
    mutating func encode(_ value: Bool) throws { writer.write(value, level: level, key: key) }
    mutating func encode(_ value: String) throws { writer.write(value, level: level, key: key) }

    mutating func encode(_ value: Double) throws {
        writer.write(value, level: level, key: key, path: describe(path.keys))
    }

    mutating func encode(_ value: Float) throws { try encode(Double(value)) }
    mutating func encode(_ value: Int) throws { writer.write(Int64(value), level: level, key: key) }
    mutating func encode(_ value: Int8) throws { try encode(Int(value)) }
    mutating func encode(_ value: Int16) throws { try encode(Int(value)) }
    mutating func encode(_ value: Int32) throws { try encode(Int(value)) }
    mutating func encode(_ value: Int64) throws { writer.write(value, level: level, key: key) }
    mutating func encode(_ value: UInt) throws { writer.write(UInt64(value), level: level, key: key) }
    mutating func encode(_ value: UInt8) throws { try encode(UInt(value)) }
    mutating func encode(_ value: UInt16) throws { try encode(UInt(value)) }
    mutating func encode(_ value: UInt32) throws { try encode(UInt(value)) }
    mutating func encode(_ value: UInt64) throws { writer.write(value, level: level, key: key) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encodeValue(value, writer: writer, level: level, key: key, path: path)
    }
}

/// A coding key the coder makes itself: an array index, or a name read from
/// the document.
struct JSONKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }

    init(name: String) {
        stringValue = name
        intValue = nil
    }

    init(index: Int) {
        stringValue = String(index)
        intValue = index
    }
}

/// A coding path, kept as the path of the container a value is in and the one
/// step from there to the value, and only put together when something reads
/// it.
///
/// Nearly nothing does: the path is for errors, and for the rare `Codable`
/// conformance that looks. Built eagerly it was an array for every value in
/// every document, and for an array element a number formatted as a string
/// too -- much of what a small request body cost to decode and a small answer
/// to encode.
struct JSONPath {
    enum Step {
        case key(any CodingKey)
        case index(Int)

        var codingKey: any CodingKey {
            switch self {
            case .key(let key): key
            case .index(let index): JSONKey(index: index)
            }
        }
    }

    private let parent: [any CodingKey]
    private let step: Step?

    static let root = JSONPath(parent: [], step: nil)

    private init(parent: [any CodingKey], step: Step?) {
        self.parent = parent
        self.step = step
    }

    var keys: [any CodingKey] {
        guard let step else { return parent }
        return parent + [step.codingKey]
    }

    /// The path one step further down. This one is put together first if it
    /// has a step of its own: once for each container inside another, rather
    /// than once for each value.
    func appending(_ step: Step) -> JSONPath {
        JSONPath(parent: keys, step: step)
    }
}

/// A coding path as it reads in an error: `user.tags[0].name`.
func describe(_ path: [any CodingKey]) -> String {
    var text = ""
    for key in path {
        if let index = key.intValue {
            text += "[\(index)]"
        } else if text.isEmpty {
            text += key.stringValue
        } else {
            text += "." + key.stringValue
        }
    }
    return text
}
