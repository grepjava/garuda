//===----------------------------------------------------------------------===//
// Responses whose body is written as it is produced.
//
//     app.on(.get, "/export") { request, response in
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
// `stream` makes the head at once, as every other answer's is made --
// middleware's headers, onSend hooks, the server's own -- with no
// Content-Length unless the handler set one. The body is then framed as it
// is written: chunked on HTTP/1.1, delimited by the close on HTTP/1.0, DATA
// frames on HTTP/2. Returning from the handler ends it; throwing part-way
// cuts it off the way a truncated message has to be -- the connection
// closed, the stream reset -- so no client takes half a body for all of it.
//
// Over HTTP/2 the head goes at once. Over HTTP/1 it goes with the first
// write, or with `flush()`: a handler that has something to say soon says
// it in the same write as the head.
//
// A write queues its bytes and returns, unless what is still waiting to go
// out has passed `ServerConfig.writeHighWaterMark`. Then it waits until that
// has fallen to `writeLowWaterMark`: a client that reads slowly slows the
// handler writing to it and nothing else. What is queued goes out once the
// handler next waits or returns -- over HTTP/1 a run of writes is one system
// call, as an answer is -- or at once with `flush()`. Writers in child
// tasks of the handler may write at once, and every one of them waits. A
// client that goes away, or takes no part of one write for
// `ServerConfig.writeTimeout`, ends every write with
// `HandlerWaitError.cancelled`.
//
// What that bounds, exactly: a write is queued and then waited on, so each
// writer can carry the backlog past the mark by its own last write, and no
// further. The mark is where writers start waiting, not a ceiling on the
// buffer.
//===----------------------------------------------------------------------===//

@_spi(Garuda) import VegaQUICCore
import VegaWire
@_spi(Garuda) import VegaHTTP3Core
import GarudaWire
import Synchronization
@_spi(Garuda) import Vega
import VegaFS
import VegaIO
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// A wait a handler made was given up: the client went away, or the body
/// it was writing has ended.
public enum HandlerWaitError: Error, Equatable, Sendable {
    case cancelled
}

/// Writes the body of a response that has already been started.
///
/// May be shared with child tasks of the handler: bytes go out in the order
/// the writes were made. Not past the handler's return, though -- the body
/// ends then, and later writes throw `cancelled`.
public struct ResponseBodyWriter: Sendable {
    let channel: BodyChannel

    /// Whether writes still reach the client: false once the body has ended,
    /// or the request has -- the connection closed, the stream reset.
    public var isOpen: Bool { channel.isOpen }

    /// Bytes written and not yet taken by the client. A write waits while
    /// this is above `ServerConfig.writeHighWaterMark`.
    public var queuedBytes: Int { channel.backlog }

    /// Sends `bytes`, waiting first if the client is behind. Throws
    /// `cancelled` once the request has ended, and past a Content-Length the
    /// handler declared, where the body is ended at the declared length.
    public func write(_ bytes: [UInt8]) async throws(HandlerWaitError) {
        let queued = bytes.withUnsafeBufferPointer { channel.queue(UnsafeRawBufferPointer($0)) }
        try await channel.settle(queued)
    }

    /// Sends `text` as UTF-8, waiting first if the client is behind.
    public func write(_ text: String) async throws(HandlerWaitError) {
        var text = text
        let queued = text.withUTF8 { channel.queue(UnsafeRawBufferPointer($0)) }
        try await channel.settle(queued)
    }

    /// Sends bytes lent for the call, copied before any wait.
    public func write(_ bytes: Span<UInt8>) async throws(HandlerWaitError) {
        let queued = bytes.withUnsafeBufferPointer { channel.queue(UnsafeRawBufferPointer($0)) }
        try await channel.settle(queued)
    }

    /// Sends whatever is queued now -- over HTTP/1, the head too, before
    /// anything has been written -- and waits for it to go.
    public func flush() async throws(HandlerWaitError) {
        try await channel.settle(channel.isOpen ? .sent : .refused, flushing: true)
    }

    /// Waits `milliseconds` between writes.
    public func sleep(milliseconds: UInt64) async throws(HandlerWaitError) {
        try await sleep(for: .milliseconds(Int64(clamping: milliseconds)))
    }

    /// Waits `duration` between writes. Throws `cancelled` if the request
    /// ends first.
    public func sleep(for duration: Duration) async throws(HandlerWaitError) {
        do {
            try await Runtime.sleep(for: duration)
        } catch {
            throw .cancelled
        }
        if !channel.isOpen && !channel.bodyless { throw .cancelled }
    }

    /// Ends the body now rather than when the handler returns. Later writes
    /// throw `cancelled`.
    public func finish() {
        channel.finish()
    }
}

