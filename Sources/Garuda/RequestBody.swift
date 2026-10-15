//===----------------------------------------------------------------------===//
// Request bodies read as they arrive.
//
//     app.onStreamingBody(.put, "/files/:name", maxBodySize: 10 << 30) { request, response, body in
//         let file = try await File.create(path)
//         var buffer = IOBuffer(capacity: 256 * 1024)
//         do {
//             while try await body.read(into: &buffer) > 0 {
//                 try await file.write(buffer)
//                 buffer.clear()
//             }
//         } catch RequestBodyError.incomplete {
//             // The client went away part-way. Everything it sent was read.
//         }
//         response.send(status: .created)
//     }
//
// Every other route is given its body whole, read up to its limit before the
// handler runs. A streaming route is dispatched at its request's head
// instead, and the body is taken as the handler asks for it. Taking bytes is
// what lets more in: over HTTP/1.1 the handler's read is the connection's
// read, into a buffer of `streamedBodyBuffer`; over HTTP/2 the stream's
// window is given back as the bytes are read, not as they arrive; over
// HTTP/3 QUIC's stream window grows the same way. So one window bounds what
// a handler that stops reading leaves waiting, and a slow disk slows its own
// upload and nothing else.
//
// A request that ends before its body did -- the connection closed, the
// stream reset -- still hands over every byte that arrived: the reader
// returns them, and then throws `incomplete`. That is the difference between
// an upload that can be resumed and one that has to start again. It is also
// why a reset does not cancel a streaming handler's task, as it does any
// other handler's: the body ending is how such a handler learns its request
// did, and a cancelled task could not store what it had been given.
//
// The route's body limit is its own, `Int.max` unless it says otherwise, in
// place of `--max-body`: a declared length past it is answered 413 before
// the handler runs, and a body that grows past it as it arrives makes the
// reader throw `tooLarge`, which answers 413 unless the handler answers
// first.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega
import VegaIO

/// Why a request body could not be read to its end.
public enum RequestBodyError: Error, Equatable, Sendable {
    /// The request ended before the body did: the client closed the
    /// connection or reset the stream, or it was cancelled. What arrived was
    /// read first.
    case incomplete
    /// The body passed the route's `maxBodySize`, or `readAll`'s limit.
    case tooLarge
}

extension RequestBodyError: ResponseError {
    public var status: HTTPStatus {
        switch self {
        case .incomplete: .badRequest
        case .tooLarge: .contentTooLarge
        }
    }

    public var reason: String? {
        switch self {
        case .incomplete: "the request ended before its body did"
        case .tooLarge: "the request body is larger than this route takes"
        }
    }
}

/// A handler for a route that reads its request body as it arrives.
public typealias StreamingBodyHandler =
    @Sendable (borrowing Request, borrowing Response, RequestBody) async throws -> Void

extension RouteBuilder {
    /// Registers a route that reads its request body as it arrives rather
    /// than being given it whole. The body is held to `maxBodySize` in place
    /// of `--max-body`, or of a `maxBodySize` scope around it.
    @discardableResult
    public func onStreamingBody(_ method: HTTPMethod, _ pattern: String, maxBodySize: Int = .max,
                                _ handler: @escaping StreamingBodyHandler) -> OpenAPIOperation {
        precondition(maxBodySize >= 0, "a body limit cannot be negative")
        var operation: OpenAPIOperation?
        // A scope of its own, as `maxBodySize` is: the marker is read when the
        // application compiles, and costs the route no layer.
        group("/") {
            use(StreamingBodyMarker(bytes: maxBodySize))
            operation = documentedRoute(method, pattern) { request, response in
                try await handler(request, response, RequestBody(request))
            }
        }
        return operation!
    }
}

/// The body of a request to a streaming route, read as it arrives.
///
/// Read from the handler, or from tasks it starts, one read at a time; it
/// means nothing once the handler has returned. `cancel` may be called from
/// anywhere.
public struct RequestBody: Sendable {
    /// Nil for a request with no body to stream: one without a body at all.
    let source: RequestBodySource?
    let generation: UInt64
    /// The length the client declared, if it declared one.
    public let expectedLength: Int?

