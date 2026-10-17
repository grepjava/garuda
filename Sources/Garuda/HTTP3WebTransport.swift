//===----------------------------------------------------------------------===//
// WebTransport over HTTP/3 (draft-ietf-webtrans-http3): the endpoint's side.
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
// The handler runs in its CONNECT stream's pooled task, and never touches the
// QUIC connection, which is the endpoint's alone (HTTP3.swift). What the two
// share is kept under the endpoint's lock: a stream's bytes the handler has
// yet to read, and what it has written and the endpoint has yet to send. The
// endpoint copies what arrives into the first as it arrives, and gives the
// stream's window back only as the handler reads, so a stream nobody reads
// slows its sender and nothing else. The handler asks the endpoint for
// anything it cannot do itself -- sending, opening a stream, closing -- by
// marking the stream and posting the session's CONNECT stream, as a request
// task posts its answer (HTTP3Stream.swift).
//
// A stream the handler opens needs its identifier at once, and only the
// endpoint can open one. So the identifier is reserved under the lock, from
// the peer's stream limit as the endpoint last saw it, and the endpoint opens
// the reserved streams in the order they were reserved, which gives each the
// identifier reserved for it.
//
// The handler's API is in WebTransport.swift. scripts/webtransport-test.py
// checks the routing, capsules and closing against aioquic.
//===----------------------------------------------------------------------===//

import VegaQUIC
import GarudaWire
import Synchronization
import Vega

/// How many WebTransport sessions one connection may run at once: each holds
/// a pooled task for as long as it lasts.
let wtMaxSessions = 16
/// The most datagrams one session will hold for a handler that is not
/// reading them, and the most bytes those may total.
let wtMaxQueuedDatagrams = 64
let wtMaxQueuedDatagramBytes = 256 * 1024
/// Streams that named a session we have not seen yet, held while the CONNECT
/// they belong to catches up. Reordering across QUIC streams is ordinary.
let wtMaxOrphanStreams = 32
/// The longest close reason the draft allows.
let wtMaxCloseReason = 1024
/// The largest datagram sent, prefix included: what fits a packet of the
/// smallest size a QUIC path must carry, whatever larger the peer allows.
let wtDatagramCeiling = 1100

/// One stream belonging to a session.
///
/// Its stored properties are `@exclusivity(unchecked)`: each is the
/// endpoint's, or kept under the endpoint's lock.
final class WTStream: @unchecked Sendable {
    let id: UInt64
    let bidirectional: Bool
    /// Opened by the server.
    let local: Bool
    unowned(unsafe) let session: WTSession

    // MARK: The endpoint's

    /// The QUIC stream exists: a peer's, or one of ours the endpoint has
    /// opened.
    @exclusivity(unchecked) var opened = false
    /// FIN or a reset has been queued, or there is no sending side.
    @exclusivity(unchecked) var sendDone = false
    /// The bytes of the peer's prefix, which count toward its window.
    @exclusivity(unchecked) var prefix: UInt64 = 0
    /// Released to the transport, and no longer the session's.
    @exclusivity(unchecked) var retired = false

    // MARK: Under the endpoint's lock

    /// What arrived and the handler has not read.
    @exclusivity(unchecked) var inbound = ByteBuffer()
    /// Read by the handler, or dropped: what the window may be given back.
    @exclusivity(unchecked) var taken: UInt64 = 0
    /// Taken since the endpoint was last asked to give the window back.
    @exclusivity(unchecked) var owed = 0
    /// The peer finished or reset its side.
    @exclusivity(unchecked) var peerEnded = false
    /// The peer reset its side or asked this one to stop.
    @exclusivity(unchecked) var aborted = false
    /// The handler has been told the read side ended, or ended it.
    @exclusivity(unchecked) var readDone: Bool
    /// The handler may still write.
    @exclusivity(unchecked) var writable: Bool
    @exclusivity(unchecked) var finRequested = false
    @exclusivity(unchecked) var resetCode: UInt64?
    @exclusivity(unchecked) var stopCode: UInt64?
    /// Written by the handler, for the endpoint to send.
    @exclusivity(unchecked) var staged = ByteBuffer()
    /// On the session's list of streams for the endpoint to look at.
    @exclusivity(unchecked) var dirty = false
    /// A task is waiting to read, or for room to write: one each at a time.
    @exclusivity(unchecked) var reading = false
    @exclusivity(unchecked) var writing = false

