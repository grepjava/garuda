//===----------------------------------------------------------------------===//
// Building datagrams.
//
// A datagram is filled by asking each encryption level in turn what it owes,
// and packets from different levels are coalesced into one datagram -- an
// Initial and a Handshake packet travel together during the handshake, which
// is what keeps the number of round trips down.
//
// Two constraints shape everything here:
//
//  * A datagram carrying an Initial packet must be at least 1200 bytes. That
//    is what proves the path can carry a handshake at all, and it is why the
//    packets are laid out first and sealed afterwards: the padding has to go
//    inside the last packet, and its length field has to count it.
//  * Before the client's address is validated, the server may send no more
//    than three times what it has received. Without that limit, one spoofed
//    packet would make this server an amplifier pointed at someone else.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

/// Writes frames into a fixed region, refusing anything that will not fit.
struct QUICFrameWriter {
    let base: UnsafeMutablePointer<UInt8>
    var offset: Int
    let limit: Int

    @inline(__always) var room: Int { limit - offset }

    @inline(__always)
    mutating func varint(_ value: UInt64) {
        offset += quicWriteVarint(value, base + offset)
    }

    @inline(__always)
    mutating func byte(_ value: UInt8) {
        base[offset] = value
        offset += 1
    }

    @inline(__always)
    mutating func bytes(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if n > 0 {
            (base + offset).update(from: p, count: n)
            offset += n
        }
    }
}

extension QUICConnection {
    /// The largest packet number we might use next, which decides how many
    /// bytes the packet number field needs.
    private func packetNumberLength(_ level: QUICLevel) -> Int {
        quicPacketNumberLength(spaces[level.rawValue].nextPacketNumber,
                               largestAcked: spaces[level.rawValue].largestAckedPacket)
    }

    /// Fills `out` with the next datagram, or returns 0 if there is nothing to
    /// send. Called repeatedly until it returns 0.
    public func nextDatagram(_ out: UnsafeMutablePointer<UInt8>, _ capacity: Int,
                             nowMs: UInt64) -> Int {
        if status == .drained { return 0 }

        var budget = min(capacity, recovery.maxDatagramSize)
        if !addressValidated {
            let allowance = 3 * bytesReceived - bytesSent
            if allowance <= 0 { return 0 }
            budget = min(budget, allowance)
        }
        if budget < 64 { return 0 }

        // A closing connection sends nothing but its close, and sends it
        // sparingly: the peer may not have heard, but repeating it on every
        // arriving packet is a way to be used against somebody.
        if status == .closing {
            return buildClose(out, budget, nowMs: nowMs)
        }

        var planned: [PlannedPacket] = []
        var offset = 0
        var carriesInitial = false

        for level in [QUICLevel.initial, .handshake, .application] {
            if !keys[level.rawValue].send.isValid { continue }
            // 1-RTT packets wait for the handshake: sending application data
            // before the client's Finished would be sending it to somebody
            // unauthenticated.
            if level == .application && !handshakeComplete { continue }
            guard let packet = buildPacket(level: level, out: out, start: offset,
                                           limit: budget, nowMs: nowMs) else { continue }
            if level == .initial { carriesInitial = true }
            offset = packet.end
            planned.append(packet)
            // Only one packet per level per datagram: a second would need its
            // own header for no gain.
        }
        if planned.isEmpty { return 0 }

        // Pad. An Initial-bearing datagram must reach 1200 bytes; every packet
        // needs enough ciphertext for a header protection sample. `end` counts
        // the tag that sealing will add, so these are sizes on the wire.
        let target = carriesInitial ? min(QUICPacket.minimumInitialSize, budget) : 0
        var last = planned[planned.count - 1]
        let minimumPayload = max(4 - last.pnLength, 0)
        var padding = 0
        if last.payloadLength < minimumPayload { padding = minimumPayload - last.payloadLength }
        if offset + padding < target { padding = target - offset }
        if padding > 0 && last.end + padding <= budget {
            (out + last.end - quicAEADTagLength).update(repeating: 0, count: padding)
            last.payloadLength += padding
            last.end += padding
            offset = last.end
            planned[planned.count - 1] = last
        }

        // Seal each packet where it lies. The length field of a long header is
        // only written now, because until the padding was placed it was not
        // known.
        var total = 0
        for packet in planned {
            if packet.level != .application {
                let length = packet.pnLength + packet.payloadLength + quicAEADTagLength
                quicWriteVarint(UInt64(length), width: 2, out + packet.lengthOffset)
            }
            guard let sealed = QUICProtect.seal(out + packet.start,
                                                pnOffset: packet.pnOffset - packet.start,
                                                pnLength: packet.pnLength,
                                                payloadLength: packet.payloadLength,
                                                packetNumber: packet.packetNumber,
                                                keys: keys[packet.level.rawValue].send.keys,
                                                header: keys[packet.level.rawValue].send.header)
            else { return 0 }
            total = packet.start + sealed

            var sent = QUICSentPacket(packetNumber: packet.packetNumber,
                                      sentAtMs: nowMs,
                                      size: sealed,
                                      ackEliciting: packet.ackEliciting,
                                      inFlight: packet.ackEliciting || packet.hasData,
                                      frames: packet.frames,
                                      largestAcked: packet.largestAcked)
            spaces[packet.level.rawValue].record(sent)
            recovery.onPacketSent(sent)
            sent.frames = QUICSentFrames()
        }
        bytesSent += total
        return total
    }

