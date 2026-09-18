//===----------------------------------------------------------------------===//
// WebSockets: the engine side.
//
// A WebSocket is an HTTP/1.1 request that stops being HTTP. The request head
// is parsed by the ordinary parser and routed like any other request, so
// middleware and extractors run in front of it. The route's handler accepts
// the upgrade (WebSocketAPI.swift), and from the moment the 101 goes out the
// connection carries RFC 6455 frames instead, in its own state (`.websocket`)
// rather than pretending to still be mid-response.
//
// Frames are decoded as they arrive, whether or not the handler is reading:
// a ping has to be answered and a pong seen on time, or a healthy peer that
// the handler is merely busy with would be timed out. Data messages decoded
// ahead of the handler queue on the connection's `WSChannel`, and once the
// queue is full the socket is no longer read, which makes a slow handler TCP
// backpressure rather than memory.
//
// Frames are decoded only once their whole payload is buffered. The message
// size limit already bounds that, and whole-frame decoding removes a class of
// resumption bug from the mask and validation state machine.
//
// The close handshake is RFC 6455's: a close is answered with a close, and
// the connection ends once both have gone and what was queued is written. A
// close the server sent first waits `--ws-ping-timeout` for the reply.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// Per-connection WebSocket framing state. Default-constructible, because
/// connections live in a flat slab that is initialised in bulk.
public struct WebSocketState {
    /// The handshake has been answered with 101.
    public var accepted = false
    /// A close frame has gone out; nothing more may be sent.
    public var closeSent = false
    /// A close frame has come in.
    public var closeReceived = false
    /// When the close went out, for giving up on the reply.
    public var closeSentAt: UInt64 = 0
    /// The close code of a protocol violation that came in behind messages
    /// the handler has not read yet, or 0. The violation is acted on once
    /// they have been read, so replies to them go out before the close.
    public var pendingFailure: UInt16 = 0
    /// When the violation arrived, for not waiting on a handler forever.
    public var pendingFailureAt: UInt64 = 0

    /// Opcode of the message being assembled across continuation frames.
    public var messageOpcode: UInt8 = 0
    public var assembling = false
    public var validator = UTF8Validator()
    /// The message being assembled.
    public var message = ByteBuffer()

    /// When the outstanding keepalive ping was sent, or 0.
    public var pingSentAt: UInt64 = 0
    /// --ws-compress: what was agreed, or nil when nothing was.
    public var deflate: WSDeflateAgreement? = nil
    /// zlib contexts, made on first use rather than at the handshake: a
    /// connection that never sends a compressed message never pays for one.
    public var deflater: UnsafeMutableRawPointer? = nil
    public var inflater: UnsafeMutableRawPointer? = nil
    /// The message being assembled arrived compressed.
    public var messageCompressed = false

    /// What the handler reads from and waits on.
    var channel: WSChannel? = nil

    public init() {}
}

/// The part of a WebSocket its handler shares with the engine. A class,
/// because the handler holds it past the connection: messages that arrived
/// before a close are still read after the slot is gone.
final class WSChannel {
    var queue: [WebSocketMessage] = []
    var queuedBytes = 0
    /// The peer sent its close, or the connection ended. Nothing more will be
    /// queued.
    var ended = false
    /// The connection's slot has been released. The engine can no longer be
    /// asked for anything.
    var gone = false
    var closeCode: UInt16 = WSCloseCode.abnormal
    var closeReason: [UInt8] = []
    var receiveWaiter: UnsafeContinuation<Void, Never>? = nil
    /// The senders waiting for the backlog to drain -- all of them, not the
    /// first only: one let through because another was already waiting would
    /// be free to queue frames for ever against a peer reading nothing.
    var writeWaiters: [WebSocketWriteWaiter] = []
    /// Timed waits (`WebSocket.sleep`) to end early when the connection goes.
    var sleeps: [Int32] = []

    var isWriteWaiting: Bool { !writeWaiters.isEmpty }

    /// Resumes every sender waiting for room. Each reads the backlog again
    /// for itself and waits again if it is still above the mark.
    func wakeWriters() {
        let waiting = writeWaiters
        guard !waiting.isEmpty else { return }
        writeWaiters = []
        for waiter in waiting { waiter.wake.take()?.resume() }
    }

