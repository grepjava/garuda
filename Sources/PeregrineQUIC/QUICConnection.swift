//===----------------------------------------------------------------------===//
// A QUIC connection.
//
// The shape of this is different from a TCP connection in three ways that
// matter to everything below:
//
//  * It is not a socket. One UDP socket serves every client, and a connection
//    is found by the destination connection ID in the packet, so a client that
//    changes address -- a phone leaving wifi -- keeps its connection.
//  * There is no single sequence of bytes. Three packet number spaces run at
//    once during the handshake, each with its own keys, acknowledgements and
//    loss detection, and a datagram may carry a packet from more than one.
//  * Nothing is ever retransmitted. A lost packet's *contents* are sent again
//    in a new packet, which is why streams keep their unacknowledged bytes and
//    why every sent packet records what it carried.
//
// This file is the receiving half: decrypt, parse frames, update state. The
// sending half -- deciding what goes in the next datagram -- is in QUICSend.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore

public struct QUICServerConfig {
    /// The certificate and key, owned by the caller for the life of the server.
    public var certKey: OpaquePointer
    /// ALPN protocols, in the server's order of preference.
    public var alpn: [[UInt8]]
    public var maxIdleTimeoutMs: UInt64 = 30_000
    public var initialMaxData: UInt64 = 1 << 20
    public var initialMaxStreamData: UInt64 = 256 * 1024
    public var initialMaxStreamsBidi: UInt64 = 128
    public var initialMaxStreamsUni: UInt64 = 128
    /// RFC 9221 datagrams, which WebTransport needs. Zero disables them.
    public var maxDatagramFrameSize: UInt64 = 1200
    public var maxIncomingStreams = 256

    public init(certKey: OpaquePointer, alpn: [[UInt8]]) {
        self.certKey = certKey
        self.alpn = alpn
    }
}

public struct QUICEvent {
    public enum Kind: UInt8 {
        case handshakeComplete
        case streamReadable
        case streamFinished
        case streamReset
        case stopSending
        case streamWritable
        case datagram
        case closed
    }
    public var kind: Kind
    public var streamID: UInt64 = 0
    public var code: UInt64 = 0

    public init(_ kind: Kind, streamID: UInt64 = 0, code: UInt64 = 0) {
        self.kind = kind
        self.streamID = streamID
        self.code = code
    }
}

public final class QUICConnection {
    // MARK: Identity

    public let version: UInt32
    /// What the peer puts in the packets it sends us.
    public private(set) var localCID: QUICConnectionID
    /// What we put in the packets we send.
    public private(set) var peerCID: QUICConnectionID
    /// The connection ID the client invented for its first packet, which the
    /// transport parameters have to reflect back.
    public let originalDCID: QUICConnectionID
    public var peerAddress = pg_udp_addr()
    public var localAddress = pg_udp_addr()

    // MARK: Crypto

    var keys = [QUICKeyPair](repeating: QUICKeyPair(), count: 3)
    /// The generation after the current one, derived early so that a peer's
    /// key update can be answered without a pause.
    var nextReceiveKeys = QUICKeys()
    var previousReceiveKeys = QUICKeys()
    var previousKeysExpireMs: UInt64 = 0
    var currentKeyPhase = false
    var keyUpdatePermitted = false
    var tls: TLSServerHandshake?

    public private(set) var handshakeComplete = false
    public private(set) var handshakeConfirmed = false
    public private(set) var selectedALPN: [UInt8] = []
    public private(set) var serverName: [UInt8] = []
    /// Where the application layer keeps its own state for this connection.
    /// The transport does not look at it.
    public var applicationSlot: Int32 = -1

    // MARK: Packet number spaces

    var spaces = [QUICPacketSpace](repeating: QUICPacketSpace(), count: 3)
    var recovery = QUICRecovery()
    var cryptoReceive = [QUICReceiveStream](repeating: QUICReceiveStream(), count: 3)
    var cryptoSend = [QUICSendStream](repeating: QUICSendStream(), count: 3)

    // MARK: Streams and flow control

    public internal(set) var streams: [UInt64: QUICStream] = [:]
    var localParameters = QUICTransportParameters()
    var peerParameters = QUICTransportParameters()

    /// Connection-wide flow control: what we have granted, and what we owe.
    var receiveLimit: UInt64 = 0
    var receivedBytes: UInt64 = 0
    var sendLimit: UInt64 = 0
    var sentBytes: UInt64 = 0
    var maxDataPending = false

    var localMaxStreamsBidi: UInt64 = 0
    var localMaxStreamsUni: UInt64 = 0
    var maxStreamsBidiPending = false
    var maxStreamsUniPending = false
    var peerMaxStreamsBidi: UInt64 = 0
    var peerMaxStreamsUni: UInt64 = 0
    var nextLocalStreamUni: UInt64 = 0
    var nextLocalStreamBidi: UInt64 = 0
    var highestIncomingBidi: Int64 = -1
    var highestIncomingUni: Int64 = -1

    /// Streams with data queued that the sender has not finished with. Kept as
    /// a list so a busy connection does not walk the whole map per packet.
    var writable: [UInt64] = []
    var writableSet: Set<UInt64> = []

    // MARK: Datagrams (RFC 9221)

