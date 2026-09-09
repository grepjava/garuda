//===----------------------------------------------------------------------===//
// QUIC streams.
//
// A stream is an ordered byte sequence with its own flow control, delivered
// out of packets that may arrive in any order and may not arrive at all. So a
// stream is really two problems joined at the identifier:
//
//  * Receiving: put arriving ranges back in order, hold the ones that are
//    early, and refuse anything past the limit we granted.
//  * Sending: keep every byte until it is acknowledged, because a lost packet
//    is retransmitted as *data* -- QUIC never resends a packet, it sends the
//    frames again in a new one.
//
// The send buffer therefore holds from the lowest unacknowledged byte onward,
// and is trimmed from the front as acknowledgements come in. That is a
// window, not a queue, which is what makes a lost packet cost a copy of a few
// hundred bytes rather than the whole stream.
//===----------------------------------------------------------------------===//

import PeregrineCore

/// An ascending set of byte ranges, used for what has been acknowledged and
/// for what has to be sent again. Half-open: [low, high).
public struct QUICByteRanges {
    public private(set) var ranges: [(low: UInt64, high: UInt64)] = []

    public init() {}

    @inlinable public var isEmpty: Bool { ranges.isEmpty }
    @inlinable public var count: Int { ranges.count }

    public mutating func add(_ low: UInt64, _ high: UInt64) {
        if high <= low { return }
        var i = 0
        while i < ranges.count && ranges[i].high < low { i += 1 }
        if i == ranges.count {
            ranges.append((low, high))
            return
        }
        if high < ranges[i].low {
            ranges.insert((low, high), at: i)
            return
        }
        // Overlapping or adjacent: widen this range and swallow the ones it
        // now reaches.
        ranges[i].low = min(ranges[i].low, low)
        ranges[i].high = max(ranges[i].high, high)
        var j = i + 1
        while j < ranges.count && ranges[j].low <= ranges[i].high {
            ranges[i].high = max(ranges[i].high, ranges[j].high)
            j += 1
        }
        if j > i + 1 { ranges.removeSubrange((i + 1)..<j) }
    }

    /// How far a contiguous run from `base` extends.
    public func contiguousEnd(from base: UInt64) -> UInt64 {
        guard let first = ranges.first, first.low <= base else { return base }
        return max(base, first.high)
    }

    /// Removes exactly [low, high), splitting a range it falls inside.
    ///
    /// This is what an acknowledgement does to what is owed: it clears the
    /// bytes that were acknowledged and *only* those. QUIC acknowledges
    /// packets, and a packet carries one range of a stream, so an ACK arriving
    /// for a later range says nothing at all about an earlier one still
    /// waiting to be sent again.
    public mutating func subtract(_ low: UInt64, _ high: UInt64) {
        if high <= low { return }
        var i = 0
        while i < ranges.count {
            let range = ranges[i]
            if range.high <= low { i += 1; continue }
            if range.low >= high { return }
            if range.low < low && range.high > high {
                // Removed from the middle: what is left is two ranges.
                ranges[i].high = low
                ranges.insert((high, range.high), at: i + 1)
                return
            }
            if range.low < low {
                ranges[i].high = low
                i += 1
            } else if range.high > high {
                ranges[i].low = high
                return
            } else {
                ranges.remove(at: i)
            }
        }
    }

    public mutating func removeBelow(_ offset: UInt64) {
        while let first = ranges.first, first.high <= offset { ranges.removeFirst() }
        if var first = ranges.first, first.low < offset {
            first.low = offset
            ranges[0] = first
        }
    }

    /// Takes the first range, for a sender walking what it owes.
    public mutating func removeFirst() -> (low: UInt64, high: UInt64)? {
        ranges.isEmpty ? nil : ranges.removeFirst()
    }

    public mutating func clear() { ranges.removeAll(keepingCapacity: true) }
}

