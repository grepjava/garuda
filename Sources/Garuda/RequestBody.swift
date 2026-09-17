//===----------------------------------------------------------------------===//
// Request bodies read as they arrive, and interim (1xx) responses.
//
//     app.onStreamingBody(.put, "/files/:name", maxBodySize: 10 << 30) { request, response, body in
//         let file = try openForWriting(...)
//         do {
//             while let bytes = try await body.read() { try file.write(bytes) }
//         } catch RequestBodyError.incomplete {
//             // The client went away part-way. Everything it sent was read.
//         }
//         response.send(status: .created)
//     }
//
// Every other route is given its body whole, read up to `--max-body` before
// the handler runs. A streaming route is dispatched at its request's head
// instead, and the body stays in the connection's buffer -- at most
// `--body-high-water` of it -- until the handler reads it. Taking bytes is
// what lets more in: on HTTP/1.1 read interest comes back, on HTTP/2 the
// stream's window is updated, on HTTP/3 QUIC's is extended. A handler that
// stops reading stops the upload, and nothing else.
//
// A request that ends before its body did -- the connection closed, the
// stream reset -- still hands over every byte that arrived: the reader
// returns them, and then throws `incomplete`. That is the difference between
// an upload that can be resumed and one that has to start again.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import AvianHTTP

/// Why a request body could not be read to its end.
public enum RequestBodyError: Error, Equatable, Sendable {
    /// The request ended before the body did: the client closed the
    /// connection or reset the stream. What arrived was read first.
    case incomplete
    /// The body passed the route's `maxBodySize`, or the `readAll` limit.
    case tooLarge
    /// Another read of this body was already waiting.
    case concurrentRead
}

/// What a streaming route's reader and the engine share about one body.
/// Outlives the slot, so the bytes that arrived before a close are kept.
final class RequestBodyState {
    var waiter: UnsafeContinuation<Void, Never>? = nil
    /// Bytes handed over when the slot closed, not yet read.
    var tail: [UInt8] = []
    var tailOffset = 0
    /// Set when the body will not be read to its end.
    var failure: RequestBodyError? = nil
    /// The slot has let go: `tail` is all there is.
    var detached = false

    func wake() {
        waiter.take()?.resume()
    }
}