extension Response {
    /// Starts a response whose body is written as it is produced. `status`
    /// defaults to `self.status`.
    ///
    /// Set any headers first, Content-Length included if the length is
    /// known, which sends the body unframed and holds the writes to it.
    /// Called again, it returns the same body; called once the request has
    /// been answered, a writer whose writes throw.
    public func stream(status: HTTPStatus? = nil, contentType: StaticString? = nil) -> ResponseBodyWriter {
        let x = exchange
        if let channel = x.pointee.channel { return ResponseBodyWriter(channel: channel) }
        guard !x.pointee.answered else { return ResponseBodyWriter(channel: BodyChannel(refusing: ())) }
        if let contentType, !x.pointee.hasContentType { _ = x.pointee.addContentType(contentType) }
        x.pointee.status = (status ?? self.status).code
        return ResponseBodyWriter(channel: startStream(x))
    }

    /// Whether this response's body is being streamed.
    public var isStreaming: Bool { exchange.pointee.channel != nil }
}

extension OutgoingResponse {
    /// Whether the body is to be streamed: the head is being made before
    /// any of it exists, and `withBody` sees none of it.
    public var isStreaming: Bool { exchange.pointee.streamStarting }
}

// MARK: - As a value a handler returns

/// A body written by `produce` after the head has gone, as a typed handler's
/// answer.
///
///     app.get("/ticks") { () async in
///         StreamingBody(contentType: "text/plain") { body in
///             for i in 1...3 { try await body.write("tick \(i)\n") }
///         }
///     }
public struct StreamingBody: ResponseConvertible {
    public var status: HTTPStatus?
    public var contentType: StaticString?
    let produce: StreamProducer

    public init(status: HTTPStatus? = nil, contentType: StaticString? = nil,
                _ produce: @escaping @Sendable (ResponseBodyWriter) async throws -> Void) {
        self.status = status
        self.contentType = contentType
        self.produce = produce
    }

    public func write(to response: borrowing Response) throws {
        let x = response.exchange
        guard !x.pointee.answered else { return }
        if let contentType, !x.pointee.hasContentType { _ = x.pointee.addContentType(contentType) }
        if let status { x.pointee.status = status.code }
        // Started when the handler returns, so that middleware still on its
        // way out can add to the head.
        x.pointee.producer = produce
        x.pointee.touchedStream = true
        x.pointee.answered = true
    }
}

typealias StreamProducer = @Sendable (ResponseBodyWriter) async throws -> Void

/// Runs the producer a returned `StreamingBody` left: the head, then the
/// body. Called once the handler and its middleware have returned.
func runProducer(_ x: UnsafeMutablePointer<Exchange>, _ produce: StreamProducer) async throws {
    x.pointee.producer = nil
    // `answered` was only holding the place.
    x.pointee.answered = false
    let channel = startStream(x)
    try await produce(ResponseBodyWriter(channel: channel))
}

// MARK: - Starting

/// Makes the head of `x`'s streamed answer and readies the channel its body
/// goes through.
func startStream(_ x: UnsafeMutablePointer<Exchange>) -> BodyChannel {
    x.pointee.answered = true
    let replacedBefore = x.pointee.bodyReplaced
    x.pointee.streamStarting = true
    if !x.pointee.sendHooks.isEmpty { runSendHooks(x) }
    x.pointee.streamStarting = false
    if x.pointee.bodyReplaced && !replacedBefore {
        // A hook answered in place of the body: that is the answer, written
        // as any other is, and the handler's writes go nowhere.
        return BodyChannel(dropping: ())
    }
    let status = x.pointee.status
    let forbids = HTTPResponseWriter.statusForbidsBody(status)
    let bodyless = forbids || x.pointee.head.method == .head
    let declared = x.pointee.headerKinds.contains(.contentLength) ? declaredLength(x) : -1
    // A bodyless answer still states a declared length when it describes a
    // body sent elsewhere: a HEAD's is the GET's, and a 304's that of the
    // representation it stands for (RFC 9110 section 8.6). A 204's or a
    // 1xx's never is.
    let keepsDeclared = forbids ? status == 304 : x.pointee.head.method == .head
    // --cache-size: the copy is of the application's bytes, before any
    // compression.
    let capture = x.pointee.cacheInvalidates != 0 || x.pointee.capture != nil ? cacheStreamStart(x) : nil
    // --compress: compressed as written, with no length to state, though the
    // declared one still bounds what the handler writes.
    let encoder = x.pointee.compress && !x.pointee.noCompress ? x.pointee.streamEncoder(bodyless: bodyless) : nil
    let stated = encoder == nil ? declared : -1
    let channel: BodyChannel
    switch x.pointee.link {
    case .http1(let held, let parts, let limits):
        let framing: H1Framing
        if bodyless {
            framing = declared >= 0 && keepsDeclared ? .length(declared) : .none
        } else if stated >= 0 {
            framing = .length(declared)
        } else if x.pointee.head.httpMinor == 0 {
            // HTTP/1.0 has no chunks: the close is the only end it has.
            x.pointee.keepAlive = false
            framing = .none
        } else {
            framing = .chunked
        }
        writeHTTP1Head(x, parts, keepAlive: x.pointee.keepAlive, framing: framing)
        channel = BodyChannel(http1: held, parts: parts, limits: limits, bodyless: bodyless,
                              chunked: framing == .chunked, declared: bodyless ? -1 : declared, encoder: encoder)
    case .http2(let stream):
        let s = stream.takeUnretainedValue()
        channel = BodyChannel(http2: s, bodyless: bodyless, declared: bodyless ? -1 : declared, encoder: encoder)
        x.pointee.committed = true
        let said = bodyless ? (keepsDeclared ? declared : -1) : stated
        s.connection.startStreamedAnswer(s, channel: channel, declared: said)
    case .http3(let stream):
        let s = stream.takeUnretainedValue()
        channel = BodyChannel(http3: s, bodyless: bodyless, declared: bodyless ? -1 : declared, encoder: encoder)
        x.pointee.committed = true
        let said = bodyless ? (keepsDeclared ? declared : -1) : stated
        s.endpoint.startStreamedAnswer(s, declared: said)
    case .none:
        x.pointee.committed = true
        channel = BodyChannel(dropping: ())
    }
    channel.runtime = x.pointee.application?.takeUnretainedValue().runtime
    channel.capture = bodyless ? nil : capture
    x.pointee.channel = channel
    x.pointee.touchedStream = true
    return channel
}