    func wakeAll() {
        receiveWaiter.take()?.resume()
        wakeWriters()
    }
}

/// One sender's place in the queue for room, so that a cancelled send takes
/// its own continuation back and leaves everyone else's alone.
///
/// Unchecked on the same ground as `WSChannel`: it belongs to one worker,
/// whose one thread is the only one that ever touches it.
final class WebSocketWriteWaiter: @unchecked Sendable {
    var wake: UnsafeContinuation<Void, Never>? = nil
}

/// RFC 6455 section 1.3.
private let wsGUID: StaticString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

/// What the handshake asked for, read from the request head at dispatch.
struct WebSocketOffer {
    enum Problem: Error {
        /// Not an upgrade at all: answered 426 with `Upgrade: websocket`.
        case notUpgrade
        /// An upgrade to a version other than 13: 426 with the version.
        case version
        /// An upgrade missing what it needs: 400.
        case malformed
        /// A request on an HTTP/2 or HTTP/3 stream that is not an extended
        /// CONNECT for a WebSocket served here.
        case multiplexed
    }

    /// Sec-WebSocket-Key: HTTP/1.1 only.
    var key: ByteSpan?
    var subprotocols: [String]
    var extensions: [ByteSpan]
}

extension Worker {

    // MARK: - Handshake

    /// Reads the WebSocket handshake from the request on `slot`.
    mutating func websocketOffer(_ slot: Int) -> Result<WebSocketOffer, WebSocketOffer.Problem> {
        let c = table[slot]
        let stream = c.pointee.isStream
        // On HTTP/2 and HTTP/3 a WebSocket is an extended CONNECT, and a plain
        // GET to its route is not one.
        if stream && !streamWebSocketAllowed(slot) { return .failure(.multiplexed) }
        ensureHeaders(slot)
        let head = c.pointee.head
        let base = c.pointee.headBase()

        var key: ByteSpan? = nil
        var sawUpgrade = false
        var sawConnection = false
        var version = -1
        var subprotocols: [String] = []
        var extensions: [ByteSpan] = []

        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i += 1
            let np = base + Int(h.name.offset)
            let vp = base + Int(h.value.offset)
            let vLen = Int(h.value.length)
            switch h.name.length {
            case 7 where equalsLowercased(np, 7, "upgrade"):
                sawUpgrade = sawUpgrade || containsTokenLowercased(vp, vLen, "websocket")
            case 10 where equalsLowercased(np, 10, "connection"):
                sawConnection = sawConnection || containsTokenLowercased(vp, vLen, "upgrade")
            case 17 where equalsLowercased(np, 17, "sec-websocket-key"):
                key = ByteSpan(vp, vLen)
            case 21 where equalsLowercased(np, 21, "sec-websocket-version"):
                version = parseDecimal(vp, vLen)
            case 22 where equalsLowercased(np, 22, "sec-websocket-protocol"):
                forEachListItem(vp, vLen) { p, n in
                    subprotocols.append(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
                }
            case 24 where equalsLowercased(np, 24, "sec-websocket-extensions"):
                extensions.append(ByteSpan(vp, vLen))
            default:
                break
            }
        }
        if stream {
            // RFC 8441 section 5: no key and no Upgrade, since the stream is
            // the tunnel; the version is still sent.
            guard version == 13 else { return .failure(.version) }
            return .success(WebSocketOffer(key: nil, subprotocols: subprotocols, extensions: extensions))
        }
        guard head.method == .get, sawUpgrade, sawConnection else { return .failure(.notUpgrade) }
        guard head.httpMinor == 1 else { return .failure(.malformed) }
        guard version == 13 else { return .failure(.version) }
        // A key is 16 random bytes in base64: 24 characters.
        guard let key, key.count == 24 else { return .failure(.malformed) }
        _ = key
        return .success(WebSocketOffer(key: key, subprotocols: subprotocols, extensions: extensions))
    }

