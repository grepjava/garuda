//===----------------------------------------------------------------------===//
// An HTTP/3 request stream, and its answer.
//
// A request is read by the endpoint (HTTP3Connection.swift) into the stream's
// own `Exchange`, exactly as HTTP/2 rebuilds one: described as the HTTP/1
// parser would describe the HTTP/1.1 head it amounts to, with its version set
// to 3. Its body is collected whole before dispatch, held to the same body
// limit. Then the stream runs `dispatch` in a task from the shard's stream
// pool, and a stream the client cancels has its task cancelled.
//
// The task never touches the QUIC connection. It frames its answer itself --
// QPACK here never indexes, so encoding needs no state shared with anything
// -- and hands it to the endpoint by POSTING the stream: under the endpoint's
// lock, the stream goes on the endpoint's list and the endpoint is woken.
//
//   - A whole answer is a HEADERS frame and a DATA frame header, framed in
//     the stream's `outHead`, and the body where the handler left it, in the
//     exchange. The endpoint sends the head and then moves the body onto the
//     QUIC stream as far as the stream's send budget allows, the rest as
//     acknowledgements make room, and then the stream's FIN.
//   - A streamed answer (StreamingResponse.swift) is staged: its HEADERS
//     frame, then DATA frames as the handler writes, in `staged`, under the
//     lock. The endpoint takes them as room allows. A writer waits while more
//     than the high-water mark is staged, until the endpoint has taken it down
//     to the low-water mark. The end -- FIN, or a reset for a body cut short
//     -- goes once everything staged is out.
//   - An interim (1xx) head is staged too, and so goes out ahead of the
//     answer.
//
// Streams, their exchanges and their buffers are kept by their connection for
// its next request: a request costs no allocation once a connection is warm.
//===----------------------------------------------------------------------===//

import GarudaQUIC
import GarudaWire
import Synchronization
import Vega

/// One request stream. Kept by its connection for the next.
///
/// Its stored properties are `@exclusivity(unchecked)`: each is the
/// endpoint's, the task's, or kept under the endpoint's lock.
final class H3Stream: @unchecked Sendable {
    unowned(unsafe) let connection: H3Connection
    unowned(unsafe) let endpoint: QUICEndpoint
    let x: UnsafeMutablePointer<Exchange>
    /// The request head as HTTP/1.1 text; every slice in the exchange is
    /// relative to it.
    @exclusivity(unchecked) var head = ByteBuffer()
    @exclusivity(unchecked) var body = ByteBuffer()
    @exclusivity(unchecked) var id: UInt64 = 0

    // MARK: The endpoint's

    /// In the connection's table: the endpoint is not done with its QUIC
    /// stream.
    @exclusivity(unchecked) var inTable = false
    /// In the connection's spare list.
    @exclusivity(unchecked) var isSpare = false
    /// A task is running it, as far as the endpoint knows: until the task's
    /// last post is taken.
    @exclusivity(unchecked) var taskActive = false
    /// The request body is still arriving.
    @exclusivity(unchecked) var receiving = false
    /// Answered 413 while its body arrived: the rest is counted and dropped.
    @exclusivity(unchecked) var refused = false
    @exclusivity(unchecked) var trailersSeen = false
    /// The frame being read past its header: DATA, or one being skipped.
    @exclusivity(unchecked) var frameType: UInt64 = 0
    @exclusivity(unchecked) var frameRemaining = 0
    @exclusivity(unchecked) var received = 0
    @exclusivity(unchecked) var bodyLimit = 0
    /// The route matched for the body limit, or -1.
    @exclusivity(unchecked) var matched: Int32 = -1
    @exclusivity(unchecked) var lastActivity: UInt64 = 0
    /// FIN or a reset has been queued on the QUIC stream.
    @exclusivity(unchecked) var sendEnded = false
    /// A whole answer's: `outHead` is on the QUIC stream, and this much of
    /// the body of `bodyLength`.
    @exclusivity(unchecked) var headSent = false
    @exclusivity(unchecked) var bodySent = 0

    // MARK: Shared, under the endpoint's lock

    /// Cancelled by the client, or by the connection's end: whatever the
    /// task answers goes nowhere.
    @exclusivity(unchecked) var reset = false
    /// The handler's task while it runs, for a reset to cancel.
    @exclusivity(unchecked) var task: UnsafeCurrentTask?
    /// On the endpoint's list of posted streams.
    @exclusivity(unchecked) var queued = false
    /// The task has ended.
    @exclusivity(unchecked) var taskDone = false
    /// A whole answer is framed in `outHead`, its body of `bodyLength` in
    /// the exchange.
    @exclusivity(unchecked) var answerReady = false
    @exclusivity(unchecked) var bodyLength = 0
    /// The answer is streamed: everything is in `staged`.
    @exclusivity(unchecked) var streamed = false
    /// Frames for the endpoint to send, ahead of a whole answer's head.
    @exclusivity(unchecked) var staged = ByteBuffer()
    /// A streamed body has ended, whole or cut off part-way.
    @exclusivity(unchecked) var bodyEnded = false
    @exclusivity(unchecked) var bodyFailed = false
    /// Writers of a streamed body waiting for `staged` to drain.
    @exclusivity(unchecked) var waiters: [UnsafeContinuation<Bool, Never>] = []