/// The body of a request to a streaming route, read as it arrives.
///
/// Read from the handler's task, or tasks it starts on the same worker, one
/// read at a time.
public final class RequestBodyStream: @unchecked Sendable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let generation: UInt32
    let requestId: UInt32
    let state: RequestBodyState

    /// How many bytes have been read so far.
    public private(set) var bytesRead = 0
    /// The length the client declared, if it declared one.
    public let expectedLength: Int?

    init(_ request: borrowing Request) {
        worker = request.worker
        slot = request.slot
        let c = request.connection
        generation = c.pointee.generation
        requestId = c.pointee.requestId
        expectedLength = c.pointee.head.flags.contains(.hasContentLength)
            ? c.pointee.head.contentLength : nil
        if let shared = c.pointee.bodyStream, c.pointee.flags.contains(.bodyStreaming) {
            state = shared
        } else {
            // Nothing to stream: no body, or one that was already whole when
            // the request was dispatched. It is read the same way.
            let whole = RequestBodyState()
            let n = c.pointee.body.readableBytes
            if n > 0 {
                whole.tail = [UInt8](UnsafeBufferPointer(start: UnsafePointer(c.pointee.body.readPointer),
                                                         count: n))
            }
            whole.detached = true
            state = whole
        }
    }

    /// Up to `maxBytes` of the body, waiting for some when none has arrived.
    /// Nil at the end. Throws `incomplete` once everything that arrived has
    /// been read, if the request ended before the body did.
    public func read(maxBytes: Int = 64 * 1024) async throws(RequestBodyError) -> [UInt8]? {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a request body was read off its worker's thread")
        let limit = max(1, maxBytes)
        while true {
            if state.tailOffset < state.tail.count {
                let n = min(limit, state.tail.count - state.tailOffset)
                let bytes = Array(state.tail[state.tailOffset..<(state.tailOffset + n)])
                state.tailOffset += n
                if state.tailOffset == state.tail.count {
                    state.tail = []
                    state.tailOffset = 0
                }
                bytesRead += n
                return bytes
            }
            if state.detached {
                if let failure = state.failure { throw failure }
                return nil
            }
            let c = worker.pointee.table[slot]
            guard c.pointee.state != .free, c.pointee.generation == generation,
                  c.pointee.requestId == requestId, c.pointee.bodyStream === state else {
                throw .incomplete
            }
            let available = c.pointee.body.readableBytes
            if available > 0 {
                let n = min(available, limit)
                let bytes = [UInt8](UnsafeBufferPointer(start: UnsafePointer(c.pointee.body.readPointer),
                                                        count: n))
                c.pointee.body.consume(n)
                bytesRead += n
                worker.pointee.streamedBodyConsumed(slot)
                return bytes
            }
            if c.pointee.bodyRemaining == 0 { return nil }
            if let failure = state.failure { throw failure }
            guard state.waiter == nil else { throw .concurrentRead }
            let state = self.state
            await withUnsafeContinuation { state.waiter = $0 }
        }
    }

    /// Ends the request this body belongs to: the HTTP/1.1 connection is
    /// closed, an HTTP/2 or HTTP/3 stream is reset as cancelled. What had
    /// arrived is still read, and then the reader throws `incomplete`. For a
    /// request that another has superseded, such as an upload being resumed
    /// on a new connection while the old one is still open.
    public func cancel() {
        precondition(av_worker_current() == UnsafeMutableRawPointer(worker),
                     "a request was cancelled off its worker's thread")
        let c = worker.pointee.table[slot]
        guard c.pointee.state != .free, c.pointee.generation == generation,
              c.pointee.requestId == requestId else { return }
        if c.pointee.bodyStream === state && state.failure == nil { state.failure = .incomplete }
        worker.pointee.abortRequest(slot)
    }

    /// The rest of the body, or `tooLarge` once it passes `maxBytes`.
    public func readAll(maxBytes: Int) async throws(RequestBodyError) -> [UInt8] {
        var all: [UInt8] = []
        while let bytes = try await read() {
            if all.count + bytes.count > maxBytes { throw .tooLarge }
            all += bytes
        }
        return all
    }
}

/// A handler for a route that reads its body as it arrives.
public typealias StreamingBodyHandler =
    (borrowing Request, inout Response, RequestBodyStream) async throws -> Void

extension Routes {
    mutating func onStreamingBody(_ method: HTTPMethod, _ pattern: String, maxBodySize: Int,
                                  _ handler: @escaping StreamingBodyHandler) {
        onAsync(method, pattern) { request, response in
            let body = RequestBodyStream(request)
            try await handler(request, &response, body)
        }
        bodyLimits[bodyLimits.count - 1] = max(0, maxBodySize)
    }
}

extension Application {
    /// Registers a route that reads its request body as it arrives, rather
    /// than being given it whole. The body is held to `maxBodySize` instead
    /// of `--max-body`; past it the request is answered 413 and the reader
    /// throws `tooLarge`.
    public func onStreamingBody(_ method: HTTPMethod, _ pattern: String, maxBodySize: Int,
                                _ handler: sending @escaping StreamingBodyHandler) {
        precondition(compiled == nil, "route \(pattern) added after the application was compiled")
        routes.onStreamingBody(method, pattern, maxBodySize: maxBodySize, handler)
    }
}

// MARK: - The engine side