    init(_ request: borrowing Request) {
        let x = request.exchange
        source = x.pointee.bodySource
        generation = source?.generation.load(ordering: .relaxed) ?? 0
        let head = x.pointee.head
        expectedLength = head.flags.contains(.hasContentLength) ? head.contentLength : nil
    }

    /// How many bytes have been read so far.
    public var bytesRead: Int {
        guard let source, source.generation.load(ordering: .relaxed) == generation else { return 0 }
        return source.delivered
    }

    /// Reads into `buffer`'s spare capacity, waiting for bytes when none has
    /// arrived. Returns how many it read, 0 at the end of the body. Throws
    /// `incomplete` once everything that arrived has been read, if the
    /// request ended before the body did.
    public func read(into buffer: inout IOBuffer) async throws(RequestBodyError) -> Int {
        precondition(buffer.spareCapacity > 0, "a request body was read into a full buffer")
        guard let source else { return 0 }
        guard source.generation.load(ordering: .relaxed) == generation else { throw .incomplete }
        let n = try await source.read(into: &buffer)
        source.delivered &+= n
        return n
    }

    /// Up to `maxBytes` of the body, waiting for some when none has arrived.
    /// Nil at the end.
    public func read(maxBytes: Int = 64 * 1024) async throws(RequestBodyError) -> [UInt8]? {
        var buffer = IOBuffer(capacity: max(1, maxBytes))
        let n = try await read(into: &buffer)
        return n == 0 ? nil : buffer.withUnsafeBytes { Array($0) }
    }

    /// The rest of the body, or `tooLarge` once it passes `maxBytes`.
    public func readAll(maxBytes: Int) async throws(RequestBodyError) -> [UInt8] {
        var buffer = IOBuffer(capacity: 64 * 1024)
        while true {
            if buffer.spareCapacity == 0 {
                if buffer.count > maxBytes { throw .tooLarge }
                buffer.reserveCapacity(buffer.capacity * 2)
            }
            if try await read(into: &buffer) == 0 { break }
        }
        if buffer.count > maxBytes { throw .tooLarge }
        return buffer.withUnsafeBytes { Array($0) }
    }

    /// Ends the request this body belongs to: an HTTP/1.1 connection is
    /// closed, an HTTP/2 or HTTP/3 stream is reset as cancelled. What had
    /// arrived is still read, and then the reader throws `incomplete`. For a
    /// request another has superseded, such as an upload resumed on a new
    /// connection while the old one is still open.
    public func cancel() {
        source?.cancel(generation)
    }
}

// MARK: - Sources

/// Where a streamed body comes from: the HTTP/1 connection, or the frames an
/// HTTP/2 or HTTP/3 stream delivers. Kept by its connection or stream and
/// used again for the next request whose body it streams.
class RequestBodySource: @unchecked Sendable {
    /// Which request the source serves now: a `RequestBody` made for an
    /// earlier one finds it has moved on.
    final let generation = Atomic<UInt64>(0)
    /// Bytes the handler has read, the reading task's alone.
    final var delivered = 0

    /// The handler's read.
    func read(into buffer: inout IOBuffer) async throws(RequestBodyError) -> Int {
        preconditionFailure("RequestBodySource.read")
    }

    /// Ends the request, if it is still the one `generation` names.
    func cancel(_ generation: UInt64) {}

    /// Moves the source on to the next request.
    final func advance() {
        generation.add(1, ordering: .relaxed)
        delivered = 0
    }
}

/// What the HTTP/1 read buffer may hold of a streamed body: the most read
/// from the socket ahead of the handler.
let streamedBodyBuffer = 256 * 1024

/// A held stream's reading side, as `HeldWriting` is its writing side.
protocol HeldReading {
    static func read(_ stream: UnsafeMutableRawPointer, into buffer: inout IOBuffer) async throws(IOError) -> Int
}

enum HeldReader<S: AsyncReader & ~Copyable>: HeldReading {
    static func read(_ stream: UnsafeMutableRawPointer, into buffer: inout IOBuffer) async throws(IOError) -> Int {
        try await stream.assumingMemoryBound(to: S.self).pointee.read(into: &buffer)
    }
}

