//===----------------------------------------------------------------------===//
// Garuda's JSON coder: the writer, the errors, and the way in.
//
// `Encodable` and `Decodable` are in the standard library, but `JSONEncoder`
// and `JSONDecoder` are Foundation, which Garuda does not link. So the coder
// is here: `JSON.encode` writes a value's bytes, and `JSON.decode` reads a
// type straight out of the request's bytes, without building a dictionary of
// everything first (JSONDecoding.swift).
//
// The writer streams. Containers are not closed when their encoder goes away,
// which a value type cannot tell us about; instead every write first closes
// whatever is open deeper than the level it writes at, and `finish` closes the
// rest. Nesting is bounded, so neither a hostile document nor a recursive
// value can run the stack out.
//===----------------------------------------------------------------------===//

import GarudaCore

/// What a document, or a value, could not be.
public enum JSONError: Error, Equatable {
    /// The bytes are not JSON, at this offset.
    case syntax(offset: Int)
    /// More than `JSON.depthLimit` objects and arrays deep.
    case depthExceeded(offset: Int)
    /// A complete value, and then more bytes.
    case trailingBytes(offset: Int)
    /// The value at `path` is not of the type the decoder asked for.
    case typeMismatch(path: String, expected: String)
    /// The object at `path` has no such key.
    case missingKey(path: String)
    /// The value at `path` is null, where one was needed.
    case valueNotFound(path: String, expected: String)
    /// A number that does not fit the type asked for.
    case numberOutOfRange(path: String)
    /// A value that cannot be written as JSON, such as an infinite Double.
    case invalidValue(path: String, reason: String)
}

public enum JSON {
    /// How deeply objects and arrays may nest, reading or writing. Deep
    /// nesting is a cheap way to make a parser recurse until it dies, so it
    /// is bounded rather than trusted.
    public static let depthLimit = 64

    /// The JSON bytes for `value`.
    public static func encode(_ value: some Encodable) throws -> [UInt8] {
        let writer = JSONWriter()
        defer { writer.destroy() }
        try value.encode(to: JSONEncoding(writer: writer, level: -1, key: nil, codingPath: []))
        return try writer.finish()
    }

    /// The JSON bytes for `value`, appended to `buffer`. For a response that
    /// is written straight into the connection's own buffer.
    static func encode(_ value: some Encodable, into buffer: inout ByteBuffer) throws {
        let writer = JSONWriter()
        defer { writer.destroy() }
        try value.encode(to: JSONEncoding(writer: writer, level: -1, key: nil, codingPath: []))
        try writer.finish(into: &buffer)
    }
}

// MARK: - The writer

/// Writes JSON into a buffer as the containers above it are used. Shared by
/// every encoder and container of one `encode`, which is why it is a class:
/// the containers are values, and they all write here.
final class JSONWriter {
    enum Kind: UInt8 {
        case object = 0x7B  // {
        case array = 0x5B   // [

        var closing: UInt8 { self == .object ? 0x7D : 0x5D }
    }

    private var buffer = ByteBuffer()
    /// The containers still open, outermost first.
    private var open: [Kind] = []
    /// Whether each open container has had an element written into it.
    private var wrote: [Bool] = []
    /// The first failure from a call that could not throw, such as
    /// `Encoder.container(keyedBy:)`. Thrown by `finish`.
    private var failure: JSONError? = nil

    /// The level a container just begun writes its elements at.
    var currentLevel: Int { open.count - 1 }

    func destroy() {
        buffer.destroy()
    }

    /// Opens a container inside the container at `level`, and returns the
    /// level its own elements are written at.
    @discardableResult
    func begin(_ kind: Kind, level: Int, key: String?) -> Int {
        guard open.count < JSON.depthLimit else {
            record(.depthExceeded(offset: buffer.readableBytes))
            return level
        }
        prepare(level: level, key: key)
        buffer.reserve(1)
        buffer.writeByte(kind.rawValue)
        open.append(kind)
        wrote.append(false)
        return open.count - 1
    }

    func writeNull(level: Int, key: String?) {
        prepare(level: level, key: key)
        buffer.write("null")
    }

    func write(_ value: Bool, level: Int, key: String?) {
        prepare(level: level, key: key)
        if value { buffer.write("true") } else { buffer.write("false") }
    }

    func write(_ value: Int64, level: Int, key: String?) {
        prepare(level: level, key: key)
        writeInteger(value)
    }