    struct PlannedPacket {
        var level: QUICLevel
        var start: Int
        var lengthOffset: Int
        var pnOffset: Int
        var pnLength: Int
        var payloadLength: Int
        var end: Int
        var packetNumber: UInt64
        var ackEliciting: Bool
        var hasData: Bool
        var largestAcked: UInt64?
        var frames: QUICSentFrames
    }

    /// Lays out one packet's header and frames without sealing it.
    private func buildPacket(level: QUICLevel, out: UnsafeMutablePointer<UInt8>,
                             start: Int, limit: Int, nowMs: UInt64) -> PlannedPacket? {
        let space = level.rawValue
        // Leave room for the tag, which is added when the packet is sealed.
        let bodyLimit = limit - quicAEADTagLength
        if start + 32 > bodyLimit { return nil }

        let pnLength = packetNumberLength(level)
        let packetNumber = spaces[space].nextPacketNumber
        var offset = start
        var lengthOffset = 0

        if level == .application {
            out[offset] = 0x40 | (currentKeyPhase ? 0x04 : 0x00)
                        | UInt8(pnLength - 1)
            offset += 1
            peerCID.withBytes { p, n in
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
        } else {
            let typeBits: UInt8
            if version == QUICVersion.v2 {
                typeBits = level == .initial ? 1 : 3
            } else {
                typeBits = level == .initial ? 0 : 2
            }
            out[offset] = 0xC0 | (typeBits << 4) | UInt8(pnLength - 1)
            offset += 1
            quicWriteUInt32BE(version, out + offset)
            offset += 4
            peerCID.withBytes { p, n in
                out[offset] = UInt8(n)
                offset += 1
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
            localCID.withBytes { p, n in
                out[offset] = UInt8(n)
                offset += 1
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
            if level == .initial {
                out[offset] = 0      // an empty token: this server issues none
                offset += 1
            }
            // Two bytes of length, filled in once the padding is known.
            lengthOffset = offset
            out[offset] = 0x40
            out[offset + 1] = 0
            offset += 2
        }

        let pnOffset = offset
        offset += pnLength
        if offset >= bodyLimit { return nil }

        var writer = QUICFrameWriter(base: out, offset: offset, limit: bodyLimit)
        var frames = QUICSentFrames()
        var ackEliciting = false
        var largestAcked: UInt64?

        // Acknowledgements first: they are the most valuable thing in the
        // packet and the least likely to fit if left until last.
        if spaces[space].ackPending && !spaces[space].acks.isEmpty {
            let delay = level == .application
                ? ((nowMs &- spaces[space].largestReceivedAtMs) * 1000)
                  >> localParameters.ackDelayExponent
                : 0
            var scratch = ByteBuffer(capacity: 256)
            scratch.writeAckFrame(spaces[space].acks, delay: delay)
            if scratch.readableBytes <= writer.room {
                writer.bytes(scratch.readPointer, scratch.readableBytes)
                largestAcked = spaces[space].acks.largest
                spaces[space].ackPending = false
                spaces[space].ackElicitingPending = false
                spaces[space].ackDeadlineMs = 0
            }
            scratch.destroy()
        }

        if level == .application {
            writeApplicationFrames(&writer, &frames, &ackEliciting, nowMs: nowMs)
        }

        // Handshake bytes, at every level that still has them.
        writeCrypto(&writer, &frames, &ackEliciting, level: level)

        if pingPending && writer.room >= 1 {
            writer.varint(QUICFrameType.ping)
            frames.ping = true
            ackEliciting = true
            pingPending = false
        }

        let payloadLength = writer.offset - (pnOffset + pnLength)
        if payloadLength == 0 { return nil }

        // `end` is where the *next* packet in this datagram may begin, which
        // is past the tag that sealing has yet to write.
        return PlannedPacket(level: level, start: start, lengthOffset: lengthOffset,
                             pnOffset: pnOffset, pnLength: pnLength,
                             payloadLength: payloadLength,
                             end: writer.offset + quicAEADTagLength,
                             packetNumber: packetNumber,
                             ackEliciting: ackEliciting,
                             hasData: payloadLength > 0,
                             largestAcked: largestAcked,
                             frames: frames)
    }

    private func writeCrypto(_ writer: inout QUICFrameWriter, _ frames: inout QUICSentFrames,
                             _ ackEliciting: inout Bool, level: QUICLevel) {
        let index = level.rawValue
        // What was lost goes before what is new: a handshake that stalls
        // because a retransmission kept losing its place is a handshake that
        // never finishes.
        var offset: UInt64
        var length: Int
        if let range = cryptoSend[index].lost.ranges.first {
            offset = range.low
            length = Int(range.high - range.low)
        } else {
            offset = cryptoSend[index].sent
            length = Int(cryptoSend[index].written > offset
                         ? cryptoSend[index].written - offset : 0)
        }
        if length == 0 { return }

        // Header: type, offset, length. Reserve for the worst case so the
        // length can be written before the data is copied.
        let overhead = 1 + quicVarintLength(offset) + 4
        if writer.room <= overhead { return }
        length = min(length, writer.room - overhead)
        guard let data = cryptoSend[index].slice(at: offset, length) else { return }

        writer.varint(QUICFrameType.crypto)
        writer.varint(offset)
        writer.varint(UInt64(length))
        writer.bytes(data, length)

        frames.crypto = (offset, offset + UInt64(length))
        ackEliciting = true
        if !cryptoSend[index].lost.isEmpty {
            // Exactly what went into this frame stops being owed -- not
            // everything below it, which would drop a lower gap this packet
            // did not carry.
            cryptoSend[index].lost.subtract(offset, offset + UInt64(length))
        }
        if offset + UInt64(length) > cryptoSend[index].sent {
            cryptoSend[index].sent = offset + UInt64(length)
        }
    }

    private func writeApplicationFrames(_ writer: inout QUICFrameWriter,
                                        _ frames: inout QUICSentFrames,
                                        _ ackEliciting: inout Bool, nowMs: UInt64) {
        if handshakeDonePending && writer.room >= 1 {
            writer.varint(QUICFrameType.handshakeDone)
            frames.handshakeDone = true
            ackEliciting = true
            handshakeDonePending = false
        }

        while let response = pathResponsePending.first, writer.room >= 9 {
            writer.varint(QUICFrameType.pathResponse)
            response.withUnsafeBufferPointer { writer.bytes($0.baseAddress!, 8) }
            frames.pathResponse = response
            ackEliciting = true
            pathResponsePending.removeFirst()
        }

        if maxDataPending && writer.room >= 1 + quicVarintLength(receiveLimit) {
            writer.varint(QUICFrameType.maxData)
            writer.varint(receiveLimit)
            frames.maxData = true
            ackEliciting = true
            maxDataPending = false
        }
        if maxStreamsBidiPending && writer.room >= 1 + quicVarintLength(localMaxStreamsBidi) {
            writer.varint(QUICFrameType.maxStreamsBidi)
            writer.varint(localMaxStreamsBidi)
            frames.maxStreamsBidi = true
            ackEliciting = true
            maxStreamsBidiPending = false
        }
        if maxStreamsUniPending && writer.room >= 1 + quicVarintLength(localMaxStreamsUni) {
            writer.varint(QUICFrameType.maxStreamsUni)
            writer.varint(localMaxStreamsUni)
            frames.maxStreamsUni = true
            ackEliciting = true
            maxStreamsUniPending = false
        }

        while let payload = outgoingDatagrams.first {
            let overhead = 1 + quicVarintLength(UInt64(payload.count))
            if writer.room < overhead + payload.count { break }
            writer.varint(QUICFrameType.datagramWithLength)
            writer.varint(UInt64(payload.count))
            payload.withUnsafeBufferPointer { writer.bytes($0.baseAddress!, $0.count) }
            ackEliciting = true
            outgoingDatagrams.removeFirst()
        }

        writeStreamFrames(&writer, &frames, &ackEliciting)
        _ = nowMs
    }

    private func writeStreamFrames(_ writer: inout QUICFrameWriter,
                                   _ frames: inout QUICSentFrames,
                                   _ ackEliciting: inout Bool) {
        guard !writable.isEmpty else { return }
        // Round-robin: the list is walked from the front and anything still
        // owing goes to the back, so one large response cannot starve the
        // others.
        var deferred: [UInt64] = []
        var index = 0

        while index < writable.count && writer.room > 8 {
            let id = writable[index]
            index += 1
            guard let stream = streams[id] else {
                writableSet.remove(id)
                continue
            }

            if let code = stream.stopSendingQueued, !stream.stopSendingSent {
                let need = 1 + quicVarintLength(id) + quicVarintLength(code)
                if writer.room >= need {
                    writer.varint(QUICFrameType.stopSending)
                    writer.varint(id)
                    writer.varint(code)
                    stream.stopSendingSent = true
                    frames.stopSending.append(id)
                    ackEliciting = true
                }
            }

            if let code = stream.send.resetCode, !stream.send.resetSent {
                let final = stream.send.written
                let need = 1 + quicVarintLength(id) + quicVarintLength(code)
                         + quicVarintLength(final)
                if writer.room >= need {
                    writer.varint(QUICFrameType.resetStream)
                    writer.varint(id)
                    writer.varint(code)
                    writer.varint(final)
                    stream.send.resetSent = true
                    frames.resetStream.append(id)
                    ackEliciting = true
                }
                // A reset stream sends no more data.
                writableSet.remove(id)
                continue
            }

            // A reader that has caught up needs the peer told it may send
            // more -- once per raise. Saying it again would put a frame in
            // every packet for as long as the stream had anything to send.
            if stream.receive.limit > stream.receive.announced {
                let need = 1 + quicVarintLength(id) + quicVarintLength(stream.receive.limit)
                if writer.room >= need {
                    writer.varint(QUICFrameType.maxStreamData)
                    writer.varint(id)
                    writer.varint(stream.receive.limit)
                    stream.receive.announced = stream.receive.limit
                    frames.maxStreamData.append(id)
                    ackEliciting = true
                }
            }

            let wrote = writeOneStream(stream, &writer, &frames, &ackEliciting)
            let owes = stream.send.pending > 0 || !stream.send.lost.isEmpty
                     || (stream.send.finQueued && !stream.send.finSent)
            if owes {
                deferred.append(id)
            } else {
                writableSet.remove(id)
            }
            if !wrote && !owes { continue }
            if writer.room <= 8 { break }
        }

        // Anything not reached this time keeps its place at the front.
        var rest: [UInt64] = []
        rest.reserveCapacity(writable.count)
        if index < writable.count {
            for i in index..<writable.count where writableSet.contains(writable[i]) {
                rest.append(writable[i])
            }
        }
        rest.append(contentsOf: deferred)
        writable = rest
    }

    private func writeOneStream(_ stream: QUICStream, _ writer: inout QUICFrameWriter,
                                _ frames: inout QUICSentFrames,
                                _ ackEliciting: inout Bool) -> Bool {
        // Retransmissions before new data, for the same reason as the crypto
        // stream: a gap that keeps being deferred never closes.
        var offset: UInt64
        var available: UInt64
        var isRetransmit = false
        if let range = stream.send.lost.ranges.first {
            offset = range.low
            available = range.high - range.low
            isRetransmit = true
        } else {
            offset = stream.send.sent
            available = stream.send.written > offset ? stream.send.written - offset : 0
        }

        // The end of the stream can only be marked on a frame that actually
        // reaches the end of it. A retransmission never does, however much of
        // it there is: it is filling a gap behind the write cursor, and
        // marking it final would tell the peer the stream ended at an offset
        // it has already seen data past.
        let finPending = stream.send.finQueued && !stream.send.finSent
        let atEnd = offset == stream.send.written
        if available == 0 && (isRetransmit || !finPending || !atEnd) { return false }

        if !isRetransmit {
            // Flow control applies to new bytes only; a retransmission was
            // already counted when it was first sent.
            let streamRoom = stream.send.window
            let connectionRoom = sendLimit > sentBytes ? sendLimit - sentBytes : 0
            available = min(available, min(streamRoom, connectionRoom))
            if available == 0 && !(finPending && atEnd) { return false }
        }

        let overhead = 1 + quicVarintLength(stream.id) + quicVarintLength(offset) + 2
        if writer.room <= overhead { return false }
        let length = Int(min(available, UInt64(writer.room - overhead)))
        let fin = !isRetransmit && finPending
                && offset &+ UInt64(length) == stream.send.written

        var type = QUICFrameType.streamFirst | QUICFrameType.streamLength
        if offset > 0 { type |= QUICFrameType.streamOffset }
        if fin { type |= QUICFrameType.streamFin }

        writer.varint(type)
        writer.varint(stream.id)
        if offset > 0 { writer.varint(offset) }
        writer.varint(UInt64(length))
        if length > 0 {
            guard let data = stream.send.slice(at: offset, length) else { return false }
            writer.bytes(data, length)
        }

        frames.streams.append((stream.id, offset, offset + UInt64(length), fin))
        ackEliciting = true
        if isRetransmit {
            stream.send.lost.subtract(offset, offset + UInt64(length))
        } else {
            sentBytes &+= UInt64(length)
        }
        if offset + UInt64(length) > stream.send.sent {
            stream.send.sent = offset + UInt64(length)
        }
        if fin { stream.send.finSent = true }
        _ = length
        return true
    }

    /// A datagram carrying nothing but CONNECTION_CLOSE, at the highest level
    /// whose keys both sides have.
    private func buildClose(_ out: UnsafeMutablePointer<UInt8>, _ budget: Int,
                            nowMs: UInt64) -> Int {
        if closeWasReceived { return 0 }
        if !closeFramePending {
            // The close is repeated at most a few times, spaced out, so that a
            // peer whose acknowledgement was lost still hears.
            if closeSendCount >= 3 { return 0 }
            if nowMs < closeSentAtMs + recovery.ptoMs(includeMaxAckDelay: true) { return 0 }
        }

        var level = QUICLevel.application
        if !keys[QUICLevel.application.rawValue].send.isValid || !handshakeComplete {
            level = keys[QUICLevel.handshake.rawValue].send.isValid ? .handshake : .initial
        }
        guard keys[level.rawValue].send.isValid else { return 0 }

        guard var packet = buildCloseFrame(level: level, out: out, limit: budget) else {
            return 0
        }
        if level != .application {
            let length = packet.pnLength + packet.payloadLength + quicAEADTagLength
            quicWriteVarint(UInt64(length), width: 2, out + packet.lengthOffset)
        }
        guard let sealed = QUICProtect.seal(out, pnOffset: packet.pnOffset,
                                            pnLength: packet.pnLength,
                                            payloadLength: packet.payloadLength,
                                            packetNumber: packet.packetNumber,
                                            keys: keys[level.rawValue].send.keys,
                                            header: keys[level.rawValue].send.header)
        else { return 0 }
        spaces[level.rawValue].nextPacketNumber += 1
        closeFramePending = false
        closeSentAtMs = nowMs
        closeSendCount += 1
        bytesSent += sealed
        packet.payloadLength = 0
        return sealed
    }

    private func buildCloseFrame(level: QUICLevel, out: UnsafeMutablePointer<UInt8>,
                                 limit: Int) -> PlannedPacket? {
        let pnLength = 1
        let packetNumber = spaces[level.rawValue].nextPacketNumber
        var offset = 0
        var lengthOffset = 0

        if level == .application {
            out[0] = 0x40 | (currentKeyPhase ? 0x04 : 0x00) | UInt8(pnLength - 1)
            offset = 1
            peerCID.withBytes { p, n in
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
        } else {
            let typeBits: UInt8 = version == QUICVersion.v2
                ? (level == .initial ? 1 : 3)
                : (level == .initial ? 0 : 2)
            out[0] = 0xC0 | (typeBits << 4) | UInt8(pnLength - 1)
            offset = 1
            quicWriteUInt32BE(version, out + offset)
            offset += 4
            peerCID.withBytes { p, n in
                out[offset] = UInt8(n); offset += 1
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
            localCID.withBytes { p, n in
                out[offset] = UInt8(n); offset += 1
                if n > 0 { (out + offset).update(from: p, count: n) }
                offset += n
            }
            if level == .initial { out[offset] = 0; offset += 1 }
            lengthOffset = offset
            out[offset] = 0x40
            out[offset + 1] = 0
            offset += 2
        }

        let pnOffset = offset
        offset += pnLength
        var writer = QUICFrameWriter(base: out, offset: offset,
                                     limit: limit - quicAEADTagLength)

        // An application error cannot be expressed before the handshake is
        // done, so it is reported as a generic application error instead.
        let useApplication = closeIsApplication && level == .application
        if writer.room < 16 { return nil }
        writer.varint(useApplication ? QUICFrameType.connectionCloseApplication
                                     : QUICFrameType.connectionCloseTransport)
        writer.varint(closeIsApplication && !useApplication
                      ? QUICError.applicationError.rawValue : closeError)
        if !useApplication { writer.varint(0) }        // the frame type at fault
        let reasonLength = min(closeReason.count, max(0, writer.room - 8))
        writer.varint(UInt64(reasonLength))
        if reasonLength > 0 {
            closeReason.withUnsafeBufferPointer { writer.bytes($0.baseAddress!, reasonLength) }
        }

        var payloadLength = writer.offset - (pnOffset + pnLength)
        // Enough ciphertext for a header protection sample.
        while payloadLength < 4 - pnLength {
            out[writer.offset] = 0
            writer.offset += 1
            payloadLength += 1
        }
        return PlannedPacket(level: level, start: 0, lengthOffset: lengthOffset,
                             pnOffset: pnOffset, pnLength: pnLength,
                             payloadLength: payloadLength, end: writer.offset,
                             packetNumber: packetNumber, ackEliciting: false,
                             hasData: false, largestAcked: nil, frames: QUICSentFrames())
    }

    // MARK: - Timers

    /// Whether anything is waiting to go out. Used to decide whether the
    /// connection needs a turn at the socket.
    public var hasOutput: Bool {
        if status == .closing { return closeFramePending && !closeWasReceived }
        if status == .drained { return false }
        for space in spaces where space.ackPending { return true }
        for i in 0..<3 where cryptoSend[i].pending > 0 || !cryptoSend[i].lost.isEmpty {
            return true
        }
        if handshakeDonePending || maxDataPending || maxStreamsBidiPending
            || maxStreamsUniPending || pingPending { return true }
        if !pathResponsePending.isEmpty || !outgoingDatagrams.isEmpty { return true }
        if !writable.isEmpty { return true }
        return false
    }

    /// When this connection next needs attention, in milliseconds since the
    /// same origin as `nowMs`.
    public func nextTimeout(nowMs: UInt64) -> UInt64? {
        if status == .drained { return nil }
        if status == .closing {
            return closeSentAtMs + 3 * recovery.ptoMs(includeMaxAckDelay: true)
        }

        var deadline: UInt64?
        func consider(_ time: UInt64) {
            if time == 0 { return }
            if deadline == nil || time < deadline! { deadline = time }
        }

        for space in spaces where space.ackDeadlineMs != 0 { consider(space.ackDeadlineMs) }
        for space in spaces { consider(space.lossTimeMs) }

        // The probe timeout, on the space with something outstanding.
        var hasInFlight = false
        var lastSent: UInt64 = 0
        for (index, space) in spaces.enumerated() where space.ackElicitingInFlight > 0 {
            hasInFlight = true
            if space.timeOfLastAckElicitingMs > lastSent {
                lastSent = space.timeOfLastAckElicitingMs
            }
            _ = index
        }
        if hasInFlight {
            // Before the handshake finishes there is no max_ack_delay to
            // account for: the peer has not told us one yet.
            consider(lastSent + recovery.ptoMs(includeMaxAckDelay: handshakeConfirmed))
        } else if !handshakeComplete {
            // Nothing in flight but the handshake is unfinished, which means we
            // are waiting on the peer; probe rather than stall.
            consider(lastActivityMs + recovery.ptoMs(includeMaxAckDelay: false))
        }

        if idleTimeoutMs > 0 {
            let floor = 3 * recovery.ptoMs(includeMaxAckDelay: true)
            consider(lastActivityMs + max(idleTimeoutMs, floor))
        }
        return deadline
    }

    public func onTimeout(nowMs: UInt64) {
        if status == .drained { return }
        if status == .closing {
            if nowMs >= closeSentAtMs + 3 * recovery.ptoMs(includeMaxAckDelay: true) {
                status = .drained
            }
            return
        }
        if isIdle(nowMs: nowMs) {
            status = .drained
            events.append(QUICEvent(.closed, code: QUICError.noError.rawValue))
            return
        }

        for space in spaces where space.ackDeadlineMs != 0 && nowMs >= space.ackDeadlineMs {
            // Handled below by clearing the deadline; the ACK goes out with
            // the next datagram.
            _ = space
        }
        for i in 0..<3 where spaces[i].ackDeadlineMs != 0 && nowMs >= spaces[i].ackDeadlineMs {
            spaces[i].ackDeadlineMs = 0
            spaces[i].ackPending = true
        }

        var actedOnLoss = false
        for i in 0..<3 where spaces[i].lossTimeMs != 0 && nowMs >= spaces[i].lossTimeMs {
            let level = QUICLevel(rawValue: i)!
            let lost = QUICLossDetection.onLossTimer(space: &spaces[i], recovery: &recovery,
                                                     nowMs: nowMs)
            for packet in lost { onPacketLostPublic(packet, level: level) }
            actedOnLoss = true
        }
        if actedOnLoss { return }

        // Probe timeout. A PING would elicit an acknowledgement, but during
        // the handshake the peer is not waiting for an acknowledgement -- it is
        // waiting for bytes it never received. So anything unacknowledged goes
        // back on the wire.
        recovery.onProbeTimeout()
        var resent = false
        for i in 0..<3 where keys[i].send.isValid {
            if cryptoSend[i].sent > cryptoSend[i].base {
                cryptoSend[i].declareLost(cryptoSend[i].base, cryptoSend[i].sent)
                resent = true
            }
        }
        if !resent { pingPending = true }
    }

    /// Exposed so the timer path can reuse the loss bookkeeping.
    func onPacketLostPublic(_ packet: QUICSentPacket, level: QUICLevel) {
        if let range = packet.frames.crypto {
            cryptoSend[level.rawValue].declareLost(range.low, range.high)
        }
        for frame in packet.frames.streams {
            guard let stream = streams[frame.id] else { continue }
            stream.send.declareLost(frame.low, frame.high)
            if frame.fin { stream.send.finSent = false }
            markWritable(frame.id)
        }
        if packet.frames.handshakeDone { handshakeDonePending = true }
        if packet.frames.maxData { maxDataPending = true }
        if packet.frames.maxStreamsBidi { maxStreamsBidiPending = true }
        if packet.frames.maxStreamsUni { maxStreamsUniPending = true }
        for id in packet.frames.maxStreamData {
            // A limit the peer never received is a limit it does not have, so
            // the current one is announced again rather than the lost value.
            streams[id]?.receive.announced = 0
            markWritable(id)
        }
        for id in packet.frames.resetStream {
            streams[id]?.send.resetSent = false
            markWritable(id)
        }
        for id in packet.frames.stopSending {
            streams[id]?.stopSendingSent = false
            markWritable(id)
        }
        if let response = packet.frames.pathResponse { pathResponsePending.append(response) }
    }
}

extension QUICLossDetection {
    /// Packets old enough to be called lost with no acknowledgement to go on.
    public static func onLossTimer(space: inout QUICPacketSpace,
                                   recovery: inout QUICRecovery,
                                   nowMs: UInt64) -> [QUICSentPacket] {
        let delay = recovery.lossDelayMs
        let threshold = space.largestAckedPacket ?? UInt64.max
        var lost: [QUICSentPacket] = []
        var kept: [QUICSentPacket] = []
        var earliest: UInt64 = 0

        for packet in space.sent {
            let age = nowMs >= packet.sentAtMs ? nowMs - packet.sentAtMs : 0
            let ordered = threshold != UInt64.max && packet.packetNumber < threshold
                        && threshold - packet.packetNumber >= UInt64(QUICRecovery.packetThreshold)
            if age >= delay || ordered {
                lost.append(packet)
                if packet.ackEliciting { space.ackElicitingInFlight -= 1 }
            } else {
                kept.append(packet)
                let at = packet.sentAtMs + delay
                if earliest == 0 || at < earliest { earliest = at }
            }
        }
        space.sent = kept
        space.lossTimeMs = earliest
        recovery.onPacketsLost(lost, nowMs: nowMs)
        return lost
    }
}
