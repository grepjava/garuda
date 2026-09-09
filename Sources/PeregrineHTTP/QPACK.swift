//===----------------------------------------------------------------------===//
// QPACK (RFC 9204): header compression for HTTP/3.
//
// QPACK exists because HPACK cannot work over QUIC. HPACK's dynamic table is a
// running conversation -- what a field means depends on every field that came
// before it -- and QUIC delivers streams independently, so a header block can
// arrive before the instructions that gave its indices meaning. QPACK's answer
// is to move the dynamic table onto its own stream and let a header block say
// how much of that stream it depends on, so a decoder knows when it must wait.
//
// This server does not take part in that. It advertises a dynamic table
// capacity of zero, which forbids the peer from inserting anything, and it
// inserts nothing itself. What is left is the static table, literals and
// Huffman coding -- the same Huffman coding as HPACK, reused here unchanged --
// and no stream can ever block on another. The cost is a few more bytes per
// request; the gain is that head-of-line blocking, the thing HTTP/3 exists to
// remove, cannot come back in through the compressor.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import PeregrineCore

public enum QPACKError: Error {
    case truncated
    case badIndex
    case badPrefix
    case badHuffman
    /// A reference to the dynamic table, which cannot exist when the
    /// advertised capacity is zero.
    case dynamicTableReference
    case tooLarge
}

// MARK: - Static table

/// The static table, copied once into stable C memory so that a lookup yields
/// a pointer rather than a `String.withUTF8` dance per field.
public enum QPACKStatic {
    nonisolated(unsafe) private static var storage: UnsafeMutablePointer<UInt8>! = nil
    nonisolated(unsafe) private static var spans: UnsafeMutablePointer<HPACKSpan>! = nil
    public static var count: Int { QPACKTables.staticTable.count }

    static let ready: Bool = {
        var total = 0
        for entry in QPACKTables.staticTable {
            total += entry.0.utf8.count + entry.1.utf8.count
        }
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
        spans = UnsafeMutablePointer<HPACKSpan>.allocate(capacity: QPACKTables.staticTable.count)
        var cursor = 0
        for (i, entry) in QPACKTables.staticTable.enumerated() {
            let nameOffset = cursor
            for byte in entry.0.utf8 {
                storage[cursor] = byte
                cursor += 1
            }
            let valueOffset = cursor
            for byte in entry.1.utf8 {
                storage[cursor] = byte
                cursor += 1
            }
            spans[i] = HPACKSpan(name: UnsafePointer(storage + nameOffset),
                                 nameLength: valueOffset - nameOffset,
                                 value: UnsafePointer(storage + valueOffset),
                                 valueLength: cursor - valueOffset)
        }
        return true
    }()

    /// Indexed from zero, unlike HPACK's.
    public static func entry(_ index: Int) -> HPACKSpan? {
        _ = ready
        if index < 0 || index >= count { return nil }
        return spans[index]
    }

    /// The first slot carrying this name, and separately the slot carrying
    /// this exact pair when there is one. Many names appear several times with
    /// different values, so the two answers are not the same question.
    public static func lookup(_ name: UnsafePointer<UInt8>, _ nameLength: Int,
                              _ value: UnsafePointer<UInt8>, _ valueLength: Int)
        -> (name: Int?, full: Int?) {
        _ = ready
        var nameIndex: Int?
        var i = 0
        while i < count {
            let s = spans[i]
            if s.nameLength == nameLength && memcmp(s.name, name, nameLength) == 0 {
                if nameIndex == nil { nameIndex = i }
                if s.valueLength == valueLength
                    && (valueLength == 0 || memcmp(s.value, value, valueLength) == 0) {
                    return (nameIndex, i)
                }
            }
            i += 1
        }
        return (nameIndex, nil)
    }
}

// MARK: - Decoding

public struct QPACKDecoder {
    /// Somewhere to put decoded literals, which have to outlive the block they
    /// came from only until the caller has copied what it wants.
    @usableFromInline var scratch = ByteBuffer()
    public var maximumFieldSectionSize = 64 * 1024

    public init() {}

    public mutating func destroy() { scratch.destroy() }