/// The Content-Length the handler set, or -1.
func declaredLength(_ x: UnsafeMutablePointer<Exchange>) -> Int {
    var length = -1
    x.pointee.forEachResponseHeader { name, value in
        if length < 0, HTTPResponseWriter.classify(name) == .contentLength { length = value.integer ?? -1 }
    }
    return length
}

// MARK: - The channel

/// The connection's stream, held where a streamed body's writes can reach
/// it, and how to write to it.
struct HeldStream {
    let pointer: UnsafeMutableRawPointer
    let writer: any HeldWriting.Type

    @inline(__always)
    func write(_ bytes: UnsafeRawBufferPointer) async throws(IOError) {
        try await writer.write(pointer, bytes)
    }

    /// Whether the stream can take a file from the kernel: plain TCP.
    var sendsFiles: Bool { writer.sendsFiles }

    func sendFile(_ file: Int32, offset: Int, count: Int) async throws(IOError) -> Int {
        try await writer.sendFile(pointer, file, offset: offset, count: count)
    }
}

protocol HeldWriting {
    static func write(_ stream: UnsafeMutableRawPointer, _ bytes: UnsafeRawBufferPointer) async throws(IOError)
    static var sendsFiles: Bool { get }
    /// Up to `count` bytes of `file` from `offset`, sent by the kernel: the
    /// bytes sent, fewer when the file ends first.
    static func sendFile(_ stream: UnsafeMutableRawPointer, _ file: Int32, offset: Int,
                         count: Int) async throws(IOError) -> Int
}

extension HeldWriting {
    static var sendsFiles: Bool { false }

    static func sendFile(_ stream: UnsafeMutableRawPointer, _ file: Int32, offset: Int,
                         count: Int) async throws(IOError) -> Int {
        throw IOError(code: ENOSYS)
    }
}

/// A plain TCP connection, which hands files to sendfile(2).
enum HeldTCPStream: HeldWriting {
    static func write(_ stream: UnsafeMutableRawPointer, _ bytes: UnsafeRawBufferPointer) async throws(IOError) {
        try await stream.assumingMemoryBound(to: TCPStream.self).pointee.write(bytes)
    }

    static var sendsFiles: Bool { true }

    static func sendFile(_ stream: UnsafeMutableRawPointer, _ file: Int32, offset: Int,
                         count: Int) async throws(IOError) -> Int {
        try await stream.assumingMemoryBound(to: TCPStream.self).pointee.sendFile(file, offset: Int64(offset),
                                                                                   count: count)
    }
}

enum HeldWriter<S: AsyncWriter & ~Copyable>: HeldWriting {
    static func write(_ stream: UnsafeMutableRawPointer, _ bytes: UnsafeRawBufferPointer) async throws(IOError) {
        try await stream.assumingMemoryBound(to: S.self).pointee.write(bytes)
    }
}

//// What a streamed body goes through: framed into a queue, which one writer
/// at a time takes to the client over HTTP/1, and the connection's writer
/// over HTTP/2.
final class BodyChannel: @unchecked Sendable {
    enum State { case open, finished, failed }
    enum Queued { case sent, dropped, refused }

    private let lock = Mutex<Void>(())
    // Under `lock` over HTTP/1, the connection's over HTTP/2.
    private var state = State.open
    /// Body bytes still allowed by a declared Content-Length, or -1.
    private var remaining: Int

    /// No body is sent -- HEAD, 204, 304, or a hook answered instead --
    /// and writes are accepted and dropped.
    let bodyless: Bool
    /// The handler threw once the body had begun: it is cut off. The
    /// handler's task's own, set and read only there.
    var handlerFailed = false

