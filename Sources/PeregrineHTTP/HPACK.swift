//===----------------------------------------------------------------------===//
// HPACK: header compression for HTTP/2 (RFC 7541).
//
// Decoding hands (name, value) to a callback as raw pointers rather than
// building objects. The pointers are valid for the duration of the call and no
// longer -- they may point into the static table, into the dynamic table's
// arena, or into a staging buffer. The caller copies what it wants, which for
// this server means appending it to a synthesised request head. That keeps a
// compressed header block from costing one allocation per field.
//
// The dynamic table is a FIFO of descriptors over an append-only byte arena.
// Eviction moves a watermark rather than the bytes; the arena is compacted only
// when it has grown well past the negotiated table size, so the steady state is
// a memcpy per inserted field and nothing else.
//
// The encoder never uses incremental indexing. Sending indexed field lines
// would mean maintaining a mirror of the peer's table, and would save a few
// bytes on responses whose headers barely repeat; Huffman coding of literals
// gets most of the benefit for none of the bookkeeping.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import PeregrineCore

public enum HPACKError: Error, Equatable {
    /// The block ended in the middle of a field.
    case truncated
    /// An index that names no entry, or index 0 where one is required.
    case badIndex
    /// A varint too large to be meant seriously.
    case integerOverflow
    /// Padding that is not all ones, an EOS symbol, or an over-long code.
    case badHuffman
    /// A dynamic table size update above the negotiated maximum.
    case badTableSize
    /// The decoded block is larger than this connection allows.
    case tooLarge
}

/// A name/value pair as borrowed bytes.
public struct HPACKSpan {
    public var name: UnsafePointer<UInt8>
    public var nameLength: Int
    public var value: UnsafePointer<UInt8>
    public var valueLength: Int

    public init(name: UnsafePointer<UInt8>, nameLength: Int,
                value: UnsafePointer<UInt8>, valueLength: Int) {
        self.name = name
        self.nameLength = nameLength
        self.value = value
        self.valueLength = valueLength
    }
}

// MARK: - Static table

/// The static table with its strings copied once into stable C memory, so a
/// lookup is a pointer rather than a `String.withUTF8` dance per field.
public enum HPACKStatic {
    nonisolated(unsafe) private static var storage: UnsafeMutablePointer<UInt8>! = nil
    nonisolated(unsafe) private static var spans: UnsafeMutablePointer<HPACKSpan>! = nil
    public static var count: Int { HPACKTables.staticTable.count }

