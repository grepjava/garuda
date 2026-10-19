//===----------------------------------------------------------------------===//
// WebSockets: the connection's side.
//
// Once the 101 has gone, an HTTP/1 connection is a WebSocket's, and its
// stream is split: the connection's task keeps the reading half and reads
// frames for as long as the WebSocket lasts, and what is sent -- the
// handler's messages, and pongs and closes the reader answers with -- goes
// through a `BodyChannel` over the writing half, as a streamed body does,
// with its backpressure and write timeout. Over HTTP/2 the WebSocket is one
// stream's (HTTP2WebSocket.swift): its DATA is what is read, and its
// streamed answer what is written.
//
// Frames are decoded as they arrive, whether or not the handler is reading:
// a ping has to be answered and a pong seen on time, or a healthy peer the
// handler is merely busy with would be timed out. Data messages decoded
// ahead of the handler queue in the session, and once the queue is full the
// socket is no longer read, which makes a slow handler TCP backpressure
// rather than memory. Frames are decoded only once their whole payload is
// buffered; the message size limit bounds that.
//
// The close handshake is RFC 6455's: a close is answered with a close, and
// the connection ends once both have gone. A close the server sent first
// waits `--ws-ping-timeout` for the reply. The connection's task ends the
// handler's when the connection ends, and waits for it before it lets go of
// the stream.
//===----------------------------------------------------------------------===//

import VegaWire
@_spi(Garuda) import VegaWebSocketCore
import CVegaCompress
import GarudaWire
import Synchronization
import Vega
import VegaIO

final class WebSocketSession: @unchecked Sendable {
    let limits: WebSocketLimits
    let channel: BodyChannel
    let deflate: WebSocketDeflateAgreement?
    /// Where a close sent from outside the reader is flushed from.
    let runtime: Runtime?
    /// Ends the reader's wait for the socket: a close nobody answered, or a
    /// server going away.
    let wake = IOTimeoutTrigger()

    // The inbound side, under `lock`.
    private let lock = Mutex<Void>(())
    private var inbox: [WebSocketMessage] = []
    private var inboxHead = 0
    private var inboxBytes = 0
    private var receiving = false
    private var receiveWaiter: UnsafeContinuation<Void, Never>?
    /// The reader, waiting for the handler to make room.
    private var roomWaiter: UnsafeContinuation<Void, Never>?
    /// Nothing more will be queued: the peer closed, or the connection ended.
    private var ended = false
    /// The connection has ended: nothing more can be sent.
    private var gone = false
    private var closeCode: UInt16 = WebSocketCloseCode.abnormal
    private var closeReason: [UInt8] = []
    /// A violation behind messages the handler has not read: acted on once
    /// they have been.
    private var pendingFailure: UInt16 = 0

    // The outbound side, under `sendLock`.
    private let sendLock = Mutex<Void>(())
    private var closeSent = false
    private var frame = ByteBuffer()
    private var deflater: UnsafeMutableRawPointer?

    // The reader's alone.
    private var inflater: UnsafeMutableRawPointer?
    private var message = ByteBuffer()
    private var assembling = false
    private var messageText = false
    private var messageCompressed = false
    private var validator = UTF8Validator()
    private var pingSentAt: UInt64 = 0
    private var lastHeard: UInt64 = 0
    /// The last frame broke the protocol, and the close waits for the
    /// handler to read what came before it.
    private var failureWaits = false
    /// The reader queued a pong or a close: it flushes before it reads on.
    private var answered = false

    /// When the reader learnt the close was sent, for giving up on its reply.
    private let closeSentAt = Atomic<UInt64>(0)

    init(limits: WebSocketLimits, channel: BodyChannel, deflate: WebSocketDeflateAgreement?, runtime: Runtime?) {
        self.limits = limits
        self.channel = channel
        self.deflate = deflate
        self.runtime = runtime
    }

    deinit {
        frame.destroy()
        message.destroy()
        if let deflater { cv_ws_deflate_free(deflater) }
        if let inflater { cv_ws_inflate_free(inflater) }
    }

    var isGone: Bool { lock.withLock { _ in gone } }

    /// Messages that arrived before the end and have not been read.
    var hasUnread: Bool { lock.withLock { _ in inboxHead < inbox.count } }

    /// Over for the handler too: gone, with nothing left for it to read.
    var isOver: Bool { lock.withLock { _ in gone && inboxHead >= inbox.count } }

