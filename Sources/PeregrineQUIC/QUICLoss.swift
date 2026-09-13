//===----------------------------------------------------------------------===//
// Loss recovery and congestion control (RFC 9002).
//
// QUIC never retransmits a packet. A packet number is used once, and when a
// packet is declared lost what gets sent again is the *data* it carried, in a
// new packet with a new number. That is why every sent packet has to remember
// what was in it: which crypto bytes, which stream ranges, which control
// frames that must not be dropped.
//
// It also means an acknowledgement is unambiguous. TCP's retransmission
// ambiguity -- was that ACK for the original or the copy? -- simply does not
// arise, which is what makes the round-trip estimate here trustworthy enough
// to drive loss detection from time as well as from ordering.
//
// Congestion control is NewReno, as the RFC specifies for a baseline. It is
// not the best available, but it is the one whose behaviour is written down,
// and a server that shares a network fairly matters more here than one that
// squeezes out the last few percent.
//===----------------------------------------------------------------------===//

import PeregrineCore

/// What a packet carried, so it can be sent again if it is lost.
public struct QUICSentFrames {
    public var crypto: (low: UInt64, high: UInt64)?
    public var streams: [(id: UInt64, low: UInt64, high: UInt64, fin: Bool)] = []
    /// Control frames that carry state rather than data. Each is re-queued
    /// wholesale rather than by range.
    public var handshakeDone = false
    public var maxData = false
    public var maxStreamsBidi = false
    public var maxStreamsUni = false
    public var maxStreamData: [UInt64] = []
    public var resetStream: [UInt64] = []
    public var stopSending: [UInt64] = []
    public var newConnectionIDs: [UInt64] = []
    public var pathResponse: [UInt8]?
    public var ping = false

    public init() {}

    @inlinable
    public var isEmpty: Bool {
        crypto == nil && streams.isEmpty && !handshakeDone && !maxData
            && !maxStreamsBidi && !maxStreamsUni && maxStreamData.isEmpty
            && resetStream.isEmpty && stopSending.isEmpty && newConnectionIDs.isEmpty
            && pathResponse == nil && !ping
    }
}

public struct QUICSentPacket {
    public var packetNumber: UInt64
    public var sentAtMs: UInt64
    public var size: Int
    public var ackEliciting: Bool
    public var inFlight: Bool
    public var frames: QUICSentFrames
    /// The largest packet number this packet's own ACK frame covered, so that
    /// acknowledging it lets us stop repeating older ranges.
    public var largestAcked: UInt64?
}

/// One packet number space: Initial, Handshake or application data. Each has
/// its own numbering, its own acknowledgements and its own loss detection.
public struct QUICPacketSpace {
    public var nextPacketNumber: UInt64 = 0
    public var largestReceived: Int64 = -1
    public var largestReceivedAtMs: UInt64 = 0
    public var acks = QUICAckRanges()
    /// Set when something arrived that must be acknowledged.
    public var ackPending = false
    /// Set when an ack-eliciting packet arrived, which puts a deadline on it.
    public var ackElicitingPending = false
    public var ackDeadlineMs: UInt64 = 0

    /// Packets still waiting for an outcome are `sent[sentHead...]`, in the
    /// order they were sent -- which is packet number order and time order
    /// both, and everything below relies on that.
    ///
    /// Settled packets leave from the front by moving the head, not by
    /// building a new array. The array used to be rebuilt on every ACK, which
    /// made each acknowledgement cost every packet in flight, each one copied
    /// with its frame lists retained and released. On a path with a large
    /// window that is thousands of packets per ACK, and it was the single
    /// largest cost of serving a download over HTTP/3.
    public internal(set) var sent: [QUICSentPacket] = []
    public internal(set) var sentHead = 0
    public var largestAckedPacket: UInt64?
    public var lossTimeMs: UInt64 = 0
    public var timeOfLastAckElicitingMs: UInt64 = 0
    public var ackElicitingInFlight = 0

    public init() {}

    /// Packets sent and not yet acknowledged or declared lost.
    @inlinable public var outstanding: Int { sent.count - sentHead }

    public mutating func record(_ packet: QUICSentPacket) {
        sent.append(packet)
        if packet.ackEliciting {
            ackElicitingInFlight += 1
            timeOfLastAckElicitingMs = packet.sentAtMs
        }
        nextPacketNumber = packet.packetNumber &+ 1
    }