    /// Decodes one field section, calling `emit` for each field. Spans point
    /// either into the static table or into the decoder's scratch buffer, and
    /// stay valid until the next call.
    ///
    /// The scratch buffer is filled before any field is emitted, because a
    /// literal decoded later must not be able to move memory an earlier span
    /// still points at.
    public mutating func decode(_ p: UnsafePointer<UInt8>, _ n: Int,
                                _ emit: (HPACKSpan) throws -> Void) throws {
        scratch.clear()
        var cursor = 0

        // Field section prefix. With a dynamic table capacity of zero the only
        // legal values are zero, but they are still encoded and still have to
        // be read.
        let requiredInsertCount = try readInteger(p, n, &cursor, prefixBits: 8)
        if requiredInsertCount != 0 { throw QPACKError.dynamicTableReference }
        if cursor >= n { throw QPACKError.truncated }
        let deltaBase = try readInteger(p, n, &cursor, prefixBits: 7)
        if deltaBase != 0 { throw QPACKError.badPrefix }

        // Two passes: gather, then emit. Literals accumulate in `scratch`,
        // which may reallocate, so nothing may hold a pointer into it until it
        // has stopped growing.
        var fields: [(nameOffset: Int, nameLength: Int,
                      valueOffset: Int, valueLength: Int, staticIndex: Int)] = []
        var total = 0

        while cursor < n {
            let first = p[cursor]
            if first & 0x80 != 0 {
                // Indexed field line.
                if first & 0x40 == 0 { throw QPACKError.dynamicTableReference }
                let index = try readInteger(p, n, &cursor, prefixBits: 6)
                guard let entry = QPACKStatic.entry(index) else { throw QPACKError.badIndex }
                total += entry.nameLength + entry.valueLength + 32
                fields.append((0, 0, 0, 0, index))
            } else if first & 0xC0 == 0x40 {
                // Literal with a name reference.
                if first & 0x10 == 0 { throw QPACKError.dynamicTableReference }
                let index = try readInteger(p, n, &cursor, prefixBits: 4)
                guard let entry = QPACKStatic.entry(index) else { throw QPACKError.badIndex }
                let value = try readString(p, n, &cursor)
                total += entry.nameLength + value.length + 32
                fields.append((-1 - index, 0, value.offset, value.length, -1))
            } else if first & 0xE0 == 0x20 {
                // Literal with a literal name.
                let huffman = first & 0x08 != 0
                let nameLength = try readInteger(p, n, &cursor, prefixBits: 3)
                let name = try readRaw(p, n, &cursor, nameLength, huffman: huffman)
                let value = try readString(p, n, &cursor)
                total += name.length + value.length + 32
                fields.append((name.offset, name.length, value.offset, value.length, -1))
            } else {
                // Post-base references, which only mean something when the
                // dynamic table is in use.
                throw QPACKError.dynamicTableReference
            }
            if total > maximumFieldSectionSize { throw QPACKError.tooLarge }
        }

        let base = scratch.allocated ? scratch.readPointer : nil
        for field in fields {
            if field.staticIndex >= 0 {
                guard let entry = QPACKStatic.entry(field.staticIndex) else {
                    throw QPACKError.badIndex
                }
                try emit(entry)
                continue
            }
            let valuePointer: UnsafePointer<UInt8>
            if field.valueLength > 0 {
                guard let base else { throw QPACKError.truncated }
                valuePointer = UnsafePointer(base + field.valueOffset)
            } else {
                valuePointer = QPACKStatic.entry(0)!.name    // any valid pointer
            }
            if field.nameOffset < 0 {
                // A name borrowed from the static table.
                guard let entry = QPACKStatic.entry(-1 - field.nameOffset) else {
                    throw QPACKError.badIndex
                }
                try emit(HPACKSpan(name: entry.name, nameLength: entry.nameLength,
                                   value: valuePointer, valueLength: field.valueLength))
            } else {
                guard let base else { throw QPACKError.truncated }
                try emit(HPACKSpan(name: UnsafePointer(base + field.nameOffset),
                                   nameLength: field.nameLength,
                                   value: valuePointer, valueLength: field.valueLength))
            }
        }
    }

    @inline(__always)
    private func readInteger(_ p: UnsafePointer<UInt8>, _ n: Int, _ cursor: inout Int,
                             prefixBits: Int) throws -> Int {
        // QPACK reuses HPACK's integer encoding unchanged.
        do {
            return try hpackReadInteger(p, n, &cursor, prefixBits: prefixBits)
        } catch HPACKError.truncated {
            throw QPACKError.truncated
        } catch {
            throw QPACKError.badIndex
        }
    }