/// An HTTP/1 request's body, read from the connection by the handler's
/// read -- which runs in the connection's own task, the one the handler runs
/// in -- out of the read buffer, where the head stays in front of it.
///
/// The buffer is made large enough before the handler runs and never moved
/// while it does, since the request's head, and what middleware noted of
/// it, stay where they are: what the handler has read is let go of by
/// moving what it has not read down behind the head.
final class H1RequestBody: RequestBodySource, @unchecked Sendable {
    let parts: UnsafeMutablePointer<ConnectionParts>

    // What another task may touch, under `lock`.
    private let lock = Mutex<Void>(())
    private var cancelled = false
    /// The connection's task while the handler runs, for `cancel`.
    private var task: UnsafeCurrentTask?

    // The connection task's.
    private var held: HeldStream?
    private var reader: (any HeldReading.Type)?
    private var timeout = Duration.zero
    private var writeTimeout = Duration.zero
    /// Where the head ends and the body begins in the read buffer.
    private var headEnd = 0
    /// Where the next byte not yet taken is.
    private var at = 0
    /// What a Content-Length still allows, or -1 for a chunked body.
    private var remaining = 0
    private var decoder = ChunkedDecoder()
    private var limit = Int.max
    private var received = 0
    private var failure: RequestBodyError?
    /// The whole body has been taken.
    private(set) var ended = false
    /// `Expect: 100-continue`: the client waits to be told to send.
    private var continueOwed = false

    init(parts: UnsafeMutablePointer<ConnectionParts>) {
        self.parts = parts
    }

    /// Readies the source for the request in the exchange, whose head is at
    /// the front of the read buffer.
    func begin(held: HeldStream, reader: any HeldReading.Type, limits: ConnectionLimits, limit: Int) {
        advance()
        lock.withLock { _ in cancelled = false }
        self.held = held
        self.reader = reader
        timeout = limits.bodyTimeout
        writeTimeout = limits.writeTimeout
        let head = parts.pointee.exchange.pointee.head
        headEnd = head.headEnd
        at = headEnd
        remaining = head.isChunked ? -1 : head.contentLength
        decoder = ChunkedDecoder()
        self.limit = limit
        received = 0
        failure = nil
        ended = remaining == 0
        continueOwed = head.flags.contains(.expectContinue)
    }

    /// The handler is about to run in the current task, or has returned.
    func attach(_ running: Bool) {
        if running {
            withUnsafeCurrentTask { current in lock.withLock { _ in task = current } }
        } else {
            lock.withLock { _ in task = nil }
            held = nil
            reader = nil
        }
    }

    /// The request was cancelled, or its body cut off: the connection cannot
    /// serve another.
    var broken: Bool {
        failure != nil || lock.withLock { _ in cancelled }
    }

    /// Where the next request begins, once the body has ended: everything
    /// the handler took is gone from in front of it.
    var consumed: Int { at &- headEnd }

    /// Takes what the handler left unread when all of it is in the buffer
    /// already, so the connection can go on to the next request. False when
    /// the rest is still to arrive: the connection closes instead of
    /// reading a body nobody wants.
    func skipRest() -> Bool {
        if ended { return true }
        guard failure == nil, remaining > 0, parts.pointee.input.count &- at >= remaining else { return false }
        at &+= remaining
        remaining = 0
        ended = true
        return true
    }

    override func cancel(_ generation: UInt64) {
        lock.withLock { _ in
            guard self.generation.load(ordering: .relaxed) == generation, !cancelled else { return }
            cancelled = true
            // The handler may be waiting on the client, which has gone quiet:
            // the wait is ended by ending the connection's task, which ends
            // the connection.
            task?.cancel()
        }
    }

    override func read(into buffer: inout IOBuffer) async throws(RequestBodyError) -> Int {
        while true {
            if let failure { throw failure }
            if lock.withLock({ _ in cancelled }) { throw fail(.incomplete) }
            if ended { return 0 }
            let n = try take(into: &buffer)
            if n > 0 || ended { return n }
            try await fill()
        }
    }