/// One direction's receive side: reassembly plus the limit we granted.
public struct QUICReceiveStream {
    /// Bytes in order and ready to be read.
    public var ready = ByteBuffer()
    /// The offset one past the last byte in `ready`; everything below has
    /// arrived, though not necessarily been consumed.
    public var received: UInt64 = 0
    /// Pieces that arrived early, lowest first.
    public var early: [(offset: UInt64, bytes: [UInt8])] = []
    /// The highest offset the peer has mentioned, for flow control.
    public var highWater: UInt64 = 0
    /// The limit we advertised.
    public var limit: UInt64 = 0
    /// The largest limit the peer has been told, so that raising it is what
    /// sends a frame rather than merely being behind one. Re-announcing a
    /// limit the peer already has is not just waste: a stream that owes data
    /// it cannot send yet would otherwise give the sender something to put in
    /// a packet on every pass, forever.
    public var announced: UInt64 = 0
    public var finalSize: UInt64?
    public var finished = false
    /// Set once the application has been told the stream ended.
    public var delivered = false

    public init() {}

    public enum Outcome {
        case ok
        case flowControlError
        case finalSizeError
    }

    /// Accepts a run of stream or crypto bytes.
    public mutating func accept(offset: UInt64, _ p: UnsafePointer<UInt8>, _ n: Int,
                                fin: Bool) -> Outcome {
        let end = offset &+ UInt64(n)
        if end < offset { return .finalSizeError }        // wrapped: impossible offsets
        if end > limit { return .flowControlError }

        if let final = finalSize {
            // Once the end is known, nothing may claim to be past it, and a
            // second FIN must agree with the first.
            if end > final { return .finalSizeError }
            if fin && end != final { return .finalSizeError }
        } else if fin {
            if end < highWater { return .finalSizeError }
            finalSize = end
        }
        if end > highWater { highWater = end }

        if end <= received {
            // Entirely a duplicate.
            checkFinished()
            return .ok
        }

        if offset <= received {
            let skip = Int(received - offset)
            ready.write(p + skip, n - skip)
            received = end
            drainEarly()
        } else {
            insertEarly(offset: offset, p, n)
        }
        checkFinished()
        return .ok
    }

    private mutating func insertEarly(offset: UInt64, _ p: UnsafePointer<UInt8>, _ n: Int) {
        // Out of order is the exception, so this is allowed to be the slow
        // path: copies and a linear walk rather than a structure that would
        // cost something on every packet.
        //
        // What is kept is only the part not held already, so `early` stays a
        // set of disjoint ranges. That is what bounds it. Flow control bounds
        // the *offsets* a peer may use, not the bytes it may send inside them:
        // a 4 KiB window admits thousands of distinct offsets, each carrying
        // nearly the whole window again, so storing every fragment whole is
        // bounded by nothing. Disjoint ranges inside a window can never hold
        // more than the window.
        let high = offset &+ UInt64(n)
        var low = offset

        func piece(_ from: UInt64, _ to: UInt64) -> (offset: UInt64, bytes: [UInt8]) {
            let start = Int(from &- offset)
            return (from, [UInt8](UnsafeBufferPointer(start: p + start,
                                                      count: Int(to &- from))))
        }

        var i = 0
        while i < early.count
            && early[i].offset &+ UInt64(early[i].bytes.count) <= low { i += 1 }
        while low < high {
            if i == early.count || early[i].offset >= high {
                early.insert(piece(low, high), at: i)
                return
            }
            let held = early[i]
            if held.offset > low {
                early.insert(piece(low, held.offset), at: i)
                i += 1
            }
            low = held.offset &+ UInt64(held.bytes.count)
            i += 1
        }
    }

    private mutating func drainEarly() {
        while let first = early.first {
            if first.offset > received { return }
            let end = first.offset &+ UInt64(first.bytes.count)
            if end > received {
                let skip = Int(received - first.offset)
                first.bytes.withUnsafeBufferPointer {
                    ready.write($0.baseAddress! + skip, $0.count - skip)
                }
                received = end
            }
            early.removeFirst()
        }
    }

    private mutating func checkFinished() {
        if let final = finalSize, received >= final { finished = true }
    }

    /// How much more the peer may send before it needs a new limit.
    @inlinable public var window: UInt64 { limit > highWater ? limit - highWater : 0 }

    public mutating func destroy() {
        ready.destroy()
        early.removeAll()
    }
}

