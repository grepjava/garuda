//===----------------------------------------------------------------------===//
// Reading JSON without Codable.
//
// `Codable` describes a type's shape once and decides everything else at run
// time: containers are existentials, keys are looked up through them, and the
// metadata for each is fetched again for every document. Measured in a worker
// rather than in a loop, decoding a small body through Codable costs 3.8
// microseconds of a request that is otherwise 8.
//
// A type that conforms to `JSONReadable` reads itself instead, walking the
// bytes with a `JSONReader`: no containers, no metadata, no boxes. The same
// body then costs 0.8 microseconds. Writing that out is dull and easy to get
// wrong, so `@JSON` writes it; this is what it writes against, and what a
// conformance written by hand uses too.
//
// The coder finds the conformance itself (JSONFastPath.swift), so no call
// site changes: `Body<Order>` reads this way for a type that has it and the
// Codable way for a type that does not.
//===----------------------------------------------------------------------===//

import AvianCore

/// A key just read from an object, as the bytes it is: matching one costs a
/// length and a comparison rather than a `String`.
public struct JSONName {
    @usableFromInline let base: UnsafePointer<UInt8>
    /// How many bytes the key is, as written.
    public let count: Int
    /// Whether the key is written with an escape in it, and so is not the
    /// name it spells. Rare, and `matches` handles it.
    public let escaped: Bool

    @inlinable
    init(base: UnsafePointer<UInt8>, count: Int, escaped: Bool) {
        self.base = base
        self.count = count
        self.escaped = escaped
    }

    /// Whether this key is `name`.
    @inlinable
    public func matches(_ name: StaticString) -> Bool {
        guard !escaped else { return spelledOut() == name.description }
        guard count == name.utf8CodeUnitCount else { return false }
        return count == 0 || memcmp(base, name.utf8Start, count) == 0
    }

    /// The name the key spells, escapes undone. For a message, for a
    /// dictionary, and for the rare escaped key.
    public var spelled: String {
        (try? JSONValue.text(base - 1, from: 0, to: count + 2)) ?? ""
    }

    /// The same, for the rare escaped key, where `matches` needs it.
    @usableFromInline
    func spelledOut() -> String { spelled }
}

/// Walks a JSON document, reading values out of it.
///
/// It owns nothing: the bytes belong to whoever lent them, a request body
/// most often, and must outlive it. Every read moves past what it read, or
/// throws and leaves the reader where the trouble is.
public struct JSONReader {
    @usableFromInline let base: UnsafePointer<UInt8>
    @usableFromInline let count: Int
    /// How far reading has got.
    public var index: Int

    /// Reads the document in `base`, which is `count` bytes long.
    @inlinable
    public init(base: UnsafePointer<UInt8>, count: Int, at index: Int = 0) {
        self.base = base
        self.count = count
        self.index = index
    }