    private func fail(_ error: RequestBodyError) -> RequestBodyError {
        if failure == nil { failure = error }
        return failure!
    }

    /// Takes what the read buffer holds of the body, as much as `buffer` has
    /// room for.
    private func take(into buffer: inout IOBuffer) throws(RequestBodyError) -> Int {
        let available = parts.pointee.input.count &- at
        guard available > 0 else { return 0 }
        let base = parts.pointee.input.withUnsafeBytes { $0.baseAddress! }
        if remaining >= 0 {
            let n = min(available, remaining, buffer.spareCapacity)
            _ = buffer.append(UnsafeRawBufferPointer(start: base + at, count: n))
            at &+= n
            remaining &-= n
            received &+= n
            if remaining == 0 { ended = true }
            return n
        }
        // Decoded bytes are never more than the bytes they came from, so the
        // decoder is given no more than `buffer` has room for.
        var consumed = 0
        var produced = 0
        let p = base.assumingMemoryBound(to: UInt8.self) + at
        let outcome = decoder.decode(p, min(available, buffer.spareCapacity), consumed: &consumed) { run, n in
            _ = buffer.append(UnsafeRawBufferPointer(start: run, count: n))
            produced &+= n
        }
        at &+= consumed
        received &+= produced
        switch outcome {
        case .finished:
            ended = true
        case .failure:
            throw fail(.incomplete)
        case .needMore:
            break
        }
        if received > limit {
            // Nothing past the limit is handed over.
            buffer.count &-= produced
            throw fail(.tooLarge)
        }
        return produced
    }

    /// Reads more of the body from the connection, once the handler has
    /// taken everything the buffer held.
    private func fill() async throws(RequestBodyError) {
        guard let held, let reader else { throw fail(.incomplete) }
        if continueOwed {
            continueOwed = false
            let line: StaticString = "HTTP/1.1 100 Continue\r\n\r\n"
            do {
                try await Runtime.withIODeadline(writeTimeout) { () async throws(IOError) -> Void in
                    try await held.write(UnsafeRawBufferPointer(start: line.utf8Start, count: line.utf8CodeUnitCount))
                }
            } catch {
                throw fail(.incomplete)
            }
        }
        // What the handler took goes; what it has not, a chunk header cut in
        // two, moves down behind the head.
        if at > headEnd {
            let unread = parts.pointee.input.count &- at
            if unread > 0 {
                let base = UnsafeMutableRawPointer(mutating: parts.pointee.input.withUnsafeBytes { $0.baseAddress! })
                (base + headEnd).copyMemory(from: base + at, byteCount: unread)
            }
            parts.pointee.input.count = headEnd &+ unread
            at = headEnd
        }
        let n: Int
        do {
            n = try await Runtime.withIODeadline(timeout) { () async throws(IOError) -> Int in
                try await reader.read(held.pointer, into: &parts.pointee.input)
            }
        } catch {
            throw fail(.incomplete)
        }
        if n == 0 { throw fail(.incomplete) }
    }
}

/// The body of an HTTP/2 or HTTP/3 stream, delivered by the connection's
/// reader or the QUIC endpoint as its frames arrive and taken by the
/// handler's reads. What arrives is held here until it is read, and the
/// stream's window grows only by what has been read.
final class BodyPipe: RequestBodySource, @unchecked Sendable {
    enum Owner {
        case h2(Unmanaged<H2Stream>)
        case h3(Unmanaged<H3Stream>)
    }

    /// The stream this is the body of, which outlives it.
    let owner: Owner
    private let lock = Mutex<Void>(())
    private let arrived = IOEvent()
    private var buffer = ByteBuffer()
    /// HTTP/2: what the client may still send on the stream. QUIC keeps
    /// HTTP/3's.
    private var window = Int.max
    /// Read and not yet given back to the window.
    private var owed = 0
    private var creditAt = 1
    /// The client ended its side.
    private var ended = false
    /// The stream ended before the body did, or the body ran past its limit.
    private var failure: RequestBodyError?
    /// The handler has returned: what arrives is dropped.
    private var closed = false

    init(_ owner: Owner) {
        self.owner = owner
    }

    deinit {
        buffer.destroy()
    }

