//===----------------------------------------------------------------------===//
// WebTransport over HTTP/3 (draft-ietf-webtrans-http3).
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
// request head, a body buffer, a parser and an ASGI task, and a WebTransport
// stream wants none of that: it is a byte pipe whose bytes are handed to the
// application as they arrive. They are tracked here instead, and their data is
// read straight out of the QUIC receive buffer, so a large upload is copied
// once into a Python `bytes` and not before.
//
// ASGI has no WebTransport specification. This one is Peregrine's, announced
// in `scope["extensions"]["webtransport"]` the way the specification says a
// server extension announces itself, and documented in README.md.
//
//   receive():
//     {"type": "webtransport.connect"}
//     {"type": "webtransport.stream.opened", "stream": int,
//      "bidirectional": bool}
//     {"type": "webtransport.stream.receive", "stream": int, "data": bytes,
//      "more_data": bool}
//     {"type": "webtransport.datagram.receive", "data": bytes}
//     {"type": "webtransport.disconnect", "code": int, "reason": str}
//
//   send():
//     {"type": "webtransport.accept", "headers": [...]}
//     {"type": "webtransport.close", "code": int, "reason": str}
//     {"type": "webtransport.stream.open", "bidirectional": bool}
//     {"type": "webtransport.stream.send", "stream": int, "data": bytes,
//      "end_stream": bool}
//     {"type": "webtransport.stream.pause", "stream": int}
//     {"type": "webtransport.stream.resume", "stream": int}
//     {"type": "webtransport.datagram.send", "data": bytes}
//
// A stream the application opens is answered with `webtransport.stream.opened`
// rather than by a return value, because ASGI's `send()` returns nothing. In
// order of arrival, so an application that opens several can tell them apart.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineASGI
import PeregrineCore
import PeregrineHTTP
import PeregrinePython
import PeregrineQUIC

/// One stream belonging to a session.
public final class WTStream {
    public let id: UInt64
    public let bidirectional: Bool
    /// The peer will send nothing more, and the application has been told.
    public var endDelivered = false
    /// The peer will send nothing more, whether by FIN or by reset.
    public var recvClosed = false
    /// We have finished our direction.
    public var finSent = false
    /// The application may not write to a peer's unidirectional stream.
    public var writable: Bool
    /// The application is not reading this stream. Its bytes stay in the
    /// QUIC buffer and its window does not reopen; every other stream still
    /// does.
    public var paused = false

    init(id: UInt64, bidirectional: Bool, writable: Bool) {
        self.id = id
        self.bidirectional = bidirectional
        self.writable = writable
    }
}

/// A WebTransport session, on the slot its CONNECT stream owns.
public final class WTSession {
    /// The identifier of the CONNECT stream, which is also the session's.
    public let sessionID: UInt64
    public var accepted = false
    public var connectDelivered = false
    public var disconnectDelivered = false
    /// A close has been decided; the disconnect is owed to the application.
    public var gone = false
    public var closeSent = false
    public var closeCode: UInt64 = 0
    public var closeReason: [UInt8] = []

    public var streams: [UInt64: WTStream] = [:]
    /// Streams with bytes, or an ending, waiting to be delivered. A queue
    /// rather than a scan, so that a session with a thousand streams costs
    /// nothing per `receive()`.
    var readable: [UInt64] = []
    var readableSet: Set<UInt64> = []
    /// Readable, but the application asked us not to deliver. Resume moves
    /// them back. Kept out of `readable` so a paused stream cannot spin the
    /// take loop.
    var pausedReadable: Set<UInt64> = []
    /// Streams we opened, waiting to be announced.
    var opened: [UInt64] = []
    /// Datagrams are unreliable by definition, so the queue is bounded and
    /// drops the oldest rather than growing or applying backpressure.
    var datagrams: [[UInt8]] = []
    var datagramBytes = 0
    /// Alternates so a busy stream cannot starve datagrams, or the reverse.
    var datagramTurn = false

    init(sessionID: UInt64) {
        self.sessionID = sessionID
    }

    func markReadable(_ id: UInt64) {
        if let stream = streams[id], stream.paused {
            pausedReadable.insert(id)
            return
        }
        if readableSet.insert(id).inserted { readable.append(id) }
    }

    func pause(_ id: UInt64) {
        guard let stream = streams[id], !stream.paused else { return }
        stream.paused = true
        if readableSet.remove(id) != nil {
            if let i = readable.firstIndex(of: id) { readable.remove(at: i) }
            pausedReadable.insert(id)
        }
    }

