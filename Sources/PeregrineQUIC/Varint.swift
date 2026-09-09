//===----------------------------------------------------------------------===//
// QUIC variable-length integers, and the bounds-checked reader built on them.
//
// Nearly every field in QUIC is a varint: frame types, stream identifiers,
// offsets, lengths, error codes. The encoding puts the length in the top two
// bits of the first byte, so a value under 64 costs one byte and the full
// 62-bit range costs eight.
//
// The reader is a struct over borrowed memory with no ownership and no
// allocation: a datagram is parsed in place, straight out of the receive
// buffer. Every read is bounds-checked and returns nil rather than trapping,
// because the input is a packet from the network and a malformed one is
// routine, not exceptional.
//===----------------------------------------------------------------------===//

import PeregrineCore

@inlinable
public func quicVarintLength(_ value: UInt64) -> Int {
    if value < 0x40 { return 1 }
    if value < 0x4000 { return 2 }
    if value < 0x4000_0000 { return 4 }
    return 8
}

/// The largest value a varint can carry.
public let quicVarintMax: UInt64 = 0x3FFF_FFFF_FFFF_FFFF

@inlinable
public func quicWriteVarint(_ value: UInt64, _ out: UnsafeMutablePointer<UInt8>) -> Int {
    if value < 0x40 {
        out[0] = UInt8(truncatingIfNeeded: value)
        return 1
    }
    if value < 0x4000 {
        out[0] = UInt8(truncatingIfNeeded: value >> 8) | 0x40
        out[1] = UInt8(truncatingIfNeeded: value)
        return 2
    }
    if value < 0x4000_0000 {
        out[0] = UInt8(truncatingIfNeeded: value >> 24) | 0x80
        out[1] = UInt8(truncatingIfNeeded: value >> 16)
        out[2] = UInt8(truncatingIfNeeded: value >> 8)
        out[3] = UInt8(truncatingIfNeeded: value)
        return 4
    }
    out[0] = UInt8(truncatingIfNeeded: value >> 56) | 0xC0
    out[1] = UInt8(truncatingIfNeeded: value >> 48)
    out[2] = UInt8(truncatingIfNeeded: value >> 40)
    out[3] = UInt8(truncatingIfNeeded: value >> 32)
    out[4] = UInt8(truncatingIfNeeded: value >> 24)
    out[5] = UInt8(truncatingIfNeeded: value >> 16)
    out[6] = UInt8(truncatingIfNeeded: value >> 8)
    out[7] = UInt8(truncatingIfNeeded: value)
    return 8
}

/// Writes a varint into exactly `width` bytes. QUIC allows a value to be
/// encoded longer than it needs to be, which is what makes it possible to
/// reserve room for a length before knowing what it will be.
@inlinable
public func quicWriteVarint(_ value: UInt64, width: Int,
                            _ out: UnsafeMutablePointer<UInt8>) {
    switch width {
    case 1:
        out[0] = UInt8(truncatingIfNeeded: value)
    case 2:
        out[0] = UInt8(truncatingIfNeeded: value >> 8) | 0x40
        out[1] = UInt8(truncatingIfNeeded: value)
    case 4:
        out[0] = UInt8(truncatingIfNeeded: value >> 24) | 0x80
        out[1] = UInt8(truncatingIfNeeded: value >> 16)
        out[2] = UInt8(truncatingIfNeeded: value >> 8)
        out[3] = UInt8(truncatingIfNeeded: value)
    default:
        out[0] = UInt8(truncatingIfNeeded: value >> 56) | 0xC0
        out[1] = UInt8(truncatingIfNeeded: value >> 48)
        out[2] = UInt8(truncatingIfNeeded: value >> 40)
        out[3] = UInt8(truncatingIfNeeded: value >> 32)
        out[4] = UInt8(truncatingIfNeeded: value >> 24)
        out[5] = UInt8(truncatingIfNeeded: value >> 16)
        out[6] = UInt8(truncatingIfNeeded: value >> 8)
        out[7] = UInt8(truncatingIfNeeded: value)
    }
}

/// A cursor over borrowed bytes. Reads return nil when the input runs out.
public struct QUICReader {
    public let base: UnsafePointer<UInt8>
    public let count: Int
    public var offset: Int

    @inlinable
    public init(_ base: UnsafePointer<UInt8>, _ count: Int) {
        self.base = base
        self.count = count
        self.offset = 0
    }

    @inlinable
    public init(_ span: ByteSpan) {
        self.base = span.base
        self.count = span.count
        self.offset = 0
    }

    @inlinable public var remaining: Int { count &- offset }
    @inlinable public var isEmpty: Bool { offset >= count }

    @inlinable
    public mutating func byte() -> UInt8? {
        if offset >= count { return nil }
        let b = base[offset]
        offset &+= 1
        return b
    }

