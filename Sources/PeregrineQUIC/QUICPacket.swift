//===----------------------------------------------------------------------===//
// QUIC packets.
//
// A UDP datagram carries one or more packets, and a packet's header is only
// partly readable before decryption: the packet number and the low bits of the
// first byte are protected by a mask derived from the payload's own
// ciphertext. So parsing happens in two passes -- what can be read to route
// the datagram (version, connection IDs, length), and then, once the keys for
// that encryption level exist, the rest.
//
// Connection IDs are the addressing. A QUIC connection is not a socket: it
// survives the client changing address, and it is found by the destination
// connection ID in the packet rather than by the four-tuple it arrived on.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public enum QUICVersion {
    /// RFC 9000.
    public static let v1: UInt32 = 0x0000_0001
    /// RFC 9369. Different salts and labels, same protocol.
    public static let v2: UInt32 = 0x6b33_43cf
    /// Sent to make a client exercise its version negotiation.
    public static let negotiation: UInt32 = 0x0000_0000

    @inlinable
    public static func isSupported(_ v: UInt32) -> Bool { v == v1 || v == v2 }
}

/// The maximum a connection ID may be in QUIC v1.
public let quicMaxCIDLength = 20
/// The length this server issues. Eight bytes is enough to make guessing
/// hopeless and leaves room in the header for a short first byte.
public let quicLocalCIDLength = 8

/// A connection ID: up to 20 bytes, held inline so that routing a datagram
/// touches no allocation and the value can live in a flat table.
public struct QUICConnectionID: Equatable, Hashable {
    @usableFromInline var words: (UInt64, UInt64, UInt64) = (0, 0, 0)
    public var length: UInt8 = 0

    @inlinable public init() {}

    @inlinable
    public init?(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if n < 0 || n > quicMaxCIDLength { return nil }
        length = UInt8(n)
        if n > 0 {
            withUnsafeMutableBytes(of: &words) { raw in
                raw.baseAddress!.copyMemory(from: UnsafeRawPointer(p), byteCount: n)
            }
        }
    }

    /// A fresh, unpredictable connection ID.
    public static func random(length: Int = quicLocalCIDLength) -> QUICConnectionID {
        var cid = QUICConnectionID()
        cid.length = UInt8(length)
        withUnsafeMutableBytes(of: &cid.words) { raw in
            _ = pg_random_bytes(raw.baseAddress!, length)
        }
        return cid
    }

    @inlinable
    public func withBytes<R>(_ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
        withUnsafeBytes(of: words) { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: UInt8.self), Int(length))
        }
    }

    @inlinable
    public var isEmpty: Bool { length == 0 }

    @inlinable
    public static func == (a: QUICConnectionID, b: QUICConnectionID) -> Bool {
        a.length == b.length
            && a.words.0 == b.words.0 && a.words.1 == b.words.1 && a.words.2 == b.words.2
    }

    @inlinable
    public func hash(into hasher: inout Hasher) {
        hasher.combine(words.0)
        hasher.combine(words.1)
        hasher.combine(words.2)
        hasher.combine(length)
    }
}

public enum QUICPacketType: UInt8 {
    case initial = 0
    case zeroRTT = 1
    case handshake = 2
    case retry = 3
    case oneRTT = 4
    case versionNegotiation = 5
}

/// Which set of keys protects a packet. Each level has its own packet number
/// space, its own acknowledgements and its own loss recovery.
public enum QUICLevel: Int {
    case initial = 0
    case handshake = 1
    case application = 2

    @inlinable
    public var packetType: QUICPacketType {
        switch self {
        case .initial: return .initial
        case .handshake: return .handshake
        case .application: return .oneRTT
        }
    }
}

/// What can be read from a packet before its keys are known.
public struct QUICPacketHeader {
    public var type: QUICPacketType = .oneRTT
    public var version: UInt32 = 0
    public var dcid = QUICConnectionID()
    public var scid = QUICConnectionID()
    /// Retry or Initial token, borrowed from the datagram.
    public var token = ByteSpan(UnsafePointer(bitPattern: 1)!, 0)
    /// Offset of the packet number field within the datagram.
    public var pnOffset = 0
    /// One past the last byte of this packet within the datagram: where the
    /// next coalesced packet starts.
    public var end = 0
    /// True when the first byte failed the fixed-bit check or the form is one
    /// a server never receives.
    public var isValid = false

    @inlinable public var isLong: Bool { type != .oneRTT }
}