    var isClosed: Bool {
        if isGone { return true }
        return sendLock.withLock { _ in closeSent }
    }

    var peerClose: (code: UInt16, reason: String)? {
        lock.withLock { _ in
            ended ? (closeCode, String(decoding: closeReason, as: UTF8.self)) : nil
        }
    }

    // MARK: Receiving

    func receive() async throws -> WebSocketMessage? {
        while true {
            enum Next {
                case message(WebSocketMessage, UnsafeContinuation<Void, Never>?)
                case end, busy
                case wait(UnsafeContinuation<Void, Never>?)
            }
            let next = lock.withLock { _ -> Next in
                if inboxHead < inbox.count {
                    let m = inbox[inboxHead]
                    inboxHead += 1
                    switch m {
                    case .text(let text): inboxBytes -= text.utf8.count + 64
                    case .binary(let bytes): inboxBytes -= bytes.count + 64
                    }
                    if inboxHead == inbox.count {
                        inbox.removeAll(keepingCapacity: true)
                        inboxHead = 0
                    } else if inboxHead >= 32 && inboxHead * 2 >= inbox.count {
                        inbox.removeFirst(inboxHead)
                        inboxHead = 0
                    }
                    // Room has been made, or a violation behind the queue
                    // can be acted on now that it is read.
                    let w = roomWaiter
                    roomWaiter = nil
                    return .message(m, w)
                }
                if ended { return .end }
                if receiving { return .busy }
                // Everything before a violation has been read: the reader
                // can close now.
                var room: UnsafeContinuation<Void, Never>? = nil
                if pendingFailure != 0 {
                    room = roomWaiter
                    roomWaiter = nil
                }
                return .wait(room)
            }
            switch next {
            case .message(let m, let w):
                w?.resume()
                return m
            case .end:
                return nil
            case .busy:
                throw WebSocketError.busy
            case .wait(let room):
                room?.resume()
                await withTaskCancellationHandler {
                    await withUnsafeContinuation { (c: UnsafeContinuation<Void, Never>) in
                        let now = lock.withLock { _ -> Bool in
                            if inboxHead < inbox.count || ended || Task.isCancelled { return true }
                            receiving = true
                            receiveWaiter = c
                            return false
                        }
                        if now { c.resume() }
                    }
                } onCancel: {
                    let w = lock.withLock { _ -> UnsafeContinuation<Void, Never>? in
                        let w = receiveWaiter
                        receiveWaiter = nil
                        receiving = false
                        return w
                    }
                    w?.resume()
                }
                lock.withLock { _ in receiving = false }
                // Ended is nil, from the top; cancelled with nothing to read
                // is the connection gone under a handler still waiting.
                if Task.isCancelled && lock.withLock({ _ in inboxHead >= inbox.count && !ended }) {
                    throw WebSocketError.closed
                }
            }
        }
    }

    // MARK: Sending

    /// Frames one message onto the channel, compressed if that was agreed.
    func send(_ opcode: WebSocketOpcode, _ bytes: UnsafeBufferPointer<UInt8>) -> BodyChannel.Queued {
        if isGone { return .refused }
        return sendLock.withLock { _ -> BodyChannel.Queued in
            guard !closeSent else { return .refused }
            frame.clear()
            if let deflate, bytes.count >= WebSocketDeflate.minimumMessage, let base = bytes.baseAddress,
               let compressed = compress(deflate, base, bytes.count) {
                WebSocketCodec.writeFrame(&frame, opcode: opcode, fin: true, rsv1: true,
                                          payload: compressed.base, length: compressed.count)
            } else {
                WebSocketCodec.writeFrame(&frame, opcode: opcode, fin: true, payload: bytes.baseAddress,
                                          length: bytes.count)
            }
            return channel.queue(UnsafeRawBufferPointer(start: frame.readPointer, count: frame.readableBytes))
        }
    }

    func settle(_ queued: BodyChannel.Queued) async throws {
        do {
            try await channel.settle(queued)
        } catch {
            throw WebSocketError.closed
        }
    }

    /// A control frame the reader answers with: a pong, unless a close has
    /// gone out.
    private func sendControl(_ opcode: WebSocketOpcode, _ payload: UnsafePointer<UInt8>?, _ count: Int) {
        sendLock.withLock { _ in
            guard !closeSent else { return }
            frame.clear()
            WebSocketCodec.writeFrame(&frame, opcode: opcode, fin: true, payload: payload, length: count)
            _ = channel.queue(UnsafeRawBufferPointer(start: frame.readPointer, count: frame.readableBytes))
        }
        answered = true
    }