    /// What the waits wait on. Signalled under the lock, which a wait's
    /// cancellation, run under it as the endpoint cancels a task, never
    /// needs.
    let readable = IOEvent()
    let drained = IOEvent()

    init(id: UInt64, bidirectional: Bool, local: Bool, session: WTSession) {
        self.id = id
        self.bidirectional = bidirectional
        self.local = local
        self.session = session
        // A peer's unidirectional stream is read only; ours, written only.
        writable = bidirectional || local
        readDone = !bidirectional && local
        sendDone = !bidirectional && !local
    }

    deinit {
        inbound.destroy()
        staged.destroy()
    }

    /// Under the lock: ends the handler's waits on the stream.
    func wake() {
        if reading { readable.signal() }
        if writing { drained.signal() }
    }
}

/// A WebTransport session, on its CONNECT stream.
///
/// Its stored properties are `@exclusivity(unchecked)`: each is the
/// endpoint's, or kept under the endpoint's lock.
final class WTSession: @unchecked Sendable {
    /// The identifier of the CONNECT stream, which is also the session's.
    let sessionID: UInt64
    let endpoint: QUICEndpoint
    let connection: H3Connection
    /// The CONNECT stream: kept by its connection, which this keeps.
    unowned(unsafe) let stream: H3Stream
    /// The largest datagram payload the peer takes, after the prefix.
    let datagramLimit: Int

    // MARK: The endpoint's

    /// In the connection's table of sessions.
    @exclusivity(unchecked) var registered = false
    /// Torn down: its streams are abandoned and the table forgets it.
    @exclusivity(unchecked) var torn = false

    // MARK: Under the endpoint's lock

    /// The session has ended, by either side or with the connection. Every
    /// wait on it ends, and nothing more is sent.
    @exclusivity(unchecked) var gone = false
    @exclusivity(unchecked) var closeCode: UInt32 = 0
    @exclusivity(unchecked) var closeReason: [UInt8] = []
    @exclusivity(unchecked) var streams: [UInt64: WTStream] = [:]
    /// Streams the peer opened that the handler has not accepted yet.
    @exclusivity(unchecked) var incoming: [WTStream] = []
    @exclusivity(unchecked) var accepting = false
    let arrivals = IOEvent()
    /// Datagrams are unreliable by definition, so the queue is bounded and
    /// drops the oldest rather than growing or applying backpressure.
    @exclusivity(unchecked) var datagrams: [[UInt8]] = []
    @exclusivity(unchecked) var datagramBytes = 0
    @exclusivity(unchecked) var receiving = false
    let datagramArrived = IOEvent()
    /// Datagrams to send, prefixed.
    @exclusivity(unchecked) var outgoing: [[UInt8]] = []
    /// Streams with something for the endpoint.
    @exclusivity(unchecked) var dirty: [WTStream] = []

    init(stream: H3Stream) {
        sessionID = stream.id
        endpoint = stream.endpoint
        connection = stream.connection
        self.stream = stream
        let quarter = stream.id / 4
        let payload = stream.connection.datagramPayload
        datagramLimit = max(0, payload &- quicVarintLength(quarter))
    }

    /// Under the lock: ends every wait on the session.
    func wakeAll() {
        if accepting { arrivals.signal() }
        if receiving { datagramArrived.signal() }
        for stream in streams.values { stream.wake() }
    }

    /// Under the lock: the session is over. Nothing is sent from here.
    func endLocked() {
        guard !gone else { return }
        gone = true
        wakeAll()
    }

    /// Under the lock: `st` has something for the endpoint.
    func mark(_ st: WTStream) {
        if !st.dirty {
            st.dirty = true
            dirty.append(st)
        }
        endpoint.post(stream)
    }