    // HTTP/1, under `lock`.
    private let held: HeldStream?
    private let chunked: Bool
    /// Framed, waiting for a writer to take it out.
    private var pending = ByteBuffer()
    /// The buffer the writer taking the queue out writes from.
    private var spare = ByteBuffer()
    /// A writer is taking the queue out, and this much is in its hands.
    private var flushing = false
    private var inFlight = 0
    /// A flush is on its way to take the queue out and has not begun: asked
    /// for at the end of the handler's job, or spawned.
    private var flushSpawned = false
    /// The handler has returned and the connection has the stream back:
    /// a spawned flush that begins now takes nothing.
    private var detached = false
    /// Writers waiting for the backlog to fall.
    private var waiters: [UnsafeContinuation<Bool, Never>] = []
    private let timeout: Duration
    private let high: Int
    private let low: Int

    // Keep-alive comments, under the lock (EventStream.swift).
    /// The default quiet before one, and where its task runs.
    let keepAliveDefault: Duration
    var runtime: Runtime?
    private var keepAliveTask: Task<Void, Never>?
    /// When bytes were last queued, in monotonic nanoseconds.
    private var lastWrite: UInt64 = 0

    // HTTP/2.
    private let h2: H2Stream?
    // HTTP/3: the stream's staged frames, under its endpoint's lock.
    private let h3: H3Stream?

    /// --compress: the body is compressed as it is written, each write
    /// flushed through (Compression.swift). Under the state's lock.
    private let encoder: ResponseEncoder?
    /// --cache-size: the copy being made, stored when the body ends whole.
    /// Under the state's lock.
    var capture: ResponseCapture?

    /// One whose writes throw: the request had been answered already.
    init(refusing: Void) {
        bodyless = false
        state = .failed
        remaining = -1
        held = nil; chunked = false; h2 = nil; h3 = nil; encoder = nil
        timeout = .seconds(0); high = 0; low = 0; keepAliveDefault = .zero
    }

    /// A WebSocket's (WebSocketSession.swift): frames written as they are,
    /// on a stream of their own, with no body to end.
    init(raw held: HeldStream, limits: StreamLimits) {
        self.held = held
        bodyless = false
        chunked = false
        remaining = -1
        h2 = nil
        h3 = nil
        encoder = nil
        timeout = limits.writeTimeout
        high = limits.high
        low = limits.low
        keepAliveDefault = .zero
    }

    /// One whose writes go nowhere.
    init(dropping: Void) {
        bodyless = true
        remaining = -1
        held = nil; chunked = false; h2 = nil; h3 = nil; encoder = nil
        timeout = .seconds(0); high = 0; low = 0; keepAliveDefault = .zero
    }

    init(http1 held: HeldStream, parts: UnsafeMutablePointer<ConnectionParts>, limits: StreamLimits,
         bodyless: Bool, chunked: Bool, declared: Int, encoder: ResponseEncoder? = nil) {
        self.held = held
        self.encoder = encoder
        self.bodyless = bodyless
        self.chunked = chunked
        remaining = declared
        h2 = nil
        h3 = nil
        timeout = limits.writeTimeout
        high = limits.high
        low = limits.low
        keepAliveDefault = limits.eventKeepAlive
        // The head, behind whatever pipelined answers were still to go: the
        // connection's output itself, lent for the body and handed back by
        // `close`, so that one buffer, grown once, serves every streamed
        // answer on the connection and the body is never copied across.
        swap(&pending, &parts.pointee.output)
    }

    init(http2 s: H2Stream, bodyless: Bool, declared: Int, encoder: ResponseEncoder? = nil) {
        h2 = s
        h3 = nil
        self.encoder = encoder
        self.bodyless = bodyless
        remaining = declared
        held = nil; chunked = false
        timeout = .seconds(0)
        high = s.connection.limits.writeHighWaterMark
        low = s.connection.limits.writeLowWaterMark
        keepAliveDefault = s.connection.limits.eventKeepAlive
    }

    init(http3 s: H3Stream, bodyless: Bool, declared: Int, encoder: ResponseEncoder? = nil) {
        h2 = nil
        h3 = s
        self.encoder = encoder
        self.bodyless = bodyless
        remaining = declared
        held = nil; chunked = false
        timeout = .seconds(0)
        high = s.endpoint.settings.high
        low = s.endpoint.settings.low
        keepAliveDefault = s.endpoint.limits.eventKeepAlive
    }

    deinit {
        pending.destroy()
        spare.destroy()
    }

    /// `body` under the lock that guards the state.
    @inline(__always)
    private func locked<R>(_ body: () -> R) -> R {
        if let h2 { return h2.connection.lock.withLock { _ in body() } }
        if let h3 { return h3.endpoint.lock.withLock { _ in body() } }
        return lock.withLock { _ in body() }
    }

    var isOpen: Bool {
        locked { state == .open && h2?.reset != true && h3?.reset != true }
    }

    var backlog: Int {
        locked { h2?.backlog ?? h3?.staged.readableBytes ?? (pending.readableBytes &+ inFlight) }
    }

    // MARK: Writing

