//===----------------------------------------------------------------------===//
// Responses whose body is written as it is produced.
//
//     app.onAsync(.get, "/export") { request, response in
//         let body = response.stream(contentType: "text/csv")
//         for try await row in rows {
//             try await body.write(row.csv)
//         }
//     }
//
// or, from a typed handler, as a value:
//
//     app.get("/count") { () async in
//         StreamingBody(contentType: "text/plain") { body in
//             for i in 1...10 { try await body.write("\(i)\n") }
//         }
//     }
//
// `stream` sends the head at once, through the same sink as every other
// answer -- middleware's headers, onSend hooks, the server's own -- with no
// Content-Length unless the handler set one. The body is then framed as it
// is written: chunked on HTTP/1.1, delimited by the close on HTTP/1.0, DATA
// frames on HTTP/2 and HTTP/3. Returning from the handler ends it; throwing
// part-way cuts it off the way a truncated message has to be -- the
// connection closed, the stream reset -- so no client takes half a body for
// all of it.
//
// A write queues its bytes and returns, unless what is still waiting to go
// out has passed `ServerConfig.writeHighWaterMark`. Then it waits, on the
// worker, until that has fallen to `writeLowWaterMark`: a client that reads slowly slows
// the handler writing to it and nothing else. Every producer waits, not only
// the first to arrive. A client that goes away ends the wait with
// `HandlerWaitError.cancelled`, as it ends every other wait on the engine; a
// client that stops reading altogether is closed once it has been silent for
// `--request-timeout`.
//
// What that bounds, exactly: a write is queued and then waited on, so each
// producer can carry the backlog past the mark by its own last write, and no
// further -- it is parked before it can queue another. With one producer the
// ceiling is the mark plus that write; with several it is the mark plus one
// write each. The mark is where writers start waiting, not a ceiling on the
// buffer, and a handler that means to bound its memory exactly should write
// in pieces it has chosen rather than in whatever size a row happens to be.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// Writes the body of a response that has already been started.
///
/// Belongs to the task that runs the handler, and to the child tasks it
/// starts, which run on the same worker. Writers do not have to take turns:
/// bytes go out in the order the writes were made. Every one of them waits
/// while the client is behind, though -- a producer let through because
/// another was already waiting would be free to queue for ever.
public final class ResponseBodyWriter: @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let generation: UInt32
    let requestId: UInt32
    /// A response with no body to write -- HEAD, 204, 304 -- or one an
    /// onSend hook answered in place of: writes are accepted and dropped.
    let bodyless: Bool

    init(_ response: borrowing Response) {
        worker = response.worker
        slot = response.slot
        generation = response.generation
        requestId = response.requestId
        bodyless = !worker.pointee.isStreaming(slot, generation: generation, requestId: requestId)
    }

    /// Whether writes still reach the client: false once the body has ended,
    /// or the request has -- the connection closed, the stream reset.
    public var isOpen: Bool {
        onWorker()
        if bodyless { return worker.pointee.stillHolds(slot, generation: generation, requestId: requestId) }
        return worker.pointee.isStreaming(slot, generation: generation, requestId: requestId)
    }

    /// Bytes written and not yet taken by the client: queued on the
    /// connection and, over HTTP/3, sent but not yet acknowledged. A write
    /// waits while this is above `ServerConfig.writeHighWaterMark`.
    public var queuedBytes: Int {
        onWorker()
        guard !bodyless, worker.pointee.isStreaming(slot, generation: generation, requestId: requestId)
        else { return 0 }
        return worker.pointee.streamBacklog(slot)
    }

    /// Sends `bytes`, waiting first if the client is behind. Throws
    /// `cancelled` once the request has ended, and past a Content-Length the
    /// handler declared, where the body is ended at the declared length.
    public func write(_ bytes: [UInt8]) async throws(HandlerWaitError) {
        let queued = bytes.withUnsafeBufferPointer { queue($0) }
        try await settle(queued)
    }

    /// Sends `text` as UTF-8, waiting first if the client is behind.
    public func write(_ text: String) async throws(HandlerWaitError) {
        var text = text
        let queued = text.withUTF8 { queue($0) }
        try await settle(queued)
    }

    /// Sends bytes lent for the call, copied before any wait.
    public func write(_ bytes: Span<UInt8>) async throws(HandlerWaitError) {
        let queued = bytes.withUnsafeBufferPointer { queue($0) }
        try await settle(queued)
    }

    /// Waits `milliseconds` on the worker's timers between writes, as
    /// `Response.sleep` does before a response has started. Throws
    /// `cancelled` if the request ends first.
    public func sleep(milliseconds: UInt64) async throws(HandlerWaitError) {
        onWorker()
        let worker = self.worker
        let index = try worker.pointee.armTaskWait(slot, generation: generation,
                                                   requestId: requestId,
                                                   milliseconds: milliseconds)
        let completed = await withUnsafeContinuation {
            worker.pointee.handlerTasks!.park(index, $0)
        }
        if !completed { throw .cancelled }
    }

    /// Ends the body now rather than when the handler returns. Later writes
    /// throw `cancelled`.
    public func finish() {
        onWorker()
        guard !bodyless, worker.pointee.isStreaming(slot, generation: generation, requestId: requestId)
        else { return }
        worker.pointee.finishStreamingResponse(slot)
    }

    private enum Queued { case sent, dropped, refused }

    private func queue(_ bytes: UnsafeBufferPointer<UInt8>) -> Queued {
        onWorker()
        if bodyless { return .dropped }
        guard worker.pointee.isStreaming(slot, generation: generation, requestId: requestId) else {
            return .refused
        }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return .dropped }
        return worker.pointee.streamBody(slot, base, bytes.count) ? .sent : .refused
    }

    private func settle(_ queued: Queued) async throws(HandlerWaitError) {
        switch queued {
        case .dropped: return
        case .refused: throw .cancelled
        case .sent: break
        }
        let worker = self.worker
        let slot = self.slot
        while worker.pointee.isStreaming(slot, generation: generation, requestId: requestId),
              worker.pointee.streamBacklog(slot) > worker.pointee.config.writeHighWaterMark {
            // Every producer waits for itself. Checking the backlog and
            // parking happen in one turn of the worker's one thread, so there
            // is no room between them for the drain that would be missed.
            let drained = await withUnsafeContinuation { (wake: UnsafeContinuation<Bool, Never>) in
                worker.pointee.table[slot].pointee.writerWakes.append(wake)
            }
            // Ended while waiting by a `finish` elsewhere is not a failure:
            // these bytes were queued ahead of the end.
            if !drained { throw .cancelled }
        }
    }

    @inline(__always)
    private func onWorker() {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a response body was written off its worker's thread")
    }
}

