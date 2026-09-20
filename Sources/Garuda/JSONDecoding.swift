//===----------------------------------------------------------------------===//
// The `Decoder` side of Garuda's JSON coder.
//
// The document is scanned once to prove it is JSON, and then read where the
// type asks: a keyed container holds the offset of its object and finds a key
// by walking that object's members, so nothing is copied into a dictionary
// first and a request body costs only what the handler reads out of it.
//
// Scanning recurses, so it is bounded by `JSONCoder.depthLimit`: the check is the
// only thing standing between a hostile body and the stack.
//===----------------------------------------------------------------------===//

import AvianCore

extension JSONCoder {
    /// Reads `type` out of a JSON document.
    public static func decode<T: Decodable>(_ type: T.Type = T.self, from bytes: [UInt8]) throws -> T {
        try bytes.withUnsafeBufferPointer { try decode(type, from: $0.baseAddress, count: $0.count) }
    }

    /// Reads `type` out of bytes lent by the engine, such as a request body.
    public static func decode<T: Decodable>(_ type: T.Type = T.self, from bytes: Span<UInt8>) throws -> T {
        try bytes.withUnsafeBufferPointer { try decode(type, from: $0.baseAddress, count: $0.count) }
    }

    static func decode<T: Decodable>(_ type: T.Type, from base: UnsafePointer<UInt8>?,
                                     count: Int) throws -> T {
        guard let base, count > 0 else { throw JSONError.syntax(offset: 0) }
        // Proved to be JSON before any of it is read, so that a malformed
        // document fails the same way whether or not the type reads that far.
        // Both paths below are proved the same way, and the scan is free: a
        // pass over a small body did not show against the reading.
        var scanner = JSONScanner(base: base, count: count)
        try scanner.skipValue()
        let end = scanner.index
        scanner.skipWhitespace()
        guard scanner.index == count else { throw JSONError.trailingBytes(offset: end) }
        // A type with a reader of its own reads itself: no containers, no
        // metadata, a quarter of the time. JSONFastPath.swift.
        if let value = try JSONFastPath.read(T.self, from: base, count: count) { return value }
        var start = JSONScanner(base: base, count: count)
        start.skipWhitespace()
        return try T(from: JSONDecoding(base: base, count: count, valueIndex: start.index,
                                        path: .root))
    }
}

// MARK: - Scanning

/// Walks a document's bytes. It never allocates and never copies: everything
/// it reports is an offset into the bytes it was given.
struct JSONScanner {
    let base: UnsafePointer<UInt8>
    let count: Int
    var index: Int

    init(base: UnsafePointer<UInt8>, count: Int, at index: Int = 0) {
        self.base = base
        self.count = count
        self.index = index
    }

