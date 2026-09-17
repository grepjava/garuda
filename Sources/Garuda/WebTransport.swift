//===----------------------------------------------------------------------===//
// WebTransport over HTTP/3 (draft-ietf-webtrans-http3): the engine side.
//
// A WebTransport session is an extended CONNECT request that never finishes.
// The client sends CONNECT with `:protocol: webtransport`, the server answers
// 200, and from then on the request stream is not a request at all: it carries
// capsules (RFC 9297), and the session's real traffic arrives on other QUIC
// streams and in QUIC datagrams that name the session by the identifier of the
// CONNECT stream they belong to.
//
// So a session is a router, not a connection:
//
//   * a peer unidirectional stream whose type is 0x54, followed by a session
//     identifier, belongs to that session;
//   * a peer bidirectional stream whose first varint is 0x41, followed by a
//     session identifier, likewise -- and because a request stream begins with
//     a frame type instead, the two are told apart by the first varint alone;
//   * a datagram begins with the session's *quarter* stream identifier, which
//     is how RFC 9297 fits a 62-bit stream id into as few bytes as possible.
//
// Session streams do not get slots in the connection table. A slot carries a
// request head, a body buffer and a parser, and a WebTransport stream wants
// none of that: it is a byte pipe. Its bytes stay in the QUIC receive buffer
// until the handler reads them, which is what makes a slow reader
// backpressure -- the stream's window does not reopen -- rather than an
// unbounded buffer, and what keeps one unread stream from stalling the rest.
//
// The handler waits on the worker for what it asks for: a stream, bytes, room
// to write, a datagram. Each wait is a continuation on the session or stream,
// resumed from here when the frame loop delivers what it was waiting for, or
// when the session ends. The handler's API is in WebTransportAPI.swift.
//
// scripts/webtransport-test.py checks the routing, capsules and closing
// against aioquic.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP
import AvianQUIC

/// One stream belonging to a session.
final class WTStream {
    let id: UInt64
    let bidirectional: Bool
    /// The handler may still write: false for a peer's unidirectional stream,
    /// and once finished, reset, or stopped by the peer.
    var writable: Bool
    var finSent = false
    /// The peer reset its direction or asked us to stop sending.
    var aborted = false
    /// The handler has been told the stream's read side ended.
    var readEnded: Bool
    var readWaiter: UnsafeContinuation<Void, Never>? = nil
    var writeWaiter: UnsafeContinuation<Void, Never>? = nil

    init(id: UInt64, bidirectional: Bool, writable: Bool, readable: Bool) {
        self.id = id
        self.bidirectional = bidirectional
        self.writable = writable
        readEnded = !readable
    }

    func wake() {
        readWaiter.take()?.resume()
        writeWaiter.take()?.resume()
    }
}

/// A WebTransport session, on the slot its CONNECT stream owns.
final class WTSession {
    /// The identifier of the CONNECT stream, which is also the session's.
    let sessionID: UInt64
    /// The session has ended, by either side or with the connection. Every
    /// wait on it ends, and nothing more is sent.
    var gone = false
    var closeSent = false
    var closeCode: UInt32 = 0
    var closeReason: [UInt8] = []

    var streams: [UInt64: WTStream] = [:]
    /// Streams the peer opened that the handler has not accepted yet.
    var incoming: [UInt64] = []
    var acceptWaiter: UnsafeContinuation<Void, Never>? = nil
    /// Datagrams are unreliable by definition, so the queue is bounded and
    /// drops the oldest rather than growing or applying backpressure.
    var datagrams: [[UInt8]] = []
    var datagramBytes = 0
    var datagramWaiter: UnsafeContinuation<Void, Never>? = nil

    init(sessionID: UInt64) {
        self.sessionID = sessionID
    }

    func wakeAll() {
        acceptWaiter.take()?.resume()
        datagramWaiter.take()?.resume()
        for stream in streams.values { stream.wake() }
    }
}