    static let ready: Bool = {
        var total = 0
        for entry in HPACKTables.staticTable {
            total += entry.name.utf8.count + entry.value.utf8.count
        }
        storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
        spans = UnsafeMutablePointer<HPACKSpan>.allocate(capacity: HPACKTables.staticTable.count)
        var cursor = 0
        for (i, entry) in HPACKTables.staticTable.enumerated() {
            let nameOffset = cursor
            for byte in entry.name.utf8 {
                storage[cursor] = byte
                cursor += 1
            }
            let valueOffset = cursor
            for byte in entry.value.utf8 {
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

    public static func entry(_ index: Int) -> HPACKSpan {
        _ = ready
        return spans[index - 1]
    }

    /// The static index of a header name, or nil. Linear over 61 entries and
    /// only for response headers, so the loop is cheaper than a hash table.
    public static func nameIndex(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int? {
        _ = ready
        var i = 0
        while i < count {
            let s = spans[i]
            if s.nameLength == n && memcmp(s.name, p, n) == 0 { return i + 1 }
            i += 1
        }
        return nil
    }
}

// MARK: - Huffman

public enum HPACKHuffman {

    /// Canonical decoding tables, derived once from the code lengths.
    ///
    /// Deriving rather than tabulating is deliberate: it is a proof, run at
    /// start-up, that the committed table really is the canonical code the
    /// decoder assumes it is.
    struct Tables {
        /// Symbols ordered by (length, code).
        var symbols: [UInt16]
        /// First code of each length, and where its symbols start.
        var firstCode: [UInt32]
        var firstIndex: [Int]
        var count: [Int]
    }

    static let tables: Tables = {
        let lengths = HPACKTables.huffmanLengths
        var count = [Int](repeating: 0, count: 31)
        for l in lengths { count[Int(l)] += 1 }

        var firstCode = [UInt32](repeating: 0, count: 31)
        var firstIndex = [Int](repeating: 0, count: 31)
        var code: UInt32 = 0
        var index = 0
        var len = 1
        while len <= 30 {
            firstCode[len] = code
            firstIndex[len] = index
            index += count[len]
            code = (code &+ UInt32(count[len])) << 1
            len += 1
        }

        var symbols = [UInt16](repeating: 0, count: lengths.count)
        var cursor = firstIndex
        for (symbol, l) in lengths.enumerated() {
            let bucket = Int(l)
            symbols[cursor[bucket]] = UInt16(symbol)
            cursor[bucket] += 1
        }
        return Tables(symbols: symbols, firstCode: firstCode,
                      firstIndex: firstIndex, count: count)
    }()

    /// True when the committed codes match the ones the lengths imply. The
    /// decoder works from the lengths, so a table failing this would decode
    /// differently from every other HPACK implementation.
    public static func tablesAreCanonical() -> Bool {
        let t = tables
        for (symbol, l) in HPACKTables.huffmanLengths.enumerated() {
            let len = Int(l)
            var position = -1
            var i = 0
            while i < t.count[len] {
                if t.symbols[t.firstIndex[len] + i] == UInt16(symbol) { position = i; break }
                i += 1
            }
            if position < 0 { return false }
            if t.firstCode[len] &+ UInt32(position) != HPACKTables.huffmanCodes[symbol] {
                return false
            }
        }
        return true
    }

    /// Decodes `n` bytes into `out`. Returns the number of bytes produced.
    public static func decode(_ p: UnsafePointer<UInt8>, _ n: Int,
                              into out: inout ByteBuffer) throws -> Int {
        let t = tables
        // Worst case is one output byte per five input bits.
        out.reserve(n * 8 / 5 + 1)
        var produced = 0
        var code: UInt32 = 0
        var len = 0
        var i = 0
        while i < n {
            let byte = p[i]
            i += 1
            var bit = 7
            while bit >= 0 {
                code = (code << 1) | UInt32((byte >> UInt8(bit)) & 1)
                len += 1
                bit -= 1
                if len > 30 { throw HPACKError.badHuffman }
                if len < 5 { continue }
                let c = t.count[len]
                if c == 0 { continue }
                let offset = code &- t.firstCode[len]
                if offset >= UInt32(c) { continue }
                let symbol = t.symbols[t.firstIndex[len] + Int(offset)]
                // 256 is EOS, which may never appear in a literal.
                if symbol > 255 { throw HPACKError.badHuffman }
                out.writeByte(UInt8(truncatingIfNeeded: symbol))
                produced += 1
                code = 0
                len = 0
            }
        }
        // Whatever is left has to be a strict prefix of the all-ones EOS code.
        // Anything else is either a symbol the encoder could not fit or padding
        // chosen to smuggle bytes past a decoder that does not check.
        if len >= 8 { throw HPACKError.badHuffman }
        if len > 0 {
            let ones = (UInt32(1) << UInt32(len)) &- 1
            if code != ones { throw HPACKError.badHuffman }
        }
        return produced
    }

    /// Encoded length in bytes, for deciding whether Huffman is worth it.
    public static func encodedLength(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        var bits = 0
        var i = 0
        HPACKTables.huffmanLengths.withUnsafeBufferPointer { lengths in
            while i < n {
                bits += Int(lengths[Int(p[i])])
                i += 1
            }
        }
        return (bits + 7) / 8
    }

    public static func encode(_ p: UnsafePointer<UInt8>, _ n: Int,
                              into out: inout ByteBuffer) {
        var accumulator: UInt64 = 0
        var bits = 0
        HPACKTables.huffmanLengths.withUnsafeBufferPointer { lengths in
            HPACKTables.huffmanCodes.withUnsafeBufferPointer { codes in
                var i = 0
                while i < n {
                    let symbol = Int(p[i])
                    i += 1
                    let len = Int(lengths[symbol])
                    accumulator = (accumulator << UInt64(len)) | UInt64(codes[symbol])
                    bits += len
                    while bits >= 8 {
                        bits -= 8
                        out.writeByte(UInt8(truncatingIfNeeded: accumulator >> UInt64(bits)))
                    }
                }
            }
        }
        if bits > 0 {
            // Pad with the EOS prefix, which is all ones.
            let pad = 8 - bits
            let last = (accumulator << UInt64(pad)) | ((1 << UInt64(pad)) - 1)
            out.writeByte(UInt8(truncatingIfNeeded: last))
        }
    }
}

// MARK: - Integers

/// Reads an RFC 7541 variable-length integer with a `prefixBits`-bit prefix,
/// advancing `cursor` past it.
public func hpackReadInteger(_ p: UnsafePointer<UInt8>, _ n: Int, _ cursor: inout Int,
                             prefixBits: Int) throws -> Int {
    if cursor >= n { throw HPACKError.truncated }
    let mask = (1 << prefixBits) - 1
    var value = Int(p[cursor]) & mask
    cursor += 1
    if value < mask { return value }
    var shift = 0
    while true {
        if cursor >= n { throw HPACKError.truncated }
        let byte = p[cursor]
        cursor += 1
        if shift > 21 { throw HPACKError.integerOverflow }
        value += Int(byte & 0x7F) << shift
        if value > (1 << 30) { throw HPACKError.integerOverflow }
        if byte & 0x80 == 0 { break }
        shift += 7
    }
    return value
}

public func hpackWriteInteger(_ value: Int, prefixBits: Int, flags: UInt8,
                              into out: inout ByteBuffer) {
    let mask = (1 << prefixBits) - 1
    if value < mask {
        out.writeByte(flags | UInt8(value))
        return
    }
    out.writeByte(flags | UInt8(mask))
    var rest = value - mask
    while rest >= 0x80 {
        out.writeByte(UInt8(truncatingIfNeeded: (rest & 0x7F) | 0x80))
        rest >>= 7
    }
    out.writeByte(UInt8(truncatingIfNeeded: rest))
}

// MARK: - Decoder

public struct HPACKDecoder {
    /// One dynamic table entry, as offsets into `arena`.
    struct Entry {
        var nameOffset: Int
        var nameLength: Int
        var valueOffset: Int
        var valueLength: Int
        /// RFC 7541 section 4.1: the entry's cost in table-size terms.
        var cost: Int { nameLength + valueLength + 32 }
    }

    var arena = ByteBuffer()
    /// Oldest live byte in the arena; everything before it has been evicted.
    var liveStart = 0
    /// Newest entry last. HPACK index 1 is the newest, so lookups count back.
    var entries: [Entry] = []
    var tableSize = 0
    /// The table size in force, which the peer may change downward at will.
    public private(set) var maxTableSize: Int
    /// The largest size we have told the peer it may use.
    var permittedMaxSize: Int

    var scratch = ByteBuffer()
    var staging = ByteBuffer()

    public init(maxTableSize: Int = 4096) {
        self.maxTableSize = maxTableSize
        self.permittedMaxSize = maxTableSize
    }

    public mutating func destroy() {
        arena.destroy()
        scratch.destroy()
        staging.destroy()
        entries.removeAll()
    }

    /// Called when our own SETTINGS_HEADER_TABLE_SIZE changes.
    public mutating func setPermittedMaxSize(_ n: Int) {
        permittedMaxSize = n
        if maxTableSize > n { setMaxSize(n) }
    }

    mutating func setMaxSize(_ n: Int) {
        maxTableSize = n
        evictToFit(0)
    }

    // MARK: Dynamic table

    mutating func evictToFit(_ incoming: Int) {
        while tableSize + incoming > maxTableSize && !entries.isEmpty {
            let victim = entries.removeFirst()
            tableSize -= victim.cost
            liveStart = victim.valueOffset + victim.valueLength
        }
        if entries.isEmpty {
            tableSize = 0
            arena.clear()
            liveStart = 0
        }
    }

    mutating func compactArenaIfNeeded() {
        // Only worth doing once the dead prefix dominates; entries are small
        // and the negotiated table is normally 4 KiB.
        if liveStart == 0 || arena.readableBytes < 4 * maxTableSize + 4096 { return }
        let total = arena.readableBytes
        let live = total - liveStart
        if live > 0 {
            memmove(arena.pointer(at: 0), arena.pointer(at: liveStart), live)
        }
        arena.clear()
        arena.advanceWriter(live)
        for i in entries.indices {
            entries[i].nameOffset -= liveStart
            entries[i].valueOffset -= liveStart
        }
        liveStart = 0
    }

    mutating func insert(_ name: UnsafePointer<UInt8>, _ nameLength: Int,
                         _ value: UnsafePointer<UInt8>, _ valueLength: Int) {
        let cost = nameLength + valueLength + 32
        evictToFit(cost)
        // An entry larger than the whole table empties it and is not stored.
        if cost > maxTableSize { return }
        compactArenaIfNeeded()
        let nameOffset = arena.readableBytes
        arena.write(name, nameLength)
        let valueOffset = arena.readableBytes
        arena.write(value, valueLength)
        entries.append(Entry(nameOffset: nameOffset, nameLength: nameLength,
                             valueOffset: valueOffset, valueLength: valueLength))
        tableSize += cost
    }

    public var dynamicEntryCount: Int { entries.count }
    public var dynamicTableSize: Int { tableSize }

    /// Resolves a table index, static or dynamic.
    func entry(at index: Int) throws -> HPACKSpan {
        if index <= HPACKStatic.count { return HPACKStatic.entry(index) }
        let position = entries.count - (index - HPACKStatic.count)
        if position < 0 || position >= entries.count { throw HPACKError.badIndex }
        let e = entries[position]
        let base = UnsafePointer(arena.pointer(at: 0))
        return HPACKSpan(name: base + e.nameOffset, nameLength: e.nameLength,
                         value: base + e.valueOffset, valueLength: e.valueLength)
    }

    // MARK: Decoding

    /// Decodes one header block, calling `emit` for each field in order.
    ///
    /// The dynamic table is updated as the block is read, so a block whose
    /// fields the caller rejects still has to be decoded in full: HPACK is
    /// stateful, and skipping one block decodes every later one to nonsense.
    /// That is why `emit` cannot fail -- rejection happens after the fact.
    public mutating func decode(_ p: UnsafePointer<UInt8>, _ n: Int,
                                sizeLimit: Int = Int.max,
                                emit: (HPACKSpan) -> Void) throws {
        var cursor = 0
        var decodedSize = 0
        var sawField = false
        while cursor < n {
            let first = p[cursor]

            if first & 0x80 != 0 {
                // Indexed header field.
                let index = try hpackReadInteger(p, n, &cursor, prefixBits: 7)
                if index == 0 { throw HPACKError.badIndex }
                let span = try entry(at: index)
                decodedSize += span.nameLength + span.valueLength + 32
                if decodedSize > sizeLimit { throw HPACKError.tooLarge }
                emit(span)
                sawField = true
                continue
            }

            if first & 0xE0 == 0x20 {
                // Dynamic table size update, only legal before any field.
                if sawField { throw HPACKError.badTableSize }
                let size = try hpackReadInteger(p, n, &cursor, prefixBits: 5)
                if size > permittedMaxSize { throw HPACKError.badTableSize }
                setMaxSize(size)
                continue
            }

            let indexed = first & 0xC0 == 0x40
            let prefixBits = indexed ? 6 : 4
            let nameIndex = try hpackReadInteger(p, n, &cursor, prefixBits: prefixBits)

            // Name and value are staged together, so that inserting into the
            // dynamic table cannot move the bytes out from under `emit`.
            staging.clear()
            staging.reserve(64)
            var nameLength = 0
            if nameIndex == 0 {
                nameLength = try HPACKDecoder.readString(p, n, &cursor,
                                                        scratch: &scratch, into: &staging)
            } else {
                let span = try entry(at: nameIndex)
                staging.write(span.name, span.nameLength)
                nameLength = span.nameLength
            }
            let valueLength = try HPACKDecoder.readString(p, n, &cursor,
                                                          scratch: &scratch, into: &staging)

            decodedSize += nameLength + valueLength + 32
            if decodedSize > sizeLimit { throw HPACKError.tooLarge }

            let namePointer = UnsafePointer(staging.pointer(at: 0))
            let valuePointer = namePointer + nameLength
            if indexed {
                insert(namePointer, nameLength, valuePointer, valueLength)
            }
            emit(HPACKSpan(name: namePointer, nameLength: nameLength,
                           value: valuePointer, valueLength: valueLength))
            sawField = true
        }
    }

    /// Reads one length-prefixed string literal, appending it to `out`.
    /// Returns the number of bytes appended.
    /// Static so that the decoder can lend out two of its own buffers at
    /// once; a method would be an exclusive borrow of the whole decoder.
    static func readString(_ p: UnsafePointer<UInt8>, _ n: Int,
                           _ cursor: inout Int,
                           scratch: inout ByteBuffer,
                           into out: inout ByteBuffer) throws -> Int {
        if cursor >= n { throw HPACKError.truncated }
        let huffman = p[cursor] & 0x80 != 0
        let length = try hpackReadInteger(p, n, &cursor, prefixBits: 7)
        if length > n - cursor { throw HPACKError.truncated }
        defer { cursor += length }
        if !huffman {
            out.write(p + cursor, length)
            return length
        }
        scratch.clear()
        let produced = try HPACKHuffman.decode(p + cursor, length, into: &scratch)
        if produced > 0 {
            out.write(UnsafePointer(scratch.pointer(at: 0)), produced)
        }
        return produced
    }
}

// MARK: - Encoder

/// Response header encoding. Stateless: every field goes out as a literal
/// without indexing, with a static name index where one exists.
public struct HPACKEncoder {
    public init() {}

    /// `:status` values that have their own static table entry.
    static func statusIndex(_ status: Int) -> Int? {
        switch status {
        case 200: return 8
        case 204: return 9
        case 206: return 10
        case 304: return 11
        case 400: return 12
        case 404: return 13
        case 500: return 14
        default: return nil
        }
    }

    public func encodeStatus(_ status: Int, into out: inout ByteBuffer) {
        if let index = HPACKEncoder.statusIndex(status) {
            hpackWriteInteger(index, prefixBits: 7, flags: 0x80, into: &out)
            return
        }
        // Literal without indexing, name index 8 (:status).
        hpackWriteInteger(8, prefixBits: 4, flags: 0x00, into: &out)
        var digits = (UInt8(0), UInt8(0), UInt8(0))
        withUnsafeMutableBytes(of: &digits) { raw in
            let d = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            d[0] = UInt8(48 + (status / 100) % 10)
            d[1] = UInt8(48 + (status / 10) % 10)
            d[2] = UInt8(48 + status % 10)
            encodeString(UnsafePointer(d), 3, into: &out)
        }
    }

    /// One header field as a literal without indexing.
    public func encode(name: UnsafePointer<UInt8>, nameLength: Int,
                       value: UnsafePointer<UInt8>, valueLength: Int,
                       into out: inout ByteBuffer) {
        if let index = HPACKStatic.nameIndex(name, nameLength) {
            hpackWriteInteger(index, prefixBits: 4, flags: 0x00, into: &out)
        } else {
            out.writeByte(0x00)
            encodeString(name, nameLength, into: &out)
        }
        encodeString(value, valueLength, into: &out)
    }

    public func encodeString(_ p: UnsafePointer<UInt8>, _ n: Int,
                             into out: inout ByteBuffer) {
        let huffmanLength = HPACKHuffman.encodedLength(p, n)
        if huffmanLength < n {
            hpackWriteInteger(huffmanLength, prefixBits: 7, flags: 0x80, into: &out)
            HPACKHuffman.encode(p, n, into: &out)
        } else {
            hpackWriteInteger(n, prefixBits: 7, flags: 0x00, into: &out)
            out.write(p, n)
        }
    }
}