    // MARK: The connection's side

    /// Readies the pipe for the stream's next request. `window`: HTTP/2's
    /// stream window, or nil where the transport keeps it.
    func begin(window: Int?) {
        advance()
        lock.withLock { _ in
            // A buffer a large body grew is not kept for every later stream.
            if buffer.allocatedCapacity > 1 << 20 { buffer.destroy() } else { buffer.clear() }
            self.window = window ?? .max
            owed = 0
            // Half the window, as for any request body; a quarter over QUIC,
            // whose transport gives the window back once half is taken.
            creditAt = window.map { max(1, $0 / 2) } ?? 64 * 1024
            ended = false
            failure = nil
            closed = false
        }
    }

    /// `count` bytes of body, from a frame that spent `spent` of the window.
    /// False when the frame overran the window.
    func deliver(_ p: UnsafePointer<UInt8>, _ count: Int, spent: Int) -> Bool {
        var credit = 0
        let ok = lock.withLock { _ -> Bool in
            if window != .max {
                window &-= spent
                if window < 0 { return false }
            }
            if !closed && failure == nil && count > 0 { buffer.write(p, count) }
            // Padding is nobody's to read, and given back with the rest; so
            // is what nobody will read any more.
            owed &+= closed || failure != nil ? spent : spent &- count
            if owed >= creditAt && window != .max {
                credit = owed
                owed = 0
                window &+= credit
            }
            return true
        }
        if credit > 0 { giveBack(credit) }
        arrived.signal()
        return ok
    }

    /// The client ended its side.
    func end() {
        lock.withLock { _ in ended = true }
        arrived.signal()
    }

    /// The body cannot be read to its end: what arrived is still read, and
    /// then the reader throws `error`.
    func fail(_ error: RequestBodyError) {
        lock.withLock { _ in
            if failure == nil && !ended { failure = error }
        }
        arrived.signal()
    }

    /// Bytes delivered and not yet read: what the stream's window still
    /// holds back.
    var held: Int {
        lock.withLock { _ in buffer.readableBytes }
    }

    /// The handler has returned: what arrives from now on is dropped. True
    /// when the client had sent the whole body.
    func close() -> Bool {
        lock.withLock { _ -> Bool in
            closed = true
            buffer.clear()
            return ended
        }
    }

    // MARK: The handler's side

    override func read(into destination: inout IOBuffer) async throws(RequestBodyError) -> Int {
        while true {
            var credit = 0
            let got = lock.withLock { _ -> Int? in
                let n = min(buffer.readableBytes, destination.spareCapacity)
                if n > 0 {
                    _ = destination.append(UnsafeRawBufferPointer(start: buffer.readPointer, count: n))
                    buffer.consume(n)
                    owed &+= n
                    if owed >= creditAt {
                        credit = owed
                        owed = 0
                        if window != .max { window &+= credit }
                    }
                    return n
                }
                if failure != nil { return -1 }
                return ended ? 0 : nil
            }
            if credit > 0 { giveBack(credit) }
            if let got {
                if got < 0 { throw lock.withLock { _ in failure! } }
                return got
            }
            do {
                try await arrived.wait()
            } catch {
                // Only a cancelled task's wait ends without a signal.
                fail(.incomplete)
            }
        }
    }

    override func cancel(_ generation: UInt64) {
        guard self.generation.load(ordering: .relaxed) == generation else { return }
        fail(.incomplete)
        switch owner {
        case .h2(let stream):
            let s = stream.takeUnretainedValue()
            s.connection.cancelStreamedBody(s)
        case .h3(let stream):
            let s = stream.takeUnretainedValue()
            s.endpoint.cancelStreamedBody(s)
        }
    }

    /// Gives `n` bytes of window back to the client.
    private func giveBack(_ n: Int) {
        switch owner {
        case .h2(let stream):
            let s = stream.takeUnretainedValue()
            s.connection.creditStream(s, n)
        case .h3(let stream):
            // The endpoint works the window out from what is still held.
            let s = stream.takeUnretainedValue()
            let endpoint = s.endpoint
            endpoint.lock.withLock { _ in endpoint.post(s) }
        }
    }
}