    /// Queues a close, the first one only, and has it flushed: by the reader
    /// when it is the one closing, otherwise on the runtime.
    @discardableResult
    func sendClose(code: UInt16, reason: [UInt8], byReader: Bool = false) -> Bool {
        let sent = sendLock.withLock { _ -> Bool in
            guard !closeSent else { return false }
            closeSent = true
            frame.clear()
            reason.withUnsafeBufferPointer {
                WebSocketCodec.writeClose(&frame, code: code, reason: $0.baseAddress, reasonLength: $0.count)
            }
            _ = channel.queue(UnsafeRawBufferPointer(start: frame.readPointer, count: frame.readableBytes))
            return true
        }
        guard sent else { return false }
        closeSentAt.store(monotonicNanos(), ordering: .relaxed)
        if byReader {
            answered = true
        } else {
            let channel = self.channel
            if let runtime {
                runtime.spawn { try? await channel.settle(.sent) }
            } else {
                Task { try? await channel.settle(.sent) }
            }
            // The reader learns of it when it next wakes; wake it so it can
            // time the reply.
            wake.fire()
        }
        return true
    }

    /// `n` bytes compressed with a sync flush, without the empty block that
    /// ends it, which the receiver puts back. Nil to send them as they are.
    /// Under `sendLock`.
    private func compress(_ agreement: WebSocketDeflateAgreement, _ p: UnsafePointer<UInt8>, _ n: Int)
        -> (base: UnsafePointer<UInt8>, count: Int)? {
        if deflater == nil {
            deflater = cv_ws_deflate_new(agreement.deflateWindowBits, WebSocketDeflate.memoryLevel)
        }
        guard let z = deflater else { return nil }
        // Behind the frame's own header, which goes first in `frame`; the
        // compressed bytes are built in `message`'s twin.
        compressed.clear()
        var input = p
        var remaining = n
        while true {
            compressed.reserve(max(1024, remaining / 2 + 64))
            var consumed = 0
            var produced = 0
            let rc = cv_ws_deflate_run(z, input, remaining, compressed.writePointer, compressed.writableBytes,
                                       &consumed, &produced)
            input += consumed
            remaining -= consumed
            compressed.advanceWriter(produced)
            if rc < 0 { return nil }
            if rc == 0 && remaining == 0 { break }
            if rc == 0 && consumed == 0 && produced == 0 { return nil }
        }
        let length = compressed.readableBytes
        guard length >= 4 else { return nil }
        let tail = compressed.readPointer + length - 4
        guard tail[0] == 0x00, tail[1] == 0x00, tail[2] == 0xFF, tail[3] == 0xFF else { return nil }
        if agreement.serverNoContextTakeover { _ = cv_ws_deflate_reset(z) }
        return (UnsafePointer(compressed.readPointer), length - 4)
    }

    private var compressed = ByteBuffer()

    // MARK: Reading

    private enum Step { case more, full, stop }

    /// Reads frames until the WebSocket ends: the closes have crossed, the
    /// peer went, broke the protocol, stopped answering pings, or never
    /// answered a close. True for those last two: the peer was given up on,
    /// and its stream is better reset than ended.
    @discardableResult
    func read<R: AsyncReader & ~Copyable>(_ reader: borrowing R, leftover: [UInt8]) async -> Bool {
        var abandoned = false
        var input = IOBuffer(capacity: max(16 * 1024, leftover.count))
        if !leftover.isEmpty { _ = leftover.withUnsafeBytes { input.append($0) } }
        lastHeard = monotonicNanos()
        reading: while true {
            let step = processFrames(&input)
            if answered {
                answered = false
                try? await channel.settle(.sent)
            }
            switch step {
            case .stop:
                break reading
            case .full:
                await waitForRoom()
                if lock.withLock({ _ in gone }) { break reading }
                if lock.withLock({ _ in pendingFailure != 0 && inboxHead >= inbox.count }) {
                    applyPendingFailure()
                    answered = false
                    try? await channel.settle(.sent)
                    break reading
                }
                continue reading
            case .more:
                break
            }
            // One whole frame has to fit; a frame is bounded by the message
            // limit and its header.
            if input.spareCapacity < 4096 && input.capacity < limits.maxMessage + 4096 {
                input.reserveCapacity(min(input.capacity * 2, limits.maxMessage + 4096))
            }
            let wait = nextWait()
            do {
                // An idle socket's wait holds no buffer (readHoldingNothing).
                let n = try await Runtime.withIOTimeout(for: wait, trigger: wake) { () async throws(IOError) -> Int in
                    try await readHoldingNothing(reader, into: &input, capacity: 16 * 1024)
                }
                if n == 0 { break reading }
                lastHeard = monotonicNanos()
            } catch let error {
                guard error == .timedOut else { break reading }
                if !timersAllowReading() {
                    abandoned = !lock.withLock { _ in gone }
                    break reading
                }
            }
        }
        readerEnded()
        return abandoned
    }

