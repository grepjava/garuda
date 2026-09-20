//===----------------------------------------------------------------------===//
// Writing JSON without Codable.
//
// The other half of JSONReading.swift. A type that conforms to
// `JSONWritable` appends its own bytes rather than going through an encoder,
// a container and a path for every member: encoding a small answer costs 2.5
// microseconds through Codable and 1.7 this way, and neither number includes
// the metadata Codable fetches to get there.
//
// `JSONOutput` is a buffer and nothing else. It keeps no state about what is
// open, because generated code cannot get the order wrong: the macro writes
// the braces, the commas and the keys. A conformance written by hand has to
// be as careful.
//===----------------------------------------------------------------------===//

import AvianCore

/// The bytes of a document being written.
public struct JSONOutput {
    /// What has been written so far.
    public private(set) var bytes: [UInt8]
    /// The first thing found that cannot be written, if anything was. The
    /// document is refused rather than sent, as through Codable.
    public private(set) var problem: JSONError?
    /// The member being written, to name in that problem. A macro writes a
    /// key before each member, so this is the member's name without anyone
    /// keeping a path.
    private var lastKey: StaticString?

    /// Starts an empty document, with room for `capacity` bytes.
    public init(capacity: Int = 256) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    /// Empties it, keeping the room it has already taken. A worker reuses
    /// one buffer for every answer.
    public mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        problem = nil
        lastKey = nil
    }

    /// Records something that cannot be written. The first one is kept: it
    /// is the one that explains the rest.
    public mutating func note(_ error: JSONError) {
        if problem == nil { problem = error }
    }

    // MARK: - Shape

    /// `{`
    public mutating func beginObject() { bytes.append(0x7B) }
    /// `}`
    public mutating func endObject() { bytes.append(0x7D) }
    /// `[`
    public mutating func beginArray() { bytes.append(0x5B) }
    /// `]`
    public mutating func endArray() { bytes.append(0x5D) }
    /// `,`
    public mutating func comma() { bytes.append(0x2C) }
    /// `:`, for a key that was written as a string rather than a literal.
    public mutating func colon() { bytes.append(0x3A) }

    /// The comma before the next element of an array, where one is due.
    /// Called before each element, including the first.
    public mutating func element() { separate() }

    /// A comma, unless what was written last was an opening brace or
    /// bracket, or nothing at all.
    private mutating func separate() {
        guard let last = bytes.last, last != 0x7B, last != 0x5B else { return }
        bytes.append(0x2C)
    }

    /// A member's name and the colon after it, with the comma before it
    /// where one is due. What is due is known from the last byte written --
    /// an object or array that has just opened needs none -- so generated
    /// code never has to count members, which is what makes a member that is
    /// left out when it is nil safe to leave out.
    ///
    /// The name is written as it is: a key needing an escape is the caller's
    /// to escape, and `@JSON` refuses a member whose name would.
    public mutating func key(_ name: StaticString) {
        lastKey = name
        separate()
        bytes.append(0x22)
        bytes.append(contentsOf: UnsafeBufferPointer(start: name.utf8Start,
                                                     count: name.utf8CodeUnitCount))
        bytes.append(0x22)
        bytes.append(0x3A)
    }

    // MARK: - Values

    /// `null`
    public mutating func writeNull() {
        append("null")
    }

    /// `true` or `false`
    public mutating func write(_ value: Bool) {
        append(value ? "true" : "false")
    }

    /// The bytes of a literal, which the compiler has already laid out.
    public mutating func append(_ word: StaticString) {
        bytes.append(contentsOf: UnsafeBufferPointer(start: word.utf8Start,
                                                     count: word.utf8CodeUnitCount))
    }

    /// A whole number, written straight into the buffer rather than through
    /// a `String`.
    public mutating func write<T: FixedWidthInteger>(_ value: T) {
        if value == 0 {
            bytes.append(0x30)
            return
        }
        if value < 0 { bytes.append(0x2D) }
        // On the stack: a number is written for nearly every answer, and an
        // array here was an allocation for each one.
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
            var written = 0
            var magnitude = value.magnitude
            while magnitude > 0 {
                digits[written] = 0x30 + UInt8(truncatingIfNeeded: magnitude % 10)
                magnitude /= 10
                written += 1
            }
            var i = written - 1
            while i >= 0 {
                bytes.append(digits[i])
                i -= 1
            }
        }
    }

    /// A number that may have a fraction. An infinity or a NaN is not a JSON
    /// number: it is remembered as a problem and the document is refused,
    /// which is what the Codable path does too.
    public mutating func write(_ value: Double) {
        guard value.isFinite else {
            note(.invalidValue(path: lastKey.map(String.init(describing:)) ?? "",
                               reason: value.isNaN ? "NaN is not a JSON number"
                                                   : "infinity is not a JSON number"))
            writeNull()
            return
        }
        // The standard library's own description is the shortest form that
        // reads back as the same value, and for a finite Double it is always
        // valid JSON. It is also what the Codable path writes, and a type
        // that gains its own writer must not change what it sends.
        var text = String(value)
        text.withUTF8 { utf8 in
            bytes.append(contentsOf: UnsafeBufferPointer(start: utf8.baseAddress!,
                                                         count: utf8.count))
        }
    }

    /// The same for a `Float`.
    public mutating func write(_ value: Float) {
        write(Double(value))
    }

    /// A string, quoted, with whatever needs escaping escaped.
    public mutating func write(_ value: String) {
        bytes.append(0x22)
        var text = value
        text.withUTF8 { utf8 in
            var start = 0
            var i = 0
            while i < utf8.count {
                let byte = utf8[i]
                // Everything below a space, and the two characters JSON
                // gives a meaning to, must be escaped; the rest is copied in
                // runs, so a string with nothing to escape is one append.
                if byte >= 0x20 && byte != 0x22 && byte != 0x5C {
                    i += 1
                    continue
                }
                if i > start {
                    bytes.append(contentsOf: UnsafeBufferPointer(start: utf8.baseAddress! + start,
                                                                 count: i - start))
                }
                appendEscape(byte)
                i += 1
                start = i
            }
            if i > start {
                bytes.append(contentsOf: UnsafeBufferPointer(start: utf8.baseAddress! + start,
                                                             count: i - start))
            }
        }
        bytes.append(0x22)
    }

    private mutating func appendEscape(_ byte: UInt8) {
        switch byte {
        case 0x22: append(#"\""#)
        case 0x5C: append(#"\\"#)
        case 0x08: append(#"\b"#)
        case 0x0C: append(#"\f"#)
        case 0x0A: append(#"\n"#)
        case 0x0D: append(#"\r"#)
        case 0x09: append(#"\t"#)
        default:
            let hex: StaticString = "0123456789abcdef"
            append(#"\u00"#)
            bytes.append(hex.utf8Start[Int(byte >> 4)])
            bytes.append(hex.utf8Start[Int(byte & 0x0F)])
        }
    }

}

// MARK: - What can be written

/// A type that writes itself as JSON rather than through `Codable`.
///
/// `@JSON` writes the conformance; writing one by hand is the same work, with
/// a `JSONOutput`.
public protocol JSONWritable {
    /// Appends this value's JSON to `output`.
    func write(json output: inout JSONOutput)
}

extension Optional: JSONWritable where Wrapped: JSONWritable {
    public func write(json output: inout JSONOutput) {
        switch self {
        case .none: output.writeNull()
        case .some(let value): value.write(json: &output)
        }
    }
}

extension Array: JSONWritable where Element: JSONWritable {
    public func write(json output: inout JSONOutput) {
        output.beginArray()
        for value in self {
            output.element()
            value.write(json: &output)
        }
        output.endArray()
    }
}