public enum QUICPacket {
    /// Reads as much of a packet's header as is legible without keys.
    ///
    /// `localCIDLength` is how long this server's own connection IDs are,
    /// which is the only way to find the end of a short header's destination
    /// connection ID -- a short header does not carry its length.
    public static func parseHeader(_ p: UnsafePointer<UInt8>, _ n: Int,
                                   localCIDLength: Int) -> QUICPacketHeader {
        var h = QUICPacketHeader()
        if n < 1 { return h }
        let first = p[0]

        if first & 0x80 == 0 {
            // Short header. Everything past the connection ID is protected, so
            // the packet is however much of the datagram is left.
            h.type = .oneRTT
            if first & 0x40 == 0 { return h }   // fixed bit
            if n < 1 + localCIDLength { return h }
            guard let dcid = QUICConnectionID(p + 1, localCIDLength) else { return h }
            h.dcid = dcid
            h.pnOffset = 1 + localCIDLength
            h.end = n
            h.isValid = true
            return h
        }

        var r = QUICReader(p, n)
        _ = r.byte()
        guard let version = r.uint32() else { return h }
        h.version = version

        guard let dcidLen = r.byte(), dcidLen <= UInt8(quicMaxCIDLength),
              let dcidBytes = r.take(Int(dcidLen)),
              let dcid = QUICConnectionID(dcidBytes, Int(dcidLen)),
              let scidLen = r.byte(), scidLen <= UInt8(quicMaxCIDLength),
              let scidBytes = r.take(Int(scidLen)),
              let scid = QUICConnectionID(scidBytes, Int(scidLen))
        else { return h }
        h.dcid = dcid
        h.scid = scid

        if version == QUICVersion.negotiation {
            // A server never receives one of these, but recognising it keeps
            // the packet from being mistaken for something with a length.
            h.type = .versionNegotiation
            h.end = n
            h.isValid = true
            return h
        }

        // The fixed bit is checked after the version, because a version
        // negotiation packet is allowed to have it clear.
        if first & 0x40 == 0 { return h }

        // The type bits move between versions; version 2 renumbered them to
        // stop middleboxes from hard-coding version 1's layout.
        let raw = (first >> 4) & 0x03
        if version == QUICVersion.v2 {
            switch raw {
            case 0: h.type = .retry
            case 1: h.type = .initial
            case 2: h.type = .zeroRTT
            default: h.type = .handshake
            }
        } else {
            switch raw {
            case 0: h.type = .initial
            case 1: h.type = .zeroRTT
            case 2: h.type = .handshake
            default: h.type = .retry
            }
        }

        if h.type == .retry {
            // No length field: a Retry runs to the end of the datagram.
            h.end = n
            h.isValid = true
            return h
        }

        if h.type == .initial {
            guard let tokenLen = r.varintAsInt(), let token = r.span(tokenLen) else { return h }
            h.token = token
        }
        guard let length = r.varintAsInt(), length >= 0, r.remaining >= length else { return h }
        h.pnOffset = r.offset
        h.end = r.offset + length
        h.isValid = true
        return h
    }

    /// Whether a datagram is long enough to be a client's first flight. A
    /// server must not act on a small Initial: doing so would let a spoofed
    /// source address turn one packet into a large reply.
    public static let minimumInitialSize = 1200

    /// The smallest useful maximum. Every path is assumed to carry this much
    /// until a larger size is confirmed.
    public static let defaultMaxDatagramSize = 1200
}

// MARK: - Packet numbers

/// How many bytes a packet number needs, given what the peer has acknowledged.
/// The encoding is a truncation, so it only has to carry enough bits to be
/// unambiguous against every packet that might still be in flight.
@inlinable
public func quicPacketNumberLength(_ full: UInt64, largestAcked: UInt64?) -> Int {
    let range: UInt64
    if let acked = largestAcked {
        range = (full &- acked) &* 2
    } else {
        range = (full &+ 1) &* 2
    }
    if range < 1 << 8 { return 1 }
    if range < 1 << 16 { return 2 }
    if range < 1 << 24 { return 3 }
    return 4
}

/// RFC 9000 appendix A: recovers the full packet number from its truncated
/// form by choosing the candidate closest to what is expected next.
@inlinable
public func quicDecodePacketNumber(largestReceived: Int64, truncated: UInt64,
                                   bits: Int) -> UInt64 {
    let expected = largestReceived &+ 1
    let window = Int64(1) << bits
    let halfWindow = window / 2
    let candidate = (expected & ~(window &- 1)) | Int64(truncated)

    if candidate <= expected &- halfWindow && candidate < (Int64(1) << 62) &- window {
        return UInt64(candidate &+ window)
    }
    if candidate > expected &+ halfWindow && candidate >= window {
        return UInt64(candidate &- window)
    }
    return UInt64(candidate)
}
