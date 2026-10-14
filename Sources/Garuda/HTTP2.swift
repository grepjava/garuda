//===----------------------------------------------------------------------===//
// HTTP/2 (RFC 9113): a connection is a reader, a writer, and a task a stream.
//
// A connection becomes HTTP/2 when TLS settled on "h2" by ALPN, or when a
// cleartext client opens with the preface (prior knowledge). The preface is
// looked for in the HTTP/1 read buffer, so an HTTP/1 connection pays for one
// comparison of its first bytes and loses none of them.
//
// The connection's own task is the READER. It reads frames, owns the HPACK
// decoder and the table of streams, keeps the receive windows, and enforces
// every limit. A second task, the WRITER, writes what nobody else does. The
// two meet in `H2Connection`, under its lock: control frames the reader wants
// sent (SETTINGS acks, PING answers, WINDOW_UPDATEs, RST_STREAMs, GOAWAY),
// streams that have their answer, and the send windows the peer grants. The
// reader wakes the writer with a `Notify`. A stream whose answer is ready
// writes it itself when nobody else is writing and the windows take it
// whole, holding the connection's write role meanwhile; otherwise it too
// hands its answer to the writer (HTTP2Writer.swift).
//
// A stream's request head is rebuilt as HTTP/1.1 text in the stream's own
// buffer and parsed by the ordinary parser into the stream's own `Exchange`,
// with its version set to 2: routing, middleware, extractors and the heavy
// lane see a request like any other. Its body is collected whole before
// dispatch, as HTTP/1 collects one, held to the same body limit, with the
// window given back as it arrives. Then the stream runs `dispatch` in a task
// from the shard's `TaskPool`, so a handler that waits holds up no other
// stream, and its answer is written within the stream's and the
// connection's send windows.
//
// Except when nothing could be held up: the connection's only stream, going
// to a route that has run many times without ever suspending and is not
// heavy, is answered by the reader itself, as an HTTP/1 connection answers
// its request. The frames that came after it wait in the buffer until it is
// answered -- no longer than any other request takes. One run that does
// suspend sends the route to the pool for good.
//
// A stream the client resets has its task cancelled -- Swift task
// cancellation, so a handler waiting on I/O or a sleep stops waiting -- and
// whatever it answers is dropped. Pooled tasks are reused, and cancellation
// cannot be undone, so the handler runs in a child task (an `async let`, made
// from the pooled task's own allocator) and only the child is cancelled.
//
// Streams, their exchanges and their buffers are kept for the next stream on
// the connection: a stream costs no allocation once the connection is warm.
//
// The defences are Garuda 1's: frame, header-list and concurrency limits,
// CONTINUATION held to the header limit, and the rapid-reset defence
// (CVE-2023-44487), which bounds not concurrency but the ratio of streams
// cancelled to streams answered.
//===----------------------------------------------------------------------===//

import GarudaWire
import Synchronization
import Vega
import VegaIO

/// HTTP/2's settings and limits, worked out once from the config.
struct HTTP2Limits: Sendable {
    var enabled: Bool
    /// --http2-only: cleartext connections must be HTTP/2.
    var only: Bool
    var maxConcurrentStreams: Int
    var maxFrameSize: Int
    var initialWindowSize: Int
    var maxHeaderListSize: Int
    /// How many cancellations a connection may run up beyond the streams it
    /// has had answered (the rapid-reset defence).
    var resetBudget: Int

    init(_ config: ServerConfig) {
        enabled = config.http2Enabled || config.http2Only
        only = config.http2Only
        maxConcurrentStreams = max(1, config.h2MaxConcurrentStreams)
        maxFrameSize = min(max(config.h2MaxFrameSize, H2FrameHeader.defaultMaxFrameSize), 0xFF_FFFF)
        initialWindowSize = min(max(config.h2InitialWindowSize, H2FrameHeader.defaultInitialWindowSize),
                                H2FrameHeader.maxWindowSize)
        maxHeaderListSize = config.maxHeadSize
        // Deep enough that a whole window of streams can be cancelled at once,
        // which is what a navigation away from a page full of subresources
        // actually looks like.
        resetBudget = max(100, maxConcurrentStreams * 2)
    }
}

// MARK: - The shard's HTTP/2

/// What a shard's HTTP/2 connections share: the pool their streams run in,
/// and the list of connections that shutdown sends GOAWAY to.
final class HTTP2Service: @unchecked Sendable {
    let runtime: Runtime
    /// Where streams run. A stream whose handler waits holds its pooled task
    /// meanwhile, and work past `maxTasks` queues, so the bound is generous:
    /// tasks are only made when work finds none idle.
    let pool: TaskPool
    private let lock = Mutex<Void>(())
    private var first: H2Connection?
    private var stopping = false

    init(runtime: Runtime) {
        self.runtime = runtime
        pool = TaskPool(runtime: runtime, maxTasks: max(1024, runtime.workerCount * 256))
    }

    func register(_ connection: H2Connection) {
        let stopped = lock.withLock { _ -> Bool in
            connection.nextConnection = first
            first?.previousConnection = connection
            first = connection
            return stopping
        }
        if stopped { connection.beginShutdown() }
    }

    func unregister(_ connection: H2Connection) {
        lock.withLock { _ in
            if let previous = connection.previousConnection {
                previous.nextConnection = connection.nextConnection
            } else {
                first = connection.nextConnection
            }
            connection.nextConnection?.previousConnection = connection.previousConnection
            connection.previousConnection = nil
            connection.nextConnection = nil
        }
    }

    /// Shutdown has begun: every connection is sent GOAWAY, takes no new
    /// streams, and finishes the ones it has.
    func shutdown() {
        lock.withLock { _ in
            stopping = true
            var connection = first
            while let c = connection {
                c.beginShutdown()
                connection = c.nextConnection
            }
        }
    }

    /// The service the tests on `runtime` share. Kept for the process's
    /// life: its connections hold it unretained.
    static func forTesting(_ runtime: Runtime) -> HTTP2Service {
        testing.withLock { services in
            if let service = services.first(where: { $0.runtime === runtime }) { return service }
            let made = HTTP2Service(runtime: runtime)
            services.append(made)
            return made
        }
    }
    private static let testing = Mutex<[HTTP2Service]>([])
}

// MARK: - A connection's first bytes

/// How a connection opened.
enum ConnectionOpening {
    case http1
    case http2
    /// Something that cannot be HTTP/1 on a port that speaks HTTP/2: answered
    /// with GOAWAY.
    case refused
    /// Gone before it said anything.
    case closed
}