extension Response {
    /// Starts a response whose body is written as it is produced, and sends
    /// its head now. `status` defaults to `self.status`.
    ///
    /// Only from an async handler: the writes wait on the engine. Set any
    /// headers first, Content-Length included if the length is known, which
    /// sends the body unframed and holds the writes to it.
    public func stream(status: HTTPStatus? = nil, contentType: StaticString? = nil) -> ResponseBodyWriter {
        if isActive {
            let c = worker.pointee.table[slot]
            precondition(c.pointee.contKind == .task,
                         "Response.stream needs an async handler: its writes wait on the engine")
            if let contentType, !worker.pointee.hasContentType(slot) {
                addHeader("content-type", contentType)
            }
            worker.pointee.respond(slot, status: (status ?? self.status).code, nil, 0, streaming: true)
        }
        return ResponseBodyWriter(self)
    }
}

// MARK: - As a value a handler returns

/// A body written by `produce` after the head has gone, as a typed async
/// handler's answer.
///
///     app.get("/ticks") { () async in
///         StreamingBody(contentType: "text/plain") { body in
///             for i in 1...3 { try await body.write("tick \(i)\n") }
///         }
///     }
///
/// A synchronous handler cannot return one: it is answered 500.
public struct StreamingBody: ResponseConvertible {
    public var status: HTTPStatus?
    public var contentType: StaticString?
    let produce: StreamProducer