    public var incomingDatagrams: [[UInt8]] = []
    var outgoingDatagrams: [[UInt8]] = []

    // MARK: Connection state

    public enum Status {
        case handshaking
        case connected
        /// A close has been sent or received; the connection lingers only to
        /// repeat the close for anything still in flight.
        case closing
        case drained
    }
    public internal(set) var status: Status = .handshaking
    public private(set) var closeError: UInt64 = 0
    public private(set) var closeIsApplication = false
    var closeReason: [UInt8] = []
    var closeFramePending = false
    var closeSentAtMs: UInt64 = 0
    var closeSendCount = 0
    /// A close received from the peer needs no further transmission from us.
    var closeWasReceived = false

    var lastActivityMs: UInt64 = 0
    var idleTimeoutMs: UInt64 = 30_000

    /// Anti-amplification: before the client's address is validated, a server
    /// may send no more than three times what it has received. Without this a
    /// spoofed Initial packet turns the server into an amplifier.
    var bytesReceived = 0
    var bytesSent = 0
    var addressValidated = false

    var handshakeDonePending = false
    var pingPending = false
    var pathResponsePending: [[UInt8]] = []

    public internal(set) var events: [QUICEvent] = []
    /// Streams already announced as writable in the current batch.
    var writableAnnounced: Set<UInt64> = []

    let config: QUICServerConfig

    // MARK: - Life cycle

    public init?(config: QUICServerConfig, version: UInt32,
                 clientDCID: QUICConnectionID, clientSCID: QUICConnectionID,
                 localCID: QUICConnectionID, nowMs: UInt64) {
        self.config = config
        self.version = version
        self.originalDCID = clientDCID
        self.peerCID = clientSCID
        self.localCID = localCID
        self.lastActivityMs = nowMs
        self.idleTimeoutMs = config.maxIdleTimeoutMs

        guard let initial = quicInitialKeys(destinationCID: clientDCID,
                                            version: version, isServer: true)
        else { return nil }
        keys[QUICLevel.initial.rawValue] = initial

        var parameters = QUICTransportParameters()
        parameters.maxIdleTimeoutMs = config.maxIdleTimeoutMs
        parameters.initialMaxData = config.initialMaxData
        parameters.initialMaxStreamDataBidiLocal = config.initialMaxStreamData
        parameters.initialMaxStreamDataBidiRemote = config.initialMaxStreamData
        parameters.initialMaxStreamDataUni = config.initialMaxStreamData
        parameters.initialMaxStreamsBidi = config.initialMaxStreamsBidi
        parameters.initialMaxStreamsUni = config.initialMaxStreamsUni
        parameters.maxDatagramFrameSize = config.maxDatagramFrameSize
        parameters.activeConnectionIDLimit = 4
        parameters.initialSourceCID = localCID
        parameters.hasInitialSourceCID = true
        parameters.originalDestinationCID = clientDCID
        parameters.hasOriginalDestinationCID = true
        parameters.maxUDPPayloadSize = 1452
        localParameters = parameters

        receiveLimit = parameters.initialMaxData
        localMaxStreamsBidi = parameters.initialMaxStreamsBidi
        localMaxStreamsUni = parameters.initialMaxStreamsUni

        // The crypto stream has no flow control of its own beyond a sanity
        // limit: a peer that sends megabytes of handshake is not one we want.
        for i in 0..<3 { cryptoReceive[i].limit = 256 * 1024 }

        tls = TLSServerHandshake(certKey: config.certKey, alpn: config.alpn,
                                 parameters: parameters, version: version)
    }

    deinit {
        for i in 0..<3 {
            keys[i].destroy()
            cryptoReceive[i].destroy()
            cryptoSend[i].destroy()
        }
        nextReceiveKeys.destroy()
        previousReceiveKeys.destroy()
        for (_, stream) in streams { stream.destroy() }
    }

    public func takeEvents() -> [QUICEvent] {
        let out = events
        events.removeAll(keepingCapacity: true)
        writableAnnounced.removeAll(keepingCapacity: true)
        return out
    }

    /// Says that a stream can take more, once per batch of events.
    ///
    /// A large transfer is acknowledged a packet at a time, and the layer
    /// above only needs to hear that the transport caught up, not how many
    /// times: one event per stream per drain is enough to release a producer
    /// and cheap enough not to matter.
    func noteWritable(_ id: UInt64) {
        if writableAnnounced.insert(id).inserted {
            events.append(QUICEvent(.streamWritable, streamID: id))
        }
    }

    // MARK: - Receiving

    /// Takes one UDP datagram. The buffer is modified in place -- headers are
    /// unmasked and payloads decrypted where they lie.
    public func receive(_ datagram: UnsafeMutablePointer<UInt8>, _ count: Int,
                        ecn: UInt8, nowMs: UInt64) {
        if status == .drained { return }
        bytesReceived += count

        var offset = 0
        while offset < count {
            let p = datagram + offset
            let remaining = count - offset
            let header = QUICPacket.parseHeader(p, remaining,
                                                localCIDLength: Int(localCID.length))
            if !header.isValid { return }

            let level: QUICLevel?
            switch header.type {
            case .initial: level = .initial
            case .handshake: level = .handshake
            case .oneRTT: level = .application
            default: level = nil        // 0-RTT, Retry, version negotiation
            }

            if let level, receivePacket(p, header: header, level: level, nowMs: nowMs) {
                lastActivityMs = nowMs
            }
            if header.end <= 0 { return }
            offset += header.end
        }
    }