    /// Frames `bytes` onto the queue.
    func queue(_ bytes: UnsafeRawBufferPointer) -> Queued {
        locked {
            if bodyless { return state == .failed ? .refused : .dropped }
            guard state == .open, h2?.reset != true, h3?.reset != true else { return .refused }
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count > 0 else {
                return .dropped
            }
            var take = bytes.count
            var overflow = false
            if remaining >= 0 {
                // Past the declared length would be the next response on a
                // keep-alive connection, however innocent the intent.
                if take > remaining {
                    take = remaining
                    overflow = true
                }
                remaining &-= take
            }
            if take > 0 {
                if keepAliveTask != nil { lastWrite = monotonicNanos() }
                capture?.append(base, take)
                if let encoder {
                    // Flushed with each write, so what the handler sent is
                    // what the client can read now.
                    if !encode(encoder, base, take, finishing: false) {
                        Log.error("compressing a streamed response failed; ending it")
                        state = .failed
                        return .refused
                    }
                } else if let s = h2 {
                    s.staged.write(base, take)
                    s.backlog &+= take
                    s.connection.wakeWriter()
                } else if let s = h3 {
                    s.staged.writeVarint(HTTP3FrameType.data)
                    s.staged.writeVarint(UInt64(take))
                    s.staged.write(base, take)
                    s.endpoint.post(s)
                } else if chunked {
                    HTTPResponseWriter.writeChunk(&pending, base, take)
                } else {
                    pending.write(base, take)
                }
            }
            if overflow {
                Log.error("a streamed response ran past its Content-Length; ending it there")
                endLocked()
                return .refused
            }
            return .sent
        }
    }

    /// Waits for what was queued to be on its way: over HTTP/1 taking the
    /// queue out when no other writer is, and either way waiting while the
    /// client is behind. `force`: until the whole backlog has gone.
    func settle(_ queued: Queued, flushing force: Bool = false) async throws(HandlerWaitError) {
        switch queued {
        case .dropped: return
        case .refused:
            // The bytes queued ahead of the refusal still go.
            if held != nil { _ = await drain() }
            throw .cancelled
        case .sent: break
        }
        if let h2 { return try await settleH2(h2, force: force) }
        if let h3 { return try await settleH3(h3, force: force) }
        if !force, let runtime, deferFlush(runtime) { return }
        while true {
            switch await drain() {
            case .done: return
            case .failed: throw .cancelled
            case .busy: break
            }
            // Another writer is taking the queue out; a write that fits goes
            // with it.
            let drained = await withUnsafeContinuation { (c: UnsafeContinuation<Bool, Never>) in
                let resume = lock.withLock { _ -> Bool? in
                    if state == .failed { return false }
                    // Gone since: take it out ourselves.
                    if !flushing { return true }
                    if !force && pending.readableBytes &+ inFlight <= high { return true }
                    waiters.append(c)
                    return nil
                }
                if let resume { c.resume(returning: resume) }
            }
            if !drained { throw .cancelled }
            let again = lock.withLock { _ in
                force || flushing || pending.readableBytes > 0
            }
            if !again { return }
        }
    }

    /// Over HTTP/1, a write that leaves the backlog under the high-water
    /// mark: true when it may return without writing, the queue to be taken
    /// out once this task waits or returns, unless a flush is already on its
    /// way. The handler's run of writes then goes in one system call rather
    /// than one each.
    ///
    /// When the handler's job returns, `jobEnded` looks: a handler that
    /// returned has left the queue to the connection, which sends it with
    /// its own output, and only one that went off to wait on something else
    /// needs a flush of its own. Spawned at the first write instead, as it
    /// once was, the flush cost every streamed answer a task, and nearly
    /// always found nothing to take; on a runtime of several threads another
    /// worker could take it up and contend with the handler for the lock.
    private func deferFlush(_ runtime: Runtime) -> Bool {
        let spawn = lock.withLock { _ -> Bool? in
            guard state == .open, !detached, pending.readableBytes &+ inFlight <= high else { return nil }
            // A writer taking the queue out takes this too.
            if flushing || flushSpawned { return false }
            flushSpawned = true
            return true
        }
        guard let spawn else { return false }
        if spawn && !Runtime.afterJob(self) { spawnFlush(runtime) }
        return true
    }

    /// A task taking the queue out.
    private func spawnFlush(_ runtime: Runtime) {
        runtime.spawn { [self] in
            lock.withLock { _ in flushSpawned = false }
            _ = await drain()
        }
    }

    private enum Drain { case done, busy, failed }
    private enum Take { case take(ByteBuffer), empty, busy, failed }