    // MARK: The task's (or the endpoint's, when it answers itself)

    @exclusivity(unchecked) var outHead = ByteBuffer()
    @exclusivity(unchecked) var block = ByteBuffer()
    /// A streamed body's compressed bytes, before they are framed.
    @exclusivity(unchecked) var scratch = ByteBuffer()
    @exclusivity(unchecked) var dates = DateCache()

    init(connection: H3Connection, endpoint: QUICEndpoint, maxHeaders: Int) {
        self.connection = connection
        self.endpoint = endpoint
        x = .allocate(capacity: 1)
        x.initialize(to: Exchange(maxHeaders: maxHeaders, remote: connection.remote))
        x.pointee.link = .http3(Unmanaged.passUnretained(self))
    }

    /// Under the lock: resumes the writers waiting on `staged`.
    func resumeWaiters(_ drained: Bool) {
        guard !waiters.isEmpty else { return }
        let waiting = waiters
        waiters = []
        for c in waiting { c.resume(returning: drained) }
    }

    deinit {
        head.destroy()
        body.destroy()
        staged.destroy()
        outHead.destroy()
        block.destroy()
        scratch.destroy()
        x.deinitialize(count: 1)
        x.deallocate()
    }
}

// MARK: - The task's side

extension QUICEndpoint {
    /// Under the lock: puts `s` on the endpoint's list, waking it when the
    /// list was empty -- otherwise it is awake already, or about to be, and
    /// will take `s` with the rest.
    @inline(__always)
    func post(_ s: H3Stream) {
        guard !s.queued else { return }
        s.queued = true
        let first = posted.isEmpty
        posted.append(Unmanaged.passUnretained(s))
        if first { wake.fire() }
    }

    /// The stream's task (HTTP2Pool.swift): the handler, which a reset
    /// cancels by cancelling the task, then the answer, framed here and
    /// posted to the endpoint.
    func answer(_ s: H3Stream) async {
        withUnsafeCurrentTask { task in
            lock.withLock { _ in
                if s.reset { task?.cancel() } else { s.task = task }
            }
        }
        await dispatchStream(s)
        if let channel = s.x.pointee.channel {
            // Streamed: the head is staged already, and the body's end is
            // now (StreamingResponse.swift).
            lock.withLock { _ in
                s.task = nil
                channel.closeH3Locked(s, failed: channel.handlerFailed)
                s.taskDone = true
                post(s)
            }
            return
        }
        let wanted = lock.withLock { _ in !s.reset }
        if wanted { frameWhole(s) }
        lock.withLock { _ in
            // No reset cancels the task once it may have moved on.
            s.task = nil
            if !s.reset { s.answerReady = true }
            s.taskDone = true
            post(s)
        }
    }

    /// The stream's request through the application, noting whether its
    /// route's run suspended.
    @inline(__always)
    func dispatchStream(_ s: H3Stream) async {
        let x = s.x
        // Before anything can answer, so every answer carries them.
        if limits.requestID { x.pointee.assignRequestID(trusting: limits.requestIDTrust) }
        if limits.traceContext { x.pointee.readTraceParent() }
        if observing { x.pointee.started = monotonicNanos() }
        let stamp = Runtime.currentJobStamp
        await dispatchInline(x, app, matched: s.matched, observing: observing)
        // A cancelled run may have been cut short before it could wait: it
        // says nothing about the route.
        let route = x.pointee.route
        if route >= 0 && !Task.isCancelled { app.costs.noteRun(Int(route), startedIn: stamp) }
    }

    /// Frames `s`'s whole answer: the HEADERS frame and the DATA frame's
    /// header in `outHead`, the body left in the exchange.
    func frameWhole(_ s: H3Stream) {
        let count = prepareAnswer(s.x)
        s.bodyLength = count
        s.outHead.clear()
        encodeHead(s, streamed: false, declared: -1, into: &s.outHead)
        if count > 0 {
            s.outHead.writeVarint(HTTP3FrameType.data)
            s.outHead.writeVarint(UInt64(count))
        }
    }