    /// How long the next read may wait: until a keepalive ping is due, a
    /// pong is overdue, or a close has gone unanswered too long.
    private func nextWait() -> Duration {
        let now = monotonicNanos()
        var until = UInt64.max
        let interval = nanos(limits.pingInterval)
        let timeout = nanos(limits.pingTimeout)
        let closed = closeSentAt.load(ordering: .relaxed)
        if closed != 0 {
            until = closed &+ timeout
        } else if interval > 0 {
            until = pingSentAt != 0 ? pingSentAt &+ timeout : lastHeard &+ interval
        }
        if until == .max { return .seconds(86_400) }
        return .nanoseconds(Int64(clamping: until > now ? until - now : 0))
    }

    /// A read gave up on its deadline: what is due now. False when the
    /// WebSocket is over.
    private func timersAllowReading() -> Bool {
        if lock.withLock({ _ in gone }) { return false }
        let now = monotonicNanos()
        let timeout = nanos(limits.pingTimeout)
        let closed = closeSentAt.load(ordering: .relaxed)
        if closed != 0 {
            // A close nobody answered.
            return now < closed &+ timeout
        }
        let interval = nanos(limits.pingInterval)
        guard interval > 0 else { return true }
        if pingSentAt != 0 {
            // No pong came back: the peer is gone even if the socket has
            // not noticed, which is what pings are for.
            if now >= pingSentAt &+ timeout { return false }
            return true
        }
        if now >= lastHeard &+ interval {
            sendControl(.ping, nil, 0)
            pingSentAt = now
        }
        return true
    }

    private func nanos(_ d: Duration) -> UInt64 {
        let (s, a) = d.components
        return UInt64(clamping: s) &* 1_000_000_000 &+ UInt64(clamping: a / 1_000_000_000)
    }

    private func queueFull() -> Bool {
        lock.withLock { _ in
            let pending = inbox.count - inboxHead
            if pending >= limits.maxQueue { return true }
            return pending > 0 && inboxBytes >= limits.maxQueueBytes
        }
    }

    private func waitForRoom() async {
        await withUnsafeContinuation { (c: UnsafeContinuation<Void, Never>) in
            let now = lock.withLock { _ -> Bool in
                let pending = inbox.count - inboxHead
                let full = pending >= limits.maxQueue || (pending > 0 && inboxBytes >= limits.maxQueueBytes)
                if (!full && pendingFailure == 0) || gone { return true }
                if pendingFailure != 0 && pending == 0 { return true }
                roomWaiter = c
                return false
            }
            if now { c.resume() }
        }
    }

    /// Decodes every whole frame buffered: control frames are answered now,
    /// and complete data messages queued for the handler.
    private func processFrames(_ input: inout IOBuffer) -> Step {
        var step = Step.more
        var used = 0
        input.withUnsafeBytes { raw in
            guard raw.count > 0 else { return }
            let all = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            /// After a frame that ended the conversation: nothing further
            /// from this peer can be trusted.
            func over() {
                used = raw.count
                step = failureWaits ? .full : .stop
            }
            while true {
                if queueFull() {
                    step = .full
                    return
                }
                let available = raw.count - used
                if available == 0 { return }
                let base = all + used
                switch WebSocketCodec.parseHeader(base, available, maxPayload: limits.maxMessage,
                                                  allowRSV1: deflate != nil) {
                case .needMore:
                    return
                case .failure(let error):
                    fail(error == .messageTooBig ? WebSocketCloseCode.messageTooBig : WebSocketCloseCode.protocolError)
                    over()
                    return
                case .header(let header):
                    // Every frame from a client is masked (RFC 6455 section
                    // 5.1). An unmasked one is a broken client, or an attempt
                    // to have an intermediary read the payload as something
                    // else.
                    guard header.masked else {
                        fail(WebSocketCloseCode.protocolError)
                        over()
                        return
                    }
                    if available < header.totalLength { return }
                    let payload = base + header.headerLength
                    used += header.totalLength
                    let goOn = header.opcode.isControl ? control(header, payload) : data(header, payload)
                    if !goOn {
                        over()
                        return
                    }
                }
            }
        }
        if used > 0 { input.consume(used) }
        return step
    }