extension Worker {
    /// Marks the request on `slot` as streaming its body when its route does.
    /// Called at the head, before any of the body is read.
    mutating func beginStreamedBody(_ slot: Int) {
        guard let installed = application else { return }
        let c = table[slot]
        let path = c.pointee.head.path
        let (base, count) = rootPath.strip(c.pointee.headBase() + Int(path.offset), path.count)
        let route = installed.pointee.routes.match(c.pointee.head.method, base, count,
                                                   into: &c.pointee.routeParameters)
        guard route >= 0 else { return }
        let limit = installed.pointee.bodyLimits[Int(route)]
        guard limit >= 0 else { return }
        c.pointee.flags.insert(.bodyStreaming)
        c.pointee.bodyLimit = limit
        c.pointee.bodyStream = RequestBodyState()
    }

    /// Reads what an HTTP/1.1 streaming body has waiting, as far as the
    /// buffer has room, and wakes its reader. Multiplexed streams are fed by
    /// their frames instead.
    mutating func pumpStreamedBody(_ slot: Int) {
        let c = table[slot]
        if c.pointee.isStream {
            c.pointee.bodyStream?.wake()
            return
        }
        let generation = c.pointee.generation
        if c.pointee.bodyRemaining < 0 {
            if c.pointee.body.readableBytes < config.bodyHighWaterMark {
                if !fill(slot, .read, limit: config.bodyHighWaterMark) { return }
                // Closes a connection that ended mid-body, and answers a body
                // past its limit 413; both let the reader go.
                _ = advanceChunkedBody(slot)
            }
        } else if c.pointee.bodyRemaining > 0 {
            if !fill(slot, .body, limit: config.bodyHighWaterMark) { return }
            if c.pointee.bodyRemaining > 0 && c.pointee.flags.contains(.peerClosed) {
                closeConnection(slot)
                return
            }
        }
        guard c.pointee.state != .free, c.pointee.generation == generation else { return }
        c.pointee.bodyStream?.wake()
        var mask = PollMask(rawValue: c.pointee.interest)
        if readInterestAllowed(slot) { mask.insert(.read) } else { mask.remove(.read) }
        setInterest(slot, mask)
    }

    /// The handler took bytes off a streaming body: room for more.
    mutating func streamedBodyConsumed(_ slot: Int) {
        let c = table[slot]
        if c.pointee.isH3Stream {
            let parent = Int(c.pointee.parentSlot)
            guard parent >= 0, let h3 = table[parent].pointee.h3 else { return }
            readRequestStream(parent, h3, c.pointee.qstreamID)
            flushQUIC(parent)
        } else if c.pointee.isStream {
            h2NoteConsumed(slot, h2Unannounced(slot))
            h2FlushWindowUpdates(slot)
        } else {
            pumpStreamedBody(slot)
        }
    }

    /// How much of an HTTP/2 streaming body has been read and not yet given
    /// back to the window: what arrived, less what is still buffered and
    /// what has already been noted.
    func h2Unannounced(_ slot: Int) -> Int {
        let c = table[slot]
        let window = c.pointee.bodyReceived - c.pointee.body.readableBytes
        let noted = c.pointee.bodyNoted
        c.pointee.bodyNoted = window
        return max(0, window - noted)
    }

    /// Ends the request on `slot` without an answer.
    mutating func abortRequest(_ slot: Int) {
        let c = table[slot]
        if c.pointee.isH3Stream {
            let parent = Int(c.pointee.parentSlot)
            if parent >= 0, let h3 = table[parent].pointee.h3 {
                h3.quic.resetStream(c.pointee.qstreamID, code: HTTP3Error.requestCancelled)
                h3.quic.stopSending(c.pointee.qstreamID, code: HTTP3Error.requestCancelled)
                flushQUIC(parent)
            }
            closeH3Stream(slot)
        } else if c.pointee.isStream {
            closeStream(slot, resetWith: .cancel)
        } else {
            closeConnection(slot)
        }
    }

