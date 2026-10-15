//===----------------------------------------------------------------------===//
// One HTTP/3 connection: what the endpoint keeps on top of a QUIC connection.
//
// Most of what HTTP/2 needed a framing layer for, QUIC already does. There is
// no stream identifier in a frame, no flow control, no priority and no
// RST_STREAM: a frame belongs to the stream it arrived on, and the rest is the
// transport's business. What is left is a request on a bidirectional stream,
// headers compressed with QPACK, and a handful of unidirectional streams
// carrying settings and compressor state.
//
// The unidirectional streams are the awkward part, because a stream's type is
// its first varint and a stream can be opened long before anything is sent on
// it. A type nobody recognises is not an error -- it is how extensions arrive
// (WebTransport's among them, when it is served) -- and the peer is told to
// stop sending on it.
//
// QPACK runs with a dynamic table of capacity zero, which is a promise as much
// as a limit: no header block on the connection ever waits for another stream,
// the head-of-line blocking HTTP/3 exists to remove. It also means encoding
// needs no state, so a request's task encodes its own answer.
//
// Everything here is the endpoint task's alone (HTTP3.swift), but for what a
// stream shares with its task, under the endpoint's lock (HTTP3Stream.swift).
// The defences are Garuda 1's: the frame and header limits, the critical
// streams, and the rapid-reset defence (CVE-2023-44487's shape over QUIC),
// which bounds the ratio of requests cancelled to requests answered.
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import Synchronization
import Vega

final class H3Connection {
    unowned(unsafe) let endpoint: QUICEndpoint
    let quic: QUICConnection
    /// Where the peer is, and which of our addresses it wrote to: what the
    /// connection's datagrams are sent to and from.
    var peer: SocketAddress
    var local: SocketAddress?
    let localCID: QUICConnectionID
    let originalDCID: QUICConnectionID
    /// On the endpoint's list of connections to look at.
    var touched = false

    // MARK: HTTP/3

    /// The handshake finished and the control streams are open.
    var began = false
    /// The connection has ended, as far as its requests are concerned.
    var closed = false
    /// The peer's address, as every request on the connection reports it.
    var remote = SocketPeer.none
    var decoder = QPACKDecoder()
    /// Cookie crumbs being joined.
    var cookies = ByteBuffer()

    /// Our unidirectional streams; `UInt64.max` until opened.
    var controlOut = UInt64.max
    var encoderOut = UInt64.max
    var decoderOut = UInt64.max
    /// The peer's, so a second of any kind can be refused.
    var peerControl = UInt64.max
    var peerEncoder = UInt64.max
    var peerDecoder = UInt64.max
    var settingsSeen = false

    /// Request streams the endpoint is not done with.
    var streams: [UInt64: H3Stream] = [:]
    var spare: [H3Stream] = []
    /// Every stream made, so they live as long as the connection.
    var made: [H3Stream] = []
    /// Request tasks running.
    var tasks = 0
    /// How many requests this peer may still cancel before it has had any
    /// answered.
    var resetBudget: Int
    /// The highest request stream taken, or -1.
    var highestRequest: Int64 = -1
    /// GOAWAY was sent: requests on this stream or later are refused.
    var goawayID = UInt64.max

    init(endpoint: QUICEndpoint, quic: QUICConnection, peer: SocketAddress, local: SocketAddress?,
         localCID: QUICConnectionID, originalDCID: QUICConnectionID) {
        self.endpoint = endpoint
        self.quic = quic
        self.peer = peer
        self.local = local
        self.localCID = localCID
        self.originalDCID = originalDCID
        resetBudget = endpoint.settings.resetBudget
        decoder.maximumFieldSectionSize = endpoint.settings.maxHeadSize
    }

    deinit {
        decoder.destroy()
        cookies.destroy()
    }

    var settings: HTTP3Limits { endpoint.settings }

    /// A connection error: CONNECTION_CLOSE with an HTTP/3 code.
    func fail(_ code: UInt64) {
        Log.debug("h3 connection error, code \(code)")
        quic.close(code, application: true)
    }

    // MARK: - Events