/// One direction's send side.
public struct QUICSendStream {
    /// Unacknowledged bytes, starting at `base`.
    public var data = ByteBuffer()
    /// Offset of the first byte in `data`.
    public var base: UInt64 = 0
    /// Offset one past the last byte handed to a packet.
    public var sent: UInt64 = 0
    /// What the peer has acknowledged, which is not always a prefix.
    public var acked = QUICByteRanges()
    /// Ranges declared lost and owed again.
    public var lost = QUICByteRanges()
    /// The peer's limit for this stream.
    public var limit: UInt64 = 0
    public var finQueued = false
    public var finSent = false
    public var finAcked = false
    /// Set when the application gave up on this direction.
    public var resetCode: UInt64?
    public var resetSent = false

    public init() {}

    /// One past the last byte written by the application.
    @inlinable public var written: UInt64 { base &+ UInt64(data.readableBytes) }
    /// Bytes queued but not yet put in a packet.
    @inlinable public var pending: UInt64 { written > sent ? written - sent : 0 }
    /// How much may still be sent under the peer's limit.
    @inlinable public var window: UInt64 { limit > sent ? limit - sent : 0 }
    @inlinable public var isBlocked: Bool { pending > 0 && window == 0 }
    @inlinable public var isDrained: Bool {
        written == base && lost.isEmpty && (!finQueued || finAcked)
    }

    public mutating func write(_ p: UnsafePointer<UInt8>, _ n: Int) {
        data.write(p, n)
    }

    /// Borrows the bytes at an absolute offset, for building a STREAM frame.
    public func slice(at offset: UInt64, _ n: Int) -> UnsafePointer<UInt8>? {
        if offset < base { return nil }
        let index = Int(offset - base)
        if index + n > data.readableBytes { return nil }
        return UnsafePointer(data.readPointer + index)
    }

    public mutating func acknowledge(_ low: UInt64, _ high: UInt64) {
        acked.add(low, high)
        // Only the acknowledged bytes stop being owed. Dropping everything
        // below `high` would take an earlier lost range with it -- an ACK for
        // 100..200 erasing the retransmission of 0..100, which the peer is
        // still waiting for and will now never get.
        lost.subtract(low, high)
        // Drop what can never be needed again.
        let contiguous = acked.contiguousEnd(from: base)
        if contiguous > base {
            data.consume(Int(contiguous - base))
            base = contiguous
        }
    }

    public mutating func declareLost(_ low: UInt64, _ high: UInt64) {
        if high <= base { return }
        lost.add(max(low, base), high)
        // A packet can be declared lost after part of what it carried was
        // acknowledged in another one. Those bytes have arrived; sending them
        // again would be a packet spent on nothing.
        for range in acked.ranges { lost.subtract(range.low, range.high) }
    }

    public mutating func destroy() {
        data.destroy()
    }
}

/// A stream as the connection sees it.
public final class QUICStream {
    public let id: UInt64
    public var receive = QUICReceiveStream()
    public var send = QUICSendStream()
    /// The peer asked us to stop sending; the code it gave.
    public var stopSending: UInt64?
    /// We asked the peer to stop; not yet sent.
    public var stopSendingQueued: UInt64?
    public var stopSendingSent = false
    /// Set when both directions are finished and the connection may forget it.
    public var closed = false
    /// Set when the layer above has finished with this stream. Until then the
    /// transport keeps it, however complete it looks: a stream whose data has
    /// all been acknowledged can still be one the application is about to end,
    /// and forgetting it would send that ending nowhere.
    public var released = false

    public init(id: UInt64) {
        self.id = id
    }

    @inlinable public var isBidirectional: Bool { QUICStreamKind.isBidirectional(id) }
    @inlinable public var isClientInitiated: Bool { QUICStreamKind.isClientInitiated(id) }

    /// True when nothing more can happen on this stream in either direction
    /// and nobody above is still holding it.
    public var isFinished: Bool {
        if !released { return false }
        let recvDone = receive.finished || receive.finalSize != nil && receive.delivered
            || stopSendingSent
        let sendDone = send.isDrained || send.resetSent
        return recvDone && sendDone
    }

    public func destroy() {
        receive.destroy()
        send.destroy()
    }
}