    func resume(_ id: UInt64) {
        guard let stream = streams[id], stream.paused else { return }
        stream.paused = false
        if pausedReadable.remove(id) != nil {
            markReadable(id)
        }
    }
}

/// The most datagrams one session will hold for an application that is not
/// reading them, and the most bytes those may total.
private let wtMaxQueuedDatagrams = 64
private let wtMaxQueuedDatagramBytes = 256 * 1024
/// The largest chunk handed to the application in one message.
private let wtMaxChunk = 64 * 1024
/// Streams that named a session we have not seen yet, held while the CONNECT
/// they belong to catches up. Reordering across QUIC streams is ordinary.
private let wtMaxOrphanStreams = 32

extension Worker {

    // MARK: - Establishing a session

    /// Turns an accepted extended CONNECT into a session and hands it to the
    /// application. Mirrors `dispatchWebSocket`: one task, one `receive` and
    /// one `send`, with nothing delivered until the application accepts.
    mutating func dispatchWebTransport(_ slot: Int) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        if h3.sessions.count >= wtMaxSessions {
            h3FailRequest(slot, status: 503)
            return
        }

        let sessionID = c.pointee.qstreamID
        let session = WTSession(sessionID: sessionID)
        c.pointee.wt = session
        c.pointee.flags.insert(.webtransportMode)
        c.pointee.state = .dispatching
        h3.sessions[sessionID] = Int32(slot)
        adoptOrphanStreams(h3, session, slot)

        let base = c.pointee.headBase()
        let forwarded = forwardedInfo(slot, base: base)
        let forwardedClient = forwardedClientTuple(forwarded)
        defer { if let f = forwardedClient { pg_decref(f) } }

        if c.pointee.clientTuple == nil,
           let addr = c.pointee.remoteAddrObj,
           let port = c.pointee.remotePortObj {
            c.pointee.clientTuple = pg_tuple2(addr, port)
        }

        guard let scopeDict = ASGIRuntime.scope!.build(
                base: base,
                head: c.pointee.head,
                headers: headers,
                client: forwardedClient ?? c.pointee.clientTuple,
                schemeOverride: Interned[.vHTTPS],
                webtransport: true) else {
            PyError.logPending("building the webtransport scope")
            h3FailRequest(slot, status: 500)
            return
        }
        defer { pg_decref(scopeDict) }

        let token = PollToken.make(slot: slot, generation: c.pointee.generation)
        guard let receiveFn = PyTrampoline.make(asgiReceive, context: token),
              let sendFn = PyTrampoline.make(asgiSend, context: token) else {
            PyError.logPending("creating the webtransport channels")
            h3FailRequest(slot, status: 500)
            return
        }
        c.pointee.receiveCallable = receiveFn
        c.pointee.sendCallable = sendFn

        guard let coro = pg_call3(ASGIRuntime.app, scopeDict, receiveFn, sendFn) else {
            PyError.logPending("calling the application")
            h3FailRequest(slot, status: 500)
            return
        }
        defer { pg_decref(coro) }

        guard let doneCb = PyTrampoline.make(asgiTaskDone, context: token) else {
            PyError.logPending("creating the completion callback")
            h3FailRequest(slot, status: 500)
            return
        }
        defer { pg_decref(doneCb) }