    /// Answers the upgrade on `slot` with 101 and switches the connection to
    /// frames. Nil, with nothing sent, when the request is no longer there to
    /// accept.
    mutating func acceptWebSocket(_ slot: Int, _ offer: WebSocketOffer,
                                  subprotocol: String?) -> WSChannel? {
        let c = table[slot]
        if c.pointee.isStream { return acceptStreamWebSocket(slot, offer, subprotocol: subprotocol) }
        guard c.pointee.state == .dispatching, !c.pointee.flags.contains(.responseStarted),
              !c.pointee.flags.contains(.timedOut), let key = offer.key else { return nil }
        // A deadline bounds a request, and this is no longer one.
        disarmDeadline(slot)

        c.pointee.ws = WebSocketState()
        if config.wsCompress && !offer.extensions.isEmpty {
            c.pointee.ws.deflate = WSDeflate.negotiate(offer.extensions)
        }

        dates.refresh()
        var out = c.pointee.write
        out.reserve(256)
        out.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n")
        out.write("Connection: Upgrade\r\nSec-WebSocket-Accept: ")
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 28) { accept in
            computeAcceptKey(key, into: accept.baseAddress!)
            out.write(UnsafePointer(accept.baseAddress!), 28)
        }
        out.writeCRLF()
        if var subprotocol {
            out.write("Sec-WebSocket-Protocol: ")
            subprotocol.withUTF8 { if let p = $0.baseAddress, $0.count > 0 { out.write(p, $0.count) } }
            out.writeCRLF()
        }
        if let agreement = c.pointee.ws.deflate {
            out.write("Sec-WebSocket-Extensions: ")
            agreement.writeResponse(into: &out)
            out.writeCRLF()
        }
        // What middleware added -- a cookie, a request ID -- goes out with the
        // 101, the only response a WebSocket has. The handshake's own headers
        // are the server's.
        forEachHeaderRecord(c.pointee.responseHeaders) { name, value in
            if !HTTPResponseWriter.classify(name).isEmpty { return }
            if name.count == 7 && equalsLowercased(name.base, 7, "upgrade") { return }
            if name.count > 14 && equalsLowercased(name.base, 14, "sec-websocket-") { return }
            _ = HTTPResponseWriter.writeHeader(&out, name: name, value: value)
        }
        HTTPResponseWriter.writeDate(&out, dates)
        out.write("Server: garuda\r\n")
        HTTPResponseWriter.endHead(&out)
        c.pointee.write = out