    /// Over HTTP/1: takes the queue out when no other writer is, until it is
    /// empty.
    private func drain() async -> Drain {
        guard let held else { return .done }
        var buffer: ByteBuffer
        switch lock.withLock({ _ -> Take in
            if detached { return .empty }
            if state == .failed && pending.readableBytes == 0 { return .failed }
            if flushing { return .busy }
            if pending.readableBytes == 0 { return .empty }
            flushing = true
            swap(&pending, &spare)
            inFlight = spare.readableBytes
            return .take(spare)
        }) {
        case .take(let b): buffer = b
        case .empty: return .done
        case .busy: return .busy
        case .failed: return .failed
        }
        while true {
            var ok = true
            do {
                try await Runtime.withIOTimeout(for: timeout) { () async throws(IOError) -> Void in
                    try await held.write(UnsafeRawBufferPointer(start: buffer.readPointer,
                                                                count: buffer.readableBytes))
                }
            } catch {
                ok = false
            }
            buffer.clear()
            let next = lock.withLock { _ -> ByteBuffer? in
                spare = buffer
                if !ok {
                    state = .failed
                    pending.clear()
                } else if pending.readableBytes > 0 {
                    swap(&pending, &spare)
                    inFlight = spare.readableBytes
                    return spare
                }
                flushing = false
                inFlight = 0
                return nil
            }
            guard let next else {
                wakeWaiters(drained: ok)
                return ok ? .done : .failed
            }
            // Fallen to the low-water mark: the writers waiting may go on.
            if next.readableBytes <= low { wakeWaiters(drained: true) }
            buffer = next
        }
    }

    private func wakeWaiters(drained: Bool) {
        let waiting = lock.withLock { _ -> [UnsafeContinuation<Bool, Never>] in
            if waiters.isEmpty { return [] }
            let w = waiters
            waiters = []
            return w
        }
        for c in waiting { c.resume(returning: drained) }
    }

    // MARK: Ending

    /// Ends the body now: what is queued goes, and then its end.
    func finish() {
        locked { endLocked() }
    }

    /// Under the state's lock: no more writes. Over HTTP/1 the end -- the
    /// last chunk -- goes with the queue; over HTTP/2 the writer sends
    /// END_STREAM once the stream's bytes are out.
    private func endLocked() {
        stopKeepAliveLocked()
        guard state == .open else { return }
        state = .finished
        if bodyless { return }
        if let encoder, !encode(encoder, nil, 0, finishing: true) {
            Log.error("compressing a streamed response failed; ending it")
            state = .failed
            if let s = h2 {
                s.bodyFailed = true
                s.bodyEnded = true
                s.connection.wakeWriter()
            } else if let s = h3 {
                s.bodyFailed = true
                s.bodyEnded = true
                s.endpoint.post(s)
            }
            return
        }
        if let s = h2 {
            s.bodyEnded = true
            s.connection.wakeWriter()
        } else if let s = h3 {
            s.bodyEnded = true
            s.endpoint.post(s)
        } else if chunked {
            HTTPResponseWriter.writeLastChunk(&pending)
        }
    }

    /// Under the state's lock: `n` bytes through the encoder onto the queue,
    /// or its end.
    private func encode(_ encoder: ResponseEncoder, _ p: UnsafePointer<UInt8>?, _ n: Int,
                        finishing: Bool) -> Bool {
        if let s = h2 {
            let before = s.staged.readableBytes
            let ok = finishing ? encoder.finish(into: &s.staged, chunked: false)
                : encoder.encode(p, n, flush: true, into: &s.staged, chunked: false)
            let added = s.staged.readableBytes - before
            if added > 0 {
                s.backlog &+= added
                s.connection.wakeWriter()
            }
            return ok
        }
        if let s = h3 {
            // Compressed out of the way, then framed as DATA.
            s.scratch.clear()
            let ok = finishing ? encoder.finish(into: &s.scratch, chunked: false)
                : encoder.encode(p, n, flush: true, into: &s.scratch, chunked: false)
            let added = s.scratch.readableBytes
            if added > 0 {
                s.staged.writeVarint(HTTP3FrameType.data)
                s.staged.writeVarint(UInt64(added))
                s.staged.write(s.scratch.readPointer, added)
                s.endpoint.post(s)
            }
            return ok
        }
        return finishing ? encoder.finish(into: &pending, chunked: chunked)
            : encoder.encode(p, n, flush: true, into: &pending, chunked: chunked)
    }

    /// The handler has returned: over HTTP/1, moves what is still queued
    /// into the connection's output, ahead of the next answer. False when
    /// the connection cannot be kept: the body was cut short or failed.
    func close(into parts: UnsafeMutablePointer<ConnectionParts>, failed: Bool) async -> Bool {
        var keep = true
        lock.withLock { _ in
            stopKeepAliveLocked()
            if failed || state == .failed {
                // Half a body cannot be ended honestly: what was written
                // goes, and then the close.
                keep = bodyless && state != .failed
                state = .failed
            } else {
                endLocked()
                if remaining > 0 {
                    Log.error("a streamed response ended short of its Content-Length")
                    keep = false
                }
                // A body delimited by the close has no other end.
                if !bodyless && !chunked && remaining < 0 { keep = false }
                if let capture, remaining <= 0, state == .finished { _ = capture.store() }
            }
            capture = nil
        }
        // A writer the handler left behind -- a spawned flush, a keep-alive
        // comment, a task not its child -- may still be taking the queue
        // out: the connection writes nothing until it is done. Then what is
        // queued goes with the connection's own output, and a flush that
        // has yet to begin finds nothing to take.
        while true {
            let waited = await withUnsafeContinuation { (c: UnsafeContinuation<Bool, Never>) in
                let parked = lock.withLock { _ -> Bool in
                    if flushing {
                        waiters.append(c)
                        return true
                    }
                    detached = true
                    if parts.pointee.output.readableBytes == 0 {
                        // The buffer lent goes back, or the one the queue
                        // moved to: the output's own is the channel's to free.
                        swap(&pending, &parts.pointee.output)
                    } else if pending.readableBytes > 0 {
                        parts.pointee.output.write(pending.readPointer, pending.readableBytes)
                    }
                    pending.clear()
                    return false
                }
                if !parked { c.resume(returning: false) }
            }
            if !waited { break }
        }
        wakeWaiters(drained: false)
        return keep
    }