/// Serves a connection: HTTP/2 when it asks for it, HTTP/1 otherwise.
/// `negotiatedH2`: TLS chose "h2" by ALPN. `halves` splits the stream for
/// HTTP/2's reader and writer; `close` ends an HTTP/1 connection (TLS's
/// close_notify) and `closeWriter` an HTTP/2 one.
func serveConnection<S: AsyncReader & AsyncWriter & ~Copyable, R: AsyncReader & ~Copyable,
                     W: AsyncWriter & ~Copyable & Sendable>(
    _ stream: consuming S, app: CompiledApplication, limits: ConnectionLimits, peer: SocketPeer,
    secure: Bool, http2: HTTP2Service?, negotiatedH2: Bool = false,
    halves: (consuming S) -> StreamHalves<R, W>,
    close: (consuming S) async -> Void,
    closeWriter: @escaping @Sendable (borrowing W) async -> Void
) async {
    guard let http2, limits.http2.enabled else {
        await serveHTTP1(stream, app: app, limits: limits, peer: peer, secure: secure)
        await close(stream)
        return
    }
    let parts = app.connections.take(limits: limits, peer: peer)
    switch await opening(stream, parts, limits, strict: negotiatedH2 || limits.http2.only) {
    case .http1:
        await serveHTTP1(stream, parts: parts, app: app, limits: limits, secure: secure)
        await close(stream)
    case .http2:
        await serveHTTP2(halves(stream), parts: parts, app: app, limits: limits, service: http2, secure: secure,
                         closeWriter: closeWriter)
    case .refused:
        app.connections.give(parts, limits: limits)
        // RFC 9113 section 3.4: GOAWAY, then close.
        var out = ByteBuffer()
        H2FrameHeader(length: 8, type: .goaway, flags: [], streamID: 0).write(into: &out)
        HTTP2.writeUInt32(0, into: &out)
        HTTP2.writeUInt32(H2Error.protocolError.rawValue, into: &out)
        _ = try? await stream.write(UnsafeRawBufferPointer(start: out.readPointer, count: out.readableBytes))
        out.destroy()
        await close(stream)
    case .closed:
        app.connections.give(parts, limits: limits)
        await close(stream)
    }
}

/// Reads the connection's first bytes into the HTTP/1 read buffer, where
/// they stay, until they say which protocol it is. `strict`: only HTTP/2 is
/// served, so anything but the preface is refused.
func opening<S: AsyncReader & AsyncWriter & ~Copyable>(
    _ stream: borrowing S, _ parts: UnsafeMutablePointer<ConnectionParts>, _ limits: ConnectionLimits,
    strict: Bool
) async -> ConnectionOpening {
    let prefaceCount = HTTP2.preface.count
    while true {
        let count = parts.pointee.input.count
        if count > 0 {
            let p = parts.pointee.input.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
            // The preface is a valid HTTP/1.1 request line right up until it
            // is not, so it can only be recognised in full.
            if HTTP2.prefaceMatches(p, count) {
                if count >= prefaceCount { return .http2 }
            } else {
                if strict { return .refused }
                // A connection that opened with "PRI " and then diverged was
                // an HTTP/2 client, and one that opened with a byte no
                // request line starts with is likelier frames without the
                // preface than HTTP/1. Answering either in HTTP/1 would be
                // talking past it.
                if (count >= 4 && equalsExact(p, 4, "PRI ")) || !isTokenChar(p[0]) { return .refused }
                return .http1
            }
        }
        let timeout = count == 0 ? limits.keepAliveTimeout : limits.requestHeadTimeout
        do {
            let n = try await Runtime.withIODeadline(timeout) { () async throws(IOError) -> Int in
                try await stream.read(into: &parts.pointee.input)
            }
            if n == 0 { return .closed }
        } catch {
            return .closed
        }
    }
}

/// Serves HTTP/2 on `halves` until the client closes, idles out or breaks
/// the protocol. `parts.input` holds the preface and whatever followed it.
func serveHTTP2<R: AsyncReader & ~Copyable, W: AsyncWriter & ~Copyable & Sendable>(
    _ halves: consuming StreamHalves<R, W>, parts: UnsafeMutablePointer<ConnectionParts>,
    app: CompiledApplication, limits: ConnectionLimits, service: HTTP2Service, secure: Bool,
    closeWriter: @escaping @Sendable (borrowing W) async -> Void
) async {
    let reader = halves.reader
    let sink = H2WriteHalf(halves.writer)
    let connection = H2Connection(app: app, limits: limits, parts: parts, service: service, secure: secure,
                                  sink: sink)
    connection.begin()
    let writer = service.runtime.spawn {
        await connection.runWriter()
        await sink.close(closeWriter)
    }
    service.register(connection)
    await connection.runReader(reader)
    await connection.end(writer: writer)
    service.unregister(connection)
    app.connections.give(parts, limits: limits)
}

// MARK: - Streams

/// One stream: its exchange, the buffer its head is rebuilt in and the one
/// its body is collected in. Kept by the connection for its next stream.
final class H2Stream: @unchecked Sendable {
    unowned(unsafe) let connection: H2Connection
    let x: UnsafeMutablePointer<Exchange>
    /// The request head as HTTP/1.1 text; every slice in the exchange is
    /// relative to it.
    var head = ByteBuffer()
    var body = ByteBuffer()
    var id: UInt32 = 0

    // The reader's.
    /// The request body is still arriving.
    var receiving = false
    /// Its task has started, or it has gone: no longer `unstarted`.
    var started = false
    var recvWindow = 0
    /// Window consumed and not yet given back.
    var pendingUpdate = 0
    var received = 0
    var bodyLimit = 0
    /// The route matched for the body limit, or -1.
    var matched: Int32 = -1
    var lastActivity: UInt64 = 0

    // Shared, under the connection's lock.
    var sendWindow = 0
    /// Reset by the client or by a stream error: its answer goes nowhere.
    var reset = false
    /// The writer is done with it: ended, or dropped once reset.
    var closed = false
    /// The table's hold and the task-and-writer's: kept for reuse at 0.
    var holds = 0
    /// The handler's task while it runs, for a reset to cancel.
    var task: UnsafeCurrentTask?

    // The writer's.
    /// RST_STREAM to send after the answer: a 413 tells the client to stop.
    var resetAfter: H2Error?
    var sent = 0
    var length = 0
    var grant = 0

    init(connection: H2Connection, maxHeaders: Int, peer: SocketPeer) {
        self.connection = connection
        x = .allocate(capacity: 1)
        x.initialize(to: Exchange(maxHeaders: maxHeaders, remote: peer))
    }

    deinit {
        head.destroy()
        body.destroy()
        x.deinitialize(count: 1)
        x.deallocate()
    }
}

// MARK: - The connection

/// One HTTP/2 connection: what its reader and writer share, and the
/// reader's own state.
final class H2Connection: @unchecked Sendable {
    let app: CompiledApplication
    let limits: ConnectionLimits
    let settings: HTTP2Limits
    let parts: UnsafeMutablePointer<ConnectionParts>
    unowned(unsafe) let service: HTTP2Service
    let secure: Bool
    /// The access log or `app.onResponse` sees each answer.
    let observing: Bool