    /// One past the last outstanding packet numbered `number` or lower.
    func endOfPackets(through number: UInt64) -> Int {
        var low = sentHead
        var high = sent.count
        while low < high {
            let mid = (low + high) >> 1
            if sent[mid].packetNumber <= number { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Forgets everything before `index`, whose outcome has been settled.
    mutating func advanceHead(to index: Int) {
        // Release what the settled slots still hold, which after packing is
        // stale copies of packets that now live further up.
        var i = sentHead
        while i < index {
            sent[i].frames = QUICSentFrames()
            i += 1
        }
        sentHead = index
        if sentHead == sent.count {
            sent.removeAll(keepingCapacity: true)
            sentHead = 0
        } else if sentHead >= 1024 && sentHead * 2 >= sent.count {
            // Once the dead front is at least as large as what is alive, one
            // move of the live part pays for itself.
            sent.removeFirst(sentHead)
            sentHead = 0
        }
    }
}

/// Round-trip estimation and NewReno, shared across the three spaces because
/// the path is one path however many key sets are in use on it.
public struct QUICRecovery {
    // RFC 9002 constants.
    public static let packetThreshold = 3
    public static let timeThresholdNumerator: UInt64 = 9
    public static let timeThresholdDenominator: UInt64 = 8
    public static let granularityMs: UInt64 = 1
    public static let initialRTTMs: UInt64 = 333

    public var latestRTTMs: UInt64 = 0
    public var smoothedRTTMs: UInt64 = QUICRecovery.initialRTTMs
    public var rttVarianceMs: UInt64 = QUICRecovery.initialRTTMs / 2
    public var minRTTMs: UInt64 = 0
    public var haveRTTSample = false
    public var peerMaxAckDelayMs: UInt64 = 25

    // Congestion window, in bytes.
    public var maxDatagramSize = QUICPacket.defaultMaxDatagramSize
    public var congestionWindow: Int
    public var bytesInFlight = 0
    public var slowStartThreshold = Int.max
    /// Packets sent before this time are from before the last loss, so a loss
    /// among them must not halve the window twice.
    public var recoveryStartMs: UInt64 = 0

    public var ptoCount = 0

    public init() {
        // RFC 9002 section 7.2: ten packets, with a floor and a ceiling.
        let initial = min(10 * QUICPacket.defaultMaxDatagramSize,
                          max(14720, 2 * QUICPacket.defaultMaxDatagramSize))
        congestionWindow = initial
    }

    @inlinable public var canSend: Bool { bytesInFlight < congestionWindow }
    @inlinable public var sendRoom: Int { max(0, congestionWindow - bytesInFlight) }

    public mutating func onPacketSent(_ packet: QUICSentPacket) {
        if packet.inFlight { bytesInFlight += packet.size }
    }

    /// RFC 9002 section 5.3.
    public mutating func updateRTT(latest: UInt64, ackDelay: UInt64) {
        latestRTTMs = latest
        if !haveRTTSample {
            minRTTMs = latest
            smoothedRTTMs = latest
            rttVarianceMs = latest / 2
            haveRTTSample = true
            return
        }
        if latest < minRTTMs { minRTTMs = latest }
        // The peer's reported delay is only subtracted where doing so leaves a
        // sample no smaller than the minimum: a peer that overstates its delay
        // must not be able to talk the estimate down to nothing.
        var adjusted = latest
        let delay = min(ackDelay, peerMaxAckDelayMs)
        if latest >= minRTTMs + delay { adjusted = latest - delay }

        let difference = smoothedRTTMs > adjusted
            ? smoothedRTTMs - adjusted : adjusted - smoothedRTTMs
        rttVarianceMs = (3 * rttVarianceMs + difference) / 4
        smoothedRTTMs = (7 * smoothedRTTMs + adjusted) / 8
    }

    public var lossDelayMs: UInt64 {
        let base = max(latestRTTMs, smoothedRTTMs)
        let scaled = base * QUICRecovery.timeThresholdNumerator
                   / QUICRecovery.timeThresholdDenominator
        return max(scaled, QUICRecovery.granularityMs)
    }

    /// The probe timeout: how long to wait before assuming something was lost
    /// when there is nothing else to tell us.
    public func ptoMs(includeMaxAckDelay: Bool) -> UInt64 {
        var pto = smoothedRTTMs + max(4 * rttVarianceMs, QUICRecovery.granularityMs)
        if includeMaxAckDelay { pto += peerMaxAckDelayMs }
        return pto << UInt64(min(ptoCount, 20))
    }

    public mutating func onPacketsAcked(_ packets: [QUICSentPacket], nowMs: UInt64) {
        for packet in packets where packet.inFlight {
            bytesInFlight -= packet.size
            if packet.sentAtMs <= recoveryStartMs { continue }   // still in recovery
            if congestionWindow < slowStartThreshold {
                congestionWindow += packet.size
            } else {
                // Congestion avoidance: one maximum-sized packet more per
                // round trip, approximated per acknowledgement.
                congestionWindow += maxDatagramSize * packet.size / max(congestionWindow, 1)
            }
        }
        _ = nowMs
    }

    public mutating func onPacketsLost(_ packets: [QUICSentPacket], nowMs: UInt64) {
        var largestLostSentAt: UInt64 = 0
        for packet in packets where packet.inFlight {
            bytesInFlight -= packet.size
            if packet.sentAtMs > largestLostSentAt { largestLostSentAt = packet.sentAtMs }
        }
        if largestLostSentAt == 0 { return }
        // One congestion event per round trip: losses from packets sent before
        // the window was already halved do not halve it again.
        if largestLostSentAt <= recoveryStartMs { return }
        recoveryStartMs = nowMs
        congestionWindow = max(congestionWindow / 2, 2 * maxDatagramSize)
        slowStartThreshold = congestionWindow
    }

    /// A probe timeout means the window is not to be trusted, but it is not
    /// evidence of loss either -- so the window is left alone and only the
    /// backoff grows.
    public mutating func onProbeTimeout() {
        ptoCount += 1
    }

    public mutating func onAckReceived() {
        ptoCount = 0
    }
}

/// Takes the packets an ACK frame covers out of a space, and works out which
/// of the rest are now old enough to call lost.
public enum QUICLossDetection {
    public struct Result {
        public var acked: [QUICSentPacket] = []
        public var lost: [QUICSentPacket] = []
        public var largestNewlyAcked: QUICSentPacket?
    }

    public static func onAck(space: inout QUICPacketSpace,
                             recovery: inout QUICRecovery,
                             ranges: [(low: UInt64, high: UInt64)],
                             largestAcked: UInt64,
                             ackDelayMs: UInt64,
                             nowMs: UInt64) -> Result {
        var result = Result()
        if space.outstanding == 0 { return result }

        // Nothing numbered above the largest acknowledged packet can be
        // covered by this ACK, and nothing above the threshold can be old
        // enough in ordering to call lost. So only the outstanding packets up
        // to the threshold are looked at, and the rest -- on a fast path, most
        // of what is in flight -- are not touched at all.
        let threshold = max(space.largestAckedPacket ?? largestAcked, largestAcked)
        let head = space.sentHead
        let end = space.endOfPackets(through: threshold)
        if end == head { return result }

        // Acknowledged packets are taken out walking downward, so the ones
        // that stay can be packed against `end` without overwriting a slot
        // not yet looked at.
        var keep = end
        var i = end
        while i > head {
            i -= 1
            let number = space.sent[i].packetNumber
            var isAcked = false
            if number <= largestAcked {
                for range in ranges where number >= range.low && number <= range.high {
                    isAcked = true
                    break
                }
            }
            if isAcked {
                if number == largestAcked { result.largestNewlyAcked = space.sent[i] }
                result.acked.append(space.sent[i])
            } else {
                keep -= 1
                if keep != i { space.sent[keep] = space.sent[i] }
            }
        }
        if result.acked.isEmpty {
            return result
        }
        result.acked.reverse()

        space.largestAckedPacket = threshold

        // The round-trip sample is only taken from the largest acknowledged
        // packet, and only when that packet is newly acknowledged: an older
        // one would measure a delay the peer never incurred.
        if let largest = result.largestNewlyAcked, largest.ackEliciting {
            let sample = nowMs >= largest.sentAtMs ? nowMs - largest.sentAtMs : 0
            recovery.updateRTT(latest: sample, ackDelay: ackDelayMs)
        }
        recovery.onAckReceived()

        for packet in result.acked where packet.ackEliciting {
            space.ackElicitingInFlight -= 1
        }
        // An acknowledgement of a packet that itself carried an ACK means the
        // peer knows what we knew, so those ranges need never be repeated.
        for packet in result.acked {
            if let covered = packet.largestAcked { space.acks.removeUpTo(covered) }
        }

        // Loss: by ordering first, then by time -- over what survived above,
        // which is every outstanding packet below the threshold. The delay is
        // read now, after the round-trip sample this ACK may have given.
        let delay = recovery.lossDelayMs
        let survivors = keep
        keep = end
        var earliestLossTime: UInt64 = 0
        i = end
        while i > survivors {
            i -= 1
            let number = space.sent[i].packetNumber
            let sentAt = space.sent[i].sentAtMs
            var isLost = false
            if number < threshold {
                let gap = threshold - number
                let age = nowMs >= sentAt ? nowMs - sentAt : 0
                isLost = gap >= UInt64(QUICRecovery.packetThreshold) || age >= delay
            }
            if isLost {
                if space.sent[i].ackEliciting { space.ackElicitingInFlight -= 1 }
                result.lost.append(space.sent[i])
            } else {
                if number < threshold {
                    // When this packet would age out, if nothing else settles it.
                    let at = sentAt + delay
                    if earliestLossTime == 0 || at < earliestLossTime { earliestLossTime = at }
                }
                keep -= 1
                if keep != i { space.sent[keep] = space.sent[i] }
            }
        }
        result.lost.reverse()
        space.advanceHead(to: keep)
        space.lossTimeMs = earliestLossTime

        recovery.onPacketsAcked(result.acked, nowMs: nowMs)
        recovery.onPacketsLost(result.lost, nowMs: nowMs)
        return result
    }

    /// Everything a space is still waiting on, given up because the probe
    /// timeout fired too many times or the connection is closing.
    public static func abandon(space: inout QUICPacketSpace,
                               recovery: inout QUICRecovery) -> [QUICSentPacket] {
        let lost = Array(space.sent[space.sentHead...])
        space.sent = []
        space.sentHead = 0
        space.ackElicitingInFlight = 0
        for packet in lost where packet.inFlight {
            recovery.bytesInFlight -= packet.size
        }
        return lost
    }
}