    private mutating func readString(_ p: UnsafePointer<UInt8>, _ n: Int,
                                     _ cursor: inout Int) throws -> (offset: Int, length: Int) {
        if cursor >= n { throw QPACKError.truncated }
        let huffman = p[cursor] & 0x80 != 0
        let length = try readInteger(p, n, &cursor, prefixBits: 7)
        return try readRaw(p, n, &cursor, length, huffman: huffman)
    }

    private mutating func readRaw(_ p: UnsafePointer<UInt8>, _ n: Int, _ cursor: inout Int,
                                  _ length: Int,
                                  huffman: Bool) throws -> (offset: Int, length: Int) {
        if length < 0 || n - cursor < length { throw QPACKError.truncated }
        let offset = scratch.readableBytes
        if huffman {
            do {
                let produced = try HPACKHuffman.decode(p + cursor, length, into: &scratch)
                cursor += length
                return (offset, produced)
            } catch {
                throw QPACKError.badHuffman
            }
        }
        scratch.write(p + cursor, length)
        cursor += length
        return (offset, length)
    }
}

// MARK: - Encoding

public struct QPACKEncoder {
    public init() {}

    /// Opens a field section. With no dynamic table there is nothing to depend
    /// on, so the prefix is two zeroes -- but it is not optional.
    public func begin(into out: inout ByteBuffer) {
        out.writeByte(0)        // required insert count
        out.writeByte(0)        // S bit clear, delta base 0
    }

    public func encode(name: UnsafePointer<UInt8>, nameLength: Int,
                       value: UnsafePointer<UInt8>, valueLength: Int,
                       into out: inout ByteBuffer) {
        let found = QPACKStatic.lookup(name, nameLength, value, valueLength)
        if let full = found.full {
            // Indexed field line, static table.
            hpackWriteInteger(full, prefixBits: 6, flags: 0xC0, into: &out)
            return
        }
        if let nameIndex = found.name {
            // Literal with a static name reference: 0 1 N T index(4+), with T
            // set for the static table and N clear -- nothing this server
            // sends is so sensitive that an intermediary must be told never to
            // index it.
            hpackWriteInteger(nameIndex, prefixBits: 4, flags: 0x50, into: &out)
            encodeString(value, valueLength, into: &out)
            return
        }
        // Literal with a literal name: 0 0 1 N H index(3+).
        let huffmanLength = HPACKHuffman.encodedLength(name, nameLength)
        if huffmanLength < nameLength {
            hpackWriteInteger(huffmanLength, prefixBits: 3, flags: 0x28, into: &out)
            HPACKHuffman.encode(name, nameLength, into: &out)
        } else {
            hpackWriteInteger(nameLength, prefixBits: 3, flags: 0x20, into: &out)
            out.write(name, nameLength)
        }
        encodeString(value, valueLength, into: &out)
    }

    public func encodeString(_ p: UnsafePointer<UInt8>, _ n: Int, into out: inout ByteBuffer) {
        let huffmanLength = HPACKHuffman.encodedLength(p, n)
        if huffmanLength < n {
            hpackWriteInteger(huffmanLength, prefixBits: 7, flags: 0x80, into: &out)
            HPACKHuffman.encode(p, n, into: &out)
        } else {
            hpackWriteInteger(n, prefixBits: 7, flags: 0x00, into: &out)
            out.write(p, n)
        }
    }

    /// A status line, which is nearly always in the static table.
    public func encodeStatus(_ status: Int, into out: inout ByteBuffer) {
        // The static table carries 103, 200, 304, 404 and 503 outright.
        let index: Int?
        switch status {
        case 103: index = 24
        case 200: index = 25
        case 304: index = 26
        case 404: index = 27
        case 503: index = 28
        default: index = nil
        }
        if let index {
            hpackWriteInteger(index, prefixBits: 6, flags: 0xC0, into: &out)
            return
        }
        // Otherwise a literal value against :status, which is slot 24.
        hpackWriteInteger(24, prefixBits: 4, flags: 0x50, into: &out)
        var digits = (UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &digits) { raw in
            let d = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            d[0] = UInt8(48 + (status / 100) % 10)
            d[1] = UInt8(48 + (status / 10) % 10)
            d[2] = UInt8(48 + status % 10)
            hpackWriteInteger(3, prefixBits: 7, flags: 0x00, into: &out)
            out.write(d, 3)
        }
    }
}