    // MARK: Shared, under `lock`

    let lock = Mutex<Void>(())
    /// Wakes the writer.
    let wake = Notify()
    /// Wakes the reader at the end, waiting for the last stream task.
    let idle = Notify()
    /// Control frames for the writer to send.
    var control = ByteBuffer()
    /// Streams answered, for the writer.
    var ready: [H2Stream] = []
    var spare: [H2Stream] = []
    /// Every stream made, so they live as long as the connection.
    var made: [H2Stream] = []
    var sendWindow = H2FrameHeader.defaultInitialWindowSize
    var peerMaxFrameSize = H2FrameHeader.defaultMaxFrameSize
    var peerInitialWindowSize = H2FrameHeader.defaultInitialWindowSize
    /// Streams the writer has ended since the reader last looked: each
    /// buys back one cancellation.
    var earned = 0
    /// Stream tasks running.
    var tasks = 0
    /// Streams taken whose task has not started: their request is still
    /// arriving, or being read.
    var unstarted = 0
    /// The peer sent GOAWAY.
    var peerGoneAway = false
    var lastPeerStream: UInt32 = 0
    var goawaySent = false
    /// The writer is to stop as soon as it has sent the control frames.
    var stopping = false
    var readerDone = false
    /// The writer could not write.
    let writeFailed = Atomic<Bool>(false)

    /// Someone holds the write role (HTTP2Writer.swift).
    var writing = false
    /// The writer is waiting for the role.
    var writerWanted = false

    // MARK: The write role's

    /// The write half: kept alive by `serveHTTP2` and the writer, which
    /// outlive every task that writes.
    unowned(unsafe) let sink: any H2Sink
    @exclusivity(unchecked) var wOut = ByteBuffer(capacity: 16 * 1024)
    @exclusivity(unchecked) var wBlock = ByteBuffer(capacity: 1024)
    @exclusivity(unchecked) var wDigits = ByteBuffer(capacity: 32)
    var frameSizeForRole = H2FrameHeader.defaultMaxFrameSize

    // Links in the service's list, under its lock.
    unowned(unsafe) var previousConnection: H2Connection?
    unowned(unsafe) var nextConnection: H2Connection?

    // MARK: The reader's

    var decoder = HPACKDecoder(maxTableSize: 4096)
    /// The open streams, by the reader's account: few, so a list.
    var streams: [H2Stream] = []
    /// Control frames made while reading, posted once per batch of frames.
    var outgoing = ByteBuffer()
    /// Where in the read buffer the next frame starts.
    var start = 0
    var recvWindow: Int
    var pendingRecvUpdate = 0
    var resetBudget: Int
    /// A header block arriving in CONTINUATION frames.
    var headerBlock = ByteBuffer()
    var blockStream: UInt32 = 0
    var blockEndsStream = false
    var expectingContinuation = false
    /// A stream whose handler the reader runs itself, once the frame that
    /// completed its request is handled.
    var inlineStream: H2Stream?
    /// Scratch for rebuilding a head.
    var pseudo = ByteBuffer()
    var fields = ByteBuffer()
    var cookies = ByteBuffer()

    init(app: CompiledApplication, limits: ConnectionLimits, parts: UnsafeMutablePointer<ConnectionParts>,
         service: HTTP2Service, secure: Bool, sink: any H2Sink) {
        self.sink = sink
        self.app = app
        self.limits = limits
        settings = limits.http2
        self.parts = parts
        self.service = service
        self.secure = secure
        observing = limits.accessLog || !app.observers.isEmpty
        recvWindow = H2FrameHeader.defaultInitialWindowSize
        resetBudget = settings.resetBudget
        ready.reserveCapacity(16)
        streams.reserveCapacity(16)
    }

    deinit {
        decoder.destroy()
        control.destroy()
        outgoing.destroy()
        headerBlock.destroy()
        pseudo.destroy()
        fields.destroy()
        cookies.destroy()
        wOut.destroy()
        wBlock.destroy()
        wDigits.destroy()
    }

    /// Takes the preface off the read buffer and queues our SETTINGS, which
    /// have to be the first thing sent.
    func begin() {
        parts.pointee.input.consume(HTTP2.preface.count)
        let entries: [(H2Setting, Int)] = [
            (.maxConcurrentStreams, settings.maxConcurrentStreams),
            (.initialWindowSize, settings.initialWindowSize),
            (.maxFrameSize, settings.maxFrameSize),
            (.maxHeaderListSize, settings.maxHeaderListSize),
            // We never push, and saying so up front keeps a client from
            // reserving anything on our behalf.
            (.enablePush, 0),
        ]
        frame(&control, entries.count * 6, .settings, [], 0)
        for (setting, value) in entries {
            control.writeByte(UInt8(truncatingIfNeeded: setting.rawValue >> 8))
            control.writeByte(UInt8(truncatingIfNeeded: setting.rawValue))
            HTTP2.writeUInt32(UInt32(value), into: &control)
        }
        // A connection window larger than the default lets one upload use the
        // link; the per-stream window is what bounds a stream.
        let bump = settings.initialWindowSize - H2FrameHeader.defaultInitialWindowSize
        if bump > 0 {
            frame(&control, 4, .windowUpdate, [], 0)
            HTTP2.writeUInt32(UInt32(bump), into: &control)
            recvWindow = settings.initialWindowSize
        }
        // Room for the largest frame we accept, header and all.
        let room = 2 * (settings.maxFrameSize + H2FrameHeader.size)
        if parts.pointee.input.capacity < room { parts.pointee.input.reserveCapacity(room) }
    }

    /// Shutdown: GOAWAY naming the last stream taken, and no new ones.
    func beginShutdown() {
        lock.withLock { _ in
            guard !goawaySent else { return }
            goawaySent = true
            frame(&control, 8, .goaway, [], 0)
            HTTP2.writeUInt32(lastPeerStream, into: &control)
            HTTP2.writeUInt32(H2Error.noError.rawValue, into: &control)
            wake.notifyOne()
        }
    }

    // MARK: - Reading

