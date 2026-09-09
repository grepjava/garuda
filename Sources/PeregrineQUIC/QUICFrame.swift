//===----------------------------------------------------------------------===//
// QUIC frames.
//
// A packet's payload is a sequence of frames with no length prefix between
// them: each frame's type says how to find its end, so a frame that cannot be
// parsed ends the connection rather than being skipped. That is deliberate --
// there is no way to resynchronise, and pretending otherwise would let a peer
// hide data inside a frame we did not understand.
//
// Frames are parsed straight out of the decrypted packet with the same reader
// the header used. Nothing is copied here; what a frame refers to is handed to
// the connection as a pointer into the datagram, and the connection decides
// what is worth keeping.
//===----------------------------------------------------------------------===//

import PeregrineCore

public enum QUICFrameType {
    public static let padding: UInt64 = 0x00
    public static let ping: UInt64 = 0x01
    public static let ack: UInt64 = 0x02
    public static let ackECN: UInt64 = 0x03
    public static let resetStream: UInt64 = 0x04
    public static let stopSending: UInt64 = 0x05
    public static let crypto: UInt64 = 0x06
    public static let newToken: UInt64 = 0x07
    public static let streamFirst: UInt64 = 0x08
    public static let streamLast: UInt64 = 0x0f
    public static let maxData: UInt64 = 0x10
    public static let maxStreamData: UInt64 = 0x11
    public static let maxStreamsBidi: UInt64 = 0x12
    public static let maxStreamsUni: UInt64 = 0x13
    public static let dataBlocked: UInt64 = 0x14
    public static let streamDataBlocked: UInt64 = 0x15
    public static let streamsBlockedBidi: UInt64 = 0x16
    public static let streamsBlockedUni: UInt64 = 0x17
    public static let newConnectionID: UInt64 = 0x18
    public static let retireConnectionID: UInt64 = 0x19
    public static let pathChallenge: UInt64 = 0x1a
    public static let pathResponse: UInt64 = 0x1b
    public static let connectionCloseTransport: UInt64 = 0x1c
    public static let connectionCloseApplication: UInt64 = 0x1d
    public static let handshakeDone: UInt64 = 0x1e
    /// RFC 9221. The low bit says whether an explicit length is present.
    public static let datagram: UInt64 = 0x30
    public static let datagramWithLength: UInt64 = 0x31

    /// The STREAM frame type bits: which optional fields are present and
    /// whether the stream ends here.
    public static let streamFin: UInt64 = 0x01
    public static let streamLength: UInt64 = 0x02
    public static let streamOffset: UInt64 = 0x04

    /// Frames that may appear in Initial and Handshake packets. Anything else
    /// at those levels is a protocol violation, not merely unexpected: the
    /// handshake has no room for stream data or flow control.
    @inlinable
    public static func allowedDuringHandshake(_ type: UInt64) -> Bool {
        switch type {
        case padding, ping, ack, ackECN, crypto,
             connectionCloseTransport:
            return true
        default:
            return false
        }
    }

    /// Frames that do not by themselves make a packet worth acknowledging.
    /// Acknowledging an acknowledgement forever is how two idle peers keep
    /// each other awake.
    @inlinable
    public static func isAckEliciting(_ type: UInt64) -> Bool {
        switch type {
        case padding, ack, ackECN, connectionCloseTransport, connectionCloseApplication:
            return false
        default:
            return true
        }
    }

    /// Frames a peer must not send in a 0-RTT packet, because their meaning
    /// depends on the handshake having finished.
    @inlinable
    public static func allowedInZeroRTT(_ type: UInt64) -> Bool {
        switch type {
        case ack, ackECN, crypto, newToken, pathResponse, handshakeDone:
            return false
        default:
            return true
        }
    }
}

/// RFC 9000 section 20.1.
public enum QUICError: UInt64 {
    case noError = 0x00
    case internalError = 0x01
    case connectionRefused = 0x02
    case flowControlError = 0x03
    case streamLimitError = 0x04
    case streamStateError = 0x05
    case finalSizeError = 0x06
    case frameEncodingError = 0x07
    case transportParameterError = 0x08
    case connectionIDLimitError = 0x09
    case protocolViolation = 0x0a
    case invalidToken = 0x0b
    case applicationError = 0x0c
    case cryptoBufferExceeded = 0x0d
    case keyUpdateError = 0x0e
    case aeadLimitReached = 0x0f
    case noViablePath = 0x10
}

/// A TLS alert reported as a transport error: 0x0100 plus the alert code.
@inlinable
public func quicCryptoError(_ alert: UInt8) -> UInt64 { 0x0100 | UInt64(alert) }

// MARK: - Stream identifiers

/// The low two bits of a stream ID say who opened it and whether it is
/// bidirectional, so a stream needs no other state to be classified.
public enum QUICStreamKind {
    @inlinable public static func isClientInitiated(_ id: UInt64) -> Bool { id & 0x01 == 0 }
    @inlinable public static func isServerInitiated(_ id: UInt64) -> Bool { id & 0x01 == 1 }
    @inlinable public static func isBidirectional(_ id: UInt64) -> Bool { id & 0x02 == 0 }
    @inlinable public static func isUnidirectional(_ id: UInt64) -> Bool { id & 0x02 == 2 }
    /// Position within its own category, which is what stream limits count.
    @inlinable public static func index(_ id: UInt64) -> UInt64 { id >> 2 }