        guard let task = pg_call3(ASGIRuntime.fnSpawn, ASGIRuntime.loop, coro, doneCb) else {
            PyError.logPending("scheduling the webtransport task")
            h3FailRequest(slot, status: 500)
            return
        }
        c.pointee.task = task
    }

    /// Streams that arrived before their CONNECT did.
    private mutating func adoptOrphanStreams(_ h3: H3Connection, _ session: WTSession,
                                             _ slot: Int) {
        guard let waiting = h3.wtOrphans.removeValue(forKey: session.sessionID) else { return }
        for (streamID, bidirectional) in waiting {
            guard h3.quic.stream(streamID) != nil else { continue }
            let stream = WTStream(id: streamID, bidirectional: bidirectional,
                                  writable: bidirectional)
            session.streams[streamID] = stream
            h3.wtStreams[streamID] = Int32(slot)
            session.markReadable(streamID)
        }
    }

    // MARK: - Routing streams into a session

    /// Claims a peer stream whose WebTransport prefix has just been read.
    /// Returns false when the connection was closed.
    mutating func adoptWebTransportStream(_ connectionSlot: Int, _ h3: H3Connection,
                                          _ streamID: UInt64, sessionID: UInt64,
                                          bidirectional: Bool) -> Bool {
        if let sessionSlot = h3.sessions[sessionID].map(Int.init),
           let session = table[sessionSlot].pointee.wt {
            let stream = WTStream(id: streamID, bidirectional: bidirectional,
                                  writable: bidirectional)
            session.streams[streamID] = stream
            h3.wtStreams[streamID] = Int32(sessionSlot)
            wtStreamReadable(sessionSlot, h3, streamID)
            return true
        }

        // The CONNECT has not arrived yet, or the session is over. Holding a
        // bounded number of streams covers reordering; past that the peer is
        // told to give up on them rather than left waiting.
        var waiting = h3.wtOrphans[sessionID] ?? []
        let total = h3.wtOrphans.values.reduce(0) { $0 + $1.count }
        if total >= wtMaxOrphanStreams {
            h3.quic.resetStream(streamID,
                                code: HTTP3Error.webTransportBufferedStreamRejected)
            h3.quic.stopSending(streamID,
                                code: HTTP3Error.webTransportBufferedStreamRejected)
            h3.quic.releaseStream(streamID)
            return true
        }
        waiting.append((streamID, bidirectional))
        h3.wtOrphans[sessionID] = waiting
        return true
    }

    /// New bytes, or an ending, on a stream belonging to a session.
    mutating func wtStreamReadable(_ sessionSlot: Int, _ h3: H3Connection,
                                   _ streamID: UInt64) {
        guard let session = table[sessionSlot].pointee.wt,
              let stream = session.streams[streamID] else { return }
        guard let quicStream = h3.quic.stream(streamID) else { return }
        if quicStream.receive.ready.readableBytes > 0 || quicStream.receive.finished {
            if quicStream.receive.finished { stream.recvClosed = true }
            session.markReadable(streamID)
            deliverPendingReceive(sessionSlot)
        }
    }

    /// The peer reset a session stream, or asked us to stop sending on one.
    mutating func wtStreamAborted(_ sessionSlot: Int, _ h3: H3Connection,
                                  _ streamID: UInt64) {
        guard let session = table[sessionSlot].pointee.wt,
              let stream = session.streams[streamID] else { return }
        stream.recvClosed = true
        stream.writable = false
        session.markReadable(streamID)
        deliverPendingReceive(sessionSlot)
    }

    /// A session stream drained, which may release an application parked in
    /// `await send()`.
    mutating func wtStreamWritable(_ sessionSlot: Int) {
        resumeWriterIfDrained(sessionSlot)
    }

    /// Routes one datagram to the session named by its quarter stream id.
    mutating func wtDatagram(_ connectionSlot: Int, _ h3: H3Connection,
                             _ payload: [UInt8]) {
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
              let session = table[sessionSlot].pointee.wt, session.accepted else { return }

        let count = payload.count - offset
        session.datagrams.append([UInt8](payload[offset...]))
        session.datagramBytes += count
        while session.datagrams.count > wtMaxQueuedDatagrams
                || session.datagramBytes > wtMaxQueuedDatagramBytes {
            // Unreliable in, unreliable out: an application too slow to read
            // its datagrams loses the oldest, not the newest.
            session.datagramBytes -= session.datagrams.removeFirst().count
        }
        deliverPendingReceive(sessionSlot)
    }

    // MARK: - Capsules on the CONNECT stream

    /// Reads whatever capsules have arrived on a session's CONNECT stream.
    mutating func readWTCapsules(_ sessionSlot: Int, _ h3: H3Connection,
                                 _ stream: QUICStream) {
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
                    session.closeCode = UInt64(p[0]) << 24 | UInt64(p[1]) << 16
                        | UInt64(p[2]) << 8 | UInt64(p[3])
                    session.closeReason = [UInt8](
                        UnsafeBufferPointer(start: p + 4, count: length - 4))
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

    // MARK: - receive()

    /// The next WebTransport message for the application, or nil to park.
    mutating func nextWebTransportMessage(_ slot: Int) -> PyObj? {
        let c = table[slot]
        guard let session = c.pointee.wt else { return nil }
        if !session.connectDelivered {
            session.connectDelivered = true
            return ASGIWebTransportMessage.connect()
        }
        if session.disconnectDelivered { return nil }
        // Nothing belonging to the session may be delivered before the
        // application has accepted it: until then there is no session.
        if !session.accepted {
            if session.gone {
                session.disconnectDelivered = true
                return ASGIWebTransportMessage.disconnect(code: session.closeCode,
                                                          reason: session.closeReason)
            }
            return nil
        }

        if !session.opened.isEmpty {
            let id = session.opened.removeFirst()
            let bidirectional = session.streams[id]?.bidirectional ?? false
            return ASGIWebTransportMessage.streamOpened(id, bidirectional: bidirectional)
        }

        if session.datagramTurn, let message = takeWTDatagram(session) {
            session.datagramTurn = false
            return message
        }
        if let message = takeWTStreamChunk(slot, session) {
            session.datagramTurn = true
            return message
        }
        if let message = takeWTDatagram(session) {
            session.datagramTurn = false
            return message
        }

        if session.gone {
            session.disconnectDelivered = true
            return ASGIWebTransportMessage.disconnect(code: session.closeCode,
                                                      reason: session.closeReason)
        }
        return nil
    }

    private func takeWTDatagram(_ session: WTSession) -> PyObj? {
        if session.datagrams.isEmpty { return nil }
        let payload = session.datagrams.removeFirst()
        session.datagramBytes -= payload.count
        return payload.withUnsafeBufferPointer { buffer in
            ASGIWebTransportMessage.datagram(buffer.baseAddress, buffer.count)
        }
    }

    /// Takes the next run of bytes, or the next ending, from a session stream.
    private mutating func takeWTStreamChunk(_ slot: Int, _ session: WTSession) -> PyObj? {
        let parent = Int(table[slot].pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else { return nil }

        while let streamID = session.readable.first {
            session.readable.removeFirst()
            session.readableSet.remove(streamID)
            guard let stream = session.streams[streamID],
                  let quicStream = h3.quic.stream(streamID) else { continue }
            if stream.paused {
                session.pausedReadable.insert(streamID)
                continue
            }

            let available = quicStream.receive.ready.readableBytes
            let take = min(available, wtMaxChunk)
            if take == 0 {
                if stream.recvClosed && !stream.endDelivered {
                    stream.endDelivered = true
                    retireWTStream(session, h3, stream)
                    return ASGIWebTransportMessage.streamReceive(streamID, nil, 0,
                                                                 moreData: false)
                }
                continue
            }

            let p = UnsafePointer(quicStream.receive.ready.readPointer)
            let ended = stream.recvClosed && take == available
            let message = ASGIWebTransportMessage.streamReceive(streamID, p, take,
                                                                moreData: !ended)
            quicStream.receive.ready.consume(take)
            // Reading is what re-opens the window, and holding the bytes here
            // until the application takes them is what makes it backpressure
            // rather than an unbounded buffer.
            let consumed = quicStream.receive.received
                - UInt64(quicStream.receive.ready.readableBytes)
            h3.quic.extendStreamWindow(streamID, consumed: consumed)
            if ended {
                stream.endDelivered = true
                retireWTStream(session, h3, stream)
            } else if quicStream.receive.ready.readableBytes > 0 || stream.recvClosed {
                // More than one chunk's worth: back of the queue, so that one
                // busy stream cannot starve the others.
                session.markReadable(streamID)
            }
            flushQUIC(parent)
            return message
        }
        return nil
    }

    /// Lets the transport forget a stream once neither side can use it again.
    private func retireWTStream(_ session: WTSession, _ h3: H3Connection,
                                _ stream: WTStream) {
        if stream.writable && !stream.finSent { return }
        session.streams.removeValue(forKey: stream.id)
        session.pausedReadable.remove(stream.id)
        session.readableSet.remove(stream.id)
        if let i = session.readable.firstIndex(of: stream.id) {
            session.readable.remove(at: i)
        }
        h3.wtStreams.removeValue(forKey: stream.id)
        h3.quic.releaseStream(stream.id)
    }

    // MARK: - send()

    mutating func webtransportSend(_ slot: Int, type: UnsafePointer<UInt8>,
                                   typeLength: Int, message: PyObj) -> Bool {
        let c = table[slot]
        guard let session = c.pointee.wt else {
            pg_err_set_str(pg_exc_runtime(), "the webtransport session is gone")
            return false
        }

        if typeLength == 19 && equalsExact(type, 19, "webtransport.accept") {
            if session.accepted {
                pg_err_set_str(pg_exc_runtime(), "webtransport.accept sent twice")
                return false
            }
            return acceptWebTransport(slot, session, message: message)
        }

        if typeLength == 18 && equalsExact(type, 18, "webtransport.close") {
            var code: UInt64 = 0
            if let codeObj = pg_dict_get(message, Interned[.code]),
               pg_is(codeObj, Interned.none) == 0 {
                let v = pg_int_as_long(codeObj)
                if v < 0 { pg_err_clear() } else { code = UInt64(v) }
            }
            var reason: [UInt8] = []
            if let reasonObj = pg_dict_get(message, Interned[.reason]),
               pg_is(reasonObj, Interned.none) == 0 {
                var n: pg_ssize_t = 0
                if let text = pg_str_utf8_data(reasonObj, &n) {
                    let p = UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self)
                    reason = [UInt8](UnsafeBufferPointer(start: p, count: Int(n)))
                } else {
                    pg_err_clear()
                }
            }
            if !session.accepted {
                // Refusing the session. The client sees an HTTP failure,
                // because that is all the CONNECT has become so far. A code in
                // the range of a failure status is used as one -- that is how
                // an application says "not found" rather than "forbidden" --
                // and anything else is a session code with no session to
                // carry it.
                let status = code >= 400 && code <= 599 ? Int(code) : 403
                h3FailRequest(slot, status: status)
                return true
            }
            session.closeCode = code
            session.closeReason = reason
            closeWebTransportSession(slot, session)
            return true
        }

        guard session.accepted else {
            pg_err_set_str(pg_exc_runtime(),
                           "webtransport messages are not allowed before accept")
            return false
        }

        if typeLength == 24 && equalsExact(type, 24, "webtransport.stream.open") {
            var bidirectional = true
            if let b = pg_dict_get(message, Interned[.bidirectional]) {
                bidirectional = pg_is_true(b) == 1
            }
            return openWebTransportStream(slot, session, bidirectional: bidirectional)
        }

        if typeLength == 24 && equalsExact(type, 24, "webtransport.stream.send") {
            return sendWebTransportStream(slot, session, message: message)
        }

        if typeLength == 25 && equalsExact(type, 25, "webtransport.stream.pause") {
            return pauseWebTransportStream(slot, session, message: message)
        }

        if typeLength == 26 && equalsExact(type, 26, "webtransport.stream.resume") {
            return resumeWebTransportStream(slot, session, message: message)
        }

        if typeLength == 26 && equalsExact(type, 26, "webtransport.datagram.send") {
            return sendWebTransportDatagram(slot, session, message: message)
        }

        pg_err_set_str(pg_exc_value(), "unsupported webtransport message type")
        return false
    }

    /// Answers the CONNECT with 200, which is what establishes the session.
    private mutating func acceptWebTransport(_ slot: Int, _ session: WTSession,
                                             message: PyObj) -> Bool {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }

        dates.refresh()
        var block = ByteBuffer()
        defer { block.destroy() }
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(200, into: &block)

        var lower = ByteBuffer()
        defer { lower.destroy() }
        if let headerList = pg_dict_get(message, Interned[.headers]),
           pg_is(headerList, Interned.none) == 0 {
            guard PySeq.isSequence(headerList) else {
                pg_err_set_str(pg_exc_value(),
                               "webtransport.accept headers must be a list of pairs")
                return false
            }
            let count = PySeq.count(headerList)
            var i = 0
            while i < count {
                guard let item = PySeq.item(headerList, i),
                      let (nameObj, valueObj) = PySeq.pair(item) else {
                    pg_err_set_str(pg_exc_value(),
                                   "each response header must be a (name, value) pair")
                    return false
                }
                i += 1
                guard let nameView = PyBytesView.of(nameObj) else {
                    pg_err_set_str(pg_exc_value(), "a response header name is not bytes")
                    return false
                }
                guard let valueView = PyBytesView.of(valueObj) else {
                    nameView.release()
                    pg_err_set_str(pg_exc_value(), "a response header value is not bytes")
                    return false
                }
                let name = nameView.span
                let value = valueView.span
                var bad = false
                if name.count == 0 || name.base[0] == 0x3A
                    || HTTP2.isConnectionSpecific(name.base, name.count)
                    || !HTTP2.validFieldValue(value.base, value.count) {
                    bad = true
                } else {
                    lower.clear()
                    lower.reserve(name.count)
                    var j = 0
                    while j < name.count {
                        lower.writeByte(asciiLower(name.base[j]))
                        j += 1
                    }
                    let lowered = UnsafePointer(lower.readPointer)
                    if HTTP2.validFieldName(lowered, name.count) {
                        h3.encoder.encode(name: lowered, nameLength: name.count,
                                          value: value.count > 0 ? value.base : emptyH3Byte,
                                          valueLength: value.count, into: &block)
                    } else {
                        bad = true
                    }
                }
                valueView.release()
                nameView.release()
                if bad {
                    pg_err_set_str(pg_exc_value(), "header is not valid in HTTP/3")
                    return false
                }
            }
        }
        encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        encodeStaticH3(h3, "server", "peregrine", into: &block)

        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)
        session.accepted = true
        logAccess(slot, status: 200)
        flushQUIC(parent)
        // Streams may already have arrived and queued while the application
        // was deciding; now there is somewhere for them to go.
        deliverPendingReceive(slot)
        return true
    }

    private mutating func openWebTransportStream(_ slot: Int, _ session: WTSession,
                                                 bidirectional: Bool) -> Bool {
        let parent = Int(table[slot].pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }
        guard let id = h3.quic.openStream(unidirectional: !bidirectional) else {
            pg_err_set_str(pg_exc_runtime(),
                           "the peer will not accept another stream right now")
            return false
        }

        // Our streams carry the same prefix the peer's do: a unidirectional
        // stream is typed 0x54, a bidirectional one starts with the frame that
        // says it is not a request.
        var prefix = ByteBuffer(capacity: 16)
        defer { prefix.destroy() }
        prefix.writeVarint(bidirectional
            ? HTTP3FrameType.webTransportStream
            : HTTP3StreamType.webTransport)
        prefix.writeVarint(session.sessionID)
        h3.quic.send(id, UnsafePointer(prefix.readPointer), prefix.readableBytes, fin: false)

        let stream = WTStream(id: id, bidirectional: bidirectional, writable: true)
        // A unidirectional stream we opened will never carry anything back.
        stream.recvClosed = !bidirectional
        stream.endDelivered = !bidirectional
        session.streams[id] = stream
        h3.wtStreams[id] = Int32(slot)
        session.opened.append(id)
        flushQUIC(parent)
        deliverPendingReceive(slot)
        return true
    }

    private func wtStreamID(_ message: PyObj) -> UInt64? {
        guard let idObj = pg_dict_get(message, Interned[.stream]) else {
            pg_err_set_str(pg_exc_value(),
                           "webtransport stream message needs a stream")
            return nil
        }
        let raw = pg_int_as_long(idObj)
        if raw < 0 {
            pg_err_set_str(pg_exc_value(), "stream must be a non-negative integer")
            return nil
        }
        return UInt64(raw)
    }

    /// Stops delivering one stream without stopping the session. Its bytes
    /// stay in the QUIC receive buffer, so its window does not reopen.
    private mutating func pauseWebTransportStream(_ slot: Int, _ session: WTSession,
                                                  message: PyObj) -> Bool {
        guard let id = wtStreamID(message) else { return false }
        session.pause(id)
        return true
    }

    private mutating func resumeWebTransportStream(_ slot: Int, _ session: WTSession,
                                                   message: PyObj) -> Bool {
        guard let id = wtStreamID(message) else { return false }
        session.resume(id)
        deliverPendingReceive(slot)
        return true
    }

    private mutating func sendWebTransportStream(_ slot: Int, _ session: WTSession,
                                                 message: PyObj) -> Bool {
        let parent = Int(table[slot].pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }
        guard let idObj = pg_dict_get(message, Interned[.stream]) else {
            pg_err_set_str(pg_exc_value(), "webtransport.stream.send needs a stream")
            return false
        }
        let raw = pg_int_as_long(idObj)
        if raw < 0 {
            pg_err_set_str(pg_exc_value(), "stream must be a non-negative integer")
            return false
        }
        let id = UInt64(raw)
        guard let stream = session.streams[id] else {
            // A stream the peer has already reset is not the application's
            // mistake: it may have written before the reset reached it.
            return true
        }
        if !stream.writable {
            pg_err_set_str(pg_exc_value(), "this stream cannot be written to")
            return false
        }
        if stream.finSent { return true }

        var endStream = false
        if let e = pg_dict_get(message, Interned[.endStream]) {
            endStream = pg_is_true(e) == 1
        }

        if let dataObj = pg_dict_get(message, Interned[.data]),
           pg_is(dataObj, Interned.none) == 0 {
            guard let view = PyBytesView.of(dataObj) else {
                pg_err_set_str(pg_exc_value(), "webtransport data must be bytes")
                return false
            }
            defer { view.release() }
            h3.quic.send(id, view.span.count > 0 ? view.span.base : emptyH3Byte,
                         view.span.count, fin: endStream)
        } else if endStream {
            h3.quic.send(id, emptyH3Byte, 0, fin: true)
        }

        if endStream {
            stream.finSent = true
            stream.writable = false
            if stream.endDelivered { retireWTStream(session, h3, stream) }
        }
        flushQUIC(parent)
        return true
    }

    private mutating func sendWebTransportDatagram(_ slot: Int, _ session: WTSession,
                                                   message: PyObj) -> Bool {
        let parent = Int(table[slot].pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            pg_err_set_str(pg_exc_runtime(), "the connection is gone")
            return false
        }
        guard let dataObj = pg_dict_get(message, Interned[.data]),
              let view = PyBytesView.of(dataObj) else {
            pg_err_set_str(pg_exc_value(), "webtransport.datagram.send needs data bytes")
            return false
        }
        defer { view.release() }

        var out = ByteBuffer(capacity: view.span.count + 8)
        defer { out.destroy() }
        out.writeVarint(session.sessionID / 4)
        if view.span.count > 0 { out.write(view.span.base, view.span.count) }
        // A datagram too large for the path is dropped rather than refused:
        // that is what unreliable means, and an application cannot know the
        // peer's limit before it sends.
        _ = h3.quic.sendDatagram(UnsafePointer(out.readPointer), out.readableBytes)
        flushQUIC(parent)
        return true
    }

    // MARK: - Ending a session

    /// Sends the close capsule and finishes the CONNECT stream.
    mutating func closeWebTransportSession(_ slot: Int, _ session: WTSession) {
        let parent = Int(table[slot].pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            endWebTransportSession(slot, clean: false)
            return
        }
        if !session.closeSent {
            session.closeSent = true
            var body = ByteBuffer(capacity: session.closeReason.count + 8)
            defer { body.destroy() }
            let code = UInt32(truncatingIfNeeded: session.closeCode)
            body.writeByte(UInt8(truncatingIfNeeded: code >> 24))
            body.writeByte(UInt8(truncatingIfNeeded: code >> 16))
            body.writeByte(UInt8(truncatingIfNeeded: code >> 8))
            body.writeByte(UInt8(truncatingIfNeeded: code))
            session.closeReason.withUnsafeBufferPointer { p in
                if let base = p.baseAddress, p.count > 0 { body.write(base, p.count) }
            }

            var capsule = ByteBuffer(capacity: body.readableBytes + 16)
            defer { capsule.destroy() }
            capsule.writeVarint(HTTP3Capsule.closeWebTransportSession)
            capsule.writeVarint(UInt64(body.readableBytes))
            capsule.write(UnsafePointer(body.readPointer), body.readableBytes)
            h3.quic.send(session.sessionID, UnsafePointer(capsule.readPointer),
                         capsule.readableBytes, fin: true)
            table[slot].pointee.flags.insert(.endStreamSent)
            flushQUIC(parent)
        }
        endWebTransportSession(slot, clean: true)
    }

    /// Tears the session down: every stream it owned goes with it.
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
                if !stream.finSent {
                    h3.quic.resetStream(id, code: HTTP3Error.webTransportSessionGone)
                }
                if !stream.recvClosed {
                    h3.quic.stopSending(id, code: HTTP3Error.webTransportSessionGone)
                }
                h3.quic.releaseStream(id)
            }
            session.streams.removeAll()
            h3.sessions.removeValue(forKey: session.sessionID)
            h3.wtOrphans.removeValue(forKey: session.sessionID)
            if !clean && !c.pointee.flags.contains(.endStreamSent) {
                c.pointee.flags.insert(.endStreamSent)
                h3.quic.send(session.sessionID, emptyH3Byte, 0, fin: true)
            }
            flushQUIC(parent)
        }
        session.readable.removeAll()
        session.readableSet.removeAll()
        session.opened.removeAll()

        // The application is owed a disconnect before its slot goes away.
        deliverPendingReceive(slot)
        if c.pointee.task == nil { closeH3Stream(slot) }
    }

    /// Called when the application task finishes, however it finished.
    mutating func webtransportTaskFinished(_ slot: Int, error: Bool) {
        let c = table[slot]
        guard let session = c.pointee.wt else {
            closeH3Stream(slot)
            return
        }
        if !session.accepted {
            // Returning without accepting is a refusal.
            if !c.pointee.flags.contains(.responseStarted) {
                h3FailRequest(slot, status: error ? 500 : 403)
            } else {
                closeH3Stream(slot)
            }
            return
        }
        if !session.gone {
            if error { session.closeCode = 0 }
            closeWebTransportSession(slot, session)
        }
        if table[slot].pointee.state != .free { closeH3Stream(slot) }
    }

    /// Releases everything a session holds. Called from `closeConnection`,
    /// where the slot is going away whatever state the session is in.
    mutating func releaseWebTransport(_ slot: Int) {
        let c = table[slot]
        guard let session = c.pointee.wt else { return }
        c.pointee.wt = nil
        let parent = Int(c.pointee.parentSlot)
        if parent >= 0, let h3 = table[parent].pointee.h3 {
            for (id, _) in session.streams {
                h3.wtStreams.removeValue(forKey: id)
                h3.quic.resetStream(id, code: HTTP3Error.webTransportSessionGone)
                h3.quic.releaseStream(id)
            }
            h3.sessions.removeValue(forKey: session.sessionID)
            h3.wtOrphans.removeValue(forKey: session.sessionID)
        }
        session.streams.removeAll()
        session.datagrams.removeAll()
    }

    /// How much this session has queued on the transport but not had
    /// acknowledged, which is what its write backpressure is measured against.
    @usableFromInline
    func wtOutstanding(_ slot: Int) -> Int {
        let c = table[slot]
        guard let session = c.pointee.wt else { return 0 }
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else { return 0 }
        var total = 0
        for (id, _) in session.streams {
            if let stream = h3.quic.stream(id) {
                total += stream.send.data.readableBytes
            }
        }
        return total
    }
}

