//===----------------------------------------------------------------------===//
// WebSockets.
//
// A WebSocket is an HTTP request that stops being HTTP. The request head is
// parsed by the ordinary parser, the upgrade is recognised here, and from the
// moment the 101 goes out the connection carries RFC 6455 frames instead --
// which is why the connection has its own state (.websocket) rather than
// pretending to still be mid-response.
//
// The ASGI side maps onto the same machinery as an HTTP request: one task, one
// `receive` and one `send` callable carrying the packed (generation, slot)
// token. The differences are all in what those two produce and accept:
//
//   receive: websocket.connect, then websocket.receive per message, then
//            websocket.disconnect exactly once.
//   send:    websocket.accept (or websocket.close, to reject), then
//            websocket.send, then websocket.close.
//
// Frames are decoded only once their whole payload is buffered. Streaming a
// partial frame would save memory on very large messages, but the message size
// limit already bounds that, and whole-frame decoding removes an entire class
// of resumption bug from the mask/validation state machine.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineASGI
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

/// Per-connection WebSocket state. Trivial and default-constructible, because
/// connections live in a flat slab that is initialised in bulk.
public struct WebSocketState {
    /// The handshake has been answered with 101.
    public var accepted = false
    /// A close frame has gone out; nothing more may be sent.
    public var closeSent = false
    /// A close frame has come in.
    public var closeReceived = false
    public var connectDelivered = false
    public var disconnectDelivered = false

    /// Opcode of the message being assembled across continuation frames.
    public var messageOpcode: UInt8 = 0
    public var assembling = false
    public var validator = UTF8Validator()

    /// Complete messages decoded but not yet handed to the application.
    ///
    /// Frames have to be decoded as they arrive rather than when the
    /// application next calls `receive()`, because a ping must be answered
    /// whether or not anyone is listening and a pong must be seen or the
    /// server would time out a peer that is perfectly healthy. That means data
    /// messages can arrive with nowhere to go, so they queue here -- bounded,
    /// with the read side switched off when the bound is reached, which turns
    /// a slow application into TCP backpressure rather than into memory.
    public var queue: [PyObj] = []
    public var queuedBytes = 0

    /// When the outstanding keepalive ping was sent, or 0.
    public var pingSentAt: UInt64 = 0
    /// Close code to report to the application.
    public var closeCode: UInt16 = WSCloseCode.abnormal
    /// The precomputed Sec-WebSocket-Accept value: 28 base64 characters.
    ///
    /// Computed during dispatch and kept, because the application may take
    /// arbitrarily long to accept and the request head it was derived from is
    /// not guaranteed to still be intact by then.
    public var acceptKey: UnsafeMutablePointer<UInt8>? = nil

    public init() {}
}

/// RFC 6455 section 1.3.
private let wsGUID: StaticString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

extension Worker {

    // MARK: - Handshake detection