    /// Over HTTP/2, when the handler has returned: ended, or failed and the
    /// stream to be reset. Under the connection's lock.
    func closeH2Locked(_ s: H2Stream, failed: Bool) {
        stopKeepAliveLocked()
        if bodyless {
            state = .finished
            return
        }
        if failed || remaining > 0 {
            if !failed { Log.error("a streamed response ended short of its Content-Length") }
            state = .failed
            s.bodyFailed = true
            s.bodyEnded = true
            s.connection.wakeWriter()
            s.resumeWaiters(false)
        } else {
            endLocked()
            if let capture, state == .finished { _ = capture.store() }
        }
        capture = nil
    }

    /// Over HTTP/3, when the handler has returned: ended, or failed and the
    /// stream to be reset. Under the endpoint's lock. The endpoint ends the
    /// stream once what is staged has gone.
    func closeH3Locked(_ s: H3Stream, failed: Bool) {
        stopKeepAliveLocked()
        if bodyless {
            state = .finished
            s.bodyEnded = true
            return
        }
        if failed || remaining > 0 {
            if !failed { Log.error("a streamed response ended short of its Content-Length") }
            state = .failed
            s.bodyFailed = true
            s.bodyEnded = true
            s.resumeWaiters(false)
        } else {
            endLocked()
            // Ended already by the handler, or now; either way the endpoint
            // ends the stream once what is staged has gone.
            if state != .failed { s.bodyEnded = true }
            if let capture, state == .finished { _ = capture.store() }
        }
        capture = nil
    }

    /// A WebSocket's, once it has ended: what is queued goes, waiting at
    /// most the write timeout, and then nothing more is written, so the
    /// stream can be let go of.
    func stopAfterDraining() async {
        try? await settle(.sent, flushing: true)
        lock.withLock { _ in state = .failed }
        // A writer still taking the queue out finishes first.
        while true {
            let waited = await withUnsafeContinuation { (c: UnsafeContinuation<Bool, Never>) in
                let parked = lock.withLock { _ -> Bool in
                    guard flushing else { return false }
                    waiters.append(c)
                    return true
                }
                if !parked { c.resume(returning: false) }
            }
            if !waited { break }
        }
        lock.withLock { _ in pending.clear() }
        wakeWaiters(drained: false)
    }

    // MARK: Files

    /// Sends `count` bytes of `file` from `start` as the body: by the kernel
    /// over a stream that can take a file, else read a block at a time and
    /// written as any other bytes are. Throws `cancelled` when the body
    /// cannot be finished -- the client went, or the file ended early.
    func sendFile(_ file: borrowing File, from start: Int, count: Int) async throws(HandlerWaitError) {
        if bodyless || count == 0 { return }
        if let held, held.sendsFiles, !chunked {
            // What is queued -- the head -- goes first.
            try await settle(.sent, flushing: true)
            let taken = lock.withLock { _ -> Bool in
                guard state == .open, !flushing else { return false }
                flushing = true
                inFlight = count
                if remaining >= 0 { remaining = max(0, remaining &- count) }
                return true
            }
            guard taken else { throw .cancelled }
            var sent = 0
            while sent < count {
                let n: Int
                do {
                    let at = start + sent
                    let left = count - sent
                    n = try await Runtime.withIOTimeout(for: timeout) { () async throws(IOError) -> Int in
                        try await held.sendFile(file.descriptor, offset: at, count: left)
                    }
                } catch {
                    break
                }
                if n <= 0 { break }
                sent += n
            }
            let ok = sent == count
            lock.withLock { _ in
                flushing = false
                inFlight = 0
                if !ok { state = .failed }
            }
            wakeWaiters(drained: ok)
            if !ok { throw .cancelled }
            return
        }
        var buffer = IOBuffer(capacity: min(count, fileBlockBytes))
        var offset = start
        var left = count
        while left > 0 {
            buffer.clear()
            let n: Int
            do {
                n = try await file.read(into: &buffer, at: offset)
            } catch {
                throw .cancelled
            }
            if n <= 0 { throw .cancelled }
            let take = min(n, left)
            let queued = buffer.withUnsafeBytes { queue(UnsafeRawBufferPointer(rebasing: $0[0..<take])) }
            try await settle(queued)
            offset += take
            left -= take
        }
    }