    mutating func skipWhitespace() {
        while index < count {
            switch base[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func peek() -> UInt8? { index < count ? base[index] : nil }

    /// Advances past one complete value. Recursion is bounded by the depth
    /// limit, which is what keeps a nested document off the stack.
    mutating func skipValue(depth: Int = 0) throws {
        guard depth < JSONCoder.depthLimit else { throw JSONError.depthExceeded(offset: index) }
        skipWhitespace()
        guard index < count else { throw JSONError.syntax(offset: index) }
        switch base[index] {
        case 0x22: try skipString()
        case 0x7B: try skipObject(depth: depth)
        case 0x5B: try skipArray(depth: depth)
        case 0x74: try skipLiteral("true")
        case 0x66: try skipLiteral("false")
        case 0x6E: try skipLiteral("null")
        case 0x2D, 0x30...0x39: try skipNumber()
        default: throw JSONError.syntax(offset: index)
        }
    }

    private mutating func skipLiteral(_ word: StaticString) throws {
        let n = word.utf8CodeUnitCount
        guard index + n <= count else { throw JSONError.syntax(offset: index) }
        for i in 0..<n where base[index + i] != word.utf8Start[i] {
            throw JSONError.syntax(offset: index)
        }
        index += n
    }

    mutating func skipString() throws {
        guard index < count, base[index] == 0x22 else { throw JSONError.syntax(offset: index) }
        index += 1
        while index < count {
            let byte = base[index]
            if byte == 0x22 {
                index += 1
                return
            }
            if byte == 0x5C {
                index += 1
                guard index < count else { throw JSONError.syntax(offset: index) }
                switch base[index] {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    index += 1
                case 0x75:
                    guard index + 4 < count else { throw JSONError.syntax(offset: index) }
                    for i in 1...4 where hexValue(base[index + i]) < 0 {
                        throw JSONError.syntax(offset: index + i)
                    }
                    index += 5
                default:
                    throw JSONError.syntax(offset: index)
                }
                continue
            }
            // A raw control character is not allowed in a JSON string.
            if byte < 0x20 { throw JSONError.syntax(offset: index) }
            index += 1
        }
        throw JSONError.syntax(offset: index)
    }

    mutating func skipNumber() throws {
        let start = index
        if index < count, base[index] == 0x2D { index += 1 }
        let digitsStart = index
        while index < count, base[index] >= 0x30, base[index] <= 0x39 { index += 1 }
        guard index > digitsStart else { throw JSONError.syntax(offset: start) }
        // A leading zero may not be followed by another digit.
        if base[digitsStart] == 0x30 && index - digitsStart > 1 {
            throw JSONError.syntax(offset: digitsStart)
        }
        if index < count, base[index] == 0x2E {
            index += 1
            let fraction = index
            while index < count, base[index] >= 0x30, base[index] <= 0x39 { index += 1 }
            guard index > fraction else { throw JSONError.syntax(offset: index) }
        }
        if index < count, base[index] == 0x65 || base[index] == 0x45 {
            index += 1
            if index < count, base[index] == 0x2B || base[index] == 0x2D { index += 1 }
            let exponent = index
            while index < count, base[index] >= 0x30, base[index] <= 0x39 { index += 1 }
            guard index > exponent else { throw JSONError.syntax(offset: index) }
        }
    }

    private mutating func skipObject(depth: Int) throws {
        index += 1  // {
        skipWhitespace()
        if index < count, base[index] == 0x7D {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            try skipString()
            skipWhitespace()
            guard index < count, base[index] == 0x3A else { throw JSONError.syntax(offset: index) }
            index += 1
            try skipValue(depth: depth + 1)
            skipWhitespace()
            guard index < count else { throw JSONError.syntax(offset: index) }
            if base[index] == 0x2C {
                index += 1
                continue
            }
            if base[index] == 0x7D {
                index += 1
                return
            }
            throw JSONError.syntax(offset: index)
        }
    }

    private mutating func skipArray(depth: Int) throws {
        index += 1  // [
        skipWhitespace()
        if index < count, base[index] == 0x5D {
            index += 1
            return
        }
        while true {
            try skipValue(depth: depth + 1)
            skipWhitespace()
            guard index < count else { throw JSONError.syntax(offset: index) }
            if base[index] == 0x2C {
                index += 1
                continue
            }
            if base[index] == 0x5D {
                index += 1
                return
            }
            throw JSONError.syntax(offset: index)
        }
    }
}

// MARK: - Reading values

/// The value at an offset, read as what the type asked for. The document has
/// already been proved to be JSON, so a failure here is a type failure, not a
/// syntax one.
enum JSONValue {
    static func isNull(_ base: UnsafePointer<UInt8>, _ count: Int, at index: Int) -> Bool {
        index + 4 <= count && base[index] == 0x6E
    }

    static func bool(_ base: UnsafePointer<UInt8>, _ count: Int, at index: Int,
                     _ path: @autoclosure () -> [any CodingKey]) throws -> Bool {
        switch base[index] {
        case 0x74: return true
        case 0x66: return false
        case 0x6E: throw JSONError.valueNotFound(path: describe(path()), expected: "Bool")
        default: throw JSONError.typeMismatch(path: describe(path()), expected: "Bool")
        }
    }

    static func string(_ base: UnsafePointer<UInt8>, _ count: Int, at index: Int,
                       _ path: @autoclosure () -> [any CodingKey]) throws -> String {
        guard base[index] == 0x22 else {
            if base[index] == 0x6E {
                throw JSONError.valueNotFound(path: describe(path()), expected: "String")
            }
            throw JSONError.typeMismatch(path: describe(path()), expected: "String")
        }
        var scanner = JSONScanner(base: base, count: count, at: index)
        try scanner.skipString()
        return try text(base, from: index, to: scanner.index)
    }

    /// The decoded contents of the string literal between `start` and `end`.
    static func text(_ base: UnsafePointer<UInt8>, from start: Int, to end: Int) throws -> String {
        let contentStart = start + 1
        let contentEnd = end - 1
        if !hasEscape(base, contentStart, contentEnd) {
            return String(decoding: UnsafeBufferPointer(start: base + contentStart,
                                                        count: contentEnd - contentStart),
                          as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(contentEnd - contentStart)
        var i = contentStart
        while i < contentEnd {
            let byte = base[i]
            if byte != 0x5C {
                out.append(byte)
                i += 1
                continue
            }
            i += 1
            switch base[i] {
            case 0x22: out.append(0x22); i += 1
            case 0x5C: out.append(0x5C); i += 1
            case 0x2F: out.append(0x2F); i += 1
            case 0x62: out.append(0x08); i += 1
            case 0x66: out.append(0x0C); i += 1
            case 0x6E: out.append(0x0A); i += 1
            case 0x72: out.append(0x0D); i += 1
            case 0x74: out.append(0x09); i += 1
            case 0x75:
                var scalar = UInt32(hex4(base, i + 1))
                i += 5
                // A surrogate pair is two escapes, and means one scalar.
                if scalar >= 0xD800 && scalar <= 0xDBFF,
                   i + 6 <= contentEnd, base[i] == 0x5C, base[i + 1] == 0x75 {
                    let low = UInt32(hex4(base, i + 2))
                    if low >= 0xDC00 && low <= 0xDFFF {
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        i += 6
                    }
                }
                guard let unicode = Unicode.Scalar(scalar) else {
                    // A lone surrogate is not a scalar; U+FFFD says so without
                    // failing a request over one byte of someone's text.
                    out.append(contentsOf: Array("\u{FFFD}".utf8))
                    continue
                }
                out.append(contentsOf: Array(String(unicode).utf8))
            default:
                throw JSONError.syntax(offset: i)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func hasEscape(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end {
            if base[i] == 0x5C { return true }
            i += 1
        }
        return false
    }

    private static func hex4(_ base: UnsafePointer<UInt8>, _ index: Int) -> Int {
        var value = 0
        for i in 0..<4 {
            value = value << 4 | max(0, hexValue(base[index + i]))
        }
        return value
    }

    /// The number at `index`, as an integer. A fraction or an exponent is not
    /// one: `1.0` decodes as a Double, not as an Int.
    static func integer(_ base: UnsafePointer<UInt8>, _ count: Int, at index: Int,
                        _ path: @autoclosure () -> [any CodingKey],
                        expected: @autoclosure () -> String) throws -> (UInt64, Bool) {
        guard base[index] == 0x2D || (base[index] >= 0x30 && base[index] <= 0x39) else {
            if base[index] == 0x6E {
                throw JSONError.valueNotFound(path: describe(path()), expected: expected())
            }
            throw JSONError.typeMismatch(path: describe(path()), expected: expected())
        }
        var i = index
        let negative = base[i] == 0x2D
        if negative { i += 1 }
        var magnitude: UInt64 = 0
        let digitsStart = i
        while i < count, base[i] >= 0x30, base[i] <= 0x39 {
            let digit = UInt64(base[i] - 0x30)
            let (product, overflowedProduct) = magnitude.multipliedReportingOverflow(by: 10)
            guard !overflowedProduct else { throw JSONError.numberOutOfRange(path: describe(path())) }
            let (sum, overflowedSum) = product.addingReportingOverflow(digit)
            guard !overflowedSum else { throw JSONError.numberOutOfRange(path: describe(path())) }
            magnitude = sum
            i += 1
        }
        guard i > digitsStart else {
            throw JSONError.typeMismatch(path: describe(path()), expected: expected())
        }
        if i < count, base[i] == 0x2E || base[i] == 0x65 || base[i] == 0x45 {
            throw JSONError.typeMismatch(path: describe(path()), expected: expected())
        }
        return (magnitude, negative)
    }

    static func double(_ base: UnsafePointer<UInt8>, _ count: Int, at index: Int,
                       _ path: @autoclosure () -> [any CodingKey]) throws -> Double {
        guard base[index] == 0x2D || (base[index] >= 0x30 && base[index] <= 0x39) else {
            if base[index] == 0x6E {
                throw JSONError.valueNotFound(path: describe(path()), expected: "Double")
            }
            throw JSONError.typeMismatch(path: describe(path()), expected: "Double")
        }
        var scanner = JSONScanner(base: base, count: count, at: index)
        try scanner.skipNumber()
        let length = scanner.index - index
        // strtod needs its own NUL-terminated copy; a JSON number long enough
        // to matter is already far past a Double's precision.
        let value = withUnsafeTemporaryAllocation(of: CChar.self, capacity: length + 1) { scratch in
            for i in 0..<length { scratch[i] = CChar(bitPattern: base[index + i]) }
            scratch[length] = 0
            return strtod(scratch.baseAddress!, nil)
        }
        // `1e400` is a JSON number and not a Double. Infinity here would be a
        // value the encoder then refuses to write back.
        guard value.isFinite else { throw JSONError.numberOutOfRange(path: describe(path())) }
        return value
    }

    /// Whether the string literal between `start` and `end` reads as `name`.
    /// Compared as bytes where the literal has no escape in it, which is
    /// every key in practice, so finding a member makes no string.
    static func literal(_ base: UnsafePointer<UInt8>, from start: Int, to end: Int,
                        equals name: String) throws -> Bool {
        let contentStart = start + 1
        let length = end - 1 - contentStart
        if !hasEscape(base, contentStart, end - 1) {
            let same = name.utf8.withContiguousStorageIfAvailable { wanted -> Bool in
                wanted.count == length
                    && (length == 0 || memcmp(wanted.baseAddress!, base + contentStart, length) == 0)
            }
            if let same { return same }
        }
        return try text(base, from: start, to: end) == name
    }
}

// MARK: - The decoder

struct JSONDecoding: Decoder {
    let base: UnsafePointer<UInt8>
    let count: Int
    let valueIndex: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard base[valueIndex] == 0x7B else {
            throw JSONError.typeMismatch(path: describe(codingPath), expected: "an object")
        }
        return KeyedDecodingContainer(
            JSONKeyedDecoding<Key>(base: base, count: count, objectIndex: valueIndex, path: path))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard base[valueIndex] == 0x5B else {
            throw JSONError.typeMismatch(path: describe(codingPath), expected: "an array")
        }
        return JSONUnkeyedDecoding(base: base, count: count, arrayIndex: valueIndex, path: path)
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        JSONSingleValueDecoding(base: base, count: count, valueIndex: valueIndex, path: path)
    }
}

/// Reads one value at an offset, for every scalar type a container decodes.
///
/// It holds the path of the container the value is in and the step to the
/// value, rather than the value's own path: that is only put together for an
/// error, or for a value that is itself a container.
private struct JSONValueReader {
    let base: UnsafePointer<UInt8>
    let count: Int
    let index: Int
    let container: JSONPath
    let step: JSONPath.Step?

    var path: JSONPath { step.map { container.appending($0) } ?? container }

    func bool() throws -> Bool { try JSONValue.bool(base, count, at: index, path.keys) }
    func string() throws -> String { try JSONValue.string(base, count, at: index, path.keys) }
    func double() throws -> Double { try JSONValue.double(base, count, at: index, path.keys) }

    func signed<T: FixedWidthInteger & SignedInteger>(_ type: T.Type) throws -> T {
        let (magnitude, negative) = try JSONValue.integer(base, count, at: index, path.keys,
                                                          expected: "\(type)")
        if negative {
            guard magnitude <= UInt64(T.max.magnitude) + (T.min == 0 ? 0 : 1) else {
                throw JSONError.numberOutOfRange(path: describe(path.keys))
            }
            guard let value = T(exactly: Int64(bitPattern: ~magnitude &+ 1)) else {
                throw JSONError.numberOutOfRange(path: describe(path.keys))
            }
            return value
        }
        guard let value = T(exactly: magnitude) else {
            throw JSONError.numberOutOfRange(path: describe(path.keys))
        }
        return value
    }

    func unsigned<T: FixedWidthInteger & UnsignedInteger>(_ type: T.Type) throws -> T {
        let (magnitude, negative) = try JSONValue.integer(base, count, at: index, path.keys,
                                                          expected: "\(type)")
        guard !negative, let value = T(exactly: magnitude) else {
            throw JSONError.numberOutOfRange(path: describe(path.keys))
        }
        return value
    }

    /// The standard library's scalars are read directly. `Array` and
    /// `Optional` decode their elements through the generic `decode<T>`,
    /// never the overload for the element's own type, so without this every
    /// string in an array paid for a path, a decoder and a boxed
    /// single-value container of its own.
    func decoded<T: Decodable>(_ type: T.Type) throws -> T {
        if T.self == String.self { return unsafeBitCast(try string(), to: T.self) }
        if T.self == Int.self { return unsafeBitCast(try signed(Int.self), to: T.self) }
        if T.self == Bool.self { return unsafeBitCast(try bool(), to: T.self) }
        if T.self == Double.self { return unsafeBitCast(try double(), to: T.self) }
        if T.self == Int64.self { return unsafeBitCast(try signed(Int64.self), to: T.self) }
        if T.self == Int32.self { return unsafeBitCast(try signed(Int32.self), to: T.self) }
        if T.self == UInt64.self { return unsafeBitCast(try unsigned(UInt64.self), to: T.self) }
        if T.self == UInt.self { return unsafeBitCast(try unsigned(UInt.self), to: T.self) }
        return try T(from: JSONDecoding(base: base, count: count, valueIndex: index, path: path))
    }

    var isNull: Bool { JSONValue.isNull(base, count, at: index) }
}

private struct JSONKeyedDecoding<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let base: UnsafePointer<UInt8>
    let count: Int
    let objectIndex: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }

    var allKeys: [Key] {
        var keys: [Key] = []
        try? forEachMember { keyStart, keyEnd, valueIndex in
            let name = try JSONValue.text(base, from: keyStart, to: keyEnd)
            if let key = Key(stringValue: name) { keys.append(key) }
            _ = valueIndex
            return true
        }
        return keys
    }

    func contains(_ key: Key) -> Bool {
        (try? offset(of: key)) ?? nil != nil
    }

    /// Walks the object's members, handing `body` where each key's literal
    /// starts and ends and where its value starts. `body` returns false to
    /// stop.
    private func forEachMember(_ body: (Int, Int, Int) throws -> Bool) throws {
        var scanner = JSONScanner(base: base, count: count, at: objectIndex + 1)
        scanner.skipWhitespace()
        if scanner.peek() == 0x7D { return }
        while true {
            scanner.skipWhitespace()
            let keyStart = scanner.index
            try scanner.skipString()
            let keyEnd = scanner.index
            scanner.skipWhitespace()
            scanner.index += 1  // :
            scanner.skipWhitespace()
            let valueIndex = scanner.index
            if try !body(keyStart, keyEnd, valueIndex) { return }
            try scanner.skipValue()
            scanner.skipWhitespace()
            guard let byte = scanner.peek(), byte == 0x2C else { return }
            scanner.index += 1
        }
    }

    /// Where the value for `key` starts, or nil.
    private func offset(of key: Key) throws -> Int? {
        var found: Int? = nil
        let wanted = key.stringValue
        try forEachMember { keyStart, keyEnd, valueIndex in
            if try JSONValue.literal(base, from: keyStart, to: keyEnd, equals: wanted) {
                found = valueIndex
                return false
            }
            return true
        }
        return found
    }

    private func reader(_ key: Key) throws -> JSONValueReader {
        guard let index = try offset(of: key) else {
            throw JSONError.missingKey(path: describe(codingPath + [key]))
        }
        return JSONValueReader(base: base, count: count, index: index, container: path,
                               step: .key(key))
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let index = try offset(of: key) else { return true }
        return JSONValue.isNull(base, count, at: index)
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try reader(key).bool() }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try reader(key).string() }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try reader(key).double() }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { Float(try reader(key).double()) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try reader(key).signed(Int.self) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try reader(key).signed(Int8.self) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try reader(key).signed(Int16.self) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try reader(key).signed(Int32.self) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try reader(key).signed(Int64.self) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try reader(key).unsigned(UInt.self) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try reader(key).unsigned(UInt8.self) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try reader(key).unsigned(UInt16.self) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try reader(key).unsigned(UInt32.self) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try reader(key).unsigned(UInt64.self) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        try reader(key).decoded(type)
    }

    // An optional member, found with one walk of the object. The standard
    // library's own `decodeIfPresent` asks `contains`, then `decodeNil`, then
    // `decode`: three walks for every optional field of every value decoded.

    /// A reader for `key` when it is there and not null.
    private func presentReader(_ key: Key) throws -> JSONValueReader? {
        guard let index = try offset(of: key), !JSONValue.isNull(base, count, at: index) else { return nil }
        return JSONValueReader(base: base, count: count, index: index, container: path, step: .key(key))
    }

    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool? { try presentReader(key)?.bool() }
    func decodeIfPresent(_ type: String.Type, forKey key: Key) throws -> String? { try presentReader(key)?.string() }
    func decodeIfPresent(_ type: Double.Type, forKey key: Key) throws -> Double? { try presentReader(key)?.double() }
    func decodeIfPresent(_ type: Float.Type, forKey key: Key) throws -> Float? {
        try presentReader(key).map { Float(try $0.double()) }
    }
    func decodeIfPresent(_ type: Int.Type, forKey key: Key) throws -> Int? { try presentReader(key)?.signed(Int.self) }
    func decodeIfPresent(_ type: Int8.Type, forKey key: Key) throws -> Int8? { try presentReader(key)?.signed(Int8.self) }
    func decodeIfPresent(_ type: Int16.Type, forKey key: Key) throws -> Int16? { try presentReader(key)?.signed(Int16.self) }
    func decodeIfPresent(_ type: Int32.Type, forKey key: Key) throws -> Int32? { try presentReader(key)?.signed(Int32.self) }
    func decodeIfPresent(_ type: Int64.Type, forKey key: Key) throws -> Int64? { try presentReader(key)?.signed(Int64.self) }
    func decodeIfPresent(_ type: UInt.Type, forKey key: Key) throws -> UInt? { try presentReader(key)?.unsigned(UInt.self) }
    func decodeIfPresent(_ type: UInt8.Type, forKey key: Key) throws -> UInt8? { try presentReader(key)?.unsigned(UInt8.self) }
    func decodeIfPresent(_ type: UInt16.Type, forKey key: Key) throws -> UInt16? { try presentReader(key)?.unsigned(UInt16.self) }
    func decodeIfPresent(_ type: UInt32.Type, forKey key: Key) throws -> UInt32? { try presentReader(key)?.unsigned(UInt32.self) }
    func decodeIfPresent(_ type: UInt64.Type, forKey key: Key) throws -> UInt64? { try presentReader(key)?.unsigned(UInt64.self) }

    func decodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
        try presentReader(key)?.decoded(type)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = try reader(key).index
        guard base[index] == 0x7B else {
            throw JSONError.typeMismatch(path: describe(codingPath + [key]), expected: "an object")
        }
        return KeyedDecodingContainer(
            JSONKeyedDecoding<NestedKey>(base: base, count: count, objectIndex: index,
                                         path: path.appending(.key(key))))
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let index = try reader(key).index
        guard base[index] == 0x5B else {
            throw JSONError.typeMismatch(path: describe(codingPath + [key]), expected: "an array")
        }
        return JSONUnkeyedDecoding(base: base, count: count, arrayIndex: index,
                                   path: path.appending(.key(key)))
    }

    func superDecoder() throws -> any Decoder {
        JSONDecoding(base: base, count: count, valueIndex: objectIndex, path: path)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        let index = try reader(key).index
        return JSONDecoding(base: base, count: count, valueIndex: index,
                            path: path.appending(.key(key)))
    }
}

private struct JSONUnkeyedDecoding: UnkeyedDecodingContainer {
    let base: UnsafePointer<UInt8>
    /// The whole document's length. `count` belongs to the protocol, and is
    /// how many elements this array holds.
    let length: Int
    let arrayIndex: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }
    var currentIndex = 0
    let count: Int?
    /// Where the next element starts, once the elements before it have been
    /// stepped over.
    private var cursor: Int

    init(base: UnsafePointer<UInt8>, count length: Int, arrayIndex: Int, path: JSONPath) {
        self.base = base
        self.length = length
        self.arrayIndex = arrayIndex
        self.path = path
        var scanner = JSONScanner(base: base, count: length, at: arrayIndex + 1)
        scanner.skipWhitespace()
        cursor = scanner.index
        // The elements, counted once: an array decoding into a Swift array
        // asks so that it can reserve the room.
        var counting = scanner
        var elements = 0
        if counting.peek() != 0x5D {
            while (try? counting.skipValue()) != nil {
                elements += 1
                counting.skipWhitespace()
                guard counting.peek() == 0x2C else { break }
                counting.index += 1
                counting.skipWhitespace()
            }
        }
        count = elements
    }

    /// The path of the element about to be read.
    var this: JSONPath { path.appending(.index(currentIndex)) }

    var isAtEnd: Bool {
        var scanner = JSONScanner(base: base, count: length, at: cursor)
        scanner.skipWhitespace()
        return scanner.peek() == 0x5D || scanner.peek() == nil
    }

    /// The offset of the element about to be read, having stepped past it.
    private mutating func take() throws -> JSONValueReader {
        guard !isAtEnd else {
            throw JSONError.valueNotFound(path: describe(this.keys), expected: "another element")
        }
        var scanner = JSONScanner(base: base, count: length, at: cursor)
        scanner.skipWhitespace()
        let index = scanner.index
        let reader = JSONValueReader(base: base, count: length, index: index, container: path,
                                     step: .index(currentIndex))
        try scanner.skipValue()
        scanner.skipWhitespace()
        if scanner.peek() == 0x2C { scanner.index += 1 }
        cursor = scanner.index
        currentIndex += 1
        return reader
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        var scanner = JSONScanner(base: base, count: length, at: cursor)
        scanner.skipWhitespace()
        guard JSONValue.isNull(base, length, at: scanner.index) else { return false }
        _ = try take()
        return true
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try take().bool() }
    mutating func decode(_ type: String.Type) throws -> String { try take().string() }
    mutating func decode(_ type: Double.Type) throws -> Double { try take().double() }
    mutating func decode(_ type: Float.Type) throws -> Float { Float(try take().double()) }
    mutating func decode(_ type: Int.Type) throws -> Int { try take().signed(Int.self) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try take().signed(Int8.self) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try take().signed(Int16.self) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try take().signed(Int32.self) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try take().signed(Int64.self) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try take().unsigned(UInt.self) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try take().unsigned(UInt8.self) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try take().unsigned(UInt16.self) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try take().unsigned(UInt32.self) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try take().unsigned(UInt64.self) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try take().decoded(type) }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let element = this
        let reader = try take()
        guard base[reader.index] == 0x7B else {
            throw JSONError.typeMismatch(path: describe(element.keys), expected: "an object")
        }
        return KeyedDecodingContainer(
            JSONKeyedDecoding<NestedKey>(base: base, count: length, objectIndex: reader.index,
                                         path: element))
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let element = this
        let reader = try take()
        guard base[reader.index] == 0x5B else {
            throw JSONError.typeMismatch(path: describe(element.keys), expected: "an array")
        }
        return JSONUnkeyedDecoding(base: base, count: length, arrayIndex: reader.index,
                                   path: element)
    }