    /// Whether this request is a well-formed WebSocket upgrade.
    ///
    /// Returns the Sec-WebSocket-Key slice when it is, so the caller does not
    /// have to walk the headers twice.
    func websocketKey(_ slot: Int, base: UnsafePointer<UInt8>) -> ByteSpan? {
        let c = table[slot]
        let head = c.pointee.head
        guard head.method == .get, head.httpMinor == 1,
              head.flags.contains(.upgrade) else { return nil }

        var key: ByteSpan? = nil
        var sawUpgrade = false
        var sawConnection = false
        var version = 0

        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i += 1
            let np = base + Int(h.name.offset)
            let vp = base + Int(h.value.offset)
            let vLen = Int(h.value.length)
            switch h.name.length {
            case 7:
                if equalsLowercased(np, 7, "upgrade") {
                    sawUpgrade = containsTokenLowercased(vp, vLen, "websocket")
                }
            case 10:
                if equalsLowercased(np, 10, "connection") {
                    sawConnection = containsTokenLowercased(vp, vLen, "upgrade")
                }
            case 17:
                if equalsLowercased(np, 17, "sec-websocket-key") {
                    key = ByteSpan(vp, vLen)
                }
            case 21:
                if equalsLowercased(np, 21, "sec-websocket-version") {
                    version = parseDecimal(vp, vLen)
                }
            default:
                break
            }
        }
        guard sawUpgrade, sawConnection, version == 13, let key, key.count > 0 else {
            return nil
        }
        return key
    }

    /// Subprotocols the client offered, as a Python list of str.
    func websocketSubprotocols(_ slot: Int, base: UnsafePointer<UInt8>) -> PyObj? {
        guard let list = pg_list_empty_new() else { return nil }
        let head = table[slot].pointee.head
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 22,
                  equalsLowercased(base + Int(h.name.offset), 22, "sec-websocket-protocol")
            else { continue }
            // One header, comma separated, possibly repeated.
            let vp = base + Int(h.value.offset)
            let vLen = Int(h.value.length)
            var start = 0
            while start <= vLen {
                var end = start
                while end < vLen, vp[end] != cComma { end += 1 }
                var lo = start
                var hi = end
                while lo < hi, vp[lo] == cSP || vp[lo] == cHT { lo += 1 }
                while hi > lo, vp[hi - 1] == cSP || vp[hi - 1] == cHT { hi -= 1 }
                if hi > lo {
                    if let s = (vp + lo).withMemoryRebound(to: CChar.self, capacity: hi - lo, {
                        pg_str_utf8($0, pg_ssize_t(hi - lo))
                    }) {
                        _ = pg_list_append(list, s)
                        pg_decref(s)
                    } else {
                        pg_err_clear()
                    }
                }
                if end >= vLen { break }
                start = end + 1
            }
        }
        return list
    }

    /// Computes the 28-character Sec-WebSocket-Accept value.
    func computeAcceptKey(_ key: ByteSpan, into out: UnsafeMutablePointer<UInt8>) {
        // key (24 for a well-formed client) + the 36-byte GUID.
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 256) { scratch in
            let p = scratch.baseAddress!
            let n = min(key.count, 200)
            memcpy(p, key.base, n)
            memcpy(p + n, wsGUID.utf8Start, 36)
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digest in
                pg_sha1(p, n + 36, digest.baseAddress!)
                _ = out.withMemoryRebound(to: CChar.self, capacity: 28) { o in
                    pg_base64(digest.baseAddress!, 20, o)
                }
            }
        }
    }

    // MARK: - Dispatch

    /// Answers a WebSocket upgrade with an HTTP failure.
    ///
    /// This cannot go through `failRequest`, which refuses to write a response
    /// while an application task is live -- for an HTTP request that would mean
    /// two responses on one connection. Here nothing has been written yet: the
    /// handshake was never answered, so the rejection *is* the whole response,
    /// and the task is simply finishing afterwards.
    mutating func rejectWebSocket(_ slot: Int, status: Int) {
        let c = table[slot]
        if c.pointee.flags.contains(.responseStarted) || c.pointee.ws.accepted {
            closeConnection(slot)
            return
        }
        c.pointee.flags.remove(.keepAlive)
        dates.refresh()
        c.pointee.write.clear()
        HTTPResponseWriter.writeError(&c.pointee.write, status: status,
                                      closeConnection: true, dateCache: dates)
        c.pointee.flags.insert(.responseStarted)
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        logAccess(slot, status: status)
        _ = flush(slot)
    }

    /// Starts the ASGI websocket connection scope and application task.
    mutating func dispatchWebSocket(_ slot: Int, key: ByteSpan, base: UnsafePointer<UInt8>) {
        let c = table[slot]

        c.pointee.ws = WebSocketState()
        let accept = UnsafeMutablePointer<UInt8>.allocate(capacity: 28)
        computeAcceptKey(key, into: accept)
        c.pointee.ws.acceptKey = accept
        c.pointee.flags.insert(.websocketMode)
        // A websocket is never keep-alive in the HTTP sense: the connection
        // either becomes a websocket or ends.
        c.pointee.flags.remove(.keepAlive)

        if c.pointee.clientTuple == nil,
           let addr = c.pointee.remoteAddrObj,
           let port = c.pointee.remotePortObj {
            c.pointee.clientTuple = pg_tuple2(addr, port)
        }

        let forwarded = forwardedInfo(slot, base: base)
        let forwardedClient = forwardedClientTuple(forwarded)
        defer { if let f = forwardedClient { pg_decref(f) } }

        // ws or wss, following the same trust rules as http/https.
        var secure = false
        if let https = forwarded.https {
            secure = https
        } else {
            secure = strcmp(config.scheme, staticCString("https")) == 0
        }
        let schemeObj = secure ? Interned[.vWSS] : Interned[.vWS]

        guard let subprotocols = websocketSubprotocols(slot, base: base) else {
            PyError.logPending("reading the offered subprotocols")
            rejectWebSocket(slot, status: 500)
            return
        }
        defer { pg_decref(subprotocols) }

        guard let scopeDict = asgiScope!.build(
                base: base,
                head: c.pointee.head,
                headers: headers,
                client: forwardedClient ?? c.pointee.clientTuple,
                schemeOverride: schemeObj,
                websocket: true,
                subprotocols: subprotocols) else {
            PyError.logPending("building the websocket scope")
            rejectWebSocket(slot, status: 500)
            return
        }
        defer { pg_decref(scopeDict) }

        let token = PollToken.make(slot: slot, generation: c.pointee.generation)
        guard let receiveFn = PyTrampoline.make(asgiReceive, context: token),
              let sendFn = PyTrampoline.make(asgiSend, context: token) else {
            PyError.logPending("creating the websocket channels")
            rejectWebSocket(slot, status: 500)
            return
        }
        c.pointee.receiveCallable = receiveFn
        c.pointee.sendCallable = sendFn

        guard let coro = pg_call3(ASGIRuntime.app, scopeDict, receiveFn, sendFn) else {
            PyError.logPending("calling the application")
            rejectWebSocket(slot, status: 500)
            return
        }
        defer { pg_decref(coro) }

        guard let doneCb = PyTrampoline.make(asgiTaskDone, context: token) else {
            PyError.logPending("creating the completion callback")
            rejectWebSocket(slot, status: 500)
            return
        }
        defer { pg_decref(doneCb) }

        guard let task = pg_call3(ASGIRuntime.fnSpawn, ASGIRuntime.loop, coro, doneCb) else {
            PyError.logPending("scheduling the websocket task")
            rejectWebSocket(slot, status: 500)
            return
        }
        c.pointee.task = task
        // Nothing may be read until the handshake is answered: a client that
        // pipelines frames ahead of the 101 has them wait in the socket buffer.
        setInterest(slot, [])
    }

    // MARK: - receive()

    /// The next websocket message for the application, or nil to park.
    mutating func nextWebSocketMessage(_ slot: Int) -> PyObj? {
        let c = table[slot]
        if !c.pointee.ws.connectDelivered {
            c.pointee.ws.connectDelivered = true
            return ASGIWebSocketMessage.connect()
        }
        if c.pointee.ws.disconnectDelivered { return nil }

        // Anything already decoded comes first, in arrival order.
        if !c.pointee.ws.queue.isEmpty {
            let message = c.pointee.ws.queue.removeFirst()
            c.pointee.ws.queuedBytes -= messageWeight(message)
            if c.pointee.ws.queuedBytes < 0 { c.pointee.ws.queuedBytes = 0 }
            // Space has just been freed, so the read side may re-open and more
            // frames may already be buffered behind this one.
            pumpWebSocket(slot)
            return message
        }

        // Once the peer is gone, or we have closed, the only thing left to say
        // is how it ended.
        if !c.pointee.ws.accepted {
            if c.pointee.flags.contains(.peerClosed) {
                c.pointee.ws.disconnectDelivered = true
                return ASGIWebSocketMessage.disconnect(code: WSCloseCode.abnormal)
            }
            return nil
        }
        if c.pointee.ws.closeReceived || c.pointee.flags.contains(.peerClosed) {
            c.pointee.ws.disconnectDelivered = true
            return ASGIWebSocketMessage.disconnect(code: c.pointee.ws.closeCode)
        }
        return nil
    }

    /// Roughly what a queued message costs, for the byte budget. The payload
    /// dominates; the dict and its keys are noise beside it.
    func messageWeight(_ message: PyObj) -> Int {
        var total = 64
        if let body = pg_dict_get(message, Interned[.bytesKey]), pg_is_bytes(body) != 0 {
            total += Int(pg_bytes_len(body))
        } else if let text = pg_dict_get(message, Interned[.text]), pg_is_str(text) != 0 {
            var n: pg_ssize_t = 0
            if pg_str_utf8_data(text, &n) != nil { total += Int(n) } else { pg_err_clear() }
        }
        return total
    }

    /// Whether the queue has taken as much as it should before the peer is
    /// made to wait. One message is always allowed through, so a single
    /// oversized message cannot deadlock against its own budget.
    func websocketQueueFull(_ slot: Int) -> Bool {
        let ws = table[slot].pointee.ws
        if ws.queue.count >= config.maxWebsocketQueue { return true }
        return !ws.queue.isEmpty && ws.queuedBytes >= config.maxWebsocketQueueBytes
    }

    /// Decodes every buffered frame: control frames are answered here and now,
    /// and complete data messages are queued for the application.
    ///
    /// This runs on readability, not on `receive()`. Deferring it to the
    /// application meant that a push-only endpoint -- or one simply busy
    /// between receives -- left pings unanswered and, worse, never saw the
    /// pong for the server's own keepalive ping, so the server would eventually
    /// close a connection that was working perfectly.
    mutating func pumpWebSocket(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.state == .websocket, c.pointee.ws.accepted else { return }
        let limit = config.maxWebsocketMessageSize

        while true {
            if websocketQueueFull(slot) { break }
            let available = c.pointee.read.readableBytes
            if available == 0 { break }
            let base = UnsafePointer(c.pointee.read.readPointer)

            let parsed = WebSocketCodec.parseHeader(base, available, maxPayload: limit)
            let header: WSFrameHeader
            switch parsed {
            case .needMore:
                break
            case .failure(let err):
                switch err {
                case .messageTooBig:
                    failWebSocket(slot, code: WSCloseCode.messageTooBig)
                default:
                    failWebSocket(slot, code: WSCloseCode.protocolError)
                }
                return
            case .header(let h):
                header = h
                // Every frame from a client must be masked (RFC 6455 5.1); an
                // unmasked one is either a broken client or an attempt to have
                // an intermediary interpret the payload.
                if !header.masked {
                    failWebSocket(slot, code: WSCloseCode.protocolError)
                    return
                }
                if available < header.totalLength { break }

                let payload = base + header.headerLength
                let n = header.payloadLength

                if header.opcode.isControl {
                    handleControlFrame(slot, header, payload, n)
                    if table[slot].pointee.state == .free { return }
                    c.pointee.read.consume(header.totalLength)
                    continue
                }

                if !decodeDataFrame(slot, header, payload, n, limit) { return }
                continue
            }
            break
        }
        updateWebSocketReadInterest(slot)
    }

    /// Accumulates one data frame, queueing the message when it completes.
    /// Returns false once the connection has been failed.
    private mutating func decodeDataFrame(_ slot: Int, _ header: WSFrameHeader,
                                          _ payload: UnsafePointer<UInt8>, _ n: Int,
                                          _ limit: Int) -> Bool {
        let c = table[slot]
        if header.opcode == .continuation {
            if !c.pointee.ws.assembling {
                failWebSocket(slot, code: WSCloseCode.protocolError)
                return false
            }
        } else {
            if c.pointee.ws.assembling {
                // A new data frame while a message is still in progress.
                failWebSocket(slot, code: WSCloseCode.protocolError)
                return false
            }
            c.pointee.ws.assembling = true
            c.pointee.ws.messageOpcode = header.opcode.rawValue
            c.pointee.ws.validator = UTF8Validator()
            c.pointee.body.clear()
        }

        if c.pointee.body.readableBytes + n > limit {
            failWebSocket(slot, code: WSCloseCode.messageTooBig)
            return false
        }

        if n > 0 {
            c.pointee.body.reserve(n)
            WebSocketCodec.unmask(c.pointee.body.writePointer, payload, n, header.mask)
            if c.pointee.ws.messageOpcode == WSOpcode.text.rawValue {
                if !c.pointee.ws.validator.feed(UnsafePointer(c.pointee.body.writePointer), n) {
                    failWebSocket(slot, code: WSCloseCode.invalidPayload)
                    return false
                }
            }
            c.pointee.body.advanceWriter(n)
        }
        c.pointee.read.consume(header.totalLength)

        if !header.fin { return true }

        c.pointee.ws.assembling = false
        let isText = c.pointee.ws.messageOpcode == WSOpcode.text.rawValue
        if isText && !c.pointee.ws.validator.isComplete {
            failWebSocket(slot, code: WSCloseCode.invalidPayload)
            return false
        }
        let count = c.pointee.body.readableBytes
        let bodyPtr = count > 0 ? UnsafePointer(c.pointee.body.readPointer) : nil
        if let message = ASGIWebSocketMessage.receive(bytes: bodyPtr, count: count, text: isText) {
            c.pointee.ws.queue.append(message)
            c.pointee.ws.queuedBytes += count + 64
        } else {
            PyError.logPending("building a websocket message")
        }
        c.pointee.body.clear()
        return true
    }

    /// Stops reading while the application is behind, and resumes when it
    /// catches up. This is what makes the queue bound mean something.
    mutating func updateWebSocketReadInterest(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.state == .websocket else { return }
        var mask: PollMask = websocketQueueFull(slot) ? [] : .read
        if !c.pointee.write.isEmpty { mask.insert(.write) }
        setInterest(slot, mask)
    }

    /// Ping, pong and close, all answered without involving the application.
    mutating func handleControlFrame(_ slot: Int, _ header: WSFrameHeader,
                                     _ payload: UnsafePointer<UInt8>, _ n: Int) {
        let c = table[slot]
        switch header.opcode {
        case .ping:
            // Echo the payload back, unless we are already shutting down.
            if !c.pointee.ws.closeSent {
                var unmasked = ByteBuffer(capacity: max(n, 1))
                defer { unmasked.destroy() }
                if n > 0 {
                    WebSocketCodec.unmask(unmasked.writePointer, payload, n, header.mask)
                    unmasked.advanceWriter(n)
                }
                var out = c.pointee.write
                WebSocketCodec.writeFrame(&out, opcode: .pong, fin: true,
                                          payload: n > 0 ? UnsafePointer(unmasked.readPointer) : nil,
                                          length: n)
                c.pointee.write = out
                _ = flush(slot)
            }

        case .pong:
            c.pointee.ws.pingSentAt = 0

        case .close:
            var code = WSCloseCode.noStatus
            if n >= 2 {
                var head2 = ByteBuffer(capacity: n)
                defer { head2.destroy() }
                WebSocketCodec.unmask(head2.writePointer, payload, n, header.mask)
                head2.advanceWriter(n)
                let p = UnsafePointer(head2.readPointer)
                code = (UInt16(p[0]) << 8) | UInt16(p[1])
                // A close frame with a body but no valid code, or with a
                // non-UTF-8 reason, is itself a protocol error.
                if !WebSocketCodec.isSendableCloseCode(code) {
                    failWebSocket(slot, code: WSCloseCode.protocolError)
                    return
                }
                if n > 2 {
                    var v = UTF8Validator()
                    if !v.feed(p + 2, n - 2) || !v.isComplete {
                        failWebSocket(slot, code: WSCloseCode.invalidPayload)
                        return
                    }
                }
            } else if n == 1 {
                failWebSocket(slot, code: WSCloseCode.protocolError)
                return
            }
            c.pointee.ws.closeReceived = true
            c.pointee.ws.closeCode = code
            // The handshake is symmetric: echo the close and stop reading. The
            // disconnect message itself is synthesised once the application has
            // drained whatever was queued ahead of it.
            sendCloseFrame(slot, code: code == WSCloseCode.noStatus ? WSCloseCode.normal : code,
                           reason: nil, reasonLength: 0)

        default:
            break
        }
    }

    // MARK: - send()

    /// Handles one `websocket.*` message from the application. Returns false
    /// with a Python exception pending on a protocol violation.
    mutating func websocketSend(_ slot: Int, type: UnsafePointer<UInt8>, typeLength: Int,
                                message: PyObj) -> Bool {
        let c = table[slot]

        if typeLength == 16 && equalsExact(type, 16, "websocket.accept") {
            if c.pointee.ws.accepted {
                pg_err_set_str(pg_exc_runtime(), "websocket.accept sent twice")
                return false
            }
            return acceptWebSocket(slot, message: message)
        }

        if typeLength == 14 && equalsExact(type, 14, "websocket.send") {
            if !c.pointee.ws.accepted {
                pg_err_set_str(pg_exc_runtime(),
                               "websocket.send before websocket.accept")
                return false
            }
            if c.pointee.ws.closeSent { return true }
            return sendWebSocketPayload(slot, message: message)
        }

        if typeLength == 15 && equalsExact(type, 15, "websocket.close") {
            var code = WSCloseCode.normal
            if let codeObj = pg_dict_get(message, Interned[.code]),
               pg_is(codeObj, Interned.none) == 0 {
                let v = pg_int_as_long(codeObj)
                if v < 0 { pg_err_clear() } else { code = UInt16(truncatingIfNeeded: v) }
            }
            if !c.pointee.ws.accepted {
                // Rejecting the handshake. ASGI says the client sees an HTTP
                // failure, not a websocket close.
                rejectWebSocket(slot, status: 403)
                return true
            }
            var reasonView: PyBytesView? = nil
            if let reasonObj = pg_dict_get(message, Interned[.reason]),
               pg_is(reasonObj, Interned.none) == 0 {
                reasonView = PyBytesView.of(reasonObj)
                if reasonView == nil { pg_err_clear() }
            }
            defer { reasonView?.release() }
            sendCloseFrame(slot,
                           code: WebSocketCodec.isSendableCloseCode(code) ? code : WSCloseCode.normal,
                           reason: reasonView?.base,
                           reasonLength: reasonView?.count ?? 0)
            return true
        }

        pg_err_set_str(pg_exc_value(), "unsupported websocket message type")
        return false
    }

    /// Writes the 101 response and switches the connection to frame mode.
    mutating func acceptWebSocket(_ slot: Int, message: PyObj) -> Bool {
        let c = table[slot]
        guard let accept = c.pointee.ws.acceptKey else {
            pg_err_set_str(pg_exc_runtime(), "websocket handshake state was lost")
            return false
        }

        dates.refresh()
        var out = c.pointee.write
        out.reserve(256)
        out.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n")
        out.write("Connection: Upgrade\r\nSec-WebSocket-Accept: ")
        out.write(UnsafePointer(accept), 28)
        out.writeCRLF()

        if let sub = pg_dict_get(message, Interned[.subprotocol]),
           pg_is(sub, Interned.none) == 0 {
            if let view = PyBytesView.of(sub) {
                out.write("Sec-WebSocket-Protocol: ")
                out.write(view.base, view.count)
                out.writeCRLF()
                view.release()
            } else {
                pg_err_clear()
            }
        }

        // Extra headers are allowed on the handshake response and are the only
        // way an application can set a cookie on a websocket.
        if let extra = pg_dict_get(message, Interned[.headers]),
           pg_is(extra, Interned.none) == 0, PySeq.isSequence(extra) {
            let n = PySeq.count(extra)
            var i = 0
            while i < n {
                defer { i += 1 }
                guard let item = PySeq.item(extra, i),
                      let (nameObj, valueObj) = PySeq.pair(item) else { continue }
                guard let nameView = PyBytesView.of(nameObj) else { pg_err_clear(); continue }
                guard let valueView = PyBytesView.of(valueObj) else {
                    nameView.release()
                    pg_err_clear()
                    continue
                }
                let kind = HTTPResponseWriter.classify(nameView.span)
                // The server owns the handshake headers themselves.
                if kind.isEmpty {
                    _ = HTTPResponseWriter.writeHeader(&out,
                                                       name: nameView.span,
                                                       value: valueView.span)
                }
                valueView.release()
                nameView.release()
            }
        }
        HTTPResponseWriter.writeDate(&out, dates)
        out.write("Server: peregrine\r\n")
        HTTPResponseWriter.endHead(&out)
        c.pointee.write = out

        c.pointee.ws.accepted = true
        c.pointee.state = .websocket
        c.pointee.ws.pingSentAt = 0
        c.pointee.lastActivity = pg_monotonic_ms()
        logAccess(slot, status: 101)
        _ = flush(slot)
        if table[slot].pointee.state == .free { return true }
        // Frames may now arrive, and a client that pipelined them behind the
        // handshake has them sitting in the read buffer already.
        setInterest(slot, .read)
        pumpWebSocket(slot)
        if table[slot].pointee.state == .free { return true }
        deliverPendingReceive(slot)
        return true
    }

    mutating func sendWebSocketPayload(_ slot: Int, message: PyObj) -> Bool {
        let c = table[slot]
        var opcode = WSOpcode.binary
        var view: PyBytesView? = nil

        if let textObj = pg_dict_get(message, Interned[.text]),
           pg_is(textObj, Interned.none) == 0 {
            opcode = .text
            view = PyBytesView.of(textObj)
        } else if let bytesObj = pg_dict_get(message, Interned[.bytesKey]),
                  pg_is(bytesObj, Interned.none) == 0 {
            opcode = .binary
            view = PyBytesView.of(bytesObj)
        } else {
            pg_err_set_str(pg_exc_value(), "websocket.send needs bytes or text")
            return false
        }
        guard let view else {
            pg_err_set_str(pg_exc_value(), "websocket.send payload is not bytes or str")
            return false
        }
        defer { view.release() }

        var out = c.pointee.write
        WebSocketCodec.writeFrame(&out, opcode: opcode, fin: true,
                                  payload: view.count > 0 ? view.base : nil,
                                  length: view.count)
        c.pointee.write = out
        _ = flush(slot)
        return true
    }

    /// Queues a close frame. The connection is torn down once it drains.
    mutating func sendCloseFrame(_ slot: Int, code: UInt16,
                                 reason: UnsafePointer<UInt8>?, reasonLength: Int) {
        let c = table[slot]
        if c.pointee.ws.closeSent { return }
        c.pointee.ws.closeSent = true
        var out = c.pointee.write
        WebSocketCodec.writeClose(&out, code: code, reason: reason, reasonLength: reasonLength)
        c.pointee.write = out
        // The close frame is the last thing on this connection.
        c.pointee.flags.remove(.keepAlive)
        _ = flush(slot)
        if table[slot].pointee.state != .free
            && table[slot].pointee.write.isEmpty
            && table[slot].pointee.task == nil {
            closeConnection(slot)
        }
    }

    /// Ends the connection because the peer broke the protocol.
    mutating func failWebSocket(_ slot: Int, code: UInt16) {
        let c = table[slot]
        c.pointee.ws.closeCode = code
        if c.pointee.ws.accepted {
            sendCloseFrame(slot, code: code, reason: nil, reasonLength: 0)
        }
        // Nothing further from this peer can be trusted.
        c.pointee.read.clear()
        c.pointee.ws.closeReceived = true
        c.pointee.flags.insert(.peerClosed)
        deliverPendingReceive(slot)
        if table[slot].pointee.state != .free && table[slot].pointee.task == nil {
            closeConnection(slot)
        }
    }

    // MARK: - Readiness and housekeeping

    mutating func handleWebSocketReadable(_ slot: Int) {
        // One whole frame has to fit, and a frame is bounded by the message
        // limit plus its 14-byte header. Reading further ahead than that would
        // let a peer pin twice the configured limit per connection.
        let limit = config.maxWebsocketMessageSize &+ 1024
        if !fill(slot, .read, limit: limit) { return }
        if table[slot].pointee.state == .free { return }
        // Decode now, whether or not anyone is waiting: control frames have to
        // be answered on arrival.
        pumpWebSocket(slot)
        if table[slot].pointee.state == .free { return }
        deliverPendingReceive(slot)
        let d = table[slot]
        if d.pointee.state == .free { return }
        if d.pointee.flags.contains(.peerClosed) && d.pointee.write.isEmpty
            && d.pointee.task == nil {
            closeConnection(slot)
        }
    }

    /// Keepalive pings and dead-peer detection for one websocket connection.
    mutating func sweepWebSocket(_ slot: Int, now: UInt64) {
        let c = table[slot]
        let interval = config.websocketPingIntervalMs
        if interval == 0 { return }
        if c.pointee.ws.closeSent { return }

        if c.pointee.ws.pingSentAt != 0 {
            if now &- c.pointee.ws.pingSentAt > config.websocketPingTimeoutMs {
                // No pong came back: the peer is gone even if the socket has
                // not noticed, which is exactly what pings are for.
                c.pointee.ws.closeCode = WSCloseCode.abnormal
                c.pointee.flags.insert(.peerClosed)
                deliverPendingReceive(slot)
                closeConnection(slot)
            }
            return
        }
        if now &- c.pointee.lastActivity < interval { return }
        var out = c.pointee.write
        WebSocketCodec.writeFrame(&out, opcode: .ping, fin: true, payload: nil, length: 0)
        c.pointee.write = out
        c.pointee.ws.pingSentAt = now
        _ = flush(slot)
    }

    /// The application task ended. Whatever it did or did not send, the
    /// connection has to be terminated properly.
    mutating func websocketTaskFinished(_ slot: Int, error: Bool) {
        let c = table[slot]
        if !c.pointee.ws.accepted {
            // The application returned without accepting: that is a rejection.
            if !c.pointee.flags.contains(.responseStarted) {
                rejectWebSocket(slot, status: error ? 500 : 403)
            } else if c.pointee.write.isEmpty {
                closeConnection(slot)
            } else {
                // A rejection is already queued; let it drain first.
                c.pointee.state = .writing
                _ = flush(slot)
            }
            return
        }
        if !c.pointee.ws.closeSent {
            sendCloseFrame(slot,
                           code: error ? WSCloseCode.internalError : WSCloseCode.normal,
                           reason: nil, reasonLength: 0)
        }
        if table[slot].pointee.state != .free && table[slot].pointee.write.isEmpty {
            closeConnection(slot)
        }
    }
}