    // MARK: Keep-alive

    /// Sends `comment` whenever the body has been quiet for `interval`, until
    /// it ends. Comments are written whole, between whole writes.
    func keepAlive(every interval: Duration, comment: [UInt8]) {
        guard interval > .zero, !bodyless, let runtime else { return }
        let nanos = UInt64(clamping: interval.components.seconds) &* 1_000_000_000
            &+ UInt64(clamping: interval.components.attoseconds / 1_000_000_000)
        locked {
            guard state == .open, keepAliveTask == nil else { return }
            lastWrite = monotonicNanos()
            keepAliveTask = runtime.spawn { [self] in
                var wait = interval
                while true {
                    do {
                        try await Runtime.sleep(for: wait)
                    } catch {
                        return
                    }
                    let quiet = locked { () -> UInt64? in
                        guard state == .open, keepAliveTask != nil else { return nil }
                        return monotonicNanos() &- lastWrite
                    }
                    guard let quiet else { return }
                    if quiet < nanos {
                        wait = .nanoseconds(Int64(nanos &- quiet))
                        continue
                    }
                    wait = interval
                    // A client already behind needs no reminder that the
                    // stream is there; the write timeout deals with it.
                    if backlog > 0 { continue }
                    let queued = comment.withUnsafeBufferPointer { queue(UnsafeRawBufferPointer($0)) }
                    do {
                        try await settle(queued)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    /// Under the state's lock.
    private func stopKeepAliveLocked() {
        guard let task = keepAliveTask else { return }
        keepAliveTask = nil
        task.cancel()
    }

    // MARK: HTTP/3

    private func settleH3(_ s: H3Stream, force: Bool) async throws(HandlerWaitError) {
        let endpoint = s.endpoint
        while true {
            let drained = await withUnsafeContinuation { (c: UnsafeContinuation<Bool, Never>) in
                let resume = endpoint.lock.withLock { _ -> Bool? in
                    if s.reset || state == .failed { return false }
                    // The endpoint answering the stream itself cannot wait for
                    // itself to take what was staged.
                    if s.runsInline { return true }
                    if s.staged.readableBytes <= (force ? 0 : high) { return true }
                    s.waiters.append(c)
                    return nil
                }
                if let resume { c.resume(returning: resume) }
            }
            if !drained { throw .cancelled }
            let more = endpoint.lock.withLock { _ in
                !s.runsInline && s.staged.readableBytes > (force ? 0 : high) && !s.reset && state != .failed
            }
            if !more { return }
        }
    }

    // MARK: HTTP/2

    private func settleH2(_ s: H2Stream, force: Bool) async throws(HandlerWaitError) {
        let connection = s.connection
        while true {
            let drained = await withUnsafeContinuation { (c: UnsafeContinuation<Bool, Never>) in
                let resume = connection.lock.withLock { _ -> Bool? in
                    if s.reset || state == .failed { return false }
                    // The reader answering the stream itself cannot wait for
                    // the window it is the one to read.
                    if s.runsInline { return true }
                    if s.backlog <= (force ? 0 : high) { return true }
                    s.waiters.append(c)
                    return nil
                }
                if let resume { c.resume(returning: resume) }
            }
            if !drained { throw .cancelled }
            let more = connection.lock.withLock { _ in
                !s.runsInline && s.backlog > (force ? 0 : high) && !s.reset && state != .failed
            }
            if !more { return }
        }
    }
}

// What a streamed body is held to, from the config.
extension BodyChannel: JobEndAction {
    /// The job that queued the first write has returned (`deferFlush`).
    func jobEnded() {
        let flush = lock.withLock { _ -> Bool in
            // Returned, and the connection has the queue; or a writer, or a
            // failure, got there first.
            guard state != .failed, !detached, !flushing, pending.readableBytes > 0 else {
                flushSpawned = false
                return false
            }
            return true
        }
        if flush, let runtime {
            spawnFlush(runtime)
        } else if flush {
            lock.withLock { _ in flushSpawned = false }
        }
    }
}

struct StreamLimits {
    var writeTimeout: Duration
    var high: Int
    var low: Int

    var eventKeepAlive: Duration

    init(_ limits: ConnectionLimits) {
        writeTimeout = limits.writeTimeout
        high = limits.writeHighWaterMark
        low = limits.writeLowWaterMark
        eventKeepAlive = limits.eventKeepAlive
    }
}

/// Where a streamed body goes, set by the connection.
enum BodyLink {
    case none
    case http1(HeldStream, UnsafeMutablePointer<ConnectionParts>, StreamLimits)
    case http2(Unmanaged<H2Stream>)
    case http3(Unmanaged<H3Stream>)
}

/// How an HTTP/1 response's body is delimited.
enum H1Framing: Equatable {
    case length(Int)
    case chunked
    /// No body, or one that ends with the connection.
    case none
}