    /// Under the lock: ends the session with a CLOSE_WEBTRANSPORT_SESSION
    /// capsule and FIN on its CONNECT stream, after what was staged there.
    func closeLocked(code: UInt32, reason: [UInt8]) {
        guard !gone else { return }
        closeCode = code
        closeReason = reason
        let s = stream
        s.staged.writeVarint(HTTP3Capsule.closeWebTransportSession)
        s.staged.writeVarint(UInt64(4 &+ reason.count))
        s.staged.writeByte(UInt8(truncatingIfNeeded: code >> 24))
        s.staged.writeByte(UInt8(truncatingIfNeeded: code >> 16))
        s.staged.writeByte(UInt8(truncatingIfNeeded: code >> 8))
        s.staged.writeByte(UInt8(truncatingIfNeeded: code))
        reason.withUnsafeBufferPointer { if let base = $0.baseAddress, $0.count > 0 { s.staged.write(base, $0.count) } }
        s.bodyEnded = true
        endLocked()
        endpoint.post(s)
    }
}

/// A session accepted by its route, for the stream's task to run once the
/// route has returned (WebTransport.swift).
final class WTAcceptance: @unchecked Sendable {
    let session: WTSession
    let run: CarriedWebTransportHandler

    init(session: WTSession, run: CarriedWebTransportHandler) {
        self.session = session
        self.run = run
    }
}

// MARK: - The stream's task

extension QUICEndpoint {
    /// Runs the session `s`'s route accepted, in `s`'s task: the 200, staged
    /// ahead of whatever the session sends on its CONNECT stream, then the
    /// handler, then the session closed if the handler left it open. False,
    /// with nothing sent, when the connection has as many sessions as it may.
    func runWebTransport(_ s: H3Stream, _ accepted: WTAcceptance) async -> Bool {
        let connection = s.connection
        let admitted = lock.withLock { _ -> Bool in
            guard connection.sessionCount < wtMaxSessions else { return false }
            connection.sessionCount &+= 1
            return true
        }
        guard admitted else { return false }
        let session = accepted.session
        let x = s.x
        // The 200 is the session's start, nothing for --cache-size to keep.
        x.pointee.capture = nil
        x.pointee.cacheInvalidates = 0
        s.outHead.clear()
        encodeHead(s, length: -1, into: &s.outHead)
        lock.withLock { _ in
            s.streamed = true
            s.staged.write(s.outHead.readPointer, s.outHead.readableBytes)
            s.wt = session
            // Cancelled already: the endpoint will not see the session.
            if s.reset { session.endLocked() }
            post(s)
        }
        await accepted.run.run(Request(x), WebTransportSession(state: session))
        lock.withLock { _ in
            // A session the handler left open is closed for it, cleanly.
            session.closeLocked(code: 0, reason: [])
            connection.sessionCount &-= 1
            s.task = nil
            s.taskDone = true
            post(s)
        }
        return true
    }
}

// MARK: - The endpoint's side

extension H3Connection {
    /// The session `s`'s task accepted, now that its 200 has been posted:
    /// in the table, with the streams that named it before it existed.
    func register(_ session: WTSession, on s: H3Stream) {
        guard !session.registered else { return }
        session.registered = true
        s.liveSession = session
        sessions[session.sessionID] = session
        var waiting: [UInt64] = []
        for (id, orphan) in orphans where orphan.session == session.sessionID { waiting.append(id) }
        for id in waiting.sorted() {
            guard let orphan = orphans.removeValue(forKey: id) else { continue }
            if quic.stream(id) != nil {
                attach(id, to: session, bidirectional: orphan.bidirectional, prefix: orphan.prefix)
            }
        }
        // The server is going away: the session ends as soon as it starts.
        if endpoint.stopping { endpoint.lock.withLock { _ in session.closeLocked(code: 0, reason: []) } }
        if let stream = quic.stream(s.id) { readSession(s, stream) }
    }