    mutating func superDecoder() throws -> any Decoder {
        let element = this
        let reader = try take()
        return JSONDecoding(base: base, count: length, valueIndex: reader.index, path: element)
    }
}

private struct JSONSingleValueDecoding: SingleValueDecodingContainer {
    let base: UnsafePointer<UInt8>
    let count: Int
    let valueIndex: Int
    let path: JSONPath
    var codingPath: [any CodingKey] { path.keys }

    private var reader: JSONValueReader {
        JSONValueReader(base: base, count: count, index: valueIndex, container: path, step: nil)
    }

    func decodeNil() -> Bool { reader.isNull }
    func decode(_ type: Bool.Type) throws -> Bool { try reader.bool() }
    func decode(_ type: String.Type) throws -> String { try reader.string() }
    func decode(_ type: Double.Type) throws -> Double { try reader.double() }
    func decode(_ type: Float.Type) throws -> Float { Float(try reader.double()) }
    func decode(_ type: Int.Type) throws -> Int { try reader.signed(Int.self) }
    func decode(_ type: Int8.Type) throws -> Int8 { try reader.signed(Int8.self) }
    func decode(_ type: Int16.Type) throws -> Int16 { try reader.signed(Int16.self) }
    func decode(_ type: Int32.Type) throws -> Int32 { try reader.signed(Int32.self) }
    func decode(_ type: Int64.Type) throws -> Int64 { try reader.signed(Int64.self) }
    func decode(_ type: UInt.Type) throws -> UInt { try reader.unsigned(UInt.self) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try reader.unsigned(UInt8.self) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try reader.unsigned(UInt16.self) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try reader.unsigned(UInt32.self) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try reader.unsigned(UInt64.self) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T { try reader.decoded(type) }
}