    /// Reads `type` out of `bytes`, which must be the whole document.
    public static func decode<T: JSONReadable>(_ type: T.Type = T.self,
                                               from bytes: Span<UInt8>) throws -> T {
        try bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, buffer.count > 0 else {
                throw JSONError.syntax(offset: 0)
            }
            return try decode(type, from: base, count: buffer.count)
        }
    }

    /// Reads `type` out of bytes lent by the engine.
    public static func decode<T: JSONReadable>(_ type: T.Type = T.self,
                                               from base: UnsafePointer<UInt8>,
                                               count: Int) throws -> T {
        var reader = JSONReader(base: base, count: count)
        let value = try T(json: &reader)
        reader.skipSpace()
        guard reader.index == count else { throw JSONError.trailingBytes(offset: reader.index) }
        return value
    }

    // MARK: - Where reading is

    /// The byte reading is at, or nil at the end.
    @inlinable
    public var current: UInt8? { index < count ? base[index] : nil }

    /// Moves past spaces, tabs and newlines.
    @inlinable
    public mutating func skipSpace() {
        while index < count {
            let byte = base[index]
            guard byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D else { return }
            index += 1
        }
    }

    /// Moves past one whole value, whatever it is. For a key the type does
    /// not know: unknown members are ignored, as they are through Codable.
    public mutating func skipValue() throws {
        var scanner = JSONScanner(base: base, count: count, at: index)
        try scanner.skipValue()
        index = scanner.index
    }

    /// The error for a value that is not what the type needs.
    @inlinable
    public func mismatch(_ expected: String) -> JSONError {
        .typeMismatch(path: "", expected: expected)
    }

    @usableFromInline
    mutating func take(_ byte: UInt8) -> Bool {
        skipSpace()
        guard index < count, base[index] == byte else { return false }
        index += 1
        return true
    }

    // MARK: - Objects

    /// Opens an object, or throws where the value is not one.
    @inlinable
    public mutating func beginObject() throws {
        guard take(0x7B) else { throw mismatch("an object") }
    }

    /// The next key of an object, or nil once the object has ended. What
    /// follows a key is read next, or passed over with `skipValue`.
    @inlinable
    public mutating func nextKey() throws -> JSONName? {
        skipSpace()
        if index < count, base[index] == 0x2C {
            index += 1
            skipSpace()
        }
        if index < count, base[index] == 0x7D {
            index += 1
            return nil
        }
        guard index < count, base[index] == 0x22 else { throw JSONError.syntax(offset: index) }
        // One pass. The document was proved to be JSON before any of it was
        // read (JSONDecoding.swift), so what is inside an escape does not
        // have to be checked again here -- only stepped over, so that a
        // quote written \" does not end the key.
        let start = index + 1
        var end = start
        var escaped = false
        while end < count, base[end] != 0x22 {
            if base[end] == 0x5C {
                escaped = true
                end += 1
            }
            end += 1
        }
        guard end < count else { throw JSONError.syntax(offset: index) }
        index = end + 1
        skipSpace()
        guard index < count, base[index] == 0x3A else { throw JSONError.syntax(offset: index) }
        index += 1
        return JSONName(base: base + start, count: end - start, escaped: escaped)
    }

    // MARK: - Arrays

    /// Opens an array, or throws where the value is not one.
    @inlinable
    public mutating func beginArray() throws {
        guard take(0x5B) else { throw mismatch("an array") }
    }

    /// Whether the array has another element, which is then read. Called
    /// before each one, including the first.
    @inlinable
    public mutating func nextElement() throws -> Bool {
        skipSpace()
        if index < count, base[index] == 0x2C {
            index += 1
            skipSpace()
        }
        if index < count, base[index] == 0x5D {
            index += 1
            return false
        }
        guard index < count else { throw JSONError.syntax(offset: index) }
        return true
    }

    // MARK: - Values

    /// Reads a value and names it in whatever goes wrong, so that a body
    /// refused for its shape says which member was wrong. Nothing is built
    /// unless something throws.
    @inlinable
    public mutating func read<T: JSONReadable>(_ type: T.Type = T.self,
                                               named name: StaticString) throws -> T {
        do {
            return try T(json: &self)
        } catch let error as JSONError {
            throw error.under(name.description)
        }
    }

    /// The same for an element of an array, named by its place in it.
    @inlinable
    public mutating func read<T: JSONReadable>(_ type: T.Type = T.self,
                                               at position: Int) throws -> T {
        do {
            return try T(json: &self)
        } catch let error as JSONError {
            throw error.under("[\(position)]")
        }
    }

    /// Whether the value is `null`, which is then read.
    @inlinable
    public mutating func takeNull() -> Bool {
        skipSpace()
        guard index + 4 <= count, base[index] == 0x6E else { return false }
        index += 4
        return true
    }

    /// Reads a string.
    @inlinable
    public mutating func string() throws -> String {
        skipSpace()
        guard index < count else { throw mismatch("a string") }
        guard base[index] == 0x22 else {
            throw base[index] == 0x6E ? JSONError.valueNotFound(path: "", expected: "String")
                                      : mismatch("a string")
        }
        // The common case is a string with no escape in it, and then the
        // bytes are the text: one pass to find the end, and one copy.
        let start = index + 1
        var end = start
        while end < count, base[end] != 0x22, base[end] != 0x5C { end += 1 }
        guard end < count else { throw JSONError.syntax(offset: index) }
        if base[end] == 0x22 {
            let text = String(decoding: UnsafeBufferPointer(start: base + start,
                                                            count: end - start), as: UTF8.self)
            index = end + 1
            return text
        }
        return try stringWithEscapes()
    }

    /// A string with an escape in it, which is undone rather than copied.
    @usableFromInline
    mutating func stringWithEscapes() throws -> String {
        var scanner = JSONScanner(base: base, count: count, at: index)
        try scanner.skipString()
        let text = try JSONValue.text(base, from: index, to: scanner.index)
        index = scanner.index
        return text
    }

    /// Reads a whole number.
    @inlinable
    public mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        skipSpace()
        guard index < count else { throw mismatch("\(type)") }
        // Read and stepped over at once. A number too long to be a UInt64,
        // or one with a fraction or an exponent, falls through to the
        // reading that reports which it was.
        var at = index
        let negative = base[at] == 0x2D
        if negative { at += 1 }
        var magnitude: UInt64 = 0
        let digitsFrom = at
        var overflowed = false
        while at < count, base[at] >= 0x30, base[at] <= 0x39 {
            let (product, times) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, plus) = product.addingReportingOverflow(UInt64(base[at] - 0x30))
            if times || plus { overflowed = true }
            magnitude = sum
            at += 1
        }
        let fraction = at < count && (base[at] == 0x2E || base[at] == 0x65 || base[at] == 0x45)
        if at > digitsFrom, !overflowed, !fraction {
            index = at
            return try narrow(magnitude, negative: negative, to: T.self)
        }
        return try integerTheLongWay(T.self)
    }

    /// A number that the pass above would not take: too long for a UInt64,
    /// or with a fraction or an exponent, which is not a whole number.
    @usableFromInline
    mutating func integerTheLongWay<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let (magnitude, negative) = try JSONValue.integer(base, count, at: index, [],
                                                          expected: "\(type)")
        try skipNumber()
        return try narrow(magnitude, negative: negative, to: T.self)
    }

    /// The magnitude and sign just read, as the type that asked for them.
    @usableFromInline
    func narrow<T: FixedWidthInteger>(_ magnitude: UInt64, negative: Bool,
                                              to type: T.Type) throws -> T {
        if negative {
            guard T.isSigned, magnitude <= UInt64(T.max.magnitude) + 1,
                  let value = T(exactly: Int64(bitPattern: ~magnitude &+ 1)) else {
                throw JSONError.numberOutOfRange(path: "")
            }
            return value
        }
        guard let value = T(exactly: magnitude) else {
            throw JSONError.numberOutOfRange(path: "")
        }
        return value
    }

    /// Reads a number that may have a fraction or an exponent.
    public mutating func double() throws -> Double {
        skipSpace()
        guard index < count else { throw mismatch("Double") }
        let value = try JSONValue.double(base, count, at: index, [])
        try skipNumber()
        return value
    }

    /// Reads true or false.
    @inlinable
    public mutating func boolean() throws -> Bool {
        skipSpace()
        guard index < count else { throw mismatch("Bool") }
        switch base[index] {
        case 0x74: index += 4; return true
        case 0x66: index += 5; return false
        case 0x6E: throw JSONError.valueNotFound(path: "", expected: "Bool")
        default: throw mismatch("Bool")
        }
    }

    @usableFromInline
    mutating func skipNumber() throws {
        var scanner = JSONScanner(base: base, count: count, at: index)
        try scanner.skipNumber()
        index = scanner.index
    }
}