// MARK: - Messages

public enum ASGIWebSocketMessage {

    public static func connect() -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        if pg_dict_set(d, Interned[.type], Interned[.vWebsocketConnect]) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }

    /// `{"type": "websocket.receive", "bytes"|"text": ...}`
    ///
    /// The unused key is present and None, which the specification requires and
    /// which some frameworks check for rather than using `.get`.
    public static func receive(bytes: UnsafePointer<UInt8>?, count: Int, text: Bool) -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        var ok = pg_dict_set(d, Interned[.type], Interned[.vWebsocketReceive]) == 0
        if ok {
            let payload: PyObj?
            if text {
                payload = count > 0
                    ? bytes!.withMemoryRebound(to: CChar.self, capacity: count, {
                        pg_str_utf8($0, pg_ssize_t(count))
                      })
                    : Interned.emptyString
            } else {
                payload = count > 0
                    ? bytes!.withMemoryRebound(to: CChar.self, capacity: count, {
                        pg_bytes($0, pg_ssize_t(count))
                      })
                    : Interned.emptyBytes
            }
            guard let payload else {
                pg_decref(d)
                return nil
            }
            let owned = count > 0
            ok = pg_dict_set(d, text ? Interned[.text] : Interned[.bytesKey], payload) == 0
            if owned { pg_decref(payload) }
            if ok {
                ok = pg_dict_set(d, text ? Interned[.bytesKey] : Interned[.text],
                                 Interned.none) == 0
            }
        }
        if !ok {
            pg_decref(d)
            return nil
        }
        return d
    }

    public static func disconnect(code: UInt16) -> PyObj? {
        guard let d = pg_dict_new() else { return nil }
        guard let codeObj = pg_int(Int(code)) else {
            pg_decref(d)
            return nil
        }
        defer { pg_decref(codeObj) }
        if pg_dict_set(d, Interned[.type], Interned[.vWebsocketDisconnect]) != 0
            || pg_dict_set(d, Interned[.code], codeObj) != 0 {
            pg_decref(d)
            return nil
        }
        return d
    }
}