    public init(status: HTTPStatus? = nil, contentType: StaticString? = nil,
                _ produce: sending @escaping (ResponseBodyWriter) async throws -> Void) {
        self.status = status
        self.contentType = contentType
        self.produce = produce
    }

    public func write(to response: borrowing Response) throws {
        response.startStream(status: status, contentType: contentType, produce)
    }
}

typealias StreamProducer = (ResponseBodyWriter) async throws -> Void

extension Response {
    /// Sends the head of a streamed body, and leaves `produce` for the task
    /// running the handler to call once the handler returns.
    func startStream(status: HTTPStatus?, contentType: StaticString?, _ produce: @escaping StreamProducer) {
        guard isActive else { return }
        let c = worker.pointee.table[slot]
        guard c.pointee.contKind == .task else {
            Log.error("a streamed body was returned from a synchronous handler; answering 500")
            send(status: .internalServerError)
            return
        }
        if let contentType, !worker.pointee.hasContentType(slot) {
            addHeader("content-type", contentType)
        }
        worker.pointee.respond(slot, status: (status ?? self.status).code, nil, 0, streaming: true)
        guard isActive else { return }
        worker.pointee.requestContext(slot).streamProducer = produce
    }
}

// MARK: - The engine side

extension Worker {
    /// Whether the request is still the handler's and its streamed body is
    /// still open.
    @inline(__always)
    func isStreaming(_ slot: Int, generation: UInt32, requestId: UInt32) -> Bool {
        let c = table[slot]
        return c.pointee.state == .dispatching
            && c.pointee.generation == generation
            && c.pointee.requestId == requestId
            && c.pointee.flags.contains(.streamingResponse)
    }

    /// Frames `n` bytes of the body and starts them on their way. False when
    /// they ran past the declared Content-Length, which ends the body there.
    mutating func streamBody(_ slot: Int, _ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let c = table[slot]
        var take = n
        var overflow = false
        if c.pointee.responseRemaining >= 0 {
            // Past the declared length is the next response on a keep-alive
            // connection, however innocent the intent.
            if take > c.pointee.responseRemaining {
                take = c.pointee.responseRemaining
                overflow = true
            }
            c.pointee.responseRemaining -= take
        }
        if take > 0 {
            if c.pointee.eventKeepAliveMs != 0 {
                c.pointee.eventKeepAliveDue = av_monotonic_ms() &+ UInt64(c.pointee.eventKeepAliveMs)
            }
            if c.pointee.capture.active { c.pointee.capture.append(p, take) }
            let chunked = c.pointee.flags.contains(.chunkedResponse)
            if c.pointee.encoder.active {
                // Flushed with each write, so what the handler sent is what
                // the client can read now.
                if !c.pointee.encoder.encode(p, take, flush: true, into: &c.pointee.write, chunked: chunked) {
                    Log.error("compressing a streamed response failed; ending the connection")
                    failStreamedResponse(slot)
                    return false
                }
            } else if chunked {
                HTTPResponseWriter.writeChunk(&c.pointee.write, p, take)
            } else {
                c.pointee.write.write(p, take)
            }
        }
        if overflow {
            Log.error("a streamed response ran past its Content-Length; ending it there")
            finishStreamingResponse(slot)
            return false
        }
        // From a handler, sent when the handler next waits rather than now: a
        // handler writing a body in pieces makes its writes in one run of its
        // task, and every one of them flushed on its own was a system call
        // and a wakeup of the reader for each piece -- sixteen for a 64 KiB
        // body in 4 KiB chunks, where one does. The run's end flushes, so
        // what was written is on the wire before anything else can happen to
        // it. A backlog past the low-water mark goes out at once, so holding
        // it never grows the buffer much.
        if runningHandlerTasks {
            flushSoon(slot, holdingUpTo: config.writeLowWaterMark)
        } else {
            _ = flush(slot)
        }
        return true
    }