    @inlinable
    public static func id(index: UInt64, serverInitiated: Bool, unidirectional: Bool) -> UInt64 {
        (index << 2) | (serverInitiated ? 0x01 : 0x00) | (unidirectional ? 0x02 : 0x00)
    }
}

// MARK: - Acknowledgements

/// The set of packet numbers received but not yet acknowledged, kept as
/// descending ranges because that is the shape an ACK frame is written in and
/// because arrivals are mostly contiguous -- a run of packets collapses into
/// one range rather than a thousand entries.
public struct QUICAckRanges {
    /// Ranges, highest first, each inclusive.
    public private(set) var ranges: [(low: UInt64, high: UInt64)] = []
    /// Ranges older than this are dropped: an ACK that reaches back forever
    /// grows without bound and tells the peer nothing it did not already know.
    public var maximumRanges = 32

    public init() {}

    @inlinable public var isEmpty: Bool { ranges.isEmpty }
    @inlinable public var largest: UInt64? { ranges.first?.high }

    public mutating func add(_ packetNumber: UInt64) {
        var i = 0
        while i < ranges.count {
            let r = ranges[i]
            if packetNumber >= r.low && packetNumber <= r.high { return }   // duplicate
            if packetNumber == r.high &+ 1 {
                ranges[i].high = packetNumber
                // The gap above may have closed.
                if i > 0 && ranges[i - 1].low == packetNumber &+ 1 {
                    ranges[i].high = ranges[i - 1].high
                    ranges.remove(at: i - 1)
                }
                return
            }
            if r.low > 0 && packetNumber == r.low &- 1 {
                ranges[i].low = packetNumber
                if i + 1 < ranges.count && ranges[i + 1].high &+ 1 == packetNumber {
                    ranges[i].low = ranges[i + 1].low
                    ranges.remove(at: i + 1)
                }
                return
            }
            if packetNumber > r.high { break }
            i += 1
        }
        ranges.insert((packetNumber, packetNumber), at: i)
        if ranges.count > maximumRanges { ranges.removeLast(ranges.count - maximumRanges) }
    }

    /// Forgets everything at or below `packetNumber`, once the peer has
    /// acknowledged our acknowledgement of it.
    public mutating func removeUpTo(_ packetNumber: UInt64) {
        while let last = ranges.last, last.high <= packetNumber {
            ranges.removeLast()
        }
        if var last = ranges.last, last.low <= packetNumber {
            last.low = packetNumber &+ 1
            ranges[ranges.count - 1] = last
        }
    }

    public mutating func clear() { ranges.removeAll(keepingCapacity: true) }
}

extension ByteBuffer {
    /// Writes an ACK frame. `delay` is already in the peer's exponent.
    public mutating func writeAckFrame(_ acks: QUICAckRanges, delay: UInt64,
                                       ecn: (ect0: UInt64, ect1: UInt64, ce: UInt64)? = nil) {
        guard let first = acks.ranges.first else { return }
        writeVarint(ecn == nil ? QUICFrameType.ack : QUICFrameType.ackECN)
        writeVarint(first.high)
        writeVarint(delay)
        writeVarint(UInt64(acks.ranges.count - 1))
        writeVarint(first.high - first.low)

        var previousLow = first.low
        for i in 1..<acks.ranges.count {
            let r = acks.ranges[i]
            // Gap and length are both encoded one less than they are, which is
            // what makes a run of single packets cost two bytes rather than
            // four.
            writeVarint(previousLow - r.high - 2)
            writeVarint(r.high - r.low)
            previousLow = r.low
        }
        if let ecn {
            writeVarint(ecn.ect0)
            writeVarint(ecn.ect1)
            writeVarint(ecn.ce)
        }
    }

    /// The room an ACK frame would need, so a packet builder can decide
    /// whether it fits before committing to it.
    public static func ackFrameSize(_ acks: QUICAckRanges, delay: UInt64) -> Int {
        guard let first = acks.ranges.first else { return 0 }
        var n = 1 + quicVarintLength(first.high) + quicVarintLength(delay)
                  + quicVarintLength(UInt64(acks.ranges.count - 1))
                  + quicVarintLength(first.high - first.low)
        var previousLow = first.low
        for i in 1..<acks.ranges.count {
            let r = acks.ranges[i]
            n += quicVarintLength(previousLow - r.high - 2) + quicVarintLength(r.high - r.low)
            previousLow = r.low
        }
        return n
    }
}

/// Reads the ranges out of an ACK frame, after its type byte. The callback is
/// given each acknowledged range, highest first.
@inlinable
public func quicReadAckFrame(_ r: inout QUICReader, hasECN: Bool,
                             _ range: (UInt64, UInt64) -> Void) -> UInt64? {
    guard let largest = r.varint(),
          let delay = r.varint(),
          let count = r.varint(),
          let firstRange = r.varint(),
          firstRange <= largest
    else { return nil }
    range(largest - firstRange, largest)

    var smallest = largest - firstRange
    var i: UInt64 = 0
    while i < count {
        guard let gap = r.varint(), let length = r.varint() else { return nil }
        // Every range must sit strictly below the previous one, and the
        // arithmetic must not wrap: a peer can otherwise claim to acknowledge
        // packet numbers that were never issued.
        let step = gap &+ 2
        if step > smallest { return nil }
        let high = smallest - step
        if length > high { return nil }
        range(high - length, high)
        smallest = high - length
        i &+= 1
    }
    if hasECN {
        guard r.varint() != nil, r.varint() != nil, r.varint() != nil else { return nil }
    }
    return delay
}