    /// Takes a peer's stream whose WebTransport prefix has just been read.
    func adopt(_ id: UInt64, sessionID: UInt64, bidirectional: Bool, prefix: Int) {
        if let session = sessions[sessionID], !session.torn {
            attach(id, to: session, bidirectional: bidirectional, prefix: UInt64(prefix))
            return
        }
        // The CONNECT has not been accepted yet, or the session is over.
        // Holding a bounded number of streams covers reordering; past that
        // the peer is told to give up on them rather than left waiting.
        if orphans.count >= wtMaxOrphanStreams {
            refuse(id, code: HTTP3Error.webTransportBufferedStreamRejected)
            return
        }
        orphans[id] = (sessionID, bidirectional, UInt64(prefix))
    }

    private func attach(_ id: UInt64, to session: WTSession, bidirectional: Bool, prefix: UInt64) {
        let st = WTStream(id: id, bidirectional: bidirectional, local: false, session: session)
        st.opened = true
        st.prefix = prefix
        wtStreams[id] = st
        endpoint.lock.withLock { _ in
            session.streams[id] = st
            session.incoming.append(st)
            if session.accepting { session.arrivals.signal() }
        }
        readWT(st)
    }

    /// What arrived on a session's stream, for the handler.
    func readWT(_ st: WTStream) {
        guard let stream = quic.stream(st.id) else { return }
        let n = stream.receive.ready.readableBytes
        let finished = stream.receive.finished
        var dropped = false
        endpoint.lock.withLock { _ in
            if n > 0 {
                if st.readDone || st.session.gone {
                    // Nobody will read it: counted, so the window opens.
                    st.taken &+= UInt64(n)
                    dropped = true
                } else {
                    st.inbound.write(stream.receive.ready.readPointer, n)
                }
            }
            if finished { st.peerEnded = true }
            if st.reading { st.readable.signal() }
        }
        if n > 0 { stream.receive.ready.consume(n) }
        if dropped { quic.extendStreamWindow(st.id, consumed: st.prefix &+ st.taken) }
    }

    /// The peer reset a session's stream, or asked us to stop sending on it.
    func abortedWT(_ st: WTStream, stop: Bool) {
        if stop {
            // The transport resets our side in answer.
            st.sendDone = true
        }
        endpoint.lock.withLock { _ in
            st.aborted = true
            if stop {
                st.writable = false
                st.staged.clear()
            } else {
                st.peerEnded = true
            }
            st.wake()
        }
        pumpWT(st)
    }

    /// The streams of the session on `s`: those it opened, what it wrote,
    /// what it read, and the datagrams it sent.
    func serviceSession(_ session: WTSession, on s: H3Stream) {
        register(session, on: s)
        openReserved()
        let (dirty, outgoing) = endpoint.lock.withLock { _ -> ([WTStream], [[UInt8]]) in
            let d = session.dirty
            let o = session.outgoing
            if !d.isEmpty {
                for st in d { st.dirty = false }
                session.dirty.removeAll(keepingCapacity: true)
            }
            if !o.isEmpty { session.outgoing.removeAll(keepingCapacity: true) }
            return (d, o)
        }
        for datagram in outgoing {
            datagram.withUnsafeBufferPointer { _ = quic.sendDatagram($0.baseAddress!, $0.count) }
        }
        for st in dirty { pumpWT(st) }
    }

    /// Opens the streams handlers reserved, in the order they reserved them.
    func openReserved() {
        let list = endpoint.lock.withLock { _ -> [WTStream] in
            guard !opening.isEmpty else { return [] }
            let l = opening
            opening.removeAll(keepingCapacity: true)
            return l
        }
        for st in list {
            guard let id = quic.openStream(unidirectional: !st.bidirectional), id == st.id else {
                // Reservations stay within the peer's limit and are opened in
                // order, so this is a bug, and the stream is simply dead.
                Log.error("webtransport: stream \(st.id) could not be opened as reserved")
                endpoint.lock.withLock { _ in
                    st.writable = false
                    st.readDone = true
                    st.wake()
                }
                continue
            }
            st.opened = true
            if st.session.torn {
                quic.resetStream(id, code: HTTP3Error.webTransportSessionGone)
                quic.releaseStream(id)
                st.retired = true
                continue
            }
            wtStreams[id] = st
            pumpWT(st)
        }
    }