    private func receivePacket(_ p: UnsafeMutablePointer<UInt8>,
                               header: QUICPacketHeader, level: QUICLevel,
                               nowMs: UInt64) -> Bool {
        if header.isLong && header.version != version { return false }
        // A packet at a level whose keys are gone is not an error. It is a
        // straggler, and QUIC says to discard it in silence.
        guard keys[level.rawValue].receive.isValid else { return false }

        var opened: QUICProtect.Opened?
        if level == .application {
            opened = openOneRTT(p, header: header, nowMs: nowMs)
        } else {
            opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                      largestReceived: spaces[level.rawValue].largestReceived,
                                      keys: keys[level.rawValue].receive.keys,
                                      header: keys[level.rawValue].receive.header)
        }
        guard let packet = opened else {
            Log.debug { line in
                line.str("quic: packet at level ")
                line.int(level.rawValue)
                line.str(" would not open")
            }
            return false
        }

        // Receiving a Handshake packet that decrypts proves the peer is at the
        // address it claims: only somebody who saw our Initial could have
        // produced it.
        if level == .handshake && !addressValidated {
            addressValidated = true
            discardSpace(.initial)
        }

        let space = level.rawValue
        if spaces[space].acks.ranges.contains(where: {
            packet.packetNumber >= $0.low && packet.packetNumber <= $0.high
        }) {
            return true     // a duplicate; already accounted for
        }

        let ackEliciting = processFrames(packet.payload, packet.payloadLength,
                                         level: level, nowMs: nowMs)
        if ackEliciting == nil {
            return true     // the connection is closing; the error is recorded
        }