        let channel = WSChannel()
        c.pointee.ws.channel = channel
        c.pointee.ws.accepted = true
        c.pointee.state = .websocket
        c.pointee.flags.insert(.websocketMode)
        c.pointee.flags.insert(.responseStarted)
        // The connection either carries frames or ends.
        c.pointee.flags.remove(.keepAlive)
        c.pointee.lastActivity = av_monotonic_ms()
        logAccess(slot, status: 101)
        if !flush(slot) { return channel }
        // Frames may now arrive, and a client that sent them straight after
        // the handshake has them in the read buffer already.
        pumpWebSocket(slot)
        if table[slot].pointee.state == .websocket { updateWebSocketReadInterest(slot) }
        return channel
    }

    /// The 28-character Sec-WebSocket-Accept value.
    func computeAcceptKey(_ key: ByteSpan, into out: UnsafeMutablePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { scratch in
            let p = scratch.baseAddress!
            memcpy(p, key.base, 24)
            memcpy(p + 24, wsGUID.utf8Start, 36)
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 20) { digest in
                av_sha1(p, 60, digest.baseAddress!)
                _ = out.withMemoryRebound(to: CChar.self, capacity: 28) { o in
                    av_base64(digest.baseAddress!, 20, o)
                }
            }
        }
    }

    // MARK: - Receiving

    /// Whether the queue has taken as much as it should before the peer is
    /// made to wait. One message is always let through, so a single large one
    /// cannot deadlock against the byte budget.
    func websocketQueueFull(_ slot: Int) -> Bool {
        guard let channel = table[slot].pointee.ws.channel else { return false }
        if channel.queue.count >= config.maxWebsocketQueue { return true }
        return !channel.queue.isEmpty && channel.queuedBytes >= config.maxWebsocketQueueBytes
    }

    /// Decodes every buffered frame: control frames are answered now, and
    /// complete data messages are queued for the handler.
    mutating func pumpWebSocket(_ slot: Int) {
        pumpWebSocketFrames(slot)
        if table[slot].pointee.isStream && table[slot].pointee.state == .websocket {
            releaseStreamWebSocketCredit(slot)
        }
    }

    private mutating func pumpWebSocketFrames(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.state == .websocket, c.pointee.ws.accepted else { return }
        let limit = config.maxWebsocketMessageSize

        while !c.pointee.ws.closeReceived {
            if websocketQueueFull(slot) { break }
            let available = c.pointee.read.readableBytes
            if available == 0 { break }
            let base = UnsafePointer(c.pointee.read.readPointer)

            switch WebSocketCodec.parseHeader(base, available, maxPayload: limit,
                                              allowRSV1: c.pointee.ws.deflate != nil) {
            case .needMore:
                updateWebSocketReadInterest(slot)
                return
            case .failure(let error):
                failWebSocket(slot, code: error == .messageTooBig
                              ? WSCloseCode.messageTooBig : WSCloseCode.protocolError)
                return
            case .header(let header):
                // Every frame from a client is masked (RFC 6455 section 5.1).
                // An unmasked one is a broken client, or an attempt to have an
                // intermediary read the payload as something else.
                guard header.masked else {
                    failWebSocket(slot, code: WSCloseCode.protocolError)
                    return
                }
                if available < header.totalLength {
                    updateWebSocketReadInterest(slot)
                    return
                }
                let payload = base + header.headerLength
                if header.opcode.isControl {
                    let length = header.totalLength
                    if !handleControlFrame(slot, header, payload, header.payloadLength) { return }
                    c.pointee.read.consume(length)
                    continue
                }
                if !decodeDataFrame(slot, header, payload, header.payloadLength, limit) { return }
            }
        }
        updateWebSocketReadInterest(slot)
    }

    /// Accumulates one data frame, queueing the message when it completes.
    /// False once the connection has been failed.
    private mutating func decodeDataFrame(_ slot: Int, _ header: WSFrameHeader,
                                          _ payload: UnsafePointer<UInt8>, _ n: Int,
                                          _ limit: Int) -> Bool {
        let c = table[slot]
        if header.opcode == .continuation {
            guard c.pointee.ws.assembling else {
                failWebSocket(slot, code: WSCloseCode.protocolError)
                return false
            }
        } else {
            // A new message while one is still in progress.
            guard !c.pointee.ws.assembling else {
                failWebSocket(slot, code: WSCloseCode.protocolError)
                return false
            }
            c.pointee.ws.assembling = true
            c.pointee.ws.messageOpcode = header.opcode.rawValue
            c.pointee.ws.messageCompressed = header.rsv1
            c.pointee.ws.validator = UTF8Validator()
            c.pointee.ws.message.clear()
        }

        // For a compressed message this bounds the compressed bytes; what they
        // inflate to is held to the same limit as they inflate.
        if c.pointee.ws.message.readableBytes + n > limit {
            failWebSocket(slot, code: WSCloseCode.messageTooBig)
            return false
        }
        let isText = c.pointee.ws.messageOpcode == WSOpcode.text.rawValue
        if n > 0 {
            c.pointee.ws.message.reserve(n)
            WebSocketCodec.unmask(c.pointee.ws.message.writePointer, payload, n, header.mask)
            // Checked as it arrives, so an invalid message fails at the frame
            // that makes it invalid. Compressed bytes are checked once inflated.
            if isText && !c.pointee.ws.messageCompressed
                && !c.pointee.ws.validator.feed(UnsafePointer(c.pointee.ws.message.writePointer), n) {
                failWebSocket(slot, code: WSCloseCode.invalidPayload)
                return false
            }
            c.pointee.ws.message.advanceWriter(n)
        }
        c.pointee.read.consume(header.totalLength)
        if !header.fin { return true }
        c.pointee.ws.assembling = false

        if c.pointee.ws.messageCompressed {
            var inflated = ByteBuffer()
            defer { inflated.destroy() }
            let status = inflateMessage(slot, into: &inflated, limit: limit)
            if status != 0 {
                failWebSocket(slot, code: status)
                return false
            }
            if isText {
                var validator = UTF8Validator()
                let count = inflated.readableBytes
                if count > 0 && (!validator.feed(UnsafePointer(inflated.readPointer), count)
                                 || !validator.isComplete) {
                    failWebSocket(slot, code: WSCloseCode.invalidPayload)
                    return false
                }
            }
            queueWebSocketMessage(slot, inflated, text: isText)
        } else {
            if isText && !c.pointee.ws.validator.isComplete {
                failWebSocket(slot, code: WSCloseCode.invalidPayload)
                return false
            }
            queueWebSocketMessage(slot, c.pointee.ws.message, text: isText)
        }
        c.pointee.ws.message.clear()
        return true
    }

    private mutating func queueWebSocketMessage(_ slot: Int, _ payload: borrowing ByteBuffer, text: Bool) {
        guard let channel = table[slot].pointee.ws.channel else { return }
        let count = payload.readableBytes
        let bytes = UnsafeBufferPointer(start: count > 0 ? UnsafePointer(payload.readPointer) : nil,
                                        count: count)
        channel.queue.append(text ? .text(String(decoding: bytes, as: UTF8.self)) : .binary(Array(bytes)))
        channel.queuedBytes += count + 64
        channel.receiveWaiter.take()?.resume()
    }

    /// Inflates the compressed message into `out`. 0, or the close code to
    /// fail the connection with: 1009 when it inflates past the message limit
    /// -- a few kilobytes of zeros can claim gigabytes -- 1007 when it is not
    /// deflate at all, 1011 when there is no memory for zlib.
    private mutating func inflateMessage(_ slot: Int, into out: inout ByteBuffer, limit: Int) -> UInt16 {
        let c = table[slot]
        guard let agreement = c.pointee.ws.deflate else { return WSCloseCode.protocolError }
        if c.pointee.ws.inflater == nil {
            c.pointee.ws.inflater = av_ws_inflate_new(agreement.inflateWindowBits)
        }
        guard let z = c.pointee.ws.inflater else { return WSCloseCode.internalError }

        // The sender strips the empty block that ends a sync flush.
        let tail: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
        tail.withUnsafeBufferPointer { c.pointee.ws.message.write($0.baseAddress!, 4) }

        var input = UnsafePointer(c.pointee.ws.message.readPointer)
        var remaining = c.pointee.ws.message.readableBytes
        var ended = false
        while true {
            if out.readableBytes > limit { return WSCloseCode.messageTooBig }
            out.reserve(min(max(remaining * 4, 4096), 1 << 20))
            let room = min(out.writableBytes, limit + 1 - out.readableBytes)
            var consumed = 0
            var produced = 0
            let rc = av_ws_inflate_run(z, input, remaining, out.writePointer, room, &consumed, &produced)
            input += consumed
            remaining -= consumed
            out.advanceWriter(produced)
            if rc < 0 { return WSCloseCode.invalidPayload }
            if out.readableBytes > limit { return WSCloseCode.messageTooBig }
            if rc == 2 {
                // The client ended its deflate stream; what follows is at most
                // the tail put back above.
                ended = true
                break
            }
            if remaining == 0 && rc == 0 { break }
            if consumed == 0 && produced == 0 && rc == 0 { return WSCloseCode.invalidPayload }
        }
        if ended || agreement.clientNoContextTakeover {
            if av_ws_inflate_reset(z) != 0 { return WSCloseCode.internalError }
        }
        return 0
    }

    /// Reads while the queue has room, and writes while bytes are queued.
    mutating func updateWebSocketReadInterest(_ slot: Int) {
        let c = table[slot]
        // A stream has no descriptor: flow control is its read interest.
        guard c.pointee.state == .websocket, !c.pointee.isStream else { return }
        var mask: PollMask = websocketQueueFull(slot) || c.pointee.ws.closeReceived ? [] : .read
        if !c.pointee.write.isEmpty { mask.insert(.write) }
        setInterest(slot, mask)
    }

    /// Ping, pong and close, answered without the handler. False once the
    /// connection has been failed or closed.
    private mutating func handleControlFrame(_ slot: Int, _ header: WSFrameHeader,
                                             _ payload: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let c = table[slot]
        // At most 125 bytes, which the header parser has checked.
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 125) { scratch in
            let p = scratch.baseAddress!
            if n > 0 { WebSocketCodec.unmask(p, payload, n, header.mask) }
            switch header.opcode {
            case .ping:
                if !c.pointee.ws.closeSent {
                    WebSocketCodec.writeFrame(&c.pointee.write, opcode: .pong, fin: true,
                                              payload: n > 0 ? UnsafePointer(p) : nil, length: n)
                    if !flush(slot) { return false }
                }
            case .pong:
                c.pointee.ws.pingSentAt = 0
            case .close:
                var code = WSCloseCode.noStatus
                if n == 1 {
                    failWebSocket(slot, code: WSCloseCode.protocolError)
                    return false
                }
                if n >= 2 {
                    code = UInt16(p[0]) << 8 | UInt16(p[1])
                    // A close with a code no endpoint may send, or a reason that
                    // is not UTF-8, is itself a protocol error.
                    guard WebSocketCodec.isSendableCloseCode(code) else {
                        failWebSocket(slot, code: WSCloseCode.protocolError)
                        return false
                    }
                    var validator = UTF8Validator()
                    if n > 2 && (!validator.feed(UnsafePointer(p + 2), n - 2) || !validator.isComplete) {
                        failWebSocket(slot, code: WSCloseCode.invalidPayload)
                        return false
                    }
                }
                c.pointee.ws.closeReceived = true
                if let channel = c.pointee.ws.channel {
                    channel.closeCode = code
                    channel.closeReason = n > 2 ? Array(UnsafeBufferPointer(start: UnsafePointer(p + 2), count: n - 2)) : []
                    channel.ended = true
                    channel.receiveWaiter.take()?.resume()
                }
                // Anything after a close is not part of the conversation.
                c.pointee.read.clear()
                // Answered with the same code, which ends the handshake; the
                // connection goes once the answer is written. A close of ours
                // that went first has had its answer now.
                if c.pointee.ws.closeSent {
                    closeWebSocketIfDone(slot)
                } else {
                    sendCloseFrame(slot, code: code == WSCloseCode.noStatus ? WSCloseCode.normal : code,
                                   reason: nil, reasonLength: 0)
                }
                return false
            default:
                break
            }
            return true
        }
    }

    // MARK: - Sending

    /// Frames one message from the handler. False when the connection can no
    /// longer send: closed, or failed while compressing.
    mutating func sendWebSocketMessage(_ slot: Int, opcode: WSOpcode,
                                       _ p: UnsafePointer<UInt8>?, _ n: Int) -> Bool {
        let c = table[slot]
        guard c.pointee.state == .websocket, !c.pointee.ws.closeSent else { return false }
        if let agreement = c.pointee.ws.deflate, let p, n >= WSDeflate.minimumMessage {
            if c.pointee.ws.deflater == nil {
                c.pointee.ws.deflater = av_ws_deflate_new(agreement.deflateWindowBits, WSDeflate.memoryLevel)
            }
            // Without a compressor the message goes out as it is: the extension
            // lets any message be sent uncompressed.
            if let z = c.pointee.ws.deflater {
                var compressed = ByteBuffer()
                defer { compressed.destroy() }
                guard deflateMessage(z, p, n, into: &compressed) else {
                    // The context is in an unknown state, and the client's copy
                    // of it would no longer match anything sent after.
                    failWebSocket(slot, code: WSCloseCode.internalError)
                    return false
                }
                WebSocketCodec.writeFrame(&c.pointee.write, opcode: opcode, fin: true, rsv1: true,
                                          payload: UnsafePointer(compressed.readPointer),
                                          length: compressed.readableBytes)
                if agreement.serverNoContextTakeover { _ = av_ws_deflate_reset(z) }
                return flush(slot)
            }
        }
        WebSocketCodec.writeFrame(&c.pointee.write, opcode: opcode, fin: true, payload: p, length: n)
        return flush(slot)
    }

    /// One message, compressed with a sync flush and without the empty block
    /// that ends it, which the receiver puts back.
    private func deflateMessage(_ z: UnsafeMutableRawPointer, _ p: UnsafePointer<UInt8>, _ n: Int,
                                into out: inout ByteBuffer) -> Bool {
        var input = p
        var remaining = n
        while true {
            out.reserve(max(1024, remaining / 2 + 64))
            var consumed = 0
            var produced = 0
            let rc = av_ws_deflate_run(z, input, remaining, out.writePointer, out.writableBytes,
                                       &consumed, &produced)
            input += consumed
            remaining -= consumed
            out.advanceWriter(produced)
            if rc < 0 { return false }
            if rc == 0 && remaining == 0 { break }
            if rc == 0 && consumed == 0 && produced == 0 { return false }
        }
        let length = out.readableBytes
        guard length >= 4 else { return false }
        let tail = out.readPointer + length - 4
        guard tail[0] == 0x00, tail[1] == 0x00, tail[2] == 0xFF, tail[3] == 0xFF else { return false }
        out.truncate(to: length - 4)
        return true
    }

    /// What the connection has queued and the peer has not taken yet.
    func websocketBacklog(_ slot: Int) -> Int {
        // On HTTP/3 bytes go to the transport at once; what counts is what it
        // holds unacknowledged.
        streamBacklog(slot)
    }

    /// Ends the WebSocket's connection, or on HTTP/2 and HTTP/3 its stream:
    /// cleanly once the closes are done, or abandoned.
    mutating func endWebSocket(_ slot: Int, clean: Bool) {
        if table[slot].pointee.isStream {
            endStreamWebSocket(slot, clean: clean)
        } else {
            closeConnection(slot)
        }
    }

    /// Queues a close frame. Once the peer's close has also come, the
    /// connection ends when the write buffer drains.
    mutating func sendCloseFrame(_ slot: Int, code: UInt16,
                                 reason: UnsafePointer<UInt8>?, reasonLength: Int) {
        let c = table[slot]
        guard c.pointee.state == .websocket, !c.pointee.ws.closeSent else { return }
        c.pointee.ws.closeSent = true
        c.pointee.ws.closeSentAt = av_monotonic_ms()
        WebSocketCodec.writeClose(&c.pointee.write, code: code, reason: reason, reasonLength: reasonLength)
        // Writers waiting for room will never get to use it.
        c.pointee.ws.channel?.wakeWriters()
        if !flush(slot) { return }
        closeWebSocketIfDone(slot)
    }

    /// Ends the connection once both closes have been exchanged and written,
    /// or the peer has gone.
    mutating func closeWebSocketIfDone(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.state == .websocket, c.pointee.write.isEmpty else { return }
        if (c.pointee.ws.closeSent && c.pointee.ws.closeReceived)
            || c.pointee.flags.contains(.peerClosed) {
            endWebSocket(slot, clean: true)
        }
    }

    /// Ends the connection because the peer broke the protocol.
    ///
    /// Messages that arrived before the violation are still the handler's:
    /// while any are unread, the close waits for them to be read, so that
    /// what the handler answers them with goes out first, as it would have
    /// had the frames arrived one at a time.
    mutating func failWebSocket(_ slot: Int, code: UInt16) {
        let c = table[slot]
        // Nothing further from this peer can be trusted.
        c.pointee.read.clear()
        c.pointee.ws.closeReceived = true
        if let channel = c.pointee.ws.channel, !channel.gone, !channel.queue.isEmpty,
           c.pointee.state == .websocket, !c.pointee.ws.closeSent {
            c.pointee.ws.pendingFailure = code
            c.pointee.ws.pendingFailureAt = av_monotonic_ms()
            if !c.pointee.isStream { setInterest(slot, c.pointee.write.isEmpty ? [] : .write) }
            return
        }
        applyWebSocketFailure(slot, code: code)
    }

    /// Acts on a violation that was waiting for the handler to catch up.
    mutating func applyPendingWebSocketFailure(_ slot: Int) {
        let c = table[slot]
        let code = c.pointee.ws.pendingFailure
        guard code != 0, c.pointee.state == .websocket else { return }
        c.pointee.ws.pendingFailure = 0
        applyWebSocketFailure(slot, code: code)
    }

    private mutating func applyWebSocketFailure(_ slot: Int, code: UInt16) {
        let c = table[slot]
        if let channel = c.pointee.ws.channel, !channel.ended {
            channel.closeCode = code
            channel.ended = true
            channel.receiveWaiter.take()?.resume()
        }
        if c.pointee.state == .websocket && !c.pointee.ws.closeSent {
            sendCloseFrame(slot, code: code, reason: nil, reasonLength: 0)
        } else {
            closeWebSocketIfDone(slot)
        }
    }

    // MARK: - Readiness and housekeeping

    mutating func handleWebSocketReadable(_ slot: Int) {
        // One whole frame has to fit, and a frame is bounded by the message
        // limit plus its header. Reading further ahead would let a peer pin
        // twice the configured limit per connection.
        if !fill(slot, .read, limit: config.maxWebsocketMessageSize &+ 1024) { return }
        let c = table[slot]
        if c.pointee.state != .websocket { return }
        pumpWebSocket(slot)
        guard table[slot].pointee.state == .websocket else { return }
        if c.pointee.flags.contains(.peerClosed) {
            // The socket ended without a close frame: 1006, as RFC 6455 says
            // to report it.
            if let channel = c.pointee.ws.channel, !channel.ended {
                channel.ended = true
                channel.receiveWaiter.take()?.resume()
            }
            if c.pointee.write.isEmpty { closeConnection(slot) } else { c.pointee.ws.closeReceived = true }
        }
    }

    /// Keepalive pings, dead-peer detection, and a close nobody answered.
    mutating func sweepWebSocket(_ slot: Int, now: UInt64) {
        let c = table[slot]
        if c.pointee.ws.pendingFailure != 0 {
            if now &- c.pointee.ws.pendingFailureAt > config.websocketPingTimeoutMs {
                applyPendingWebSocketFailure(slot)
            }
            return
        }
        if c.pointee.ws.closeSent {
            if now &- c.pointee.ws.closeSentAt > config.websocketPingTimeoutMs { endWebSocket(slot, clean: false) }
            return
        }
        let interval = config.websocketPingIntervalMs
        if interval == 0 { return }
        if c.pointee.ws.pingSentAt != 0 {
            // No pong came back: the peer is gone even if the socket has not
            // noticed, which is what pings are for.
            if now &- c.pointee.ws.pingSentAt > config.websocketPingTimeoutMs { endWebSocket(slot, clean: false) }
            return
        }
        if now &- c.pointee.lastActivity < interval { return }
        WebSocketCodec.writeFrame(&c.pointee.write, opcode: .ping, fin: true, payload: nil, length: 0)
        c.pointee.ws.pingSentAt = now
        _ = flush(slot)
    }

    /// Wakes a handler waiting to send once the backlog has fallen to the
    /// write low-water mark.
    mutating func resumeWebSocketWriter(_ slot: Int) {
        let c = table[slot]
        guard let channel = c.pointee.ws.channel, channel.isWriteWaiting,
              streamBacklog(slot) <= config.writeLowWaterMark else { return }
        channel.wakeWriters()
    }

    /// Releases everything a WebSocket holds. Called from `closeConnection`.
    mutating func releaseWebSocket(_ slot: Int) {
        let c = table[slot]
        if let channel = c.pointee.ws.channel {
            c.pointee.ws.channel = nil
            channel.ended = true
            channel.gone = true
            channel.wakeAll()
            for id in channel.sleeps { wakeTimed(id) }
            channel.sleeps.removeAll()
        }
        if let z = c.pointee.ws.deflater { av_ws_deflate_free(z) }
        if let z = c.pointee.ws.inflater { av_ws_inflate_free(z) }
        c.pointee.ws.message.destroy()
        c.pointee.ws = WebSocketState()
    }
}

/// Calls `body` with each comma-separated item of a header value, trimmed of
/// spaces and tabs. Empty items are skipped.
func forEachListItem(_ p: UnsafePointer<UInt8>, _ n: Int, _ body: (UnsafePointer<UInt8>, Int) -> Void) {
    var start = 0
    while start <= n {
        var end = start
        while end < n, p[end] != cComma { end += 1 }
        var lo = start
        var hi = end
        while lo < hi, p[lo] == cSP || p[lo] == cHT { lo += 1 }
        while hi > lo, p[hi - 1] == cSP || p[hi - 1] == cHT { hi -= 1 }
        if hi > lo { body(p + lo, hi - lo) }
        start = end + 1
    }
}