    /// What the body has queued and the client has not taken yet.
    func streamBacklog(_ slot: Int) -> Int {
        let c = table[slot]
        // HTTP/3 hands bytes to the transport at once, so its own buffer says
        // nothing; what counts is what QUIC holds unacknowledged.
        if c.pointee.isH3Stream { return c.pointee.write.readableBytes + h3Outstanding(slot) }
        return c.pointee.write.readableBytes
    }

    mutating func resumeStreamWriter(_ slot: Int) {
        guard streamBacklog(slot) <= config.writeLowWaterMark else { return }
        // Resumed, not run: the tasks go on the executor and run when the
        // loop drains it, never inside the flush that made the room.
        wakeWriters(slot, drained: true)
    }

    /// Whether any handler is waiting for this response's backlog to drain.
    func hasWriterWaiting(_ slot: Int) -> Bool {
        !table[slot].pointee.writerWakes.isEmpty
    }

    /// Resumes every waiting writer. Each reads the backlog again for itself
    /// and parks again if it is still above the mark, so this is a nudge
    /// rather than a promise of room.
    mutating func wakeWriters(_ slot: Int, drained: Bool) {
        let waiting = table[slot].pointee.writerWakes
        guard !waiting.isEmpty else { return }
        table[slot].pointee.writerWakes = []
        for wake in waiting { wake.resume(returning: drained) }
    }

    /// Ends a streamed body: the last chunk, END_STREAM or FIN, once what is
    /// queued ahead of it has gone.
    mutating func finishStreamingResponse(_ slot: Int) {
        let c = table[slot]
        guard c.pointee.flags.contains(.streamingResponse),
              !c.pointee.flags.contains(.responseComplete) else { return }
        if c.pointee.responseRemaining > 0 {
            // The flush resets a short HTTP/2 or HTTP/3 stream; an HTTP/1.1
            // connection can only be closed.
            Log.error("a streamed response ended short of its Content-Length")
            if !c.pointee.isStream { c.pointee.flags.remove(.keepAlive) }
        }
        if c.pointee.capture.active {
            cacheCaptureFinish(slot, complete: c.pointee.responseRemaining <= 0)
        }
        if c.pointee.encoder.active
            && !c.pointee.encoder.finish(into: &c.pointee.write,
                                         chunked: c.pointee.flags.contains(.chunkedResponse)) {
            Log.error("compressing a streamed response failed; ending the connection")
            failStreamedResponse(slot)
            return
        }
        if c.pointee.flags.contains(.chunkedResponse) {
            HTTPResponseWriter.writeLastChunk(&c.pointee.write)
        }
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    /// The handler writing a streamed body returned or threw.
    mutating func streamingHandlerFinished(_ slot: Int, _ failure: (any Error)?) {
        guard let failure, !(failure is HandlerWaitError) else {
            finishStreamingResponse(slot)
            return
        }
        let description = String(describing: failure)
        Log.error { line in
            line.str("handler threw part-way through a streamed response: ")
            description.withCString { line.cstr($0) }
        }
        failStreamedResponse(slot)
    }

    /// Ends a streamed response that cannot be finished: half a body cannot
    /// be ended honestly. After the head, these reset the stream, and
    /// HTTP/1.1 has only the close.
    mutating func failStreamedResponse(_ slot: Int) {
        let c = table[slot]
        c.pointee.capture.abandon()
        c.pointee.encoder.destroy()
        if c.pointee.isH3Stream {
            h3FailRequest(slot, status: 500)
        } else if c.pointee.isStream {
            h2FailRequest(slot, status: 500)
        } else {
            // What was written before the failure goes first: writes are held
            // until the handler waits, and one that threw straight after a
            // write never did.
            if flush(slot) { closeConnection(slot) }
        }
    }

    /// The producer a returned `StreamingBody` left for the task, taken so it
    /// runs once.
    @inline(__always)
    func takeStreamProducer(_ slot: Int, generation: UInt32, requestId: UInt32) -> StreamProducer? {
        let c = table[slot]
        guard let context = c.pointee.context, context.streamProducer != nil,
              context.generation == generation, context.requestId == requestId else { return nil }
        return context.streamProducer.take()
    }
}
