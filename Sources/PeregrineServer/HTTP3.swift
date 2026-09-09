//===----------------------------------------------------------------------===//
// HTTP/3 (RFC 9114).
//
// Most of what HTTP/2 needed a framing layer for, QUIC already does. There is
// no stream identifier in a frame, no flow control, no priority, no RST_STREAM
// and no connection-level window: a frame belongs to the stream it arrived on,
// and everything else is the transport's business. What is left is a request
// on a bidirectional stream, headers compressed with QPACK, and a handful of
// unidirectional streams carrying settings and compressor state.
//
// A QUIC connection takes a slot in the same connection table as everything
// else, with no descriptor of its own, and every request stream takes a child
// slot -- exactly as HTTP/2 does. The request head is rebuilt as HTTP/1.1 text
// and re-parsed, so the scope builder, the forwarded-header logic and the
// access log work unchanged. Three protocols, one request path.
//
// The unidirectional streams are the awkward part, because their type is the
// first varint on the stream and a stream can be opened long before anything
// is sent on it. So a peer's unidirectional stream is in one of two states:
// waiting for its type byte, or dispatched to whatever that type turned out to
// be. A type nobody recognises is not an error -- it is how extensions are
// introduced -- and its bytes are dropped rather than parsed.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineQUIC

/// Per-connection HTTP/3 state, on the slot that owns the QUIC connection.
public final class H3Connection {
    public let quic: QUICConnection
    var encoder = QPACKEncoder()
    var decoder = QPACKDecoder()

    /// Our unidirectional streams. `UInt64.max` means not yet opened.
    var controlOut: UInt64 = .max
    var qpackEncoderOut: UInt64 = .max
    var qpackDecoderOut: UInt64 = .max

    /// The peer's, so a second one of any kind can be refused.
    var peerControl: UInt64 = .max
    var peerQpackEncoder: UInt64 = .max
    var peerQpackDecoder: UInt64 = .max

    /// Peer unidirectional streams whose type we know and do not want.
    var ignoredUni: Set<UInt64> = []

    var settingsSeen = false
    var peerMaxFieldSectionSize: UInt64 = 1 << 20
    var peerEnableConnect = false
    var peerDatagrams = false
    var peerWebTransportSessions: UInt64 = 0

    /// Request streams, by QUIC stream identifier.
    var streams: [UInt64: Int32] = [:]
    var goneAway = false

    /// WebTransport sessions, by the identifier of their CONNECT stream.
    var sessions: [UInt64: Int32] = [:]
    /// Which session slot a WebTransport data stream belongs to.
    var wtStreams: [UInt64: Int32] = [:]
    /// Streams that named a session whose CONNECT has not arrived yet.
    var wtOrphans: [UInt64: [(UInt64, Bool)]] = [:]

    init(quic: QUICConnection) {
        self.quic = quic
    }

    func destroy() {
        decoder.destroy()
    }
}

/// How many WebTransport sessions one connection may run at once. Each one
/// costs a slot and an application task, so this is a limit on the client
/// rather than a capability.
let wtMaxSessions = 16

/// What `beginH3Request` reports when the request ran to completion before it
/// returned, which only a synchronous application can do.
let h3RequestFinished = -2

extension Worker {
    // MARK: - Connection set-up

    mutating func beginHTTP3(_ connection: QUICConnection) {
        if connection.applicationSlot >= 0 { return }
        // Only h3 gets an HTTP/3 connection. Anything else negotiated is a
        // protocol we do not speak, and the transport says so.
        if connection.selectedALPN != Array("h3".utf8) {
            connection.close(HTTP3Error.generalProtocolError, application: true)
            return
        }

        let slot = table.allocate()
        if slot < 0 {
            connection.close(HTTP3Error.excessiveLoad, application: true)
            return
        }
        let c = table[slot]
        c.pointee.fd = -1
        c.pointee.parentSlot = -1
        c.pointee.state = .http3
        c.pointee.interest = 0
        c.pointee.flags = []
        c.pointee.lastActivity = pg_monotonic_ms()
        let h3 = H3Connection(quic: connection)
        c.pointee.h3 = h3
        c.pointee.quicRef = connection
        connection.applicationSlot = Int32(slot)

        // The peer's address, resolved once and reused by every request on
        // this connection.
        var host = [CChar](repeating: 0, count: 64)
        var port: UInt16 = 0
        var peer = connection.peerAddress
        _ = host.withUnsafeMutableBufferPointer {
            pg_udp_addr_text(&peer, $0.baseAddress, 64, &port)
        }
        host.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var n = 0
            while n < 64 && base[n] != 0 { n += 1 }
            base.withMemoryRebound(to: UInt8.self, capacity: n) { bytes in
                c.pointee.remoteAddrObj = pg_str_utf8(UnsafeRawPointer(bytes)
                    .assumingMemoryBound(to: CChar.self), pg_ssize_t(n))
            }
        }
        c.pointee.remotePortObj = pg_int(Int(port))