// MARK: - Message construction

public enum ASGIWebTransportMessage {

    public static func connect() -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        if pg_dict_set(d, Interned[.type], Interned[.vWTConnect]) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "webtransport.stream.opened", "stream": id,
    ///   "bidirectional": bool}`
    public static func streamOpened(_ id: UInt64, bidirectional: Bool) -> PyObj? {
        guard let d = pg_dict_new(), let idObj = pg_int(Int(id)) else { return nil }
        defer { pg_decref(idObj) }
        if pg_dict_set(d, Interned[.type], Interned[.vWTStreamOpened]) != 0
            || pg_dict_set(d, Interned[.stream], idObj) != 0
            || pg_dict_set(d, Interned[.bidirectional],
                           bidirectional ? Interned.pyTrue : Interned.pyFalse) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "webtransport.stream.receive", "stream": id, "data": bytes,
    ///   "more_data": bool}`
    ///
    /// `more_data` is false on the last message for a stream, whether it ended
    /// because the peer finished it or because the peer reset it: either way
    /// nothing more will arrive, which is the only thing the application can
    /// act on.
    public static func streamReceive(_ id: UInt64, _ p: UnsafePointer<UInt8>?,
                                     _ count: Int, moreData: Bool) -> PyObj? {
        guard let d = pg_dict_new(), let idObj = pg_int(Int(id)) else { return nil }
        defer { pg_decref(idObj) }
        let payload: PyObj? = count > 0
            ? p!.withMemoryRebound(to: CChar.self, capacity: count, {
                  pg_bytes($0, pg_ssize_t(count))
              })
            : Interned.emptyBytes
        guard let payload else {
            pg_decref(d)
            return nil
        }
        defer { if count > 0 { pg_decref(payload) } }
        if pg_dict_set(d, Interned[.type], Interned[.vWTStreamReceive]) != 0
            || pg_dict_set(d, Interned[.stream], idObj) != 0
            || pg_dict_set(d, Interned[.data], payload) != 0
            || pg_dict_set(d, Interned[.moreData],
                           moreData ? Interned.pyTrue : Interned.pyFalse) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "webtransport.datagram.receive", "data": bytes}`
    public static func datagram(_ p: UnsafePointer<UInt8>?, _ count: Int) -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        let payload: PyObj? = count > 0
            ? p!.withMemoryRebound(to: CChar.self, capacity: count, {
                  pg_bytes($0, pg_ssize_t(count))
              })
            : Interned.emptyBytes
        guard let payload else {
            pg_decref(d)
            return nil
        }
        defer { if count > 0 { pg_decref(payload) } }
        if pg_dict_set(d, Interned[.type], Interned[.vWTDatagramReceive]) != 0
            || pg_dict_set(d, Interned[.data], payload) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "webtransport.disconnect", "code": int, "reason": str}`
    public static func disconnect(code: UInt64, reason: [UInt8]) -> PyObj? {
        guard let d = pg_dict_new(), let codeObj = pg_int(Int(code)) else { return nil }
        defer { pg_decref(codeObj) }
        let reasonObj: PyObj? = reason.isEmpty
            ? Interned.emptyString
            : reason.withUnsafeBufferPointer { p in
                  p.baseAddress!.withMemoryRebound(to: CChar.self, capacity: p.count) {
                      pg_str_utf8($0, pg_ssize_t(p.count))
                  }
              }
        guard let reasonObj else {
            pg_err_clear()
            pg_decref(d)
            return nil
        }
        defer { if !reason.isEmpty { pg_decref(reasonObj) } }
        if pg_dict_set(d, Interned[.type], Interned[.vWTDisconnect]) != 0
            || pg_dict_set(d, Interned[.code], codeObj) != 0
            || pg_dict_set(d, Interned[.reason], reasonObj) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }
}