    /// Handles what the transport reported since the last look.
    func handleEvents(nowMs now: UInt64) {
        quic.drainEvents { event in
            switch event.kind {
            case .handshakeComplete:
                begin()
            case .streamReadable, .streamFinished:
                guard began, !closed else { return }
                let id = event.streamID
                if QUICStreamKind.isServerInitiated(id) { return }
                if QUICStreamKind.isUnidirectional(id) {
                    readUnidirectional(id)
                } else {
                    readRequest(id, nowMs: now)
                }
            case .streamReset, .stopSending:
                guard began, !closed else { return }
                aborted(event.streamID, code: event.code)
            case .streamWritable:
                if let s = streams[event.streamID] { pump(s) }
            case .datagram:
                // Not offered (QUICEndpoint.quicConfig); WebTransport's
                // when it is.
                quic.incomingDatagrams.removeAll(keepingCapacity: true)
            case .closed:
                closeHTTP()
            }
        }
        if !quic.events.isEmpty { endpoint.touch(self) }
    }

    // MARK: - Setting up

    /// The handshake is done: open our unidirectional streams and say what
    /// we accept.
    func begin() {
        guard !began else { return }
        // Only h3 is served. Anything else negotiated is a protocol this
        // server does not speak, and the transport says so.
        if quic.selectedALPN != h3ALPN {
            fail(HTTP3Error.generalProtocolError)
            return
        }
        began = true
        remote = SocketPeer(address: peer.host, port: peer.port ?? 0)
        guard let control = quic.openStream(unidirectional: true) else {
            fail(HTTP3Error.streamCreationError)
            return
        }
        controlOut = control
        var out = ByteBuffer(capacity: 64)
        defer { out.destroy() }
        var body = ByteBuffer(capacity: 32)
        defer { body.destroy() }
        // A dynamic table capacity of zero, and so no stream ever blocked on
        // one; and the header limit HTTP/1 and HTTP/2 hold a request to.
        body.writeVarint(HTTP3Setting.qpackMaxTableCapacity)
        body.writeVarint(0)
        body.writeVarint(HTTP3Setting.qpackBlockedStreams)
        body.writeVarint(0)
        body.writeVarint(HTTP3Setting.maxFieldSectionSize)
        body.writeVarint(UInt64(settings.maxHeadSize))
        // Extended CONNECT (RFC 9220) -- WebSockets and WebTransport over
        // HTTP/3 -- is not offered: neither is served yet.
        out.writeVarint(HTTP3StreamType.control)
        out.writeVarint(HTTP3FrameType.settings)
        out.writeVarint(UInt64(body.readableBytes))
        out.write(body.readPointer, body.readableBytes)
        quic.send(control, out.readPointer, out.readableBytes, fin: false)

        // The QPACK streams carry nothing from us -- nothing is ever
        // inserted -- but a peer is entitled to expect them to exist.
        if let id = quic.openStream(unidirectional: true) {
            encoderOut = id
            sendType(HTTP3StreamType.qpackEncoder, on: id)
        }
        if let id = quic.openStream(unidirectional: true) {
            decoderOut = id
            sendType(HTTP3StreamType.qpackDecoder, on: id)
        }
        if endpoint.stopping { goaway() }
    }

    private func sendType(_ type: UInt64, on id: UInt64) {
        var head = ByteBuffer(capacity: 8)
        defer { head.destroy() }
        head.writeVarint(type)
        quic.send(id, head.readPointer, head.readableBytes, fin: false)
    }

    // MARK: - Unidirectional streams