    /// The slot is letting go of a streaming body: whatever arrived and was
    /// not read goes to the reader, which is told whether that was all of it.
    mutating func detachStreamedBody(_ slot: Int) {
        let c = table[slot]
        guard let state = c.pointee.bodyStream else { return }
        c.pointee.bodyStream = nil
        let n = c.pointee.body.readableBytes
        if n > 0 {
            state.tail += UnsafeBufferPointer(start: UnsafePointer(c.pointee.body.readPointer), count: n)
            c.pointee.body.consume(n)
        }
        if c.pointee.bodyRemaining != 0 && state.failure == nil { state.failure = .incomplete }
        state.detached = true
        state.wake()
    }
}

// MARK: - Interim responses

extension Response {
    /// Sends an informational response ahead of the final one: 103 Early
    /// Hints, 104 Upload Resumption Supported. False, and nothing sent, once
    /// the final response has started, for a status outside 100-199 or 101,
    /// for a header that is not a valid field, and to an HTTP/1.0 client,
    /// which has no interim responses.
    @discardableResult
    public func sendInterim(status: HTTPStatus, headers: [(String, String)] = []) -> Bool {
        guard isActive else { return false }
        return worker.pointee.sendInterim(slot, status: status.code, headers: headers)
    }
}

extension Worker {
    mutating func sendInterim(_ slot: Int, status: Int, headers: [(String, String)]) -> Bool {
        let c = table[slot]
        guard c.pointee.state == .dispatching, !c.pointee.flags.contains(.responseStarted),
              status >= 100, status < 200, status != 101 else { return false }
        var fields: [([UInt8], [UInt8])] = []
        for (name, value) in headers {
            let n = Array(name.utf8).map(asciiLower)
            let v = Array(value.utf8)
            guard !n.isEmpty, n.allSatisfy(isTokenChar), v.allSatisfy(isFieldValueChar) else { return false }
            fields.append((n, v))
        }

        if c.pointee.isH3Stream {
            let parent = Int(c.pointee.parentSlot)
            guard parent >= 0, let h3 = table[parent].pointee.h3 else { return false }
            var block = ByteBuffer()
            defer { block.destroy() }
            h3.encoder.begin(into: &block)
            h3.encoder.encodeStatus(status, into: &block)
            for (name, value) in fields {
                name.withUnsafeBufferPointer { n in
                    value.withUnsafeBufferPointer { v in
                        h3.encoder.encode(name: n.baseAddress!, nameLength: n.count,
                                          value: v.baseAddress ?? emptyH3Byte, valueLength: v.count,
                                          into: &block)
                    }
                }
            }
            writeH3HeaderBlock(slot, h3, block: &block)
            flushQUIC(parent)
            return true
        }
        if c.pointee.isStream {
            let parent = Int(c.pointee.parentSlot)
            guard parent >= 0, let h2 = table[parent].pointee.h2 else { return false }
            var block = ByteBuffer()
            defer { block.destroy() }
            h2.encoder.encodeStatus(status, into: &block)
            for (name, value) in fields {
                name.withUnsafeBufferPointer { n in
                    value.withUnsafeBufferPointer { v in
                        h2.encoder.encode(name: n.baseAddress!, nameLength: n.count,
                                          value: v.baseAddress ?? emptyH2Byte, valueLength: v.count,
                                          into: &block)
                    }
                }
            }
            writeHeaderBlock(slot, h2, block: &block, endStream: false)
            _ = flush(parent)
            return true
        }
        if c.pointee.head.httpMinor == 0 { return false }
        let out = UnsafeMutablePointer(mutating: c).pointer(to: \.write)!
        HTTPResponseWriter.writeStatusLine(&out.pointee, status: status)
        for (name, value) in fields {
            name.withUnsafeBufferPointer { n in
                value.withUnsafeBufferPointer { v in
                    _ = HTTPResponseWriter.writeHeader(
                        &out.pointee, name: ByteSpan(n.baseAddress!, n.count),
                        value: ByteSpan(v.baseAddress ?? n.baseAddress!, v.count))
                }
            }
        }
        HTTPResponseWriter.endHead(&out.pointee)
        _ = flush(slot)
        return table[slot].pointee.state != .free
    }
}