        if Int64(packet.packetNumber) > spaces[space].largestReceived {
            spaces[space].largestReceived = Int64(packet.packetNumber)
            spaces[space].largestReceivedAtMs = nowMs
        }
        spaces[space].acks.add(packet.packetNumber)
        spaces[space].ackPending = true
        if ackEliciting == true {
            spaces[space].ackElicitingPending = true
            // RFC 9000 section 13.2.1: an acknowledgement is owed within
            // max_ack_delay, and immediately if a packet arrived out of order.
            if spaces[space].ackDeadlineMs == 0 {
                spaces[space].ackDeadlineMs = nowMs + (level == .application ? 25 : 1)
            }
        }
        return true
    }

    /// The 1-RTT path, which has to deal with the key phase bit: a flipped
    /// phase is either the peer starting a key update or a straggler from
    /// before ours.
    private func openOneRTT(_ p: UnsafeMutablePointer<UInt8>,
                            header: QUICPacketHeader, nowMs: UInt64) -> QUICProtect.Opened? {
        let level = QUICLevel.application.rawValue
        // The phase cannot be read until the header is unmasked, so the
        // current keys are tried first and the phase checked from the result.
        if let opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                         largestReceived: spaces[level].largestReceived,
                                         keys: keys[level].receive.keys,
                                         header: keys[level].receive.header) {
            if opened.keyPhase == currentKeyPhase { return opened }
            // The AEAD succeeded but the phase disagrees, which cannot happen:
            // the keys are bound to the phase. Treat it as garbage.
            return nil
        }

        // A different phase: either the peer has moved on, or this is an old
        // packet from before we did.
        if previousReceiveKeys.isValid && nowMs < previousKeysExpireMs,
           let opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                         largestReceived: spaces[level].largestReceived,
                                         keys: previousReceiveKeys,
                                         header: keys[level].receive.header),
           opened.keyPhase != currentKeyPhase {
            return opened
        }
        if keyUpdatePermitted && nextReceiveKeys.isValid,
           let opened = QUICProtect.open(p, pnOffset: header.pnOffset, end: header.end,
                                         largestReceived: spaces[level].largestReceived,
                                         keys: nextReceiveKeys,
                                         header: keys[level].receive.header),
           opened.keyPhase != currentKeyPhase {
            commitKeyUpdate(nowMs: nowMs)
            return opened
        }
        return nil
    }

    // MARK: - Frames

    /// Returns whether the packet was ack-eliciting, or nil if the connection
    /// is now closing.
    private func processFrames(_ p: UnsafePointer<UInt8>, _ n: Int,
                               level: QUICLevel, nowMs: UInt64) -> Bool? {
        var r = QUICReader(p, n)
        var ackEliciting = false

        while !r.isEmpty {
            guard let type = r.varint() else {
                close(QUICError.frameEncodingError.rawValue)
                return nil
            }
            if level != .application && !QUICFrameType.allowedDuringHandshake(type) {
                close(QUICError.protocolViolation.rawValue)
                return nil
            }
            if QUICFrameType.isAckEliciting(type) { ackEliciting = true }

            switch type {
            case QUICFrameType.padding:
                // A run of padding is one frame's worth of work, not one per
                // byte: an Initial packet is mostly padding.
                while r.peek() == 0 { _ = r.byte() }

            case QUICFrameType.ping:
                break

            case QUICFrameType.ack, QUICFrameType.ackECN:
                if !handleAck(&r, hasECN: type == QUICFrameType.ackECN,
                              level: level, nowMs: nowMs) { return nil }

            case QUICFrameType.crypto:
                if !handleCrypto(&r, level: level) { return nil }

            case QUICFrameType.resetStream:
                if !handleResetStream(&r) { return nil }

            case QUICFrameType.stopSending:
                if !handleStopSending(&r) { return nil }

            case QUICFrameType.newToken:
                // A server has no use for a token it issued being handed back
                // outside an Initial packet, and a client must not send one.
                close(QUICError.protocolViolation.rawValue)
                return nil

            case QUICFrameType.streamFirst...QUICFrameType.streamLast:
                if !handleStream(&r, type: type) { return nil }

            case QUICFrameType.maxData:
                guard let limit = r.varint() else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                if limit > sendLimit {
                    sendLimit = limit
                    events.append(QUICEvent(.streamWritable))
                }

            case QUICFrameType.maxStreamData:
                guard let id = r.varint(), let limit = r.varint() else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                if !checkStreamID(id, isSend: true) { return nil }
                if let stream = streams[id], limit > stream.send.limit {
                    stream.send.limit = limit
                    markWritable(id)
                    noteWritable(id)
                }

            case QUICFrameType.maxStreamsBidi:
                guard let limit = r.varint(), limit <= 1 << 60 else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                peerMaxStreamsBidi = max(peerMaxStreamsBidi, limit)

            case QUICFrameType.maxStreamsUni:
                guard let limit = r.varint(), limit <= 1 << 60 else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                peerMaxStreamsUni = max(peerMaxStreamsUni, limit)

            case QUICFrameType.dataBlocked:
                guard r.varint() != nil else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                maxDataPending = true

            case QUICFrameType.streamDataBlocked:
                guard let id = r.varint(), r.varint() != nil else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                if !checkStreamID(id, isSend: false) { return nil }

            case QUICFrameType.streamsBlockedBidi:
                guard let limit = r.varint(), limit <= 1 << 60 else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                maxStreamsBidiPending = true

            case QUICFrameType.streamsBlockedUni:
                guard let limit = r.varint(), limit <= 1 << 60 else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                maxStreamsUniPending = true

            case QUICFrameType.newConnectionID:
                if !handleNewConnectionID(&r) { return nil }

            case QUICFrameType.retireConnectionID:
                guard r.varint() != nil else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }

            case QUICFrameType.pathChallenge:
                guard let data = r.take(8) else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                pathResponsePending.append([UInt8](UnsafeBufferPointer(start: data, count: 8)))

            case QUICFrameType.pathResponse:
                guard r.skip(8) else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }

            case QUICFrameType.connectionCloseTransport,
                 QUICFrameType.connectionCloseApplication:
                guard let code = r.varint() else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                if type == QUICFrameType.connectionCloseTransport {
                    guard r.varint() != nil else {          // the frame type at fault
                        close(QUICError.frameEncodingError.rawValue); return nil
                    }
                }
                guard let reasonLength = r.varintAsInt(), r.skip(reasonLength) else {
                    close(QUICError.frameEncodingError.rawValue); return nil
                }
                closeWasReceived = true
                closeError = code
                closeIsApplication = type == QUICFrameType.connectionCloseApplication
                status = .closing
                closeSentAtMs = nowMs
                events.append(QUICEvent(.closed, code: code))
                return nil

            case QUICFrameType.handshakeDone:
                // Only a server sends this.
                close(QUICError.protocolViolation.rawValue)
                return nil

            case QUICFrameType.datagram, QUICFrameType.datagramWithLength:
                if !handleDatagram(&r, hasLength: type == QUICFrameType.datagramWithLength) {
                    return nil
                }

            default:
                close(QUICError.frameEncodingError.rawValue)
                return nil
            }
        }
        return ackEliciting
    }

    private func handleAck(_ r: inout QUICReader, hasECN: Bool,
                           level: QUICLevel, nowMs: UInt64) -> Bool {
        var ranges: [(low: UInt64, high: UInt64)] = []
        var largest: UInt64 = 0
        var first = true
        guard let delayRaw = quicReadAckFrame(&r, hasECN: hasECN, { low, high in
            if first { largest = high; first = false }
            ranges.append((low, high))
        }) else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        // A peer cannot acknowledge a packet number we have not issued.
        if largest >= spaces[level.rawValue].nextPacketNumber {
            close(QUICError.protocolViolation.rawValue)
            return false
        }

        // The delay is scaled by the exponent the peer announced. During the
        // handshake the exponent is not yet known, and the RFC fixes it at 3.
        let exponent = handshakeComplete ? peerParameters.ackDelayExponent : 3
        let delay = level == .application ? (delayRaw << exponent) / 1000 : 0

        let result = QUICLossDetection.onAck(space: &spaces[level.rawValue],
                                             recovery: &recovery,
                                             ranges: ranges, largestAcked: largest,
                                             ackDelayMs: delay, nowMs: nowMs)
        for packet in result.acked { onPacketAcked(packet, level: level) }
        for packet in result.lost { onPacketLost(packet, level: level) }
        if !result.acked.isEmpty && level == .application && handshakeComplete {
            // Once the peer acknowledges 1-RTT data the handshake is
            // confirmed, which is what makes a key update safe.
            handshakeConfirmed = true
            keyUpdatePermitted = true
        }
        return true
    }

    private func handleCrypto(_ r: inout QUICReader, level: QUICLevel) -> Bool {
        guard let offset = r.varint(), let length = r.varintAsInt(),
              let data = r.take(length)
        else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        let before = cryptoReceive[level.rawValue].received
        switch cryptoReceive[level.rawValue].accept(offset: offset, data, length, fin: false) {
        case .flowControlError:
            close(QUICError.cryptoBufferExceeded.rawValue)
            return false
        case .finalSizeError:
            close(QUICError.protocolViolation.rawValue)
            return false
        case .ok:
            break
        }
        let after = cryptoReceive[level.rawValue].received
        if after > before {
            let ready = cryptoReceive[level.rawValue].ready.readableBytes
            if ready > 0 {
                tls?.receive(cryptoReceive[level.rawValue].ready.readPointer, ready, level: level)
                cryptoReceive[level.rawValue].ready.consume(ready)
            }
            if !applyTLSProgress() { return false }
        }
        return true
    }

    private func handleStream(_ r: inout QUICReader, type: UInt64) -> Bool {
        guard let id = r.varint() else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        var offset: UInt64 = 0
        if type & QUICFrameType.streamOffset != 0 {
            guard let value = r.varint() else {
                close(QUICError.frameEncodingError.rawValue)
                return false
            }
            offset = value
        }
        var length = r.remaining
        if type & QUICFrameType.streamLength != 0 {
            guard let value = r.varintAsInt() else {
                close(QUICError.frameEncodingError.rawValue)
                return false
            }
            length = value
        }
        guard let data = r.take(length) else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        let fin = type & QUICFrameType.streamFin != 0

        if !checkStreamID(id, isSend: false) { return false }
        // Sending to a stream we opened for sending only is nonsense.
        if QUICStreamKind.isServerInitiated(id) && QUICStreamKind.isUnidirectional(id) {
            close(QUICError.streamStateError.rawValue)
            return false
        }
        guard let stream = openOrFind(id) else { return false }

        // Connection-level flow control counts the highest offset seen on
        // every stream, not the bytes delivered: a peer cannot evade the limit
        // by sending the same range twice.
        let end = offset &+ UInt64(length)
        if end > stream.receive.highWater {
            let growth = end - stream.receive.highWater
            if receivedBytes &+ growth > receiveLimit {
                close(QUICError.flowControlError.rawValue)
                return false
            }
            receivedBytes &+= growth
        }

        switch stream.receive.accept(offset: offset, data, length, fin: fin) {
        case .flowControlError:
            close(QUICError.flowControlError.rawValue)
            return false
        case .finalSizeError:
            close(QUICError.finalSizeError.rawValue)
            return false
        case .ok:
            break
        }
        if stream.receive.ready.readableBytes > 0 {
            events.append(QUICEvent(.streamReadable, streamID: id))
        }
        if stream.receive.finished && !stream.receive.delivered {
            events.append(QUICEvent(.streamFinished, streamID: id))
        }
        return true
    }

    private func handleResetStream(_ r: inout QUICReader) -> Bool {
        guard let id = r.varint(), let code = r.varint(), let finalSize = r.varint() else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        if !checkStreamID(id, isSend: false) { return false }
        if QUICStreamKind.isServerInitiated(id) && QUICStreamKind.isUnidirectional(id) {
            close(QUICError.streamStateError.rawValue)
            return false
        }
        guard let stream = openOrFind(id) else { return false }
        if let known = stream.receive.finalSize, known != finalSize {
            close(QUICError.finalSizeError.rawValue)
            return false
        }
        if finalSize < stream.receive.highWater {
            close(QUICError.finalSizeError.rawValue)
            return false
        }
        if finalSize > stream.receive.highWater {
            let growth = finalSize - stream.receive.highWater
            if receivedBytes &+ growth > receiveLimit {
                close(QUICError.flowControlError.rawValue)
                return false
            }
            receivedBytes &+= growth
            stream.receive.highWater = finalSize
        }
        stream.receive.finalSize = finalSize
        stream.receive.finished = true
        events.append(QUICEvent(.streamReset, streamID: id, code: code))
        return true
    }

    private func handleStopSending(_ r: inout QUICReader) -> Bool {
        guard let id = r.varint(), let code = r.varint() else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        if !checkStreamID(id, isSend: true) { return false }
        // A peer cannot ask us to stop sending on a stream it opened for
        // sending only.
        if QUICStreamKind.isClientInitiated(id) && QUICStreamKind.isUnidirectional(id) {
            close(QUICError.streamStateError.rawValue)
            return false
        }
        guard let stream = openOrFind(id) else { return false }
        stream.stopSending = code
        if stream.send.resetCode == nil {
            stream.send.resetCode = code
            markWritable(id)
        }
        events.append(QUICEvent(.stopSending, streamID: id, code: code))
        return true
    }

    private func handleNewConnectionID(_ r: inout QUICReader) -> Bool {
        guard let sequence = r.varint(), let retirePrior = r.varint(),
              let length = r.byte(), length >= 1, length <= UInt8(quicMaxCIDLength),
              let bytes = r.take(Int(length)), r.skip(16)
        else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        if retirePrior > sequence {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        // The server keeps sending to the connection ID it already has; a new
        // one is only needed to change path, which is the client's business.
        _ = bytes
        return true
    }

    private func handleDatagram(_ r: inout QUICReader, hasLength: Bool) -> Bool {
        if localParameters.maxDatagramFrameSize == 0 {
            close(QUICError.protocolViolation.rawValue)
            return false
        }
        var length = r.remaining
        if hasLength {
            guard let value = r.varintAsInt() else {
                close(QUICError.frameEncodingError.rawValue)
                return false
            }
            length = value
        }
        guard let data = r.take(length) else {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        if UInt64(length) > localParameters.maxDatagramFrameSize {
            close(QUICError.protocolViolation.rawValue)
            return false
        }
        incomingDatagrams.append([UInt8](UnsafeBufferPointer(start: data, count: length)))
        events.append(QUICEvent(.datagram))
        return true
    }

    // MARK: - Streams

    /// Checks that a stream identifier is one the peer is allowed to name, and
    /// that it is within the limits we granted.
    private func checkStreamID(_ id: UInt64, isSend: Bool) -> Bool {
        if id > quicVarintMax {
            close(QUICError.frameEncodingError.rawValue)
            return false
        }
        // A frame about a server-initiated stream we have not opened is a
        // reference to something that does not exist.
        if QUICStreamKind.isServerInitiated(id) {
            let next = QUICStreamKind.isUnidirectional(id) ? nextLocalStreamUni : nextLocalStreamBidi
            if QUICStreamKind.index(id) >= next {
                close(QUICError.streamStateError.rawValue)
                return false
            }
            return true
        }
        let index = QUICStreamKind.index(id)
        let limit = QUICStreamKind.isUnidirectional(id) ? localMaxStreamsUni : localMaxStreamsBidi
        if index >= limit {
            close(QUICError.streamLimitError.rawValue)
            return false
        }
        _ = isSend
        return true
    }

    /// Finds a stream, creating it and every lower-numbered one of its kind.
    /// QUIC opens streams implicitly: a frame for stream 12 opens 0, 4 and 8
    /// as well, so a peer cannot skip ahead to avoid a limit.
    private func openOrFind(_ id: UInt64) -> QUICStream? {
        if let existing = streams[id] { return existing }
        if QUICStreamKind.isServerInitiated(id) { return nil }

        let unidirectional = QUICStreamKind.isUnidirectional(id)
        let index = Int64(QUICStreamKind.index(id))
        var highest = unidirectional ? highestIncomingUni : highestIncomingBidi
        if index <= highest { return streams[id] }

        var created: QUICStream?
        var i = highest + 1
        while i <= index {
            let newID = QUICStreamKind.id(index: UInt64(i), serverInitiated: false,
                                          unidirectional: unidirectional)
            let stream = QUICStream(id: newID)
            stream.receive.limit = unidirectional
                ? localParameters.initialMaxStreamDataUni
                : localParameters.initialMaxStreamDataBidiRemote
            // The peer already knows this much: it read our transport
            // parameters.
            stream.receive.announced = stream.receive.limit
            stream.send.limit = unidirectional
                ? 0
                : peerParameters.initialMaxStreamDataBidiLocal
            streams[newID] = stream
            created = stream
            i += 1
        }
        highest = index
        if unidirectional { highestIncomingUni = highest } else { highestIncomingBidi = highest }
        return streams[id] ?? created
    }

    /// Opens a stream this server initiates.
    public func openStream(unidirectional: Bool) -> UInt64? {
        let limit = unidirectional ? peerMaxStreamsUni : peerMaxStreamsBidi
        let next = unidirectional ? nextLocalStreamUni : nextLocalStreamBidi
        if next >= limit { return nil }
        let id = QUICStreamKind.id(index: next, serverInitiated: true,
                                   unidirectional: unidirectional)
        let stream = QUICStream(id: id)
        stream.send.limit = unidirectional
            ? peerParameters.initialMaxStreamDataUni
            : peerParameters.initialMaxStreamDataBidiRemote
        stream.receive.limit = unidirectional
            ? 0
            : localParameters.initialMaxStreamDataBidiLocal
        stream.receive.announced = stream.receive.limit
        streams[id] = stream
        if unidirectional { nextLocalStreamUni += 1 } else { nextLocalStreamBidi += 1 }
        return id
    }

    public func stream(_ id: UInt64) -> QUICStream? { streams[id] }

    /// Says that the layer above has finished with a stream. Until this is
    /// called the transport keeps it whatever state it is in, because only the
    /// caller knows whether it still intends to write.
    public func releaseStream(_ id: UInt64) {
        guard let stream = streams[id] else { return }
        stream.released = true
        if stream.isFinished { retireStream(id) }
    }

    /// Queues bytes on a stream. Flow control is applied when the bytes are
    /// put in a packet, not here: an application that writes a large response
    /// should not have to ask permission a byte at a time.
    public func send(_ id: UInt64, _ p: UnsafePointer<UInt8>, _ n: Int, fin: Bool) {
        guard let stream = streams[id] else { return }
        if stream.send.resetCode != nil { return }
        if n > 0 { stream.send.write(p, n) }
        if fin { stream.send.finQueued = true }
        markWritable(id)
    }

    public func resetStream(_ id: UInt64, code: UInt64) {
        guard let stream = streams[id], stream.send.resetCode == nil else { return }
        stream.send.resetCode = code
        markWritable(id)
    }

    public func stopSending(_ id: UInt64, code: UInt64) {
        guard let stream = streams[id], stream.stopSendingQueued == nil else { return }
        stream.stopSendingQueued = code
        markWritable(id)
    }

    /// Whether the peer will accept unreliable datagrams, which is what
    /// WebTransport needs and what HTTP/3 advertises separately.
    public var peerAllowsDatagrams: Bool { peerParameters.maxDatagramFrameSize > 0 }

    /// The largest datagram payload the peer will take.
    public var maxDatagramPayload: Int {
        let limit = peerParameters.maxDatagramFrameSize
        return limit > 16 ? Int(limit) - 16 : 0
    }

    /// Queues an unreliable datagram (RFC 9221).
    @discardableResult
    public func sendDatagram(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        if peerParameters.maxDatagramFrameSize == 0 { return false }
        if UInt64(n) + 8 > peerParameters.maxDatagramFrameSize { return false }
        outgoingDatagrams.append([UInt8](UnsafeBufferPointer(start: p, count: n)))
        return true
    }

    func markWritable(_ id: UInt64) {
        if writableSet.insert(id).inserted { writable.append(id) }
    }

    /// Grants the peer more room on a stream the application has read from.
    public func extendStreamWindow(_ id: UInt64, consumed: UInt64) {
        guard let stream = streams[id] else { return }
        let limit = stream.receive.limit
        // Only bother when the window has fallen below half, so that a slow
        // reader does not generate a MAX_STREAM_DATA frame per packet.
        let granted = consumed + config.initialMaxStreamData
        if granted > limit && granted - limit > config.initialMaxStreamData / 2 {
            stream.receive.limit = granted
            markWritable(id)
        }
        let connectionGranted = receivedBytes + config.initialMaxData
        if connectionGranted > receiveLimit
            && connectionGranted - receiveLimit > config.initialMaxData / 2 {
            receiveLimit = connectionGranted
            maxDataPending = true
        }
    }

    // MARK: - Handshake progress

    /// Moves whatever TLS produced into the crypto send streams and installs
    /// any keys it derived.
    func applyTLSProgress() -> Bool {
        guard let tls else { return true }
        if let alert = tls.alert {
            Log.debug { line in
                line.str("quic: tls alert ")
                line.int(Int(alert))
            }
            close(quicCryptoError(alert))
            return false
        }
        if tls.initialOut.readableBytes > 0 {
            cryptoSend[QUICLevel.initial.rawValue]
                .write(tls.initialOut.readPointer, tls.initialOut.readableBytes)
            tls.initialOut.clear()
        }
        if tls.handshakeOut.readableBytes > 0 {
            cryptoSend[QUICLevel.handshake.rawValue]
                .write(tls.handshakeOut.readPointer, tls.handshakeOut.readableBytes)
            tls.handshakeOut.clear()
        }
        for secrets in tls.takePendingSecrets() {
            if !installKeys(secrets) {
                close(QUICError.internalError.rawValue)
                return false
            }
        }
        if tls.state == .complete && !handshakeComplete {
            handshakeComplete = true
            handshakeDonePending = true
            selectedALPN = tls.selectedALPN
            serverName = tls.serverName
            peerParameters = tls.peerParameters
            adoptPeerParameters()
            status = .connected
            events.append(QUICEvent(.handshakeComplete))
            // The Handshake keys have done their job the moment the client's
            // Finished has been read.
            discardSpace(.handshake)
        }
        return true
    }

    private func installKeys(_ secrets: TLSServerHandshake.Secrets) -> Bool {
        let level = secrets.level.rawValue
        guard let send = secrets.server.withUnsafeBufferPointer({
                  quicDirection(secret: $0.baseAddress!, secretLen: $0.count,
                                cipher: secrets.cipher, version: version)
              }),
              let receive = secrets.client.withUnsafeBufferPointer({
                  quicDirection(secret: $0.baseAddress!, secretLen: $0.count,
                                cipher: secrets.cipher, version: version)
              })
        else { return false }
        keys[level].destroy()
        keys[level].send = send
        keys[level].receive = receive

        if secrets.level == .application {
            // The next generation is derived now so that a key update costs
            // nothing at the moment it happens.
            nextReceiveKeys = receive.keys.nextGeneration(version: version) ?? QUICKeys()
        }
        return true
    }

    /// Takes the limits out of the peer's transport parameters once they are
    /// authenticated.
    private func adoptPeerParameters() {
        sendLimit = peerParameters.initialMaxData
        peerMaxStreamsBidi = peerParameters.initialMaxStreamsBidi
        peerMaxStreamsUni = peerParameters.initialMaxStreamsUni
        recovery.peerMaxAckDelayMs = peerParameters.maxAckDelayMs
        if peerParameters.maxIdleTimeoutMs > 0 {
            // The connection lives by the shorter of the two claims.
            idleTimeoutMs = localParameters.maxIdleTimeoutMs == 0
                ? peerParameters.maxIdleTimeoutMs
                : min(localParameters.maxIdleTimeoutMs, peerParameters.maxIdleTimeoutMs)
        }
        // Streams opened before the parameters arrived were given a limit of
        // zero; they get the real one now.
        for (id, stream) in streams where QUICStreamKind.isClientInitiated(id) {
            if QUICStreamKind.isBidirectional(id) {
                stream.send.limit = max(stream.send.limit,
                                        peerParameters.initialMaxStreamDataBidiLocal)
            }
        }
    }

    private func discardSpace(_ level: QUICLevel) {
        let index = level.rawValue
        if !keys[index].send.isValid && !keys[index].receive.isValid { return }
        let lost = QUICLossDetection.abandon(space: &spaces[index], recovery: &recovery)
        _ = lost     // nothing at these levels needs sending again once discarded
        keys[index].destroy()
        keys[index] = QUICKeyPair()
        spaces[index].acks.clear()
        spaces[index].ackPending = false
        spaces[index].ackElicitingPending = false
        cryptoSend[index].destroy()
        cryptoSend[index] = QUICSendStream()
        cryptoReceive[index].destroy()
        cryptoReceive[index] = QUICReceiveStream()
    }

    private func commitKeyUpdate(nowMs: UInt64) {
        let level = QUICLevel.application.rawValue
        previousReceiveKeys.destroy()
        previousReceiveKeys = keys[level].receive.keys
        // RFC 9001 section 6.5: the old keys are kept for three round trips,
        // long enough for anything still in flight to arrive.
        previousKeysExpireMs = nowMs + 3 * max(recovery.smoothedRTTMs, 10)
        keys[level].receive.keys = nextReceiveKeys
        nextReceiveKeys = keys[level].receive.keys.nextGeneration(version: version) ?? QUICKeys()

        if let next = keys[level].send.keys.nextGeneration(version: version) {
            var old = keys[level].send.keys
            keys[level].send.keys = next
            old.destroy()
        }
        currentKeyPhase.toggle()
    }

    // MARK: - Acknowledgement bookkeeping

    private func onPacketAcked(_ packet: QUICSentPacket, level: QUICLevel) {
        if let range = packet.frames.crypto {
            cryptoSend[level.rawValue].acknowledge(range.low, range.high)
        }
        for frame in packet.frames.streams {
            guard let stream = streams[frame.id] else { continue }
            let buffered = stream.send.data.readableBytes
            stream.send.acknowledge(frame.low, frame.high)
            if frame.fin { stream.send.finAcked = true }
            // An acknowledgement is what actually frees the send buffer, so it
            // is what a producer waiting for room has to be told about. Flow
            // control alone is not enough: a peer with a large window never
            // sends MAX_STREAM_DATA, and a producer parked on one would wait
            // for a frame that is never coming.
            if stream.send.data.readableBytes < buffered { noteWritable(frame.id) }
            if stream.isFinished { retireStream(frame.id) }
        }
        if packet.frames.handshakeDone { handshakeDonePending = false }
    }

    private func onPacketLost(_ packet: QUICSentPacket, level: QUICLevel) {
        if let range = packet.frames.crypto {
            cryptoSend[level.rawValue].declareLost(range.low, range.high)
        }
        for frame in packet.frames.streams {
            guard let stream = streams[frame.id] else { continue }
            stream.send.declareLost(frame.low, frame.high)
            if frame.fin { stream.send.finSent = false }
            markWritable(frame.id)
        }
        // Control frames carry state, so what is re-sent is the current value
        // rather than the one that was lost.
        if packet.frames.handshakeDone { handshakeDonePending = true }
        if packet.frames.maxData { maxDataPending = true }
        if packet.frames.maxStreamsBidi { maxStreamsBidiPending = true }
        if packet.frames.maxStreamsUni { maxStreamsUniPending = true }
        for id in packet.frames.maxStreamData { markWritable(id) }
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

    func retireStream(_ id: UInt64) {
        guard let stream = streams[id] else { return }
        stream.destroy()
        streams.removeValue(forKey: id)
        writableSet.remove(id)
        // The peer may open another in its place.
        if QUICStreamKind.isClientInitiated(id) {
            if QUICStreamKind.isUnidirectional(id) {
                localMaxStreamsUni += 1
                maxStreamsUniPending = true
            } else {
                localMaxStreamsBidi += 1
                maxStreamsBidiPending = true
            }
        }
    }

    // MARK: - Closing

    public func close(_ code: UInt64, application: Bool = false, reason: [UInt8] = []) {
        if status == .closing || status == .drained { return }
        closeError = code
        closeIsApplication = application
        closeReason = reason
        closeFramePending = true
        status = .closing
        events.append(QUICEvent(.closed, code: code))
    }

    public var isClosed: Bool { status == .drained }

    /// Whether the connection has been silent long enough to give up on.
    public func isIdle(nowMs: UInt64) -> Bool {
        if idleTimeoutMs == 0 { return false }
        // RFC 9000 section 10.1: the timeout is at least three probe timeouts,
        // so a connection is never dropped while a probe could still land.
        let floor = 3 * recovery.ptoMs(includeMaxAckDelay: true)
        return nowMs > lastActivityMs + max(idleTimeoutMs, floor)
    }
}