    /// Ping, pong and close. False once the WebSocket is over.
    private func control(_ header: WebSocketFrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        let n = header.payloadLength
        // At most 125 bytes, which the header parser has checked.
        return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 125) { scratch in
            let p = scratch.baseAddress!
            if n > 0 { WebSocketCodec.unmask(p, payload, n, header.mask) }
            switch header.opcode {
            case .ping:
                sendControl(.pong, n > 0 ? UnsafePointer(p) : nil, n)
                return true
            case .pong:
                pingSentAt = 0
                return true
            case .close:
                if n == 1 {
                    fail(WebSocketCloseCode.protocolError)
                    return false
                }
                var code = WebSocketCloseCode.noStatus
                var reason: [UInt8] = []
                if n >= 2 {
                    code = UInt16(p[0]) << 8 | UInt16(p[1])
                    // A close with a code no endpoint may send, or a reason
                    // that is not UTF-8, is itself a protocol error.
                    guard WebSocketCodec.isSendableCloseCode(code) else {
                        fail(WebSocketCloseCode.protocolError)
                        return false
                    }
                    var check = UTF8Validator()
                    if n > 2 && (!check.feed(UnsafePointer(p + 2), n - 2) || !check.isComplete) {
                        fail(WebSocketCloseCode.invalidPayload)
                        return false
                    }
                    reason = Array(UnsafeBufferPointer(start: UnsafePointer(p + 2), count: n - 2))
                }
                peerClosed(code: code, reason: reason)
                // Answered with the same code, which ends the handshake; a
                // close of ours that went first has had its answer now.
                sendClose(code: code == WebSocketCloseCode.noStatus ? WebSocketCloseCode.normal : code, reason: [],
                          byReader: true)
                return false
            default:
                return true
            }
        }
    }

    /// One data frame onto the message being assembled; the message onto
    /// the queue once it is whole. False once the WebSocket is over.
    private func data(_ header: WebSocketFrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        let n = header.payloadLength
        if header.opcode == .continuation {
            guard assembling else { return failed(WebSocketCloseCode.protocolError) }
        } else {
            // A new message while one is still in progress.
            guard !assembling else { return failed(WebSocketCloseCode.protocolError) }
            assembling = true
            messageText = header.opcode == .text
            messageCompressed = header.rsv1
            validator = UTF8Validator()
            message.clear()
        }
        // For a compressed message this bounds the compressed bytes; what
        // they inflate to is held to the same limit as they inflate.
        if message.readableBytes + n > limits.maxMessage { return failed(WebSocketCloseCode.messageTooBig) }
        if n > 0 {
            message.reserve(n)
            WebSocketCodec.unmask(message.writePointer, payload, n, header.mask)
            // Checked as it arrives, so an invalid message fails at the frame
            // that makes it invalid. Compressed bytes are checked inflated.
            if messageText && !messageCompressed
                && !validator.feed(UnsafePointer(message.writePointer), n) {
                return failed(WebSocketCloseCode.invalidPayload)
            }
            message.advanceWriter(n)
        }
        if !header.fin { return true }
        assembling = false
        if messageCompressed {
            var inflated = ByteBuffer()
            defer { inflated.destroy() }
            let status = inflate(into: &inflated)
            if status != 0 { return failed(status) }
            if messageText {
                var check = UTF8Validator()
                let count = inflated.readableBytes
                if count > 0 && (!check.feed(UnsafePointer(inflated.readPointer), count) || !check.isComplete) {
                    return failed(WebSocketCloseCode.invalidPayload)
                }
            }
            enqueue(inflated)
        } else {
            if messageText && !validator.isComplete { return failed(WebSocketCloseCode.invalidPayload) }
            enqueue(message)
        }
        message.clear()
        return true
    }

    private func enqueue(_ payload: borrowing ByteBuffer) {
        let count = payload.readableBytes
        let bytes = UnsafeBufferPointer(start: count > 0 ? UnsafePointer(payload.readPointer) : nil, count: count)
        let m: WebSocketMessage = messageText ? .text(String(decoding: bytes, as: UTF8.self)) : .binary(Array(bytes))
        let w = lock.withLock { _ -> UnsafeContinuation<Void, Never>? in
            inbox.append(m)
            inboxBytes += count + 64
            let w = receiveWaiter
            receiveWaiter = nil
            return w
        }
        w?.resume()
    }

    /// Inflates the compressed message into `out`. 0, or the close code to
    /// fail with: 1009 when it inflates past the message limit -- a few
    /// kilobytes of zeros can claim gigabytes -- 1007 when it is not deflate
    /// at all, 1011 when there is no memory for zlib.
    private func inflate(into out: inout ByteBuffer) -> UInt16 {
        guard let agreement = deflate else { return WebSocketCloseCode.protocolError }
        if inflater == nil { inflater = cv_ws_inflate_new(agreement.inflateWindowBits) }
        guard let z = inflater else { return WebSocketCloseCode.internalError }
        let limit = limits.maxMessage
        // The sender strips the empty block that ends a sync flush.
        let tail: [UInt8] = [0x00, 0x00, 0xFF, 0xFF]
        tail.withUnsafeBufferPointer { message.write($0.baseAddress!, 4) }
        var input = UnsafePointer(message.readPointer)
        var remaining = message.readableBytes
        var ended = false
        while true {
            if out.readableBytes > limit { return WebSocketCloseCode.messageTooBig }
            out.reserve(min(max(remaining * 4, 4096), 1 << 20))
            let room = min(out.writableBytes, limit + 1 - out.readableBytes)
            var consumed = 0
            var produced = 0
            let rc = cv_ws_inflate_run(z, input, remaining, out.writePointer, room, &consumed, &produced)
            input += consumed
            remaining -= consumed
            out.advanceWriter(produced)
            if rc < 0 { return WebSocketCloseCode.invalidPayload }
            if out.readableBytes > limit { return WebSocketCloseCode.messageTooBig }
            if rc == 2 {
                // The client ended its deflate stream; what follows is at
                // most the tail put back above.
                ended = true
                break
            }
            if remaining == 0 && rc == 0 { break }
            if consumed == 0 && produced == 0 && rc == 0 { return WebSocketCloseCode.invalidPayload }
        }
        if ended || agreement.clientNoContextTakeover {
            if cv_ws_inflate_reset(z) != 0 { return WebSocketCloseCode.internalError }
        }
        return 0
    }

    // MARK: Ending

    /// The peer broke the protocol. Messages that arrived before the
    /// violation are still the handler's: while any are unread, the close
    /// waits for them to be read, so that what the handler answers them
    /// with goes out first.
    private func fail(_ code: UInt16) {
        let waits = lock.withLock { _ -> Bool in
            guard inboxHead < inbox.count else { return false }
            pendingFailure = code
            return true
        }
        failureWaits = waits
        if !waits { failNow(code) }
    }

    /// `fail`, as a data frame's answer: stop.
    private func failed(_ code: UInt16) -> Bool {
        fail(code)
        return false
    }

    private func applyPendingFailure() {
        let code = lock.withLock { _ -> UInt16 in
            let code = pendingFailure
            pendingFailure = 0
            return code
        }
        if code != 0 { failNow(code) }
    }

    private func failNow(_ code: UInt16) {
        peerClosed(code: code, reason: [])
        sendClose(code: code, reason: [], byReader: true)
    }

    private func peerClosed(code: UInt16, reason: [UInt8]) {
        let w = lock.withLock { _ -> UnsafeContinuation<Void, Never>? in
            if !ended {
                ended = true
                closeCode = code
                closeReason = reason
            }
            let w = receiveWaiter
            receiveWaiter = nil
            return w
        }
        w?.resume()
    }

    /// The reader is done: nothing more will arrive, and nothing more can be
    /// sent beyond what is queued.
    private func readerEnded() {
        let (receiver, room) = lock.withLock { _ -> (UnsafeContinuation<Void, Never>?, UnsafeContinuation<Void, Never>?) in
            ended = true
            gone = true
            let r = receiveWaiter
            receiveWaiter = nil
            let w = roomWaiter
            roomWaiter = nil
            return (r, w)
        }
        receiver?.resume()
        room?.resume()
    }

    /// The handler returned or threw: a WebSocket it left open is closed for
    /// it.
    func handlerFinished(failed: Bool) {
        // A violation waiting on the handler is the reader's to act on.
        if lock.withLock({ _ in pendingFailure != 0 }) {
            let w = lock.withLock { _ -> UnsafeContinuation<Void, Never>? in
                let w = roomWaiter
                roomWaiter = nil
                return w
            }
            w?.resume()
            return
        }
        sendClose(code: failed ? WebSocketCloseCode.internalError : WebSocketCloseCode.normal, reason: [])
    }

    /// The server is going away: 1001, then the usual wait for the reply.
    func goAway() {
        sendClose(code: WebSocketCloseCode.goingAway, reason: [])
    }

    /// The reader and the handler are done: what is queued goes, and then
    /// nothing more.
    func drain() async {
        await channel.stopAfterDraining()
    }
}