    func readUnidirectional(_ id: UInt64) {
        guard let stream = quic.stream(id) else { return }
        if stream.released {
            // One we told to stop: whatever is still arriving is dropped.
            stream.receive.ready.clear()
            return
        }
        if id != peerControl && id != peerEncoder && id != peerDecoder {
            // Its first bytes: the type. Nothing is consumed until the whole
            // varint is there, so a type split across packets simply waits.
            let available = stream.receive.ready.readableBytes
            if available == 0 {
                // Ended, or reset, before it said what it was.
                if stream.receive.finished { quic.releaseStream(id) }
                return
            }
            var r = QUICReader(UnsafePointer(stream.receive.ready.readPointer), available)
            guard let type = r.varint() else { return }
            stream.receive.ready.consume(r.offset)
            switch type {
            case HTTP3StreamType.control:
                if peerControl != .max { return fail(HTTP3Error.streamCreationError) }
                peerControl = id
            case HTTP3StreamType.qpackEncoder:
                if peerEncoder != .max { return fail(HTTP3Error.streamCreationError) }
                peerEncoder = id
            case HTTP3StreamType.qpackDecoder:
                if peerDecoder != .max { return fail(HTTP3Error.streamCreationError) }
                peerDecoder = id
            case HTTP3StreamType.push:
                // Only a server pushes.
                return fail(HTTP3Error.streamCreationError)
            default:
                // An extension's stream -- WebTransport's (0x54) among them,
                // until it is served -- or a reserved type: the peer is told
                // we are not interested rather than left waiting, and the
                // stream is let go of, so its credit comes back.
                stream.receive.ready.clear()
                quic.stopSending(id, code: HTTP3Error.streamCreationError)
                quic.releaseStream(id)
                return
            }
        }
        if id == peerControl {
            readControl(stream)
        } else if id == peerEncoder {
            // With a table capacity of zero the peer has only one thing it
            // may say here: Set Dynamic Table Capacity to zero, 0x20 (RFC
            // 9204 section 4.3.1). Anything else is an error, not noise.
            let ready = stream.receive.ready
            for i in 0..<ready.readableBytes where ready.readPointer[i] != 0x20 {
                return fail(HTTP3Error.qpackEncoderStreamError)
            }
            stream.receive.ready.clear()
        } else if id == peerDecoder {
            // Acknowledgements for a table we never fill.
            stream.receive.ready.clear()
        }
        guard !quic.isClosed && quic.status != .closing else { return }
        // A critical stream may not end while the connection lasts.
        if stream.receive.finished && stream.receive.ready.readableBytes == 0 {
            return fail(HTTP3Error.closedCriticalStream)
        }
        quic.extendStreamWindow(id, consumed: stream.receive.received &- UInt64(stream.receive.ready.readableBytes))
    }