    @inlinable
    public func peek() -> UInt8? {
        offset < count ? base[offset] : nil
    }

    @inlinable
    public mutating func varint() -> UInt64? {
        if offset >= count { return nil }
        let first = base[offset]
        let width = 1 << Int(first >> 6)
        if count &- offset < width { return nil }
        var value = UInt64(first & 0x3F)
        var i = 1
        while i < width {
            value = (value << 8) | UInt64(base[offset &+ i])
            i &+= 1
        }
        offset &+= width
        return value
    }

    /// A varint that has to fit in Int, which every length and offset the
    /// server acts on must. A value that does not is not a length we could
    /// have honoured anyway.
    @inlinable
    public mutating func varintAsInt() -> Int? {
        guard let v = varint(), v <= UInt64(Int.max) else { return nil }
        return Int(v)
    }

    @inlinable
    public mutating func uint16() -> UInt16? {
        if count &- offset < 2 { return nil }
        let v = (UInt16(base[offset]) << 8) | UInt16(base[offset &+ 1])
        offset &+= 2
        return v
    }

    @inlinable
    public mutating func uint24() -> UInt32? {
        if count &- offset < 3 { return nil }
        let v = (UInt32(base[offset]) << 16) | (UInt32(base[offset &+ 1]) << 8)
              | UInt32(base[offset &+ 2])
        offset &+= 3
        return v
    }

    @inlinable
    public mutating func uint32() -> UInt32? {
        if count &- offset < 4 { return nil }
        let v = (UInt32(base[offset]) << 24) | (UInt32(base[offset &+ 1]) << 16)
              | (UInt32(base[offset &+ 2]) << 8) | UInt32(base[offset &+ 3])
        offset &+= 4
        return v
    }

    /// Borrows `n` bytes and advances past them.
    @inlinable
    public mutating func take(_ n: Int) -> UnsafePointer<UInt8>? {
        if n < 0 || count &- offset < n { return nil }
        let p = base + offset
        offset &+= n
        return p
    }

    @inlinable
    public mutating func span(_ n: Int) -> ByteSpan? {
        guard let p = take(n) else { return nil }
        return ByteSpan(p, n)
    }

    @inlinable
    @discardableResult
    public mutating func skip(_ n: Int) -> Bool {
        if n < 0 || count &- offset < n { return false }
        offset &+= n
        return true
    }

    /// Everything not yet read, without advancing.
    @inlinable
    public var rest: ByteSpan { ByteSpan(base + offset, count &- offset) }
}

extension ByteBuffer {
    @inlinable
    public mutating func writeVarint(_ value: UInt64) {
        reserve(8)
        advanceWriter(quicWriteVarint(value, writePointer))
    }

    @inlinable
    public mutating func writeUInt16BE(_ value: UInt16) {
        reserve(2)
        let p = writePointer
        p[0] = UInt8(truncatingIfNeeded: value >> 8)
        p[1] = UInt8(truncatingIfNeeded: value)
        advanceWriter(2)
    }

    @inlinable
    public mutating func writeUInt24BE(_ value: UInt32) {
        reserve(3)
        let p = writePointer
        p[0] = UInt8(truncatingIfNeeded: value >> 16)
        p[1] = UInt8(truncatingIfNeeded: value >> 8)
        p[2] = UInt8(truncatingIfNeeded: value)
        advanceWriter(3)
    }

    @inlinable
    public mutating func writeUInt32BE(_ value: UInt32) {
        reserve(4)
        let p = writePointer
        p[0] = UInt8(truncatingIfNeeded: value >> 24)
        p[1] = UInt8(truncatingIfNeeded: value >> 16)
        p[2] = UInt8(truncatingIfNeeded: value >> 8)
        p[3] = UInt8(truncatingIfNeeded: value)
        advanceWriter(4)
    }

    @inlinable
    public mutating func writeUInt64BE(_ value: UInt64) {
        reserve(8)
        let p = writePointer
        var i = 0
        while i < 8 {
            p[i] = UInt8(truncatingIfNeeded: value >> (56 &- 8 &* i))
            i &+= 1
        }
        advanceWriter(8)
    }
}

@inlinable
public func quicWriteUInt32BE(_ value: UInt32, _ p: UnsafeMutablePointer<UInt8>) {
    p[0] = UInt8(truncatingIfNeeded: value >> 24)
    p[1] = UInt8(truncatingIfNeeded: value >> 16)
    p[2] = UInt8(truncatingIfNeeded: value >> 8)
    p[3] = UInt8(truncatingIfNeeded: value)
}

@inlinable
public func quicWriteUInt64BE(_ value: UInt64, _ p: UnsafeMutablePointer<UInt8>) {
    var i = 0
    while i < 8 {
        p[i] = UInt8(truncatingIfNeeded: value >> (56 &- 8 &* i))
        i &+= 1
    }
}