// MARK: - Serving an upgraded connection

/// Runs the WebSocket `upgrade` accepted on an HTTP/1 connection, on its
/// stream split in two, until it ends.
func serveWebSocket<R: AsyncReader & ~Copyable, W: AsyncWriter & ~Copyable & Sendable>(
    _ halves: consuming StreamHalves<R, W>, _ upgrade: WebSocketUpgrade, app: CompiledApplication,
    limits: ConnectionLimits, closeWriter: @Sendable (borrowing W) async -> Void
) async {
    let reader = halves.reader
    let held = UnsafeMutablePointer<W>.allocate(capacity: 1)
    held.initialize(to: halves.writer)
    let channel = BodyChannel(raw: HeldStream(pointer: UnsafeMutableRawPointer(held), writer: HeldWriter<W>.self),
                              limits: StreamLimits(limits))
    let session = WebSocketSession(limits: upgrade.limits, channel: channel, deflate: upgrade.deflate,
                                   runtime: app.runtime)
    let handler = startWebSocketHandler(session, upgrade, app: app)
    await session.read(reader, leftover: upgrade.leftover)
    // The connection is over. A handler with messages still to read reads
    // them, and its receive then ends; one with none is told by being
    // cancelled. Either way it is waited for before the stream it writes to
    // is let go of.
    if !session.hasUnread { handler.cancel() }
    await handler.value
    await session.drain()
    app.webSockets.remove(session)
    await closeWriter(held.pointee)
    held.deinitialize(count: 1)
    held.deallocate()
}