    /// Reads and handles frames until the connection is done.
    func runReader<R: AsyncReader & ~Copyable>(_ reader: borrowing R) async {
        var failed = false
        while true {
            if !handleFrames() {
                failed = true
                break
            }
            // A stream to answer here, with the frames after its request
            // still in the buffer: they are handled once it is answered.
            while let s = inlineStream {
                inlineStream = nil
                await answerInline(s)
                if !handleFrames() {
                    failed = true
                    break
                }
            }
            if failed { break }
            // After GOAWAY either way, the writer ends the write side once
            // every stream is answered. The reader reads on until the peer
            // closes, or the keep-alive tick: closing under bytes the peer is
            // still sending would turn an orderly end into a reset.
            if writeFailed.load(ordering: .relaxed) {
                failed = true
                break
            }
            if parts.pointee.input.spareCapacity < H2FrameHeader.size + settings.maxFrameSize {
                parts.pointee.input.reserveCapacity(parts.pointee.input.capacity * 2)
            }
            do {
                // Woken at least this often to look at idleness and stalled
                // uploads; a read interrupted this way has read nothing.
                let n = try await Runtime.withIODeadline(limits.keepAliveTimeout) { () async throws(IOError) -> Int in
                    try await reader.read(into: &parts.pointee.input)
                }
                if n == 0 { break }
            } catch let error where error == .timedOut {
                if writeFailed.load(ordering: .relaxed) {
                    failed = true
                    break
                }
                if tick() { break }
            } catch {
                // Reset, or cancelled once shutdown's grace has run out.
                failed = true
                break
            }
        }
        lock.withLock { _ in
            readerDone = true
            if failed {
                stopping = true
                for s in streams { cancel(s) }
            }
            wake.notifyOne()
        }
    }

    /// Waits for the writer and for every stream task, which use the
    /// connection until they end.
    func end(writer: Task<Void, Never>) async {
        await writer.value
        // Nothing a task still running answers can be sent now.
        lock.withLock { _ in for s in streams { cancel(s) } }
        while lock.withLock({ _ in tasks }) > 0 {
            await idle.notifiedIgnoringCancellation()
        }
    }

    /// Under the lock: a stream's answer is no longer wanted.
    func cancel(_ s: H2Stream) {
        s.reset = true
        s.task?.cancel()
    }

    /// No stream open, by the reader's account, and none running.
    func isIdle() -> Bool {
        lock.withLock { _ in
            sweep()
            return streams.isEmpty && tasks == 0
        }
    }

    /// The read deadline passed with nothing read. True when the connection
    /// is done: it has been idle for the keep-alive timeout.
    func tick() -> Bool {
        if isIdle() {
            lock.withLock { _ in
                if !goawaySent {
                    goawaySent = true
                    frame(&control, 8, .goaway, [], 0)
                    HTTP2.writeUInt32(lastPeerStream, into: &control)
                    HTTP2.writeUInt32(H2Error.noError.rawValue, into: &control)
                }
            }
            return true
        }
        // A body that stopped arriving: the stream is given up on, as an
        // HTTP/1 request whose body stalls is.
        let now = monotonicNanos()
        let limit = UInt64(clamping: limits.bodyTimeout.components.seconds) &* 1_000_000_000
        var i = 0
        while i < streams.count {
            let s = streams[i]
            if s.receiving && now &- s.lastActivity > limit {
                streamError(s.id, .cancel)
                continue
            }
            i &+= 1
        }
        post()
        return false
    }

    /// Under the lock: drops the streams the writer has finished with.
    func sweep() {
        var i = 0
        while i < streams.count {
            if streams[i].closed {
                release(streams[i])
                streams.swapAt(i, streams.count - 1)
                streams.removeLast()
            } else {
                i &+= 1
            }
        }
    }

    /// Under the lock: one hold on `s` let go; at none it is kept for reuse.
    func release(_ s: H2Stream) {
        s.holds &-= 1
        if s.holds == 0 { spare.append(s) }
    }

    func find(_ id: UInt32) -> H2Stream? {
        for s in streams where s.id == id { return s }
        return nil
    }

    /// Takes `s` out of the table, letting the table's hold go.
    func remove(_ s: H2Stream) {
        if let i = streams.firstIndex(where: { $0 === s }) {
            streams.swapAt(i, streams.count - 1)
            streams.removeLast()
        }
        let starting = !s.started
        s.started = true
        s.receiving = false
        lock.withLock { _ in
            if starting { unstarted &-= 1 }
            release(s)
        }
    }

    /// Hands the control frames made while reading to the writer.
    func post() {
        guard outgoing.readableBytes > 0 else { return }
        lock.withLock { _ in
            control.write(outgoing.readPointer, outgoing.readableBytes)
            wake.notifyOne()
        }
        outgoing.clear()
    }