    /// The head of `s`'s streamed answer is made: framed now, and staged
    /// ahead of the body.
    func startStreamedAnswer(_ s: H3Stream, declared: Int) {
        s.outHead.clear()
        encodeHead(s, streamed: true, declared: declared, into: &s.outHead)
        lock.withLock { _ in
            s.streamed = true
            s.staged.write(s.outHead.readPointer, s.outHead.readableBytes)
            post(s)
        }
    }

    /// Stages an interim head for `s`, which goes out before any answer.
    /// False once the stream has been cancelled.
    func sendInterim(_ s: H3Stream, status: Int, fields: [([UInt8], [UInt8])]) -> Bool {
        let encoder = QPACKEncoder()
        var block = ByteBuffer()
        defer { block.destroy() }
        encoder.begin(into: &block)
        encoder.encodeStatus(status, into: &block)
        for (name, value) in fields {
            name.withUnsafeBufferPointer { n in
                value.withUnsafeBufferPointer { v in
                    encoder.encode(name: n.baseAddress!, nameLength: n.count,
                                   value: v.baseAddress ?? emptyBlock, valueLength: v.count, into: &block)
                }
            }
        }
        return lock.withLock { _ -> Bool in
            guard !s.reset else { return false }
            s.staged.writeVarint(HTTP3FrameType.headers)
            s.staged.writeVarint(UInt64(block.readableBytes))
            s.staged.write(block.readPointer, block.readableBytes)
            post(s)
            return true
        }
    }

    /// Frames `s`'s head as a HEADERS frame into `out`: `:status` and the
    /// response headers, as `writeHTTP1Head` writes them -- date, server and
    /// content-length added, the headers that frame an HTTP/1 message or
    /// manage its connection dropped. A streamed answer's length is the one
    /// its handler declared, if it did.
    func encodeHead(_ s: H3Stream, streamed: Bool, declared: Int, into out: inout ByteBuffer) {
        let x = s.x
        // `Response.onSend` hooks see the answer once it is final, while it
        // can still change (ResponseHooks.swift).
        if !x.pointee.sendHooks.isEmpty { runSendHooks(x) }
        x.pointee.committed = true
        s.dates.refresh()
        let status = x.pointee.status
        let forbids = HTTPResponseWriter.statusForbidsBody(status)
        let encoder = QPACKEncoder()
        s.block.clear()
        encoder.begin(into: &s.block)
        encoder.encodeStatus(status, into: &s.block)
        let kinds = x.pointee.headerKinds
        if !kinds.contains(.date) { qpack(encoder, "date", UnsafePointer(s.dates.bytes), s.dates.count, &s.block) }
        if !kinds.contains(.server) {
            let server: StaticString = "garuda"
            qpack(encoder, "server", server.utf8Start, server.utf8CodeUnitCount, &s.block)
        }
        if let hsts = x.pointee.serverFields?.hsts, !kinds.contains(.hsts) {
            hsts.withUnsafeBufferPointer { qpack(encoder, "strict-transport-security", $0.baseAddress!, $0.count, &s.block) }
        }
        // --request-id's, unless the handler set its own (RequestID.swift).
        if x.pointee.requestID.readableBytes > 0 && !kinds.contains(.requestID) {
            qpack(encoder, "x-request-id", x.pointee.requestID.readPointer, x.pointee.requestID.readableBytes, &s.block)
        }
        x.pointee.forEachResponseHeader { name, value in
            let kind = HTTPResponseWriter.classify(name)
            // Length is where the stream ends, and a connection's management
            // has no meaning on a stream.
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            if HTTP2.isConnectionSpecific(name.base, name.count) { return }
            encoder.encode(name: name.base, nameLength: name.count, value: value.count > 0 ? value.base : emptyBlock,
                           valueLength: value.count, into: &s.block)
        }
        let length = forbids ? -1 : streamed ? declared : x.pointee.responseBody.readableBytes
        if length >= 0 {
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { digits in
                let n = writeDecimal(length, digits.baseAddress!)
                qpack(encoder, "content-length", UnsafePointer(digits.baseAddress!), n, &s.block)
            }
        }
        out.writeVarint(HTTP3FrameType.headers)
        out.writeVarint(UInt64(s.block.readableBytes))
        out.write(s.block.readPointer, s.block.readableBytes)
        if observing { reportAnswer(x, limits: limits, status: status) }
    }
}

@inline(__always)
private func qpack(_ encoder: QPACKEncoder, _ name: StaticString, _ value: UnsafePointer<UInt8>, _ count: Int,
                   _ block: inout ByteBuffer) {
    encoder.encode(name: name.utf8Start, nameLength: name.utf8CodeUnitCount, value: count > 0 ? value : emptyBlock,
                   valueLength: count, into: &block)
}