    /// Moves what the handler wrote on `st` onto its QUIC stream, as far as
    /// the stream's send budget allows, then its end; gives back the window
    /// the handler has read; and lets the stream go once both sides are done.
    func pumpWT(_ st: WTStream) {
        guard st.opened, !st.retired, let stream = quic.stream(st.id) else { return }
        var room = settings.sendBudget &- stream.send.data.readableBytes
        let low = settings.low
        let sendDone = st.sendDone
        let (fin, reset, stop, taken, readDone) = endpoint.lock.withLock {
            _ -> (Bool, UInt64?, UInt64?, UInt64, Bool) in
            if !sendDone {
                let staged = st.staged.readableBytes
                if staged > 0 && room > 0 {
                    let n = min(room, staged)
                    quic.send(st.id, st.staged.readPointer, n, fin: false)
                    st.staged.consume(n)
                    room &-= n
                    if st.writing && st.staged.readableBytes <= low { st.drained.signal() }
                }
            }
            let reset = st.resetCode
            let stop = st.stopCode
            st.resetCode = nil
            st.stopCode = nil
            let fin = st.finRequested && st.staged.readableBytes == 0
            return (fin, reset, stop, st.taken, st.readDone)
        }
        if let reset, !st.sendDone {
            st.sendDone = true
            quic.resetStream(st.id, code: reset)
        } else if fin && !st.sendDone {
            st.sendDone = true
            quic.send(st.id, emptyBlock, 0, fin: true)
        }
        if let stop { quic.stopSending(st.id, code: stop) }
        // Reading is what opens the window again.
        if !readDone || stop != nil { quic.extendStreamWindow(st.id, consumed: st.prefix &+ taken) }
        if st.sendDone && readDone { retire(st) }
    }

    /// Lets the transport forget a stream neither side can use again.
    private func retire(_ st: WTStream) {
        guard !st.retired else { return }
        st.retired = true
        wtStreams[st.id] = nil
        quic.releaseStream(st.id)
        endpoint.lock.withLock { _ in _ = st.session.streams.removeValue(forKey: st.id) }
    }