        openH3ControlStreams(slot, h3)
        flushQUIC(slot)
    }

    private mutating func openH3ControlStreams(_ slot: Int, _ h3: H3Connection) {
        guard let control = h3.quic.openStream(unidirectional: true) else {
            h3.quic.close(HTTP3Error.streamCreationError, application: true)
            return
        }
        h3.controlOut = control

        var settings = ByteBuffer(capacity: 64)
        defer { settings.destroy() }
        settings.writeVarint(HTTP3StreamType.control)
        settings.writeVarint(HTTP3FrameType.settings)

        var body = ByteBuffer(capacity: 64)
        defer { body.destroy() }
        // A dynamic table capacity of zero is a promise as much as a limit: it
        // says no header block on this connection can ever wait for another
        // stream, which is the head-of-line blocking HTTP/3 exists to remove.
        body.writeVarint(HTTP3Setting.qpackMaxTableCapacity)
        body.writeVarint(0)
        body.writeVarint(HTTP3Setting.qpackBlockedStreams)
        body.writeVarint(0)
        body.writeVarint(HTTP3Setting.maxFieldSectionSize)
        body.writeVarint(UInt64(config.maxHeadSize))
        // Extended CONNECT, which is what carries WebTransport.
        body.writeVarint(HTTP3Setting.enableConnectProtocol)
        body.writeVarint(1)
        if h3.quic.peerAllowsDatagrams {
            body.writeVarint(HTTP3Setting.h3Datagram)
            body.writeVarint(1)
            // Offered only alongside datagrams. A WebTransport session whose
            // datagrams cannot be carried is a session that works differently
            // from the one the client asked for, and saying so up front is
            // better than discovering it a message in.
            body.writeVarint(HTTP3Setting.webTransportMaxSessions)
            body.writeVarint(UInt64(wtMaxSessions))
        }
        settings.writeVarint(UInt64(body.readableBytes))
        settings.write(UnsafePointer(body.readPointer), body.readableBytes)
        h3.quic.send(control, UnsafePointer(settings.readPointer), settings.readableBytes,
                     fin: false)

        // The QPACK streams carry no instructions from us -- nothing is ever
        // inserted -- but a peer is entitled to expect them to exist.
        if let encoderStream = h3.quic.openStream(unidirectional: true) {
            h3.qpackEncoderOut = encoderStream
            var head = ByteBuffer(capacity: 8)
            head.writeVarint(HTTP3StreamType.qpackEncoder)
            h3.quic.send(encoderStream, UnsafePointer(head.readPointer),
                         head.readableBytes, fin: false)
            head.destroy()
        }
        if let decoderStream = h3.quic.openStream(unidirectional: true) {
            h3.qpackDecoderOut = decoderStream
            var head = ByteBuffer(capacity: 8)
            head.writeVarint(HTTP3StreamType.qpackDecoder)
            h3.quic.send(decoderStream, UnsafePointer(head.readPointer),
                         head.readableBytes, fin: false)
            head.destroy()
        }
    }

    // MARK: - Stream dispatch

    mutating func http3StreamReadable(_ connection: QUICConnection, streamID: UInt64) {
        let slot = Int(connection.applicationSlot)
        guard slot >= 0, table[slot].pointee.state == .http3,
              let h3 = table[slot].pointee.h3 else { return }
        table[slot].pointee.lastActivity = pg_monotonic_ms()

        // A stream that belongs to a WebTransport session is not HTTP/3 at
        // all past its prefix: no frames, no QPACK, just bytes.
        if let sessionSlot = h3.wtStreams[streamID].map(Int.init) {
            wtStreamReadable(sessionSlot, h3, streamID)
            flushQUIC(slot)
            return
        }

        if QUICStreamKind.isUnidirectional(streamID) {
            if QUICStreamKind.isServerInitiated(streamID) { return }
            readPeerUnidirectional(slot, h3, streamID)
        } else {
            readRequestStream(slot, h3, streamID)
        }
        flushQUIC(slot)
    }

    mutating func http3StreamAborted(_ connection: QUICConnection, streamID: UInt64,
                                     code: UInt64) {
        let slot = Int(connection.applicationSlot)
        guard slot >= 0, let h3 = table[slot].pointee.h3 else { return }
        if let sessionSlot = h3.wtStreams[streamID].map(Int.init) {
            wtStreamAborted(sessionSlot, h3, streamID)
            flushQUIC(slot)
            return
        }
        if let sessionSlot = h3.sessions[streamID].map(Int.init) {
            // The CONNECT stream is the session. Losing it loses the session.
            endWebTransportSession(sessionSlot, clean: false)
            flushQUIC(slot)
            return
        }
        if streamID == h3.peerControl {
            // The control stream is the connection: losing it loses the
            // connection with it.
            h3.quic.close(HTTP3Error.closedCriticalStream, application: true)
            return
        }
        guard let streamSlot = h3.streams[streamID].map(Int.init) else { return }
        // The application finds out the way it finds out about any hang-up.
        table[streamSlot].pointee.flags.insert(.disconnected)
        closeH3Stream(streamSlot)
        flushQUIC(slot)
    }

    mutating func http3StreamWritable(_ connection: QUICConnection, streamID: UInt64) {
        let slot = Int(connection.applicationSlot)
        guard slot >= 0, let h3 = table[slot].pointee.h3 else { return }
        if let sessionSlot = h3.wtStreams[streamID].map(Int.init) {
            wtStreamWritable(sessionSlot)
            flushQUIC(slot)
            return
        }
        if let streamSlot = h3.streams[streamID].map(Int.init) {
            if table[streamSlot].pointee.wt != nil {
                resumeWriterIfDrained(streamSlot)
            } else {
                _ = flushH3Stream(streamSlot)
                resumeWriterIfDrained(streamSlot)
            }
        }
        flushQUIC(slot)
    }

    mutating func http3Datagrams(_ connection: QUICConnection) {
        let slot = Int(connection.applicationSlot)
        guard slot >= 0, let h3 = table[slot].pointee.h3 else {
            connection.incomingDatagrams.removeAll(keepingCapacity: true)
            return
        }
        // Datagrams belong to WebTransport sessions; one that names no live
        // session has nowhere to go, and dropping it is what unreliable means.
        let arrived = connection.incomingDatagrams
        connection.incomingDatagrams.removeAll(keepingCapacity: true)
        for payload in arrived {
            wtDatagram(slot, h3, payload)
        }
        flushQUIC(slot)
    }

    // MARK: - Unidirectional streams

    private mutating func readPeerUnidirectional(_ slot: Int, _ h3: H3Connection,
                                                 _ streamID: UInt64) {
        guard let stream = h3.quic.stream(streamID) else { return }
        if h3.ignoredUni.contains(streamID) {
            stream.receive.ready.clear()
            return
        }

        if !isKnownUni(h3, streamID) {
            // First bytes on this stream: read its type. Nothing is consumed
            // until the whole prefix is there, so a type split across packets
            // simply waits rather than needing to be remembered.
            let available = stream.receive.ready.readableBytes
            if available == 0 { return }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint() else {
                // A varint is at most eight bytes; more than that and it is
                // not one.
                if available >= 8 {
                    h3.quic.close(HTTP3Error.generalProtocolError, application: true)
                }
                return
            }
            if type == HTTP3StreamType.webTransport {
                // The session identifier follows the type, and the two
                // together are the whole prefix.
                guard let sessionID = r.varint() else {
                    if available >= 16 {
                        h3.quic.close(HTTP3Error.generalProtocolError, application: true)
                    }
                    return
                }
                stream.receive.ready.consume(r.offset)
                _ = adoptWebTransportStream(slot, h3, streamID, sessionID: sessionID,
                                            bidirectional: false)
                return
            }
            stream.receive.ready.consume(r.offset)
            if !adoptUnidirectional(slot, h3, streamID, type: type) { return }
        }

        if streamID == h3.peerControl {
            readControlStream(slot, h3, stream)
        } else if streamID == h3.peerQpackEncoder {
            // With a table capacity of zero the peer has nothing legitimate to
            // say here, and saying it anyway is an error rather than noise.
            if stream.receive.ready.readableBytes > 0 {
                h3.quic.close(HTTP3Error.qpackEncoderStreamError, application: true)
            }
        } else if streamID == h3.peerQpackDecoder {
            // Acknowledgements for a table we never fill: nothing to do.
            stream.receive.ready.clear()
        }
    }

    private func isKnownUni(_ h3: H3Connection, _ streamID: UInt64) -> Bool {
        streamID == h3.peerControl || streamID == h3.peerQpackEncoder
            || streamID == h3.peerQpackDecoder
    }

    /// Returns false when the connection has been closed.
    private mutating func adoptUnidirectional(_ slot: Int, _ h3: H3Connection,
                                              _ streamID: UInt64, type: UInt64) -> Bool {
        switch type {
        case HTTP3StreamType.control:
            if h3.peerControl != .max {
                h3.quic.close(HTTP3Error.streamCreationError, application: true)
                return false
            }
            h3.peerControl = streamID
        case HTTP3StreamType.qpackEncoder:
            if h3.peerQpackEncoder != .max {
                h3.quic.close(HTTP3Error.streamCreationError, application: true)
                return false
            }
            h3.peerQpackEncoder = streamID
        case HTTP3StreamType.qpackDecoder:
            if h3.peerQpackDecoder != .max {
                h3.quic.close(HTTP3Error.streamCreationError, application: true)
                return false
            }
            h3.peerQpackDecoder = streamID
        case HTTP3StreamType.push:
            // Only a server pushes, so a client push stream is nonsense.
            h3.quic.close(HTTP3Error.streamCreationError, application: true)
            return false
        default:
            // Unknown stream types are how extensions arrive. The peer is told
            // we are not interested rather than left waiting.
            h3.ignoredUni.insert(streamID)
            h3.quic.stopSending(streamID, code: HTTP3Error.noError)
            if let stream = h3.quic.stream(streamID) { stream.receive.ready.clear() }
        }
        return true
    }

    private mutating func readControlStream(_ slot: Int, _ h3: H3Connection,
                                            _ stream: QUICStream) {
        while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else { break }
            if r.remaining < length { break }
            let header = r.offset
            let payload = base + header

            if !h3.settingsSeen && type != HTTP3FrameType.settings {
                h3.quic.close(HTTP3Error.missingSettings, application: true)
                return
            }
            switch type {
            case HTTP3FrameType.settings:
                if h3.settingsSeen {
                    h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                    return
                }
                if !applyH3Settings(h3, payload, length) { return }
                h3.settingsSeen = true
            case HTTP3FrameType.goaway:
                h3.goneAway = true
            case HTTP3FrameType.maxPushID, HTTP3FrameType.cancelPush:
                break                       // this server never pushes
            case HTTP3FrameType.data, HTTP3FrameType.headers:
                // These belong on a request stream and nowhere else.
                h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                return
            default:
                if HTTP3FrameType.isReservedFromHTTP2(type) {
                    h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                    return
                }
            }
            stream.receive.ready.consume(header + length)
        }
        if stream.receive.finished {
            h3.quic.close(HTTP3Error.closedCriticalStream, application: true)
        }
    }

    private mutating func applyH3Settings(_ h3: H3Connection,
                                          _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var r = QUICReader(p, n)
        while !r.isEmpty {
            guard let id = r.varint(), let value = r.varint() else {
                h3.quic.close(HTTP3Error.settingsError, application: true)
                return false
            }
            if HTTP3Setting.isReservedFromHTTP2(id) {
                h3.quic.close(HTTP3Error.settingsError, application: true)
                return false
            }
            switch id {
            case HTTP3Setting.maxFieldSectionSize:
                h3.peerMaxFieldSectionSize = value
            case HTTP3Setting.enableConnectProtocol:
                if value > 1 {
                    h3.quic.close(HTTP3Error.settingsError, application: true)
                    return false
                }
                h3.peerEnableConnect = value == 1
            case HTTP3Setting.h3Datagram:
                if value > 1 {
                    h3.quic.close(HTTP3Error.settingsError, application: true)
                    return false
                }
                h3.peerDatagrams = value == 1
            case HTTP3Setting.webTransportMaxSessions:
                h3.peerWebTransportSessions = value
            default:
                break                       // unknown settings are ignorable
            }
        }
        return true
    }

    // MARK: - Request streams

    private mutating func readRequestStream(_ slot: Int, _ h3: H3Connection,
                                            _ streamID: UInt64) {
        guard let stream = h3.quic.stream(streamID) else { return }
        // A request before the peer's SETTINGS is not fatal on its own -- the
        // control stream may simply be behind -- but a request stream that
        // finishes without one is.
        var streamSlot = h3.streams[streamID].map(Int.init) ?? -1

        // An accepted extended CONNECT stops carrying frames the moment it
        // becomes a session: from there it is capsules.
        if streamSlot >= 0, table[streamSlot].pointee.wt != nil {
            readWTCapsules(streamSlot, h3, stream)
            if table[streamSlot].pointee.state != .free {
                h3.quic.extendStreamWindow(streamID, consumed: stream.receive.received)
            }
            return
        }

        // A bidirectional stream that opens with WEBTRANSPORT_STREAM is not a
        // request. Nothing is consumed until both varints are there.
        if streamSlot < 0 {
            let available = stream.receive.ready.readableBytes
            if available == 0 { return }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            if let type = r.varint(), type == HTTP3FrameType.webTransportStream {
                guard let sessionID = r.varint() else {
                    if available >= 16 {
                        h3.quic.close(HTTP3Error.frameError, application: true)
                    }
                    return
                }
                stream.receive.ready.consume(r.offset)
                _ = adoptWebTransportStream(slot, h3, streamID, sessionID: sessionID,
                                            bidirectional: true)
                return
            }
        }

        while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            let s = streamSlot >= 0 ? table[streamSlot] : nil

            // Mid-frame: DATA continues into whatever arrived.
            if let s, s.pointee.h3FrameRemaining > 0 {
                let take = min(s.pointee.h3FrameRemaining, available)
                if s.pointee.h3FrameType == HTTP3FrameType.data {
                    if !appendH3Body(streamSlot, stream.receive.ready.readPointer, take) {
                        return
                    }
                }
                stream.receive.ready.consume(take)
                s.pointee.h3FrameRemaining -= take
                continue
            }

            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else {
                if available >= 16 {
                    h3.quic.close(HTTP3Error.frameError, application: true)
                    return
                }
                break
            }
            let header = r.offset

            if HTTP3FrameType.isReservedFromHTTP2(type) {
                h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                return
            }

            switch type {
            case HTTP3FrameType.headers:
                // A header block is decoded whole: QPACK has no way to resume.
                if available - header < length { return }
                if streamSlot < 0 {
                    let outcome = beginH3Request(slot, h3, streamID,
                                                 base + header, length)
                    // Consumed whatever became of the request. A synchronous
                    // application runs to completion inside `dispatch` and can
                    // have answered and closed the stream before this line is
                    // reached; leaving its own request bytes in the buffer
                    // would start it a second time.
                    stream.receive.ready.consume(header + length)
                    if outcome == h3RequestFinished {
                        // Anything still buffered belongs to a request that is
                        // over, and the peer has been told to stop sending.
                        stream.receive.ready.clear()
                        return
                    }
                    if outcome < 0 { return }
                    streamSlot = outcome
                    continue
                } else {
                    // Trailers. Nothing downstream wants them, but they still
                    // have to be well-formed.
                    var ok = true
                    do {
                        try h3.decoder.decode(base + header, length) { _ in }
                    } catch {
                        ok = false
                    }
                    if !ok {
                        h3.quic.close(HTTP3Error.qpackDecompressionFailed, application: true)
                        return
                    }
                }
                stream.receive.ready.consume(header + length)

            case HTTP3FrameType.data:
                if streamSlot < 0 {
                    h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                    return
                }
                stream.receive.ready.consume(header)
                table[streamSlot].pointee.h3FrameType = type
                table[streamSlot].pointee.h3FrameRemaining = length

            case HTTP3FrameType.settings, HTTP3FrameType.goaway,
                 HTTP3FrameType.maxPushID, HTTP3FrameType.cancelPush:
                h3.quic.close(HTTP3Error.frameUnexpected, application: true)
                return

            default:
                // Unknown frame types are skipped, which is what makes new
                // frames deployable.
                if available - header < length {
                    if streamSlot >= 0 {
                        stream.receive.ready.consume(header)
                        table[streamSlot].pointee.h3FrameType = type
                        table[streamSlot].pointee.h3FrameRemaining = length
                    }
                    return
                }
                stream.receive.ready.consume(header + length)
            }
        }

        if stream.receive.finished && streamSlot >= 0 {
            let s = table[streamSlot]
            if s.pointee.h3FrameRemaining > 0 {
                h3.quic.close(HTTP3Error.frameError, application: true)
                return
            }
            s.pointee.bodyRemaining = 0
            // RFC 9114 section 4.1.2: a body that disagrees with the length it
            // declared is malformed.
            if s.pointee.head.flags.contains(.hasContentLength)
                && s.pointee.head.contentLength != s.pointee.bodyReceived {
                closeH3Stream(streamSlot)
                h3.quic.resetStream(streamID, code: HTTP3Error.messageError)
                return
            }
            onBodyProgress(streamSlot)
        } else if streamSlot >= 0 {
            onBodyProgress(streamSlot)
        }
        // Reading is what opens the window again.
        if streamSlot >= 0 {
            h3.quic.extendStreamWindow(streamID, consumed: stream.receive.received)
        }
    }

    private mutating func appendH3Body(_ streamSlot: Int,
                                       _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let s = table[streamSlot]
        s.pointee.bodyReceived += n
        if s.pointee.head.flags.contains(.hasContentLength)
            && s.pointee.bodyReceived > s.pointee.head.contentLength {
            let parent = Int(s.pointee.parentSlot)
            if parent >= 0, let h3 = table[parent].pointee.h3 {
                h3.quic.resetStream(s.pointee.qstreamID, code: HTTP3Error.messageError)
            }
            closeH3Stream(streamSlot)
            return false
        }
        if s.pointee.state == .closing {
            // The response finished early. The bytes are dropped, but they are
            // still counted and still checked.
            return true
        }
        if s.pointee.body.readableBytes + n > config.maxBodySize {
            failRequest(streamSlot, status: 413)
            return false
        }
        s.pointee.body.write(p, n)
        return true
    }

    /// Opens a request stream's slot and rebuilds its head. Returns -1 when the
    /// request could not be started.
    private mutating func beginH3Request(_ slot: Int, _ h3: H3Connection,
                                         _ streamID: UInt64,
                                         _ block: UnsafePointer<UInt8>,
                                         _ length: Int) -> Int {
        if h3.goneAway { return -1 }
        let streamSlot = openH3Stream(parent: slot, h3, streamID: streamID)
        if streamSlot < 0 {
            h3.quic.resetStream(streamID, code: HTTP3Error.requestRejected)
            h3.quic.stopSending(streamID, code: HTTP3Error.requestRejected)
            return -1
        }
        switch buildH3RequestHead(streamSlot, h3, block, length) {
        case .compression:
            closeH3Stream(streamSlot)
            h3.quic.close(HTTP3Error.qpackDecompressionFailed, application: true)
            return -1
        case .malformed:
            closeH3Stream(streamSlot)
            h3.quic.resetStream(streamID, code: HTTP3Error.messageError)
            h3.quic.stopSending(streamID, code: HTTP3Error.messageError)
            return -1
        case .ok:
            break
        }

        let s = table[streamSlot]
        s.pointee.bodyRemaining = -1
        // As on HTTP/2: ASGI starts on the head, WSGI waits for the whole
        // body, because it is called once and cannot be handed the rest
        // afterwards. The frame loop reads the DATA frames that follow and
        // the end of the stream is what dispatches it.
        if appProtocol == .wsgi {
            s.pointee.state = .readingBody
            return streamSlot
        }
        s.pointee.state = .dispatching
        dispatch(streamSlot)
        // A WSGI application called inline answers and finishes before this
        // returns, taking its stream slot with it. That is a completed
        // request, not a failed one, and the caller has to be able to tell
        // the difference.
        if let live = h3.streams[streamID] { return Int(live) }
        return h3RequestFinished
    }

    mutating func openH3Stream(parent: Int, _ h3: H3Connection, streamID: UInt64) -> Int {
        let slot = table.allocate()
        if slot < 0 { return -1 }
        let p = table[parent]
        let s = table[slot]
        s.pointee.fd = -1
        s.pointee.parentSlot = Int32(parent)
        s.pointee.qstreamID = streamID
        s.pointee.streamID = 0
        s.pointee.state = .readingBody
        s.pointee.interest = 0
        s.pointee.flags = p.pointee.flags.intersection([.trustEvaluated, .trustedPeer])
        s.pointee.flags.insert(.keepAlive)
        s.pointee.flags.insert(.http3Stream)
        s.pointee.read = ByteBuffer()
        s.pointee.write = ByteBuffer()
        s.pointee.body = ByteBuffer()
        s.pointee.headStore.clear()
        s.pointee.head = HTTPRequestHead()
        s.pointee.headInStore = true
        s.pointee.headOrigin = 0
        s.pointee.chunked = ChunkedDecoder()
        s.pointee.bodyRemaining = -1
        s.pointee.bodyReceived = 0
        s.pointee.requestCount = 1
        s.pointee.lastActivity = pg_monotonic_ms()
        s.pointee.task = nil
        s.pointee.pendingReceive = nil
        s.pointee.sendCallable = nil
        s.pointee.receiveCallable = nil
        s.pointee.drainWaiter = nil
        s.pointee.poolJob = nil
        s.pointee.h2 = nil
        s.pointee.h3 = nil
        s.pointee.quicRef = nil
        s.pointee.wt = nil
        s.pointee.responseRemaining = -1
        s.pointee.h3FrameType = 0
        s.pointee.h3FrameRemaining = 0
        s.pointee.clientTuple = nil
        if let a = p.pointee.remoteAddrObj { pg_incref(a); s.pointee.remoteAddrObj = a }
        if let port = p.pointee.remotePortObj { pg_incref(port); s.pointee.remotePortObj = port }
        h3.streams[streamID] = Int32(slot)
        return slot
    }

    enum H3HeaderOutcome { case ok, malformed, compression }

    /// Rebuilds the request as HTTP/1.1 text and parses it, so that everything
    /// downstream is the same code HTTP/1 and HTTP/2 already use.
    mutating func buildH3RequestHead(_ streamSlot: Int, _ h3: H3Connection,
                                     _ block: UnsafePointer<UInt8>,
                                     _ length: Int) -> H3HeaderOutcome {
        let s = table[streamSlot]
        var pseudo = ByteBuffer()
        defer { pseudo.destroy() }
        var fields = ByteBuffer()
        defer { fields.destroy() }

        var methodAt = (0, 0), pathAt = (0, 0), schemeAt = (0, 0), authorityAt = (0, 0)
        var protocolAt = (0, 0)
        var sawMethod = false, sawPath = false, sawScheme = false
        var sawAuthority = false, sawProtocol = false
        var sawRegular = false
        var malformed = false

        func stash(_ span: HPACKSpan) -> (Int, Int) {
            let at = pseudo.readableBytes
            pseudo.write(span.value, span.valueLength)
            return (at, span.valueLength)
        }

        var failed = false
        do {
            try h3.decoder.decode(block, length) { span in
                if malformed { return }
                if span.nameLength > 0 && span.name[0] == 0x3A {        // ':'
                    if sawRegular { malformed = true; return }
                    if !HTTP2.validFieldValue(span.value, span.valueLength) {
                        malformed = true; return
                    }
                    if equalsExact(span.name, span.nameLength, ":method") {
                        if sawMethod { malformed = true; return }
                        sawMethod = true; methodAt = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":path") {
                        if sawPath { malformed = true; return }
                        sawPath = true; pathAt = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":scheme") {
                        if sawScheme { malformed = true; return }
                        sawScheme = true; schemeAt = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":authority") {
                        if sawAuthority { malformed = true; return }
                        sawAuthority = true; authorityAt = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":protocol") {
                        if sawProtocol { malformed = true; return }
                        sawProtocol = true; protocolAt = stash(span)
                    } else {
                        malformed = true
                    }
                    return
                }
                sawRegular = true
                if !HTTP2.validFieldName(span.name, span.nameLength)
                    || !HTTP2.validFieldValue(span.value, span.valueLength) {
                    malformed = true; return
                }
                if HTTP2.isConnectionSpecific(span.name, span.nameLength) {
                    if !(span.nameLength == 2
                         && equalsLowercased(span.value, span.valueLength, "trailers")) {
                        malformed = true; return
                    }
                }
                fields.write(span.name, span.nameLength)
                fields.write(": ")
                fields.write(span.value, span.valueLength)
                fields.writeCRLF()
            }
        } catch {
            failed = true
        }
        if failed { return .compression }
        if malformed { return .malformed }
        if !sawMethod || methodAt.1 == 0 { return .malformed }

        let base0 = UnsafePointer(pseudo.pointer(at: 0))
        let isConnect = equalsExact(base0 + methodAt.0, methodAt.1, "CONNECT")
        if isConnect {
            // Extended CONNECT carries :protocol, :scheme and :path; the plain
            // form carries none of them and has nothing to route to.
            if !sawProtocol || !sawScheme || !sawPath { return .malformed }
            if !sawAuthority { return .malformed }
        } else {
            if sawProtocol { return .malformed }
            if !sawScheme || !sawPath || pathAt.1 == 0 { return .malformed }
        }

        var head = ByteBuffer()
        defer { head.destroy() }
        head.write(base0 + methodAt.0, methodAt.1)
        head.writeByte(cSP)
        head.write(base0 + pathAt.0, pathAt.1)
        head.write(" HTTP/1.1\r\n")
        if sawAuthority && authorityAt.1 > 0 {
            head.write("host: ")
            head.write(base0 + authorityAt.0, authorityAt.1)
            head.writeCRLF()
        }
        if fields.readableBytes > 0 {
            head.write(UnsafePointer(fields.readPointer), fields.readableBytes)
        }
        head.writeCRLF()

        s.pointee.headStore.clear()
        s.pointee.headStore.write(UnsafePointer(head.readPointer), head.readableBytes)
        s.pointee.headInStore = true
        s.pointee.headOrigin = 0

        var parsed = HTTPRequestHead()
        let parseBase = UnsafePointer(s.pointee.headStore.pointer(at: 0))
        let result = HTTPParser.parse(parseBase, s.pointee.headStore.readableBytes,
                                      maxHeadSize: config.maxHeadSize,
                                      maxHeaders: config.maxHeaders,
                                      headers: headers,
                                      head: &parsed)
        guard case .complete = result else { return .malformed }
        parsed.httpMajor = 3
        if parsed.flags.contains(.chunked) { return .malformed }
        s.pointee.head = parsed
        if parsed.method == .head { s.pointee.flags.insert(.suppressBody) }
        s.pointee.h2Scheme = equalsLowercased(base0 + schemeAt.0, schemeAt.1, "https")
        if sawProtocol {
            s.pointee.h3Protocol = ByteBuffer()
            s.pointee.h3Protocol.write(base0 + protocolAt.0, protocolAt.1)
        }
        return .ok
    }

    // MARK: - Tear-down

    mutating func closeH3Stream(_ streamSlot: Int) {
        // Everything a stream slot needs on the way out is in
        // `closeConnection`, including the one thing this used to skip by
        // cutting the parent link first: telling the transport the stream has
        // been released. Until it is told, the QUIC stream is never retired,
        // and a stream concurrency limit is a budget that is never given
        // back -- the connection serves exactly `initial_max_streams_bidi`
        // requests and then stalls, the next one waiting on credit that
        // cannot arrive.
        let parent = Int(table[streamSlot].pointee.parentSlot)
        closeConnection(streamSlot)
        // Retiring a stream queues MAX_STREAMS, and it has to go out now. The
        // peer is one stream closer to its limit and may already be at it, so
        // there is no packet of its own to carry the credit back on.
        if parent >= 0, table[parent].pointee.state == .http3 { flushQUIC(parent) }
    }

    mutating func releaseQUICConnection(_ connection: QUICConnection) {
        let slot = Int(connection.applicationSlot)
        connection.applicationSlot = -1
        guard slot >= 0, table[slot].pointee.state == .http3 else { return }
        closeConnection(slot)
    }

    /// Pushes whatever the connection now has to send.
    mutating func flushQUIC(_ slot: Int) {
        guard let connection = table[slot].pointee.quicRef, let quic else { return }
        quic.flushOne(connection, nowMs: pg_monotonic_ms())
    }
}