    /// Handles every whole frame in the read buffer. False once the
    /// connection has failed, with GOAWAY posted.
    func handleFrames() -> Bool {
        let count = parts.pointee.input.count
        guard count > 0 else { return true }
        let base = parts.pointee.input.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) }
        start = 0
        var ok = true
        while count &- start >= H2FrameHeader.size {
            let header = H2FrameHeader.parse(base + start)
            if header.length > settings.maxFrameSize {
                ok = connectionError(.frameSizeError)
                break
            }
            if count &- start &- H2FrameHeader.size < header.length { break }
            // A header block may not be interleaved with anything else.
            if expectingContinuation && header.type != H2FrameType.continuation.rawValue {
                ok = connectionError(.protocolError)
                break
            }
            if !handleFrame(header, base + start + H2FrameHeader.size) {
                ok = false
                break
            }
            start &+= H2FrameHeader.size &+ header.length
            if inlineStream != nil { break }
        }
        if ok && start > 0 { parts.pointee.input.consume(start) }
        start = 0
        post()
        return ok
    }

    func handleFrame(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        // Unknown frame types are discarded: that is how extensions are
        // meant to be ignorable.
        guard let type = H2FrameType(rawValue: header.type) else { return true }
        switch type {
        case .data: return handleData(header, payload)
        case .headers: return handleHeaders(header, payload)
        case .continuation: return handleContinuation(header, payload)
        case .priority: return handlePriority(header, payload)
        case .rstStream: return handleReset(header, payload)
        case .settings: return handleSettings(header, payload)
        case .ping: return handlePing(header, payload)
        case .goaway: return handleGoaway(header)
        case .windowUpdate: return handleWindowUpdate(header, payload)
        case .pushPromise: return connectionError(.protocolError)
        }
    }

    // MARK: DATA

    func handleData(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.streamID == 0 { return connectionError(.protocolError) }
        // Flow control is accounted before anything else can refuse the
        // frame: the peer has spent the window whether or not we want it.
        recvWindow -= header.length
        if recvWindow < 0 { return connectionError(.flowControlError) }
        pendingRecvUpdate += header.length

        var offset = 0
        var length = header.length
        if header.flags.contains(.padded) {
            if length < 1 { return connectionError(.protocolError) }
            let pad = Int(payload[0])
            offset = 1
            length -= 1
            if pad > length { return connectionError(.protocolError) }
            length -= pad
        }

        guard let s = find(header.streamID) else {
            // A stream we have finished with. The connection window still
            // has to be given back, or the peer stalls behind bytes nobody
            // wanted.
            releaseConnectionWindow()
            if header.streamID <= lastPeerStreamSeen {
                rst(header.streamID, .streamClosed)
                return true
            }
            return connectionError(.protocolError)
        }
        guard s.receiving else {
            // Data after END_STREAM.
            releaseConnectionWindow()
            streamError(header.streamID, .streamClosed)
            return true
        }
        s.lastActivity = monotonicNanos()
        s.recvWindow -= header.length
        if s.recvWindow < 0 {
            releaseConnectionWindow()
            streamError(header.streamID, .flowControlError)
            return true
        }
        s.received += length
        // Cumulative: the limit is on the upload.
        if s.received > s.bodyLimit {
            releaseConnectionWindow()
            refuseBody(s)
            return true
        }
        if length > 0 { s.body.write(payload + offset, length) }
        // RFC 9113 section 8.1.1: a body that disagrees with its declared
        // length is malformed, checked as it arrives so a client that has
        // already overshot hears about it now.
        let declared = s.x.pointee.head.flags.contains(.hasContentLength)
        if declared && s.received > s.x.pointee.head.contentLength {
            releaseConnectionWindow()
            streamError(header.streamID, .protocolError)
            return true
        }
        // The body is the handler's once it is here, so a byte buffered is a
        // byte consumed; the body limit bounds the buffer.
        s.pendingUpdate += header.length
        if header.flags.contains(.endStream) {
            releaseConnectionWindow()
            if declared && s.x.pointee.head.contentLength != s.received {
                streamError(header.streamID, .protocolError)
                return true
            }
            run(s)
            return true
        }
        // Half the window is the usual compromise between a WINDOW_UPDATE
        // per frame and letting the peer run dry.
        if s.pendingUpdate >= settings.initialWindowSize / 2 {
            let bump = s.pendingUpdate
            s.pendingUpdate = 0
            s.recvWindow += bump
            frame(&outgoing, 4, .windowUpdate, [], s.id)
            HTTP2.writeUInt32(UInt32(bump), into: &outgoing)
        }
        releaseConnectionWindow()
        return true
    }

    func releaseConnectionWindow() {
        if pendingRecvUpdate < settings.initialWindowSize / 2 { return }
        let bump = pendingRecvUpdate
        pendingRecvUpdate = 0
        recvWindow += bump
        frame(&outgoing, 4, .windowUpdate, [], 0)
        HTTP2.writeUInt32(UInt32(bump), into: &outgoing)
    }

    /// A body past its limit: answered 413, as on HTTP/1.1, and the stream
    /// then reset with NO_ERROR, which tells the client to stop sending the
    /// rest without calling the request malformed (RFC 9113 section 8.1).
    func refuseBody(_ s: H2Stream) {
        s.receiving = false
        s.started = true
        s.x.pointee.answer(413, nil, 0)
        s.resetAfter = .noError
        if let i = streams.firstIndex(where: { $0 === s }) {
            streams.swapAt(i, streams.count - 1)
            streams.removeLast()
        }
        // The table's hold passes to the writer.
        lock.withLock { _ in
            unstarted &-= 1
            ready.append(s)
            wake.notifyOne()
        }
    }

    // MARK: HEADERS and CONTINUATION

    /// The highest stream the peer has opened, as the reader sees it.
    var lastPeerStreamSeen: UInt32 = 0

    func handleHeaders(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        let id = header.streamID
        if id == 0 || id % 2 == 0 { return connectionError(.protocolError) }
        var offset = 0
        var length = header.length
        if header.flags.contains(.padded) {
            if length < 1 { return connectionError(.protocolError) }
            let pad = Int(payload[0])
            offset = 1
            length -= 1
            if pad > length { return connectionError(.protocolError) }
            length -= pad
        }
        if header.flags.contains(.priority) {
            // Priority is deprecated in RFC 9113 and parsed only far enough
            // to skip; a stream that depends on itself is still an error.
            if length < 5 { return connectionError(.frameSizeError) }
            let dependency = HTTP2.readUInt32(payload + offset) & 0x7FFF_FFFF
            if dependency == id { return connectionError(.protocolError) }
            offset += 5
            length -= 5
        }
        var existing = find(id)
        if let s = existing, !s.receiving {
            // Answered and ended, perhaps, and not yet swept: a stream that
            // has gone is not one to send trailers on.
            if lock.withLock({ _ in sweep(); return s.closed }) { existing = nil }
        }
        if existing == nil {
            // Reusing an identifier, or going backwards through them.
            if id <= lastPeerStreamSeen { return connectionError(.protocolError) }
            lastPeerStreamSeen = id
        } else if !header.flags.contains(.endStream) {
            // A second HEADERS on a live stream is a trailer section, and a
            // trailer section is the end of the request by definition.
            return connectionError(.protocolError)
        }
        blockStream = id
        blockEndsStream = header.flags.contains(.endStream)
        if header.flags.contains(.endHeaders) {
            return completeHeaderBlock(payload + offset, length)
        }
        headerBlock.clear()
        if length > 0 { headerBlock.write(payload + offset, length) }
        expectingContinuation = true
        return true
    }

    func handleContinuation(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if !expectingContinuation || header.streamID != blockStream { return connectionError(.protocolError) }
        if headerBlock.readableBytes + header.length > settings.maxHeaderListSize * 2 {
            return connectionError(.enhanceYourCalm)
        }
        if header.length > 0 { headerBlock.write(payload, header.length) }
        guard header.flags.contains(.endHeaders) else { return true }
        expectingContinuation = false
        let n = headerBlock.readableBytes
        if n == 0 { return completeHeaderBlock(emptyBlock, 0) }
        return completeHeaderBlock(UnsafePointer(headerBlock.readPointer), n)
    }

    /// Decodes a block nobody wants: HPACK is stateful, so it still has to
    /// be read, or every later block decodes to nonsense.
    func discardBlock(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        do {
            try decoder.decode(p, n, sizeLimit: settings.maxHeaderListSize) { _ in }
            return true
        } catch {
            return false
        }
    }

    /// A finished header block: a trailer section, or a new request.
    func completeHeaderBlock(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        let id = blockStream
        if let s = find(id) {
            guard discardBlock(p, n) else { return connectionError(.compressionError) }
            guard s.receiving else {
                // Half-closed already: the request is over, whatever this is.
                streamError(id, .streamClosed)
                return true
            }
            // A trailer section ends the body as surely as END_STREAM on a
            // DATA frame, and is held to the same declared length.
            let head = s.x.pointee.head
            if head.flags.contains(.hasContentLength) && head.contentLength != s.received {
                streamError(id, .protocolError)
                return true
            }
            run(s)
            return true
        }

        // Refused rather than queued when the peer runs past what we
        // advertised, or after GOAWAY either way.
        let s: H2Stream? = lock.withLock { _ in
            lastPeerStream = id
            sweep()
            if streams.count >= settings.maxConcurrentStreams || goawaySent || peerGoneAway { return nil }
            return take(id)
        }
        guard let s else {
            guard discardBlock(p, n) else { return connectionError(.compressionError) }
            rst(id, .refusedStream)
            return true
        }
        streams.append(s)
        switch buildHead(s, p, n) {
        case .compression:
            remove(s)
            return connectionError(.compressionError)
        case .malformed:
            remove(s)
            rst(id, .protocolError)
            return true
        case .ok:
            break
        }
        let head = s.x.pointee.head
        if blockEndsStream {
            if head.flags.contains(.hasContentLength) && head.contentLength > 0 {
                remove(s)
                rst(id, .protocolError)
                return true
            }
            run(s)
            return true
        }
        // The body is collected whole before dispatch, exactly as an HTTP/1
        // request's is, and held to the limit of the route it goes to.
        s.receiving = true
        s.lastActivity = monotonicNanos()
        s.bodyLimit = app.hasBodyLimits ? bodyLimit(s.x, app, limits, matched: &s.matched) : limits.maxBodySize
        // A declared length past the limit is refused before a byte of the
        // body is taken.
        if head.flags.contains(.hasContentLength) && head.contentLength > s.bodyLimit { refuseBody(s) }
        return true
    }

    /// Under the lock: a stream for `id`, kept or new, with the table's hold
    /// on it.
    func take(_ id: UInt32) -> H2Stream {
        let s: H2Stream
        if let kept = spare.popLast() {
            s = kept
        } else {
            s = H2Stream(connection: self, maxHeaders: limits.maxHeaders, peer: parts.pointee.exchange.pointee.remote)
            s.x.pointee.application = Unmanaged.passUnretained(app)
            s.x.pointee.secure = secure
            s.x.pointee.trust = limits.trust
            made.append(s)
        }
        s.id = id
        s.holds = 1
        s.started = false
        unstarted &+= 1
        s.reset = false
        s.closed = false
        s.task = nil
        s.sendWindow = peerInitialWindowSize
        s.resetAfter = nil
        s.sent = 0
        s.length = 0
        s.receiving = false
        s.recvWindow = settings.initialWindowSize
        s.pendingUpdate = 0
        s.received = 0
        s.matched = -1
        s.x.pointee.reset()
        s.head.clear()
        // A buffer a large body grew is not kept for every later stream.
        if s.body.allocatedCapacity > 1 << 20 { s.body.destroy() } else { s.body.clear() }
        return s
    }

    enum HeadOutcome { case ok, malformed, compression }

    /// Rebuilds the request as HTTP/1.1 text in the stream's head buffer and
    /// parses it into its exchange.
    ///
    /// A decoded field is only valid until the next one is decoded, so what
    /// is kept is copied out as it arrives: pseudo-header values into
    /// `pseudo`, regular fields straight into header text.
    func buildHead(_ s: H2Stream, _ p: UnsafePointer<UInt8>, _ n: Int) -> HeadOutcome {
        pseudo.clear()
        fields.clear()
        cookies.clear()
        var method = (0, 0), path = (0, 0), authority = (0, 0), host = (0, 0)
        var sawMethod = false, sawPath = false, sawScheme = false, sawAuthority = false, sawHost = false
        var sawRegular = false
        var malformed = false

        do {
            try decoder.decode(p, n, sizeLimit: settings.maxHeaderListSize) { span in
                if malformed { return }
                if span.nameLength > 0 && span.name[0] == 0x3A {      // ':'
                    // Pseudo-headers come first, once each, and only these.
                    if sawRegular || !HTTP2.validFieldValue(span.value, span.valueLength) {
                        malformed = true
                        return
                    }
                    if equalsExact(span.name, span.nameLength, ":method") {
                        if sawMethod { malformed = true; return }
                        sawMethod = true
                        method = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":path") {
                        if sawPath { malformed = true; return }
                        sawPath = true
                        path = stash(span)
                    } else if equalsExact(span.name, span.nameLength, ":scheme") {
                        if sawScheme { malformed = true; return }
                        sawScheme = true
                    } else if equalsExact(span.name, span.nameLength, ":authority") {
                        if sawAuthority { malformed = true; return }
                        sawAuthority = true
                        authority = stash(span)
                    } else {
                        // Unknown, or :protocol, which is only for a peer we
                        // told it may (RFC 8441) and we do not.
                        malformed = true
                    }
                    return
                }
                sawRegular = true
                if !HTTP2.validFieldName(span.name, span.nameLength)
                    || !HTTP2.validFieldValue(span.value, span.valueLength) {
                    malformed = true
                    return
                }
                if HTTP2.isConnectionSpecific(span.name, span.nameLength) {
                    // "te: trailers" is the one connection-specific field
                    // HTTP/2 still allows.
                    if !(span.nameLength == 2 && equalsLowercased(span.value, span.valueLength, "trailers")) {
                        malformed = true
                        return
                    }
                }
                if equalsExact(span.name, span.nameLength, "host") {
                    // Written once below: the parser refuses a second Host.
                    if sawHost { malformed = true; return }
                    sawHost = true
                    host = stash(span)
                    return
                }
                if equalsExact(span.name, span.nameLength, "cookie") {
                    // RFC 9113 section 8.2.3: crumbs a client split are
                    // joined into one field for HTTP/1.1.
                    if cookies.readableBytes > 0 { cookies.write("; ") }
                    if span.valueLength > 0 { cookies.write(span.value, span.valueLength) }
                    return
                }
                fields.write(span.name, span.nameLength)
                fields.write(": ")
                if span.valueLength > 0 { fields.write(span.value, span.valueLength) }
                fields.writeCRLF()
            }
        } catch {
            return .compression
        }
        if malformed { return .malformed }
        // A plain CONNECT has no :scheme or :path, and an extended one needs
        // :protocol, which is not offered: neither is served.
        if !sawMethod || !sawScheme || !sawPath || method.1 == 0 || path.1 == 0 { return .malformed }
        let values = UnsafePointer(pseudo.pointer(at: 0))
        guard let hostAt = requestHost(values, sawAuthority ? authority : nil, sawHost ? host : nil) else {
            return .malformed
        }
        if equalsExact(values + method.0, method.1, "CONNECT") { return .malformed }

        s.head.reserve(method.1 + path.1 + hostAt.1 + fields.readableBytes + cookies.readableBytes + 40)
        s.head.write(values + method.0, method.1)
        s.head.writeByte(cSP)
        s.head.write(values + path.0, path.1)
        s.head.write(" HTTP/1.1\r\n")
        if hostAt.1 > 0 {
            s.head.write("host: ")
            s.head.write(values + hostAt.0, hostAt.1)
            s.head.writeCRLF()
        }
        if fields.readableBytes > 0 { s.head.write(fields.readPointer, fields.readableBytes) }
        if cookies.readableBytes > 0 {
            s.head.write("cookie: ")
            s.head.write(cookies.readPointer, cookies.readableBytes)
            s.head.writeCRLF()
        }
        s.head.writeCRLF()

        let x = s.x
        let base = UnsafePointer(s.head.readPointer)
        x.pointee.base = base
        guard case .complete = HTTPParser.parse(base, s.head.readableBytes, maxHeadSize: limits.maxHeadSize,
                                                maxHeaders: limits.maxHeaders, headers: x.pointee.headers,
                                                head: &x.pointee.head) else {
            return .malformed
        }
        x.pointee.head.httpMajor = 2
        x.pointee.head.httpMinor = 0
        // Chunked framing does not exist in HTTP/2, and a request that
        // claims it is malformed rather than merely odd.
        if x.pointee.head.flags.contains(.chunked) { return .malformed }
        return .ok
    }

    /// Copies a decoded value into `pseudo`: its offset and length there.
    func stash(_ span: HPACKSpan) -> (Int, Int) {
        let at = pseudo.readableBytes
        // Never empty, so `pseudo.pointer(at: 0)` is always good.
        pseudo.reserve(span.valueLength + 1)
        if span.valueLength > 0 { pseudo.write(span.value, span.valueLength) }
        return (at, span.valueLength)
    }

    /// Which of `:authority` and a Host field the rebuilt head's one Host
    /// line is: whichever is there. Nil, a malformed request, when both are
    /// there and differ (RFC 9113 section 8.3.1) -- an empty `:authority`
    /// included, which is not the same as a Host that names something.
    func requestHost(_ base: UnsafePointer<UInt8>, _ authority: (Int, Int)?, _ host: (Int, Int)?) -> (Int, Int)? {
        guard let authority else { return host ?? (0, 0) }
        guard let host else { return authority }
        guard host.1 == authority.1 else { return nil }
        for i in 0..<host.1 where asciiLower(base[host.0 + i]) != asciiLower(base[authority.0 + i]) {
            return nil
        }
        return authority
    }

    // MARK: Running a stream

    /// The request is whole: its handler runs in a pooled task.
    func run(_ s: H2Stream) {
        s.receiving = false
        s.started = true
        let x = s.x
        if s.body.readableBytes > 0 {
            x.pointee.body = UnsafePointer(s.body.readPointer)
            x.pointee.bodyCount = s.body.readableBytes
        }
        if streams.count == 1 && runsInline(s) {
            // Still counted as unstarted, so the writer does not take the
            // connection for idle while it runs.
            inlineStream = s
            return
        }
        lock.withLock { _ in
            s.holds &+= 1
            tasks &+= 1
            unstarted &-= 1
        }
        service.pool.spawn { [s] in await s.connection.answer(s) }
    }

    /// The stream's task: the handler, in a child task a reset can cancel,
    /// then the answer to the writer.
    func answer(_ s: H2Stream) async {
        // Unretained: the stream outlives its task, and the connection the
        // stream (H2Connection.end).
        let unretained = Unmanaged.passUnretained(s)
        async let handled: Void = H2Connection.handle(unretained)
        await handled
        let data = prepareAnswer(s)
        // Written from here when nobody else is writing and the windows
        // take it all; the writer's otherwise.
        let direct = lock.withLock { _ -> Bool in
            if s.reset {
                release(s)
            } else if takeRole(for: s, data: data) {
                return true
            } else {
                ready.append(s)
                wake.notifyOne()
            }
            tasks &-= 1
            // Signalled under the lock: once it is let go, the connection
            // may be gone.
            if tasks == 0 { idle.notifyOne() }
            return false
        }
        guard direct else { return }
        frameWhole(s)
        let sent = await sendFramed()
        lock.withLock { _ in
            if !s.reset { earned &+= 1 }
            s.closed = true
            release(s)
            releaseRole(failed: !sent)
            tasks &-= 1
            if tasks == 0 { idle.notifyOne() }
        }
    }

    static func handle(_ unretained: Unmanaged<H2Stream>) async {
        let s = unretained.takeUnretainedValue()
        await s.connection.handle(s)
    }

    func handle(_ s: H2Stream) async {
        withUnsafeCurrentTask { task in
            lock.withLock { _ in
                if s.reset { task?.cancel() } else { s.task = task }
            }
        }
        await dispatchStream(s)
        lock.withLock { _ in s.task = nil }
    }

    /// The stream's request through the application, noting whether its
    /// route's run suspended.
    @inline(__always)
    func dispatchStream(_ s: H2Stream) async {
        let x = s.x
        // Before anything can answer, so every answer carries them.
        if limits.requestID { x.pointee.assignRequestID(trusting: limits.requestIDTrust) }
        if limits.traceContext { x.pointee.readTraceParent() }
        if observing { x.pointee.started = monotonicNanos() }
        let stamp = Runtime.currentJobStamp
        await dispatch(x, app, matched: s.matched, observing: observing)
        // A cancelled run may have been cut short before it could wait: it
        // says nothing about the route.
        let route = x.pointee.route
        if route >= 0 && !Task.isCancelled { app.costs.noteRun(Int(route), startedIn: stamp) }
    }

    /// Whether `s`, the connection's only stream, is answered on the reader
    /// rather than in a task of its own: its route has never been seen to
    /// suspend, and is not heavy. It then holds the reader no longer than an
    /// HTTP/1 request holds its connection, and saves two hand-offs. Matches
    /// the route, for the dispatch to use.
    func runsInline(_ s: H2Stream) -> Bool {
        let x = s.x
        if s.matched < 0 {
            let path = x.pointee.head.path
            s.matched = app.table.match(x.pointee.head.method, x.pointee.base + Int(path.offset), path.count,
                                        into: &x.pointee.parameters)
            if s.matched < 0 {
                // The dispatch works a miss out again, from nothing.
                x.pointee.parameters = RouteParameters()
                return false
            }
        }
        let route = Int(s.matched)
        return app.costs.neverSuspends(route) && !app.costs.isHeavy(route)
    }

    /// The reader answers `s` itself: runs its handler, then writes the
    /// answer when nobody else is writing, or hands it to the writer. A
    /// reset cannot arrive meanwhile -- the reader is busy -- so there is no
    /// task to cancel; a reset read afterwards is for an answered stream.
    func answerInline(_ s: H2Stream) async {
        await dispatchStream(s)
        let data = prepareAnswer(s)
        let direct = lock.withLock { _ -> Bool in
            unstarted &-= 1
            // The writer's hold, beside the table's.
            s.holds &+= 1
            if takeRole(for: s, data: data) { return true }
            ready.append(s)
            wake.notifyOne()
            return false
        }
        guard direct else { return }
        frameWhole(s)
        let sent = await sendFramed()
        lock.withLock { _ in
            earned &+= 1
            s.closed = true
            release(s)
            releaseRole(failed: !sent)
        }
    }

    // MARK: Other frames

    func handlePriority(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.streamID == 0 { return connectionError(.protocolError) }
        if header.length != 5 {
            streamError(header.streamID, .frameSizeError)
            return true
        }
        // Prioritisation is deprecated by RFC 9113 and not implemented, but
        // a stream that depends on itself is still nonsense.
        if HTTP2.readUInt32(payload) & 0x7FFF_FFFF == header.streamID {
            streamError(header.streamID, .protocolError)
        }
        return true
    }

    func handleReset(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.streamID == 0 { return connectionError(.protocolError) }
        if header.length != 4 { return connectionError(.frameSizeError) }
        guard let s = find(header.streamID) else {
            if header.streamID > lastPeerStreamSeen { return connectionError(.protocolError) }
            return true
        }
        // The handler finds out the way it finds out about any hang-up: its
        // task is cancelled.
        var answered = false
        lock.withLock { _ in
            answered = s.closed
            cancel(s)
            resetBudget = min(settings.resetBudget, resetBudget + earned)
            earned = 0
        }
        remove(s)
        // A cancellation that arrives after the answer was sent costs
        // nothing and is charged nothing: it is a race, not a reset. Every
        // stream answered buys one back; a client that only ever cancels
        // spends the budget and is sent away (CVE-2023-44487).
        if !answered {
            resetBudget -= 1
            if resetBudget <= 0 {
                Log.warning("h2 peer cancelled far more streams than it completed")
                return connectionError(.enhanceYourCalm)
            }
        }
        return true
    }

    func handleSettings(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.streamID != 0 { return connectionError(.protocolError) }
        if header.flags.contains(.ack) {
            return header.length == 0 ? true : connectionError(.frameSizeError)
        }
        if header.length % 6 != 0 { return connectionError(.frameSizeError) }
        var i = 0
        var failure: H2Error?
        lock.withLock { _ in
            while i < header.length && failure == nil {
                let id = (UInt16(payload[i]) << 8) | UInt16(payload[i + 1])
                let value = HTTP2.readUInt32(payload + i + 2)
                i += 6
                guard let setting = H2Setting(rawValue: id) else { continue }
                switch setting {
                case .headerTableSize:
                    // Bounds what we may use when encoding; we never index.
                    break
                case .enablePush, .enableConnectProtocol:
                    if value > 1 { failure = .protocolError }
                case .maxConcurrentStreams, .maxHeaderListSize:
                    // The first limits pushes only; the second is advisory.
                    break
                case .initialWindowSize:
                    if value > UInt32(H2FrameHeader.maxWindowSize) {
                        failure = .flowControlError
                        break
                    }
                    // A changed initial window applies to every stream already
                    // open, and each value in a frame in turn (RFC 9113
                    // section 6.5): the last does not stand for the rest.
                    let delta = Int(value) - peerInitialWindowSize
                    peerInitialWindowSize = Int(value)
                    if delta != 0 {
                        for s in streams where !s.closed {
                            s.sendWindow += delta
                            if s.sendWindow > H2FrameHeader.maxWindowSize { failure = .flowControlError }
                        }
                    }
                case .maxFrameSize:
                    if value < UInt32(H2FrameHeader.defaultMaxFrameSize) || value > 0xFF_FFFF {
                        failure = .protocolError
                        break
                    }
                    peerMaxFrameSize = Int(value)
                }
            }
            if failure == nil {
                frame(&control, 0, .settings, .ack, 0)
                wake.notifyOne()
            }
        }
        if let failure { return connectionError(failure) }
        return true
    }

    func handlePing(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.streamID != 0 { return connectionError(.protocolError) }
        if header.length != 8 { return connectionError(.frameSizeError) }
        if header.flags.contains(.ack) { return true }
        frame(&outgoing, 8, .ping, .ack, 0)
        outgoing.write(payload, 8)
        return true
    }

    func handleGoaway(_ header: H2FrameHeader) -> Bool {
        if header.streamID != 0 { return connectionError(.protocolError) }
        if header.length < 8 { return connectionError(.frameSizeError) }
        // No new streams, but the connection is not ours to drop: the peer
        // may still be reading answers. It closes when the last stream ends,
        // when the peer hangs up, or on idle.
        lock.withLock { _ in
            peerGoneAway = true
            wake.notifyOne()
        }
        return true
    }

    func handleWindowUpdate(_ header: H2FrameHeader, _ payload: UnsafePointer<UInt8>) -> Bool {
        if header.length != 4 { return connectionError(.frameSizeError) }
        let increment = Int(HTTP2.readUInt32(payload) & 0x7FFF_FFFF)
        if header.streamID == 0 {
            if increment == 0 { return connectionError(.protocolError) }
            let overflow = lock.withLock { _ -> Bool in
                sendWindow += increment
                wake.notifyOne()
                return sendWindow > H2FrameHeader.maxWindowSize
            }
            return overflow ? connectionError(.flowControlError) : true
        }
        if increment == 0 {
            streamError(header.streamID, .protocolError)
            return true
        }
        guard let s = find(header.streamID) else {
            if header.streamID > lastPeerStreamSeen { return connectionError(.protocolError) }
            return true
        }
        let overflow = lock.withLock { _ -> Bool in
            if s.closed { return false }
            s.sendWindow += increment
            wake.notifyOne()
            return s.sendWindow > H2FrameHeader.maxWindowSize
        }
        if overflow { streamError(header.streamID, .flowControlError) }
        return true
    }

    // MARK: Errors

    /// GOAWAY with `code`, and the connection ends once it is sent. Always
    /// false, for the frame handlers to return.
    func connectionError(_ code: H2Error) -> Bool {
        Log.debug("h2 connection error, code \(code.rawValue)")
        post()
        lock.withLock { _ in
            if !goawaySent {
                goawaySent = true
                frame(&control, 8, .goaway, [], 0)
                HTTP2.writeUInt32(lastPeerStreamSeen, into: &control)
                HTTP2.writeUInt32(code.rawValue, into: &control)
            }
            stopping = true
            wake.notifyOne()
        }
        return false
    }

    /// Resets one stream, abandoning whatever it was doing.
    func streamError(_ id: UInt32, _ code: H2Error) {
        if let s = find(id) {
            lock.withLock { _ in cancel(s) }
            remove(s)
        }
        rst(id, code)
    }

    func rst(_ id: UInt32, _ code: H2Error) {
        frame(&outgoing, 4, .rstStream, [], id)
        HTTP2.writeUInt32(code.rawValue, into: &outgoing)
    }
}

/// Writes a frame header into `out`.
@inline(__always)
func frame(_ out: inout ByteBuffer, _ length: Int, _ type: H2FrameType, _ flags: H2Flags, _ stream: UInt32) {
    H2FrameHeader(length: length, type: type, flags: flags, streamID: stream).write(into: &out)
}

/// A valid pointer for an empty header block or value.
nonisolated(unsafe) let emptyBlock: UnsafePointer<UInt8> = {
    let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
    p[0] = 0
    return UnsafePointer(p)
}()