    private func readControl(_ stream: QUICStream) {
        while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else { break }
            // A control frame is read whole; none of ours is large, and a
            // peer's that is cannot be one we want.
            if length > 64 * 1024 { return fail(HTTP3Error.excessiveLoad) }
            if r.remaining < length { break }
            let header = r.offset
            if !settingsSeen && type != HTTP3FrameType.settings { return fail(HTTP3Error.missingSettings) }
            switch type {
            case HTTP3FrameType.settings:
                if settingsSeen { return fail(HTTP3Error.frameUnexpected) }
                if !applySettings(base + header, length) { return }
                settingsSeen = true
            case HTTP3FrameType.goaway:
                // A client's GOAWAY limits pushes, which this server never
                // makes; its requests go on being answered.
                break
            case HTTP3FrameType.maxPushID, HTTP3FrameType.cancelPush:
                break
            case HTTP3FrameType.data, HTTP3FrameType.headers, HTTP3FrameType.pushPromise:
                // These belong on a request stream and nowhere else.
                return fail(HTTP3Error.frameUnexpected)
            default:
                if HTTP3FrameType.isReservedFromHTTP2(type) { return fail(HTTP3Error.frameUnexpected) }
                // Unknown types are skipped: that is how new frames deploy.
            }
            stream.receive.ready.consume(header &+ length)
        }
    }

    /// False when the settings were refused and the connection with them.
    private func applySettings(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var r = QUICReader(p, n)
        var seen: [UInt64] = []
        while !r.isEmpty {
            guard let id = r.varint(), let value = r.varint() else {
                fail(HTTP3Error.frameError)
                return false
            }
            // HTTP/2's identifiers are reserved, and a setting may be given
            // once (RFC 9114 section 7.2.4).
            if HTTP3Setting.isReservedFromHTTP2(id) || seen.contains(id) {
                fail(HTTP3Error.settingsError)
                return false
            }
            seen.append(id)
            switch id {
            case HTTP3Setting.enableConnectProtocol, HTTP3Setting.h3Datagram:
                if value > 1 {
                    fail(HTTP3Error.settingsError)
                    return false
                }
            default:
                // The QPACK table the peer allows us is never used; the field
                // section size it takes is advisory; the rest is ignorable.
                break
            }
        }
        return true
    }

    // MARK: - Request streams

    /// Reads what arrived on request stream `id`.
    func readRequest(_ id: UInt64, nowMs now: UInt64) {
        guard let stream = quic.stream(id) else { return }
        if stream.released {
            // Answered, refused or cancelled: what still arrives is dropped.
            stream.receive.ready.clear()
            return
        }
        var s = streams[id]
        reading: while true {
            let available = stream.receive.ready.readableBytes
            if available == 0 { break }
            // Mid-frame: DATA, or a frame being skipped, continues into
            // whatever arrived.
            if let current = s, current.frameRemaining > 0 {
                let take = min(current.frameRemaining, available)
                if current.frameType == HTTP3FrameType.data {
                    if !appendBody(current, stream.receive.ready.readPointer, take, nowMs: now) { return }
                }
                stream.receive.ready.consume(take)
                current.frameRemaining &-= take
                continue
            }
            let base = UnsafePointer(stream.receive.ready.readPointer)
            var r = QUICReader(base, available)
            guard let type = r.varint(), let length = r.varintAsInt() else {
                // Two varints are sixteen bytes at most.
                if available >= 16 { return fail(HTTP3Error.frameError) }
                break
            }
            let header = r.offset
            if HTTP3FrameType.isReservedFromHTTP2(type) { return fail(HTTP3Error.frameUnexpected) }
            switch type {
            case HTTP3FrameType.headers:
                // A header block is decoded whole -- QPACK has no way to
                // resume -- so one too large to take is refused rather than
                // waited for: its stream's window would never let it arrive.
                if length > settings.maxHeadSize &* 2 {
                    if let current = s { abort(current, code: HTTP3Error.excessiveLoad) } else {
                        refuse(id, code: HTTP3Error.excessiveLoad)
                    }
                    return
                }
                if available &- header < length { break reading }
                if let current = s {
                    // A second HEADERS is the trailer section, and the last
                    // thing on the stream: nothing downstream wants it, but
                    // it still has to decode.
                    if current.trailersSeen || !current.receiving && !current.refused {
                        return fail(HTTP3Error.frameUnexpected)
                    }
                    var decoded = true
                    var tooLarge = false
                    do {
                        try decoder.decode(base + header, length) { _ in }
                    } catch QPACKError.tooLarge {
                        tooLarge = true
                    } catch {
                        decoded = false
                    }
                    // Too large is the request's failing, as its head's is.
                    if tooLarge { return abort(current, code: HTTP3Error.excessiveLoad) }
                    if !decoded { return fail(HTTP3Error.qpackDecompressionFailed) }
                    current.trailersSeen = true
                    stream.receive.ready.consume(header &+ length)
                } else {
                    guard let started = beginRequest(id, base + header, length, nowMs: now), started.inTable else {
                        // Refused, answered at once (413), or the connection
                        // failed: the rest of the stream is nobody's.
                        stream.receive.ready.clear()
                        return
                    }
                    stream.receive.ready.consume(header &+ length)
                    s = started
                }
            case HTTP3FrameType.data:
                guard let current = s else { return fail(HTTP3Error.frameUnexpected) }
                if current.trailersSeen { return fail(HTTP3Error.frameUnexpected) }
                stream.receive.ready.consume(header)
                current.frameType = type
                current.frameRemaining = length
            case HTTP3FrameType.settings, HTTP3FrameType.goaway, HTTP3FrameType.maxPushID,
                 HTTP3FrameType.cancelPush, HTTP3FrameType.pushPromise:
                return fail(HTTP3Error.frameUnexpected)
            default:
                // Unknown frame types are skipped, which is what makes new
                // frames deployable. Before the request, one is skipped only
                // whole, and one larger than the window could never be.
                if let current = s {
                    stream.receive.ready.consume(header)
                    current.frameType = type
                    current.frameRemaining = length
                } else if available &- header >= length {
                    stream.receive.ready.consume(header &+ length)
                } else {
                    if header &+ length > settings.streamWindow { return refuse(id, code: HTTP3Error.excessiveLoad) }
                    break reading
                }
            }
        }
        guard let current = s else {
            // Ended without a request (RFC 9114 section 4.1): nothing, or a
            // frame the end cut short.
            if stream.receive.finished { refuse(id, code: HTTP3Error.requestIncomplete) }
            return
        }
        guard current.inTable else { return }
        // A frame the stream's end cut short (RFC 9114 section 7.1).
        if stream.receive.finished && stream.receive.ready.readableBytes > 0 { return fail(HTTP3Error.frameError) }
        if stream.receive.finished && stream.receive.ready.readableBytes == 0 && (current.receiving || current.refused) {
            if current.frameRemaining > 0 { return fail(HTTP3Error.frameError) }
            if current.refused {
                current.refused = false
                return
            }
            // RFC 9114 section 4.1.2: a body that disagrees with the length
            // it declared is malformed.
            let head = current.x.pointee.head
            if head.flags.contains(.hasContentLength) && head.contentLength != current.received {
                return abort(current, code: HTTP3Error.messageError)
            }
            run(current)
            return
        }
        extend(stream, current)
    }

    /// Opens the stream's window by what has been read: the body is the
    /// handler's once it is here, so a byte buffered is a byte consumed, and
    /// the body limit bounds the buffer.
    private func extend(_ stream: QUICStream, _ s: H3Stream?) {
        guard let s, s.receiving || s.refused else { return }
        quic.extendStreamWindow(s.id, consumed: stream.receive.received &- UInt64(stream.receive.ready.readableBytes))
    }

    /// Takes body bytes. False when the stream has been ended for them.
    private func appendBody(_ s: H3Stream, _ p: UnsafePointer<UInt8>, _ n: Int, nowMs now: UInt64) -> Bool {
        s.lastActivity = now
        s.received &+= n
        let head = s.x.pointee.head
        if head.flags.contains(.hasContentLength) && s.received > head.contentLength {
            abort(s, code: HTTP3Error.messageError)
            return false
        }
        // Answered already: the bytes are counted and checked, and dropped.
        if s.refused || !s.receiving { return true }
        // Cumulative: the limit is on the upload. The 413 may have ended the
        // stream already, and taken what was buffered on it.
        if s.received > s.bodyLimit {
            refuseBody(s)
            return s.inTable
        }
        if n > 0 { s.body.write(p, n) }
        return true
    }

    /// Fills a stream for the request in `block`. Nil when it was refused,
    /// or the connection failed.
    private func beginRequest(_ id: UInt64, _ block: UnsafePointer<UInt8>, _ length: Int,
                              nowMs now: UInt64) -> H3Stream? {
        // After GOAWAY, a request it said would not be served is not.
        if id >= goawayID || endpoint.stopping && goawayID == .max {
            refuse(id, code: HTTP3Error.requestRejected)
            return nil
        }
        let s = take(id)
        var tooLarge = false
        let outcome = buildRequestHead(s.x, into: &s.head, cookies: &cookies, limits: endpoint.limits,
                                       acceptsConnectProtocol: false, major: 3) { field throws in
            do {
                try decoder.decode(block, length, field)
            } catch QPACKError.tooLarge {
                tooLarge = true
                throw QPACKError.tooLarge
            }
        }
        switch outcome {
        case .compression where tooLarge:
            // Past the field section size. With no dynamic table there is no
            // compressor state to lose, so it is this request's failing, not
            // the connection's: answered 431, as on HTTP/1.1, and whatever
            // follows on the stream dropped.
            streams[id] = s
            s.inTable = true
            if Int64(id) > highestRequest { highestRequest = Int64(id) }
            s.refused = true
            s.x.pointee.answer(431, nil, 0)
            endpoint.frameWhole(s, headParsed: false)
            endpoint.lock.withLock { _ in s.answerReady = true }
            pump(s)
            return s
        case .compression:
            recycle(s)
            fail(HTTP3Error.qpackDecompressionFailed)
            return nil
        case .malformed:
            recycle(s)
            refuse(id, code: HTTP3Error.messageError)
            return nil
        case .ok:
            break
        }
        streams[id] = s
        s.inTable = true
        if Int64(id) > highestRequest { highestRequest = Int64(id) }
        s.receiving = true
        s.lastActivity = now
        let app = endpoint.app
        s.bodyLimit = app.hasBodyLimits ? bodyLimit(s.x, app, endpoint.limits, matched: &s.matched)
            : endpoint.limits.maxBodySize
        // A declared length past the limit is refused before a byte of the
        // body is taken.
        let head = s.x.pointee.head
        if head.flags.contains(.hasContentLength) && head.contentLength > s.bodyLimit { refuseBody(s) }
        return s
    }

    /// A stream for request `id`, kept or new.
    private func take(_ id: UInt64) -> H3Stream {
        let s: H3Stream
        if let kept = spare.popLast() {
            s = kept
            s.x.pointee.remote = remote
        } else {
            let limits = endpoint.limits
            s = H3Stream(connection: self, endpoint: endpoint, maxHeaders: limits.maxHeaders)
            s.x.pointee.application = Unmanaged.passUnretained(endpoint.app)
            s.x.pointee.secure = true
            s.x.pointee.serverFields = limits.quicFields
            s.x.pointee.trust = limits.trust
            s.x.pointee.site = limits.site
            s.x.pointee.compress = limits.compress
            s.x.pointee.compressMinimum = limits.compressMinimum
            s.x.pointee.websocketLimits = limits.websocket
            made.append(s)
        }
        s.id = id
        s.isSpare = false
        s.inTable = false
        s.taskActive = false
        s.receiving = false
        s.refused = false
        s.trailersSeen = false
        s.frameType = 0
        s.frameRemaining = 0
        s.received = 0
        s.matched = -1
        s.sendEnded = false
        s.headSent = false
        s.bodySent = 0
        endpoint.lock.withLock { _ in
            s.reset = false
            s.task = nil
            s.taskDone = false
            s.answerReady = false
            s.bodyLength = 0
            s.streamed = false
            s.staged.clear()
            s.bodyEnded = false
            s.bodyFailed = false
        }
        s.x.pointee.reset()
        s.head.clear()
        // A buffer a large body grew is not kept for every later stream.
        if s.body.allocatedCapacity > 1 << 20 { s.body.destroy() } else { s.body.clear() }
        return s
    }

    /// A body past its limit: answered 413, as on HTTP/1.1, and the client
    /// then told to stop sending the rest (RFC 9114 section 4.1.2).
    private func refuseBody(_ s: H3Stream) {
        s.receiving = false
        s.refused = true
        s.x.pointee.answer(413, nil, 0)
        endpoint.frameWhole(s)
        endpoint.lock.withLock { _ in s.answerReady = true }
        pump(s)
    }

    /// The request is whole: its handler runs in a pooled task.
    private func run(_ s: H3Stream) {
        s.receiving = false
        let x = s.x
        if s.body.readableBytes > 0 {
            x.pointee.body = UnsafePointer(s.body.readPointer)
            x.pointee.bodyCount = s.body.readableBytes
            x.pointee.bodyLimit = s.bodyLimit
        }
        s.taskActive = true
        tasks &+= 1
        if endpoint.runsInline(s) {
            endpoint.inline.append(s)
        } else {
            endpoint.pool.run(s)
        }
    }

    // MARK: - Cancellation

    /// The peer reset stream `id`, or asked us to stop sending on it.
    func aborted(_ id: UInt64, code: UInt64) {
        if id == peerControl || id == peerEncoder || id == peerDecoder {
            // A critical stream: losing it loses the connection.
            return fail(HTTP3Error.closedCriticalStream)
        }
        guard QUICStreamKind.isBidirectional(id) && QUICStreamKind.isClientInitiated(id) else {
            // A unidirectional stream not yet typed, or one already let go.
            if QUICStreamKind.isClientInitiated(id), let stream = quic.stream(id), !stream.released {
                stream.receive.ready.clear()
                quic.releaseStream(id)
            }
            return
        }
        guard let stream = quic.stream(id), !stream.released else { return }
        let s = streams[id]
        if let s, s.sendEnded { return }
        // The same accounting HTTP/2 keeps, for the same attack. A request
        // costs a header decode and a task whatever happens to it afterwards,
        // and cancelling it hands the stream credit straight back, so a peer
        // that only ever cancels could keep the server busy while never
        // holding more than one stream open. Each answered request buys one
        // cancellation back; a cancellation of a request already answered is
        // a race, not a reset, and is charged nothing.
        resetBudget &-= 1
        if resetBudget <= 0 {
            Log.warning("h3 peer cancelled far more requests than it completed")
            return fail(HTTP3Error.excessiveLoad)
        }
        if let s {
            abort(s, code: HTTP3Error.requestCancelled)
        } else {
            refuse(id, code: HTTP3Error.requestCancelled)
        }
    }

    /// Ends `s` now, both ways, its task cancelled and its answer dropped.
    func abort(_ s: H3Stream, code: UInt64) {
        endpoint.lock.withLock { _ in
            s.reset = true
            s.task?.cancel()
            s.resumeWaiters(false)
        }
        if !s.sendEnded {
            s.sendEnded = true
            quic.resetStream(s.id, code: code)
        }
        if let stream = quic.stream(s.id), !stream.receive.finished {
            quic.stopSending(s.id, code: code)
        }
        quic.stream(s.id)?.receive.ready.clear()
        finish(s)
    }

    /// Refuses stream `id` before it has a request: reset, told to stop
    /// sending, and let go of.
    func refuse(_ id: UInt64, code: UInt64) {
        quic.resetStream(id, code: code)
        if let stream = quic.stream(id) {
            if !stream.receive.finished { quic.stopSending(id, code: code) }
            stream.receive.ready.clear()
        }
        quic.releaseStream(id)
    }

    /// The endpoint is done with `s`'s QUIC stream: let it go, so the
    /// transport can retire it and give the peer its credit back.
    private func finish(_ s: H3Stream) {
        guard s.inTable else { return }
        s.inTable = false
        streams[s.id] = nil
        quic.releaseStream(s.id)
        if !s.taskActive { recycle(s) }
    }

    private func recycle(_ s: H3Stream) {
        guard !s.isSpare else { return }
        s.isSpare = true
        s.inTable = false
        spare.append(s)
    }

    // MARK: - Answers

    /// A task posted `s`: an answer, body bytes, an end, or its own end.
    func posted(_ s: H3Stream) {
        let done = endpoint.lock.withLock { _ -> Bool in
            s.queued = false
            return s.taskDone
        }
        if done && s.taskActive {
            s.taskActive = false
            tasks &-= 1
        }
        if s.inTable && !closed {
            pump(s)
        } else if !s.inTable && !s.taskActive {
            recycle(s)
        }
    }

    /// Moves what `s` has to send onto its QUIC stream, as far as the
    /// stream's send budget allows -- the rest goes as acknowledgements free
    /// room, which the transport reports as the stream being writable -- and
    /// ends the stream once everything has gone.
    func pump(_ s: H3Stream) {
        guard s.inTable, !s.sendEnded, let stream = quic.stream(s.id) else { return }
        var room = settings.sendBudget &- stream.send.data.readableBytes
        let low = settings.low
        let (whole, streamed, ended, failed, clear) = endpoint.lock.withLock { _ -> (Bool, Bool, Bool, Bool, Bool) in
            let staged = s.staged.readableBytes
            if staged > 0 && room > 0 {
                let n = min(room, staged)
                quic.send(s.id, s.staged.readPointer, n, fin: false)
                s.staged.consume(n)
                room &-= n
                // Fallen to the low-water mark: its writers may go on.
                if s.staged.readableBytes <= low { s.resumeWaiters(true) }
            }
            return (s.answerReady, s.streamed, s.bodyEnded, s.bodyFailed, s.staged.readableBytes == 0)
        }
        guard clear else { return }
        if whole {
            if !s.headSent {
                s.headSent = true
                quic.send(s.id, s.outHead.readPointer, s.outHead.readableBytes, fin: false)
            }
            let length = s.bodyLength
            if s.bodySent < length && room > 0 {
                let n = min(room, length &- s.bodySent)
                quic.send(s.id, s.x.pointee.responseBody.readPointer + s.bodySent, n, fin: false)
                s.bodySent &+= n
            }
            if s.bodySent == length { endSend(s, resetCode: nil) }
        } else if streamed && ended {
            // A body cut off part-way cannot be ended honestly.
            endSend(s, resetCode: failed ? HTTP3Error.internalError : nil)
        }
    }

    /// The answer has gone: FIN, or a reset for one cut short.
    private func endSend(_ s: H3Stream, resetCode: UInt64?) {
        s.sendEnded = true
        if let resetCode {
            quic.resetStream(s.id, code: resetCode)
        } else {
            quic.send(s.id, emptyBlock, 0, fin: true)
            // An answered request earns back one cancellation.
            if resetBudget < settings.resetBudget { resetBudget &+= 1 }
        }
        // Answered before the request was whole: the client is told to stop
        // sending the rest, without calling it an error.
        if let stream = quic.stream(s.id), !stream.receive.finished {
            quic.stopSending(s.id, code: HTTP3Error.noError)
            stream.receive.ready.clear()
        }
        finish(s)
    }

    // MARK: - Time and the end

    /// Once a second: a request body that stopped arriving is given up on,
    /// as an HTTP/1 request whose body stalls is.
    func tick(nowMs now: UInt64) {
        guard began, !closed else { return }
        let limit = settings.bodyTimeoutMs
        var stalled: [H3Stream] = []
        for s in streams.values where s.receiving && now &- s.lastActivity > limit { stalled.append(s) }
        for s in stalled { abort(s, code: HTTP3Error.requestIncomplete) }
        if !stalled.isEmpty { endpoint.touch(self) }
    }

    /// Shutdown: GOAWAY naming the first request that will not be served.
    func goaway() {
        guard began, !closed, goawayID == .max, controlOut != .max else { return }
        let id = highestRequest < 0 ? 0 : UInt64(highestRequest) &+ 4
        goawayID = id
        var frame = ByteBuffer(capacity: 16)
        defer { frame.destroy() }
        frame.writeVarint(HTTP3FrameType.goaway)
        frame.writeVarint(UInt64(quicVarintLength(id)))
        frame.writeVarint(id)
        quic.send(controlOut, frame.readPointer, frame.readableBytes, fin: false)
    }

    /// While shutting down: closes the connection once it has nothing left
    /// to answer, or now when `force`.
    func closeIfDone(force: Bool) {
        guard quic.status != .closing else { return }
        if !began {
            // Still shaking hands: there is nothing to wait for.
            quic.close(0)
            return
        }
        if force || (streams.isEmpty && tasks == 0 && settled) {
            closeHTTP()
            quic.close(HTTP3Error.noError, application: true)
        }
    }

    /// Everything sent has been acknowledged -- GOAWAY, and every answer --
    /// and no request is left on the transport: a close now cuts nothing
    /// off. (A closing connection sends nothing but its close.)
    private var settled: Bool {
        if controlOut != .max, let control = quic.stream(controlOut), control.send.data.readableBytes > 0 {
            return false
        }
        for (id, _) in quic.streams where QUICStreamKind.isBidirectional(id) { return false }
        return true
    }

    /// The connection is over for its requests: every one is cancelled, and
    /// nothing more is sent on any.
    func closeHTTP() {
        guard !closed else { return }
        closed = true
        let open = Array(streams.values)
        streams.removeAll()
        endpoint.lock.withLock { _ in
            for s in open {
                s.reset = true
                s.task?.cancel()
                s.resumeWaiters(false)
            }
        }
        for s in open {
            s.inTable = false
            s.sendEnded = true
            if !s.taskActive { recycle(s) }
        }
    }

    /// The endpoint is going away with the connection still open.
    func abandon() {
        closeHTTP()
    }
}