    /// Reads the capsules on a live session's CONNECT stream.
    func readSession(_ s: H3Stream, _ stream: QUICStream) {
        // Until the session's 200 has been posted, what the client sends
        // waits on the stream, held back by its window.
        guard let session = s.liveSession, !session.torn else { return }
        while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            // Part-way through a capsule being skipped.
            if s.frameRemaining > 0 {
                let take = min(s.frameRemaining, available)
                stream.receive.ready.consume(take)
                s.frameRemaining &-= take
                continue
            }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else {
                if available >= 16 { return abort(s, code: HTTP3Error.messageError) }
                break
            }
            let header = r.offset
            if type == HTTP3Capsule.closeWebTransportSession {
                // A 32-bit application code and a UTF-8 reason, read whole.
                if length < 4 || length > 4 &+ wtMaxCloseReason { return abort(s, code: HTTP3Error.messageError) }
                if r.remaining < length { break }
                let p = base + header
                let code = UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
                let reason = [UInt8](UnsafeBufferPointer(start: p + 4, count: length &- 4))
                stream.receive.ready.consume(header &+ length)
                peerClosed(session, s, code: code, reason: reason)
                // Nothing may follow the close.
                stream.receive.ready.clear()
                return
            }
            // DRAIN and anything unknown are advisory: a capsule nobody
            // understands is skipped, which is what makes them extensible.
            stream.receive.ready.consume(header)
            s.frameRemaining = length
        }
        if stream.receive.finished && stream.receive.ready.readableBytes == 0 {
            // FIN without a close: the session ends all the same.
            peerClosed(session, s, code: 0, reason: [])
            return
        }
        quic.extendStreamWindow(s.id, consumed: stream.receive.received &- UInt64(stream.receive.ready.readableBytes))
    }

    /// The peer closed the session: its handler sees the code and reason,
    /// and the CONNECT stream ends from this side too once what is staged
    /// has gone.
    private func peerClosed(_ session: WTSession, _ s: H3Stream, code: UInt32, reason: [UInt8]) {
        endpoint.lock.withLock { _ in
            if !session.gone {
                session.closeCode = code
                session.closeReason = reason
                session.endLocked()
            }
            s.bodyEnded = true
        }
        pump(s)
    }

    /// The session on `s` is over: every stream it owned is abandoned, and
    /// the peer told which; every wait on it ends.
    func endSession(_ session: WTSession) {
        guard !session.torn else { return }
        session.torn = true
        let owned = endpoint.lock.withLock { _ -> [WTStream] in
            session.endLocked()
            let list = Array(session.streams.values)
            session.streams.removeAll()
            session.incoming.removeAll()
            session.datagrams.removeAll()
            session.outgoing.removeAll()
            for st in session.dirty { st.dirty = false }
            session.dirty.removeAll()
            return list
        }
        for st in owned where st.opened && !st.retired {
            st.retired = true
            wtStreams[st.id] = nil
            if !st.sendDone { quic.resetStream(st.id, code: HTTP3Error.webTransportSessionGone) }
            if let stream = quic.stream(st.id), !stream.receive.finished, !(st.local && !st.bidirectional) {
                quic.stopSending(st.id, code: HTTP3Error.webTransportSessionGone)
                stream.receive.ready.clear()
            }
            quic.releaseStream(st.id)
        }
        guard session.registered else { return }
        if sessions[session.sessionID] === session { sessions[session.sessionID] = nil }
        // Streams that named it and were never claimed go with it.
        var named: [UInt64] = []
        for (id, orphan) in orphans where orphan.session == session.sessionID { named.append(id) }
        for id in named {
            orphans[id] = nil
            refuse(id, code: HTTP3Error.webTransportSessionGone)
        }
    }

    /// Datagrams, each to the session its quarter stream identifier names;
    /// one that names no live session has nowhere to go, and dropping it is
    /// what unreliable means.
    func receiveDatagrams() {
        if sessions.isEmpty {
            quic.incomingDatagrams.removeAll(keepingCapacity: true)
            return
        }
        let arrived = quic.incomingDatagrams
        quic.incomingDatagrams.removeAll(keepingCapacity: true)
        for payload in arrived {
            var quarter: UInt64 = 0
            var offset = 0
            payload.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                var r = QUICReader(base, buffer.count)
                guard let q = r.varint() else { return }
                quarter = q
                offset = r.offset
            }
            guard offset > 0, quarter <= UInt64.max / 4, let session = sessions[quarter &* 4] else { continue }
            endpoint.lock.withLock { _ in
                guard !session.gone else { return }
                session.datagrams.append(Array(payload[offset...]))
                session.datagramBytes &+= payload.count &- offset
                while session.datagrams.count > wtMaxQueuedDatagrams
                        || session.datagramBytes > wtMaxQueuedDatagramBytes {
                    // Unreliable in, unreliable out: a handler too slow to
                    // read its datagrams loses the oldest, not the newest.
                    session.datagramBytes &-= session.datagrams.removeFirst().count
                }
                if session.receiving { session.datagramArrived.signal() }
            }
        }
    }

    /// The peer's stream limits, for handlers reserving streams.
    func refreshStreamLimits() {
        let uni = quic.peerStreamLimit(unidirectional: true)
        let bidi = quic.peerStreamLimit(unidirectional: false)
        endpoint.lock.withLock { _ in
            localLimitUni = uni
            localLimitBidi = bidi
        }
    }

    /// Shutdown: every session is closed, cleanly.
    func closeSessions() {
        guard !sessions.isEmpty else { return }
        let live = Array(sessions.values)
        endpoint.lock.withLock { _ in
            for session in live { session.closeLocked(code: 0, reason: []) }
        }
        for session in live { pump(session.stream) }
    }
}