/// The most datagrams one session will hold for a handler that is not
/// reading them, and the most bytes those may total.
let wtMaxQueuedDatagrams = 64
let wtMaxQueuedDatagramBytes = 256 * 1024
/// Streams that named a session we have not seen yet, held while the CONNECT
/// they belong to catches up. Reordering across QUIC streams is ordinary.
let wtMaxOrphanStreams = 32
/// The longest close reason the draft allows.
let wtMaxCloseReason = 1024

extension Worker {

    // MARK: - Establishing a session

    /// Whether the request on `slot` asks for a WebTransport session.
    func isWebTransportRequest(_ slot: Int) -> Bool {
        let c = table[slot]
        let p = c.pointee.connectProtocol
        return c.pointee.isH3Stream && p.readableBytes == 12
            && equalsExact(UnsafePointer(p.readPointer), 12, "webtransport")
    }

    /// Answers the CONNECT on `slot` with 200, which is what establishes the
    /// session, and returns it. Nil, with the request already answered or
    /// gone, when there is no connection left or it has no room for another.
    mutating func acceptWebTransport(_ slot: Int) -> WTSession? {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard c.pointee.state == .dispatching, !c.pointee.flags.contains(.responseStarted),
              parent >= 0, let h3 = table[parent].pointee.h3 else { return nil }
        if h3.sessions.count >= wtMaxSessions {
            respond(slot, status: 503, nil, 0)
            return nil
        }

        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(200, into: &block)
        encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        encodeStaticH3(h3, "server", "garuda", into: &block)
        // What middleware added -- a request ID, a header of the application's
        // -- goes out with the answer, as it would on any other response.
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            let kind = HTTPResponseWriter.classify(name)
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            h3.encoder.encode(name: name.base, nameLength: name.count,
                              value: value.count > 0 ? value.base : emptyH3Byte,
                              valueLength: value.count, into: &block)
        }
        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)
        c.pointee.flags.insert(.webtransportMode)
        logAccess(slot, status: 200)

        let session = WTSession(sessionID: c.pointee.qstreamID)
        c.pointee.wt = session
        h3.sessions[session.sessionID] = Int32(slot)
        if let waiting = h3.wtOrphans.removeValue(forKey: session.sessionID) {
            for (streamID, bidirectional) in waiting where h3.quic.stream(streamID) != nil {
                addPeerStream(slot, h3, session, streamID, bidirectional: bidirectional)
            }
        }
        flushQUIC(parent)
        return session
    }

    private func addPeerStream(_ sessionSlot: Int, _ h3: H3Connection, _ session: WTSession,
                               _ streamID: UInt64, bidirectional: Bool) {
        session.streams[streamID] = WTStream(id: streamID, bidirectional: bidirectional,
                                             writable: bidirectional, readable: true)
        h3.wtStreams[streamID] = Int32(sessionSlot)
        session.incoming.append(streamID)
        session.acceptWaiter.take()?.resume()
    }

    // MARK: - Routing streams into a session

    /// Claims a peer stream whose WebTransport prefix has just been read.
    @discardableResult
    mutating func adoptWebTransportStream(_ connectionSlot: Int, _ h3: H3Connection,
                                          _ streamID: UInt64, sessionID: UInt64,
                                          bidirectional: Bool) -> Int {
        if let sessionSlot = h3.sessions[sessionID].map(Int.init),
           let session = table[sessionSlot].pointee.wt, !session.gone {
            addPeerStream(sessionSlot, h3, session, streamID, bidirectional: bidirectional)
            return sessionSlot
        }

        // The CONNECT has not been accepted yet, or the session is over.
        // Holding a bounded number of streams covers reordering; past that the
        // peer is told to give up on them rather than left waiting.
        let total = h3.wtOrphans.values.reduce(0) { $0 + $1.count }
        if total >= wtMaxOrphanStreams {
            h3.quic.resetStream(streamID, code: HTTP3Error.webTransportBufferedStreamRejected)
            h3.quic.stopSending(streamID, code: HTTP3Error.webTransportBufferedStreamRejected)
            h3.quic.releaseStream(streamID)
            return -1
        }
        h3.wtOrphans[sessionID, default: []].append((streamID, bidirectional))
        return -1
    }

    /// New bytes, or an ending, on a stream belonging to a session.
    mutating func wtStreamReadable(_ sessionSlot: Int, _ h3: H3Connection, _ streamID: UInt64) {
        table[sessionSlot].pointee.wt?.streams[streamID]?.readWaiter.take()?.resume()
    }

    /// The peer reset a session stream, or asked us to stop sending on one.
    mutating func wtStreamAborted(_ sessionSlot: Int, _ h3: H3Connection, _ streamID: UInt64) {
        guard let stream = table[sessionSlot].pointee.wt?.streams[streamID] else { return }
        stream.aborted = true
        stream.writable = false
        stream.wake()
    }

    /// Something a session stream sent was acknowledged, which may give a
    /// writer waiting for room its room.
    mutating func wtStreamWritable(_ sessionSlot: Int) {
        guard let session = table[sessionSlot].pointee.wt else { return }
        for stream in session.streams.values { stream.writeWaiter.take()?.resume() }
    }

    /// Routes one datagram to the session named by its quarter stream id.
    mutating func wtDatagram(_ connectionSlot: Int, _ h3: H3Connection, _ payload: [UInt8]) {
        var sessionID: UInt64 = 0
        var offset = 0
        payload.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var r = QUICReader(base, buffer.count)
            guard let quarter = r.varint() else { return }
            sessionID = quarter &* 4
            offset = r.offset
        }
        if offset == 0 { return }
        guard let sessionSlot = h3.sessions[sessionID].map(Int.init),
              let session = table[sessionSlot].pointee.wt, !session.gone else { return }

        session.datagrams.append([UInt8](payload[offset...]))
        session.datagramBytes += payload.count - offset
        while session.datagrams.count > wtMaxQueuedDatagrams
                || session.datagramBytes > wtMaxQueuedDatagramBytes {
            // Unreliable in, unreliable out: a handler too slow to read its
            // datagrams loses the oldest, not the newest.
            session.datagramBytes -= session.datagrams.removeFirst().count
        }
        session.datagramWaiter.take()?.resume()
    }

    // MARK: - Capsules on the CONNECT stream

    /// Reads whatever capsules have arrived on a session's CONNECT stream.
    mutating func readWTCapsules(_ sessionSlot: Int, _ h3: H3Connection, _ stream: QUICStream) {
        guard let session = table[sessionSlot].pointee.wt else { return }
        while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else { break }
            if r.remaining < length { break }
            let header = r.offset

            if type == HTTP3Capsule.closeWebTransportSession {
                // A 32-bit application code and a UTF-8 reason.
                if length >= 4 {
                    let p = base + header
                    session.closeCode = UInt32(p[0]) << 24 | UInt32(p[1]) << 16
                        | UInt32(p[2]) << 8 | UInt32(p[3])
                    session.closeReason = [UInt8](UnsafeBufferPointer(start: p + 4, count: length - 4))
                }
                stream.receive.ready.consume(header + length)
                endWebTransportSession(sessionSlot, clean: true)
                return
            }
            // DRAIN and anything unknown are advisory: a capsule nobody
            // understands is skipped, which is what makes them extensible.
            stream.receive.ready.consume(header + length)
        }
        if stream.receive.finished && !session.gone {
            endWebTransportSession(sessionSlot, clean: false)
        }
    }

    // MARK: - Ending a session

    /// Sends the close capsule and finishes the CONNECT stream.
    mutating func closeWebTransportSession(_ slot: Int, _ session: WTSession) {
        let parent = Int(table[slot].pointee.parentSlot)
        guard !session.gone, parent >= 0, let h3 = table[parent].pointee.h3 else {
            endWebTransportSession(slot, clean: false)
            return
        }
        if !session.closeSent {
            session.closeSent = true
            var capsule = ByteBuffer(capacity: session.closeReason.count + 16)
            defer { capsule.destroy() }
            capsule.writeVarint(HTTP3Capsule.closeWebTransportSession)
            capsule.writeVarint(UInt64(4 + session.closeReason.count))
            let code = session.closeCode
            capsule.writeByte(UInt8(truncatingIfNeeded: code >> 24))
            capsule.writeByte(UInt8(truncatingIfNeeded: code >> 16))
            capsule.writeByte(UInt8(truncatingIfNeeded: code >> 8))
            capsule.writeByte(UInt8(truncatingIfNeeded: code))
            session.closeReason.withUnsafeBufferPointer { p in
                if let base = p.baseAddress, p.count > 0 { capsule.write(base, p.count) }
            }
            h3.quic.send(session.sessionID, UnsafePointer(capsule.readPointer),
                         capsule.readableBytes, fin: true)
            table[slot].pointee.flags.insert(.endStreamSent)
            flushQUIC(parent)
        }
        endWebTransportSession(slot, clean: true)
    }

    /// Tears the session down: every stream it owned goes with it, every wait
    /// on it ends, and the CONNECT stream's slot is closed.
    ///
    /// The handler may still be running. It is not stopped -- nothing can
    /// stop a task -- but everything it asks of the session from here on
    /// finds it gone: a wait returns nil, a write throws.
    mutating func endWebTransportSession(_ slot: Int, clean: Bool) {
        let c = table[slot]
        guard let session = c.pointee.wt, !session.gone else { return }
        session.gone = true

        let parent = Int(c.pointee.parentSlot)
        if parent >= 0, let h3 = table[parent].pointee.h3 {
            // Streams of a session that has ended are not finished, they are
            // abandoned, and the peer is told which it was.
            for (id, stream) in session.streams {
                h3.wtStreams.removeValue(forKey: id)
                if stream.writable { h3.quic.resetStream(id, code: HTTP3Error.webTransportSessionGone) }
                if !stream.readEnded { h3.quic.stopSending(id, code: HTTP3Error.webTransportSessionGone) }
                h3.quic.releaseStream(id)
            }
            h3.sessions.removeValue(forKey: session.sessionID)
            h3.wtOrphans.removeValue(forKey: session.sessionID)
            if !clean && !c.pointee.flags.contains(.endStreamSent) {
                c.pointee.flags.insert(.endStreamSent)
                h3.quic.send(session.sessionID, emptyH3Byte, 0, fin: true)
            }
            flushQUIC(parent)
        }
        // Closing the slot releases the session, which ends every wait on it.
        closeH3Stream(slot)
    }

    /// The handler returned or threw. A session it left open is closed
    /// cleanly for it.
    mutating func webTransportHandlerFinished(_ slot: Int, generation: UInt32, requestId: UInt32,
                                              _ session: WTSession) {
        let c = table[slot]
        guard c.pointee.state != .free, c.pointee.generation == generation,
              c.pointee.requestId == requestId, c.pointee.wt === session else { return }
        closeWebTransportSession(slot, session)
    }

    /// Releases everything a session holds. Called from `closeConnection`,
    /// where the slot is going away whatever state the session is in.
    mutating func releaseWebTransport(_ slot: Int) {
        let c = table[slot]
        guard let session = c.pointee.wt else { return }
        c.pointee.wt = nil
        let parent = Int(c.pointee.parentSlot)
        if !session.gone, parent >= 0, let h3 = table[parent].pointee.h3 {
            for (id, _) in session.streams {
                h3.wtStreams.removeValue(forKey: id)
                h3.quic.resetStream(id, code: HTTP3Error.webTransportSessionGone)
                h3.quic.releaseStream(id)
            }
            h3.sessions.removeValue(forKey: session.sessionID)
            h3.wtOrphans.removeValue(forKey: session.sessionID)
        }
        session.gone = true
        session.wakeAll()
        session.streams.removeAll()
        session.incoming.removeAll()
        session.datagrams.removeAll()
    }
}