    func write(_ value: UInt64, level: Int, key: String?) {
        prepare(level: level, key: key)
        writeUnsigned(value, negative: false)
    }

    func write(_ value: Double, level: Int, key: String?, path: @autoclosure () -> String) {
        guard value.isFinite else {
            record(.invalidValue(path: path(),
                                 reason: value.isNaN ? "NaN is not a JSON number"
                                                     : "infinity is not a JSON number"))
            return
        }
        prepare(level: level, key: key)
        // The standard library's own description is the shortest form that
        // reads back as the same value, and it is always valid JSON for a
        // finite Double: digits, an optional sign, a point, an exponent.
        var text = String(value)
        text.withUTF8 { buffer.write($0.baseAddress!, $0.count) }
    }

    func write(_ value: String, level: Int, key: String?) {
        prepare(level: level, key: key)
        writeString(value)
    }

    /// Everything still open, closed, and the bytes.
    func finish() throws -> [UInt8] {
        try close()
        guard buffer.readableBytes > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: buffer.readPointer, count: buffer.readableBytes))
    }

    func finish(into out: inout ByteBuffer) throws {
        try close()
        guard buffer.readableBytes > 0 else { return }
        out.write(buffer.readPointer, buffer.readableBytes)
    }

    /// An encoder that wrote nothing at all -- a value with no container --
    /// still owes its parent a value.
    var isEmpty: Bool { buffer.readableBytes == 0 }

    func record(_ error: JSONError) {
        if failure == nil { failure = error }
    }

    private func close() throws {
        if let failure { throw failure }
        while !open.isEmpty { closeLast() }
    }

    private func closeLast() {
        let kind = open.removeLast()
        wrote.removeLast()
        buffer.reserve(1)
        buffer.writeByte(kind.closing)
    }

    /// Makes room for one element inside the container at `level` (-1 at the
    /// top level): closes anything open deeper, writes the separator the
    /// container needs, and writes `key` for an object.
    private func prepare(level: Int, key: String?) {
        while open.count > level + 1 { closeLast() }
        if level >= 0 && level < wrote.count {
            buffer.reserve(1)
            if wrote[level] { buffer.writeByte(cComma) }
            wrote[level] = true
        }
        if let key {
            writeString(key)
            buffer.reserve(1)
            buffer.writeByte(cColon)
        }
    }

    private func writeInteger(_ value: Int64) {
        if value < 0 {
            // Negated as a magnitude, so Int64.min does not overflow.
            writeUnsigned(UInt64(bitPattern: value).twosComplementMagnitude, negative: true)
        } else {
            writeUnsigned(UInt64(value), negative: false)
        }
    }

    private func writeUnsigned(_ value: UInt64, negative: Bool) {
        var digits = [UInt8](repeating: 0, count: 20)
        var count = 0
        var v = value
        repeat {
            digits[count] = UInt8(48 &+ (v % 10))
            v /= 10
            count += 1
        } while v > 0
        buffer.reserve(count + 1)
        if negative { buffer.writeByte(cDash) }
        var i = count - 1
        while i >= 0 {
            buffer.writeByte(digits[i])
            i -= 1
        }
    }

    /// A JSON string: the quotes, the two escapes that must be escaped, and
    /// the control characters. Everything else, UTF-8 included, is passed
    /// through as it came.
    private func writeString(_ value: String) {
        var value = value
        value.withUTF8 { bytes in
            buffer.reserve(bytes.count + 2)
            buffer.writeByte(0x22)
            for byte in bytes {
                switch byte {
                case 0x22: buffer.write("\\\"")
                case 0x5C: buffer.write("\\\\")
                case 0x08: buffer.write("\\b")
                case 0x0C: buffer.write("\\f")
                case 0x0A: buffer.write("\\n")
                case 0x0D: buffer.write("\\r")
                case 0x09: buffer.write("\\t")
                case 0x00..<0x20:
                    buffer.write("\\u00")
                    buffer.reserve(2)
                    buffer.writeByte(hexDigit(byte >> 4))
                    buffer.writeByte(hexDigit(byte & 0xF))
                default:
                    buffer.reserve(1)
                    buffer.writeByte(byte)
                }
            }
            buffer.reserve(1)
            buffer.writeByte(0x22)
        }
    }

    private func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? 48 &+ value : 87 &+ value
    }
}

extension UInt64 {
    /// The magnitude of the negative `Int64` with this bit pattern.
    fileprivate var twosComplementMagnitude: UInt64 { ~self &+ 1 }
}