/// Registers `session` and runs `upgrade`'s handler on it in a task of its
/// own, which closes the WebSocket when the handler returns or throws.
func startWebSocketHandler(_ session: WebSocketSession, _ upgrade: WebSocketUpgrade,
                           app: CompiledApplication) -> Task<Void, Never> {
    let socket = WebSocket(session: session, subprotocol: upgrade.subprotocol,
                           offeredSubprotocols: upgrade.offered)
    app.webSockets.add(session)
    let run = upgrade.run
    let body: @concurrent @Sendable () async -> Void = {
        var failed = false
        do {
            try await run.run(socket)
        } catch is CancellationError {
        } catch let error as WebSocketError where error == .closed {
            // The WebSocket ended under the handler; nothing went wrong.
        } catch {
            failed = true
            Log.error("websocket handler threw: \(error)")
        }
        session.handlerFinished(failed: failed)
    }
    return app.runtime?.spawn(body) ?? Task(operation: body)
}

/// The WebSockets a shard holds, to be closed with 1001 when it shuts down.
final class WebSocketRegistry: Sendable {
    private let sessions = Mutex<[ObjectIdentifier: WebSocketSession]>([:])
    private let stopping = Atomic<Bool>(false)

    func add(_ session: WebSocketSession) {
        sessions.withLock { $0[ObjectIdentifier(session)] = session }
        if stopping.load(ordering: .acquiring) { session.goAway() }
    }

    func remove(_ session: WebSocketSession) {
        _ = sessions.withLock { $0.removeValue(forKey: ObjectIdentifier(session)) }
    }

    func shutdown() {
        stopping.store(true, ordering: .releasing)
        let all = sessions.withLock { Array($0.values) }
        for session in all { session.goAway() }
    }
}