// MARK: - What can be read

/// A type that reads itself out of JSON bytes rather than through `Codable`.
///
/// `@JSON` writes the conformance; writing one by hand is the same work, with
/// a `JSONReader`.
public protocol JSONReadable {
    /// Reads one value, leaving the reader just past it.
    init(json reader: inout JSONReader) throws
}

extension String: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.string() }
}

extension Bool: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.boolean() }
}

extension Double: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.double() }
}

extension Float: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = Float(try reader.double()) }
}

extension Int: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension Int8: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension Int16: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension Int32: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension Int64: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension UInt: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension UInt8: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension UInt16: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension UInt32: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension UInt64: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws { self = try reader.integer() }
}

extension Optional: JSONReadable where Wrapped: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws {
        self = reader.takeNull() ? .none : .some(try Wrapped(json: &reader))
    }
}

extension Array: JSONReadable where Element: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws {
        try reader.beginArray()
        var elements: [Element] = []
        // Room for a few, so a short list is not grown twice while it is
        // read. A longer one grows as any array does.
        elements.reserveCapacity(8)
        var position = 0
        while try reader.nextElement() {
            elements.append(try reader.read(Element.self, at: position))
            position += 1
        }
        self = elements
    }
}

extension Dictionary: JSONReadable where Key == String, Value: JSONReadable {
    @inlinable
    public init(json reader: inout JSONReader) throws {
        try reader.beginObject()
        var pairs: [String: Value] = [:]
        while let key = try reader.nextKey() {
            let name = key.spelled
            do {
                pairs[name] = try Value(json: &reader)
            } catch let error as JSONError {
                throw error.under(name)
            }
        }
        self = pairs
    }
}

// MARK: - Naming what went wrong

extension JSONError {
    /// The same trouble, one step further in: a member's name or an index is
    /// put in front of the path the error already carries.
    @usableFromInline
    func under(_ step: String) -> JSONError {
        func join(_ path: String) -> String {
            if path.isEmpty { return step }
            if path.hasPrefix("[") { return step + path }
            return step + "." + path
        }
        switch self {
        case .typeMismatch(let path, let expected):
            return .typeMismatch(path: join(path), expected: expected)
        case .missingKey(let path):
            return .missingKey(path: join(path))
        case .valueNotFound(let path, let expected):
            return .valueNotFound(path: join(path), expected: expected)
        case .numberOutOfRange(let path):
            return .numberOutOfRange(path: join(path))
        case .invalidValue(let path, let reason):
            return .invalidValue(path: join(path), reason: reason)
        case .syntax, .depthExceeded, .trailingBytes:
            return self
        }
    }
}
