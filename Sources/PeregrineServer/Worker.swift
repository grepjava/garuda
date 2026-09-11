//===----------------------------------------------------------------------===//
// The worker: one process, one poller, one interpreter.
//
// Structure of a request:
//
//   accept -> readingHead -> [readingBody] -> dispatching -> writing -> reuse
//
// The whole cycle touches the heap only for the Python objects the application
// itself needs. Buffers come from a pool, connection records come from a slab,
// parsing produces offsets rather than objects, and the response is serialised
// straight into the connection write buffer.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineASGI
import PeregrineHTTP
import PeregrinePython
import PeregrineWSGI

/// The worker this thread is running. Held behind a raw pointer rather than a
/// class so that C callbacks (the asyncio reader, ASGI send/receive) can reach
/// it without an ARC-managed context.
///
/// Thread-local, not global. With one worker per process the two are the same
/// thing; under `--free-threaded` a process has several workers, each owning
/// its own poller, connection table and event loop, and a callback arriving
/// from Python has to land on the one belonging to the thread it is running on.
/// The storage is a C `_Thread_local`, so reading it is a register-relative
/// load rather than a lock or a `pthread_getspecific` call.
public var currentWorker: UnsafeMutablePointer<Worker>? {
    @inline(__always) get {
        pg_worker_current()?.assumingMemoryBound(to: Worker.self)
    }
    @inline(__always) set {
        pg_worker_set_current(UnsafeMutableRawPointer(newValue))
    }
}

public struct Worker {
    public var config: ServerConfig
    public var poller: Poller
    public var table: ConnectionTable
    public var pool: BufferPool
    public var dates: DateCache

    public var listenFD: Int32
    public var signalFD: Int32 = -1

    /// One shared header table: parsing and environ/scope construction happen
    /// back to back for a single request, so there is never a second live set.
    public var headers: UnsafeMutablePointer<HTTPHeaderRef>

    /// TLS configuration, when the listener is https. One per worker.
    public var tlsContext: TLSContext? = nil
    /// The QUIC socket, when HTTP/3 is enabled. One per worker, bound with
    /// SO_REUSEPORT so each has its own receive queue.
    public var quic: QUICListener? = nil
    /// Throttle for QUIC timers, which are far finer than the once-a-second
    /// connection sweep.
    var lastQUICTick: UInt64 = 0
    public var wsgi: WSGIRuntime? = nil
    /// The optional WSGI thread pool. nil means the worker loop calls the
    /// application inline, which is the original single-threaded model.
    public var wsgiPool: WSGIPool? = nil
    public var appProtocol: AppProtocol = .wsgi

    // --- ASGI, one set per worker ---
    //
    // These were static, which was correct while a worker was a process. Under
    // --free-threaded several workers share an interpreter, and each still
    // needs its own event loop and its own scope builder -- the builder carries
    // a mutable header-name cache and a scratch buffer, so sharing one across
    // threads would be a data race. The application object and the glue
    // functions stay process-wide on ASGIRuntime, because they are written once
    // at start-up and only read afterwards.

    /// This worker's asyncio event loop.
    public var asgiLoop: PyObj? = nil
    /// The lifespan driver, on the one worker that owns it. The ASGI lifespan
    /// is per application, not per worker, so exactly one worker in the process
    /// runs it; on every other worker this is nil.
    public var asgiLifespan: PyObj? = nil
    /// Prototype scope, interned keys and the memoised header-name cache.
    public var asgiScope: ASGIScopeBuilder? = nil
    /// `loop.add_reader` callback for the poller descriptor.
    public var asgiDrainCallback: PyObj? = nil
    /// The periodic housekeeping callback.
    public var asgiTimerCallback: PyObj? = nil

    public var running = true
    /// Set on SIGTERM: stop accepting, finish what is in flight, then exit.
    public var draining = false
    /// Whether this worker arms the `SIGALRM` watchdog when it starts draining.
    ///
    /// A worker process is the last word on its own lifetime, so it does. A
    /// free-threaded worker thread is not: the process still has to join every
    /// thread and run the lifespan shutdown after this worker has finished, and
    /// a watchdog armed here would be the shorter of the two and would `_exit`
    /// in the middle of that. The supervising thread arms one for the whole
    /// process instead.
    public var ownsExitWatchdog = true
    /// When draining must stop being polite. A request that never completes
    /// would otherwise hold the whole process open indefinitely.
    public var drainDeadline: UInt64 = 0
    public var lastSweep: UInt64 = 0
    public var acceptSuspended = false

    public init(config: ServerConfig, listenFD: Int32, poller: Poller) {
        self.config = config
        self.listenFD = listenFD
        self.poller = poller
        self.table = ConnectionTable(capacity: config.maxConnections)
        self.pool = BufferPool(blockSize: config.readBufferSize,
                               maxRetained: min(config.maxConnections, 1024))
        self.dates = DateCache()
        self.headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: config.maxHeaders)
    }

    public mutating func destroy() {
        quic?.destroy()
        headers.deallocate()
        pool.destroy()
        dates.destroy()
        table.destroy()
        poller.destroy()
        wsgi?.destroy()
    }

    // MARK: - Registration

    public mutating func registerListener() -> Bool {
        guard poller.add(listenFD, .read, token: PollToken.listener) else {
            Log.error("failed to register the listening socket")
            return false
        }
        if signalFD >= 0 {
            _ = poller.add(signalFD, .read, token: PollToken.signals)
        }
        return true
    }

    /// Registers the pool's completion pipe, so a thread finishing a request
    /// wakes the loop the same way a socket does.
    public mutating func registerPool() -> Bool {
        guard let wsgiPool else { return true }
        guard poller.add(wsgiPool.wakeupFD, .read, token: PollToken.pool) else {
            Log.error("failed to register the WSGI pool wakeup pipe")
            return false
        }
        return true
    }

    @inline(__always)
    mutating func setInterest(_ slot: Int, _ mask: PollMask) {
        let c = table[slot]
        // An HTTP/2 stream has no descriptor of its own; interest belongs to
        // the connection carrying it.
        if c.pointee.fd < 0 { return }
        if c.pointee.interest == mask.rawValue { return }
        let token = PollToken.make(slot: slot, generation: c.pointee.generation)
        _ = poller.modify(c.pointee.fd, mask, token: token)
        c.pointee.interest = mask.rawValue
    }

    // MARK: - Event dispatch

    /// Processes one batch of readiness events. Returns the number handled.
    ///
    /// Called directly by the WSGI loop, and by asyncio through the reader
    /// callback in ASGI mode.
    @discardableResult
    public mutating func drain(timeoutMillis: Int32) -> Int {
        let n = poller.wait(timeoutMillis: timeoutMillis)
        if n <= 0 { return 0 }
        processEvents(n)
        return n
    }

    /// Dispatches `n` events already collected by the poller.
    public mutating func processEvents(_ n: Int) {
        var i = 0
        while i < n {
            let (token, mask) = poller.event(i)
            i += 1
            switch token {
            case PollToken.listener:
                acceptConnections()
            case PollToken.signals:
                handleSignals()
            case PollToken.pool:
                collectPoolResults()
            case PollToken.quic:
                handleQUICEvent(mask)
            default:
                let slot = PollToken.slot(token)
                let generation = PollToken.generation(token)
                let c = table[slot]
                // A stale event for a slot that has already been recycled.
                if c.pointee.state == .free || c.pointee.generation != generation { continue }
                handleConnectionEvent(slot, mask)
            }
        }
    }

    mutating func handleConnectionEvent(_ slot: Int, _ mask: PollMask) {
        let c = table[slot]
        c.pointee.lastActivity = pg_monotonic_ms()

        if mask.contains(.error) {
            closeConnection(slot)
            return
        }
        if c.pointee.flags.contains(.tlsHandshake) {
            if !driveHandshake(slot) { return }
            // A client that sent its first request in the same flight as the
            // last handshake record has it waiting inside OpenSSL already.
            handleReadable(slot)
            drainBufferedTLS(slot)
            return
        }
        if mask.wantsWrite {
            if !flush(slot) { return }
            // The socket accepting more is exactly the signal a pooled request
            // blocked on backpressure is waiting for.
            if c.pointee.poolJob != nil {
                pumpPoolJob(slot)
                return
            }
            // Room on the socket is what a stream blocked behind a slow client
            // is waiting for.
            if c.pointee.state == .http2, let h2 = c.pointee.h2 {
                pumpAllStreams(slot, h2)
                if table[slot].pointee.state == .free { return }
            }
        }
        if mask.wantsRead {
            handleReadable(slot)
            drainBufferedTLS(slot)
            return
        }
        if mask.contains(.hangup) {
            // Half-close with nothing pending: the peer is done talking.
            if c.pointee.state == .readingHead && c.pointee.read.isEmpty {
                closeConnection(slot)
            } else {
                c.pointee.flags.insert(.peerClosed)
                // A running ASGI application may be parked on receive() waiting
                // for exactly this, so wake it rather than leaving it hanging
                // until the idle timeout.
                if c.pointee.state == .dispatching || c.pointee.state == .websocket {
                    c.pointee.flags.insert(.disconnected)
                    deliverPendingReceive(slot)
                }
            }
        }
    }

    // MARK: - Accept

    mutating func acceptConnections() {
        if draining { return }
        // Bounded per wakeup so one busy listener cannot starve established
        // connections of service.
        var budget = 64
        while budget > 0 {
            budget -= 1
            var peer = (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                        Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                        Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                        Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                        Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                        Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
            var port: UInt16 = 0
            let fd: Int32 = withUnsafeMutableBytes(of: &peer) { raw in
                pg_accept(listenFD, raw.baseAddress!.assumingMemoryBound(to: CChar.self),
                          48, &port)
            }
            if fd < 0 {
                let e = pg_errno()
                if pg_err_is_again(e) != 0 || pg_err_is_intr(e) != 0 { return }
                if e == EMFILE || e == ENFILE {
                    // Descriptor exhaustion: stop asking for a moment rather
                    // than spinning on a listener that stays readable.
                    Log.warn("out of file descriptors; pausing accepts")
                    _ = poller.modify(listenFD, [], token: PollToken.listener)
                    acceptSuspended = true
                    return
                }
                return
            }

            let slot = table.allocate()
            if slot < 0 {
                rejectOverCapacity(fd)
                continue
            }
            let c = table[slot]
            c.pointee.fd = fd
            c.pointee.state = .readingHead
            c.pointee.flags = []
            c.pointee.interest = 0
            c.pointee.read = pool.take()
            c.pointee.write = ByteBuffer()
            c.pointee.body = ByteBuffer()
            c.pointee.head = HTTPRequestHead()
            c.pointee.chunked = ChunkedDecoder()
            c.pointee.bodyRemaining = 0
            c.pointee.requestCount = 0
            c.pointee.lastActivity = pg_monotonic_ms()
            c.pointee.remoteAddrObj = nil
            c.pointee.remotePortObj = nil
            c.pointee.clientTuple = nil
            c.pointee.task = nil
            c.pointee.pendingReceive = nil
            c.pointee.sendCallable = nil
            c.pointee.receiveCallable = nil
            c.pointee.drainWaiter = nil
            c.pointee.poolJob = nil
            c.pointee.responseRemaining = -1
            c.pointee.tls = nil

            if config.tcpNoDelay { _ = pg_set_nodelay(fd, 1) }

            // Client address objects are built once per connection, not once
            // per request: a keep-alive client pays for them a single time.
            withUnsafeBytes(of: &peer) { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                var n = 0
                while n < 48 && p[n] != 0 { n += 1 }
                c.pointee.remoteAddrObj = pg_str_latin1(p, pg_ssize_t(n))
            }
            c.pointee.remotePortObj = pg_int(Int(port))

            let token = PollToken.make(slot: slot, generation: c.pointee.generation)
            if !poller.add(fd, .read, token: token) {
                Log.error("failed to register an accepted connection")
                closeConnection(slot)
                continue
            }
            c.pointee.interest = PollMask.read.rawValue
            if tlsContext != nil && !beginTLS(slot) { continue }
        }
    }

    /// Keeps reading while TLS holds decrypted bytes the poller cannot see.
    ///
    /// A record is decrypted whole, so one socket read can leave OpenSSL
    /// holding more than the buffer took. The socket is then empty, a
    /// level-triggered poller says nothing, and a request would sit there
    /// until the idle timeout.
    mutating func drainBufferedTLS(_ slot: Int) {
        var rounds = 0
        while rounds < 64 {
            let c = table[slot]
            if c.pointee.state == .free || c.pointee.tls == nil { return }
            if !connHasBufferedInput(slot) { return }
            rounds += 1
            handleReadable(slot)
        }
    }

    /// Table is full: answer honestly and hang up instead of queueing.
    func rejectOverCapacity(_ fd: Int32) {
        let msg: StaticString = """
        HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 19\r\n\r\nService Unavailable
        """
        _ = pg_write(fd, msg.utf8Start, msg.utf8CodeUnitCount)
        _ = pg_close(fd)
    }

    // MARK: - Reading

    /// Which buffer incoming bytes land in.
    ///
    /// This is the crux of head lifetime. A Content-Length body goes straight
    /// into `body`, leaving the parsed head untouched in `read` for as long as
    /// the application needs its slices. Chunked framing has to be decoded, so
    /// there -- and only there -- the head is copied aside first and `read`
    /// becomes scratch space.
    enum FillTarget { case read, body }

    mutating func handleReadable(_ slot: Int) {
        let c = table[slot]
        switch c.pointee.state {
        case .free:
            return
        case .http3:
            // An HTTP/3 connection has no descriptor of its own, so readiness
            // never reaches it this way.
            return
        case .writing, .closing:
            // Pipelined bytes arriving while the previous response drains: they
            // wait in the socket buffer until we are ready to look at them.
            setInterest(slot, .write)
            return
        case .readingHead:
            if !fill(slot, .read, limit: config.maxHeadSize) { return }
            processInput(slot)
        case .readingBody:
            let target: FillTarget = c.pointee.bodyRemaining < 0 ? .read : .body
            if !fill(slot, target, limit: config.maxBodySize) { return }
            processInput(slot)
        case .websocket:
            handleWebSocketReadable(slot)
            return
        case .http2:
            // A few frames per turn: enough to keep the pipeline full without
            // letting one connection monopolise the loop.
            if !fill(slot, .read, limit: config.h2MaxFrameSize * 4) { return }
            pumpHTTP2(slot)
            return
        case .dispatching:
            // A pooled WSGI request has its whole body already; anything
            // arriving now is the next pipelined request, and it waits in the
            // socket buffer until this one is answered.
            if c.pointee.poolJob != nil { return }
            // ASGI keeps streaming the body while the application runs, but no
            // further ahead than the high water mark: bytes an application has
            // not asked for yet are better left in the socket than in memory.
            let target: FillTarget = c.pointee.bodyRemaining < 0 ? .read : .body
            let ceiling = min(config.maxBodySize, config.bodyHighWaterMark)
            if !fill(slot, target, limit: ceiling) { return }
            onBodyProgress(slot)
            if table[slot].pointee.state != .free { updateBodyReadInterest(slot) }
        }

        let s = table[slot]
        if s.pointee.state != .free,
           s.pointee.flags.contains(.peerClosed),
           s.pointee.state == .readingHead || s.pointee.state == .readingBody,
           s.pointee.write.isEmpty {
            closeConnection(slot)
        }
    }

    /// Drains the socket into the chosen buffer. Returns false if the
    /// connection was closed.
    mutating func fill(_ slot: Int, _ target: FillTarget, limit: Int) -> Bool {
        let c = table[slot]
        var closed = false
        while true {
            var n = 0
            if target == .read {
                if c.pointee.read.readableBytes >= limit { break }
                c.pointee.read.reserve(config.readBufferSize)
                let room = c.pointee.read.writableBytes
                n = connRead(slot, c.pointee.read.writePointer, room)
                if n > 0 {
                    c.pointee.read.advanceWriter(n)
                    // A short read means the socket buffer is empty and asking
                    // again would only earn an EAGAIN -- unless TLS is holding
                    // a decrypted record the socket no longer has.
                    if n < room && !connHasBufferedInput(slot) { break }
                    continue
                }
            } else {
                if c.pointee.bodyRemaining <= 0 { break }
                if c.pointee.body.readableBytes >= limit { break }
                // Never ask for more than the declared body: the bytes after it
                // belong to the next pipelined request.
                let want = min(c.pointee.bodyRemaining, config.readBufferSize)
                c.pointee.body.reserve(want)
                n = connRead(slot, c.pointee.body.writePointer, want)
                if n > 0 {
                    c.pointee.body.advanceWriter(n)
                    c.pointee.bodyRemaining -= n
                    if n < want && !connHasBufferedInput(slot) { break }
                    continue
                }
            }
            if n == 0 { closed = true; break }
            let e = pg_errno()
            if pg_err_is_again(e) != 0 { break }
            if pg_err_is_intr(e) != 0 { continue }
            closeConnection(slot)
            return false
        }
        if closed { c.pointee.flags.insert(.peerClosed) }
        return true
    }

    /// Parses and dispatches as many pipelined requests as the buffer holds.
    mutating func processInput(_ slot: Int) {
        while true {
            let c = table[slot]
            switch c.pointee.state {
            case .readingHead:
                if c.pointee.read.readableBytes == 0 { return }
                // The HTTP/2 preface is a valid HTTP/1.1 request line right up
                // until it is not, so it can only be recognised in full, and
                // only at the very start of a connection.
                if (config.http2Only || c.pointee.flags.contains(.alpnH2))
                    && c.pointee.requestCount == 0 {
                    // Nothing here is HTTP/1, so an incomplete preface is a
                    // truncated preface and a wrong one is a protocol error.
                    if c.pointee.read.readableBytes < HTTP2.preface.count {
                        if looksLikeHTTP2(slot) { return }
                        rejectBadPreface(slot)
                        return
                    }
                    if looksLikeHTTP2(slot) { beginHTTP2(slot) } else { rejectBadPreface(slot) }
                    return
                }
                if config.http2Enabled && c.pointee.requestCount == 0
                    && looksLikeHTTP2(slot) {
                    if c.pointee.read.readableBytes < HTTP2.preface.count { return }
                    beginHTTP2(slot)
                    return
                }
                // A connection that opened with "PRI " and then diverged was
                // an HTTP/2 client, not an HTTP/1 request: answering in HTTP/1
                // would be talking past it.
                if config.http2Enabled && c.pointee.requestCount == 0
                    && ((c.pointee.read.readableBytes >= 4
                         && equalsExact(UnsafePointer(c.pointee.read.readPointer), 4, "PRI "))
                        || looksLikeBareFrames(slot)) {
                    rejectBadPreface(slot)
                    return
                }
                let origin = c.pointee.read.readerOffset
                let base = UnsafePointer(c.pointee.read.readPointer)
                var head = HTTPRequestHead()
                let result = HTTPParser.parse(base, c.pointee.read.readableBytes,
                                              maxHeadSize: config.maxHeadSize,
                                              maxHeaders: config.maxHeaders,
                                              headers: headers,
                                              head: &head)
                switch result {
                case .incomplete:
                    if c.pointee.read.readableBytes >= config.maxHeadSize {
                        failRequest(slot, status: 431)
                    }
                    return
                case .failure(let err):
                    failRequest(slot, status: err.status)
                    return
                case .complete:
                    c.pointee.head = head
                    if !beginRequest(slot, origin: origin) { return }
                }

            case .readingBody:
                // ASGI applications are given the request as soon as the head
                // is parsed: the body arrives through receive(), which is what
                // lets one reject an upload at byte one instead of after the
                // last. WSGI has a blocking input stream and nowhere to wait,
                // so it still gets the whole body first.
                if appProtocol == .asgi {
                    // Decode whatever chunk framing is already buffered, but do
                    // not wait for the terminating chunk.
                    if c.pointee.bodyRemaining < 0 { _ = advanceChunkedBody(slot) }
                    let d = table[slot]
                    switch d.pointee.state {
                    case .readingBody, .dispatching:
                        d.pointee.state = .dispatching
                    default:
                        return          // failed, closed, or already answered
                    }
                } else if c.pointee.bodyRemaining < 0 {
                    if !advanceChunkedBody(slot) { return }
                } else if c.pointee.bodyRemaining > 0 {
                    return                       // waiting on the socket
                } else {
                    c.pointee.state = .dispatching
                }

            case .dispatching:
                dispatch(slot)
                // A synchronous (WSGI) dispatch has already moved on to
                // .writing by now. An ASGI dispatch has handed the request to a
                // task and the state is still .dispatching: the connection now
                // belongs to that task, and looping here would dispatch it
                // again on every turn.
                if table[slot].pointee.state == .dispatching { return }

            default:
                return
            }

            let d = table[slot]
            if d.pointee.state == .free { return }
            if d.pointee.state == .readingHead && d.pointee.read.readableBytes > 0 { continue }
            if d.pointee.state == .readingBody || d.pointee.state == .dispatching { continue }
            return
        }
    }

    /// Sets up body framing once the head is parsed. Returns false when the
    /// connection has been failed or closed.
    mutating func beginRequest(_ slot: Int, origin: Int) -> Bool {
        let c = table[slot]
        c.pointee.headOrigin = origin
        c.pointee.headInStore = false
        c.pointee.requestCount &+= 1
        c.pointee.flags.remove(.perRequest)
        c.pointee.body.clear()
        c.pointee.chunked = ChunkedDecoder()
        // Response framing belongs to one request; a stale budget here would
        // let the next response on a reused connection overrun or fall short.
        c.pointee.responseRemaining = -1

        var keepAlive = c.pointee.head.isKeepAlive
        if config.maxRequestsPerConnection > 0,
           c.pointee.requestCount >= config.maxRequestsPerConnection {
            keepAlive = false
        }
        if draining { keepAlive = false }
        if keepAlive {
            c.pointee.flags.insert(.keepAlive)
        } else {
            c.pointee.flags.remove(.keepAlive)
        }
        if c.pointee.head.method == .head { c.pointee.flags.insert(.suppressBody) }

        if c.pointee.head.contentLength > config.maxBodySize {
            failRequest(slot, status: 413)
            return false
        }

        let headEnd = c.pointee.head.headEnd

        if c.pointee.head.isChunked {
            // `read` is about to become scratch space for chunk framing, so the
            // head has to move somewhere stable first.
            c.pointee.headStore.clear()
            c.pointee.headStore.write(UnsafePointer(c.pointee.read.pointer(at: origin)), headEnd)
            c.pointee.headInStore = true
        }

        c.pointee.read.consume(headEnd)

        // 100-continue: commit to reading the body only once we intend to.
        if c.pointee.head.flags.contains(.expectContinue) {
            c.pointee.write.write("HTTP/1.1 100 Continue\r\n\r\n")
            if !flush(slot) { return false }
        }

        if c.pointee.head.isChunked {
            c.pointee.bodyRemaining = -1
            c.pointee.state = .readingBody
        } else if c.pointee.head.contentLength > 0 {
            let total = c.pointee.head.contentLength
            // Anything of the body already buffered moves out of `read` now, so
            // that no later socket read can land on top of the head.
            let have = min(c.pointee.read.readableBytes, total)
            if have > 0 {
                c.pointee.body.reserve(min(total, 1 << 20))
                c.pointee.body.write(UnsafePointer(c.pointee.read.readPointer), have)
                c.pointee.read.consume(have)
            }
            c.pointee.bodyRemaining = total - have
            c.pointee.state = c.pointee.bodyRemaining == 0 ? .dispatching : .readingBody
        } else {
            c.pointee.bodyRemaining = 0
            c.pointee.state = .dispatching
        }
        return true
    }

    /// Decodes buffered chunked framing into the body buffer.
    /// Returns true once the terminating chunk has been seen.
    mutating func advanceChunkedBody(_ slot: Int) -> Bool {
        let c = table[slot]
        let available = c.pointee.read.readableBytes
        if available == 0 {
            if c.pointee.flags.contains(.peerClosed) { closeConnection(slot) }
            return false
        }
        var consumed = 0
        let base = UnsafePointer(c.pointee.read.readPointer)
        let limit = config.maxBodySize
        var overflow = false
        let outcome = c.pointee.chunked.decode(base, available, consumed: &consumed) { p, n in
            if c.pointee.body.readableBytes + n > limit { overflow = true; return }
            c.pointee.body.write(p, n)
        }
        c.pointee.read.consume(consumed)
        if overflow {
            failRequest(slot, status: 413)
            return false
        }
        switch outcome {
        case .failure:
            failRequest(slot, status: 400)
            return false
        case .needMore:
            if c.pointee.flags.contains(.peerClosed) { closeConnection(slot) }
            return false
        case .finished:
            c.pointee.bodyRemaining = 0
            c.pointee.state = .dispatching
            return true
        }
    }

    mutating func dispatch(_ slot: Int) {
        if config.accessLog { table[slot].pointee.requestStartUs = pg_monotonic_us() }
        switch appProtocol {
        case .wsgi:
            // WSGI has no way to express a stream that outlives its response,
            // so an extended CONNECT has nothing to be handed to.
            if table[slot].pointee.h3Protocol.readableBytes > 0 {
                failRequest(slot, status: 501)
                return
            }
            dispatchWSGI(slot)
        case .asgi:
            dispatchASGI(slot)
        }
    }

    // MARK: - Writing

    /// Pushes buffered bytes to the socket. Returns false if the connection
    /// was closed.
    @discardableResult
    mutating func flush(_ slot: Int) -> Bool {
        let c = table[slot]
        // A multiplexed stream writes into its connection, not into a socket.
        if c.pointee.isH3Stream { return flushH3Stream(slot) }
        if c.pointee.isStream { return flushStream(slot) }
        while c.pointee.write.readableBytes > 0 {
            let n = connWrite(slot,
                              c.pointee.write.readPointer,
                              c.pointee.write.readableBytes)
            if n > 0 {
                c.pointee.write.consume(n)
                continue
            }
            let e = pg_errno()
            if pg_err_is_intr(e) != 0 { continue }
            if pg_err_is_again(e) != 0 {
                // Read interest is only safe while something will actually
                // consume what arrives: not while a pooled request owns the
                // connection, and not while a websocket queue is full. A
                // level-triggered poller would otherwise spin on those bytes.
                setInterest(slot, readInterestAllowed(slot) ? [.read, .write] : [.write])
                // Partially drained still counts: a producer parked at the high
                // water mark resumes as soon as the buffer falls below the low
                // one, without waiting for the socket to empty completely.
                resumeWriterIfDrained(slot)
                return true
            }
            // EPIPE / ECONNRESET: the client is gone.
            closeConnection(slot)
            return false
        }

        resumeWriterIfDrained(slot)

        // Drained.
        if c.pointee.write.allocatedCapacity > config.readBufferSize * 4 {
            // Do not let one large response pin an oversized buffer on an
            // otherwise idle keep-alive connection.
            c.pointee.write.destroy()
        } else {
            c.pointee.write.clear()
        }

        if c.pointee.state == .writing {
            // An ASGI response can be fully flushed while the application task
            // is still finishing. Recycling the slot now would let a pipelined
            // request overwrite state the task still refers to.
            if appProtocol == .asgi && c.pointee.task != nil {
                setInterest(slot, [])
                return true
            }
            finishResponse(slot)
        } else if c.pointee.state != .free {
            setInterest(slot, readInterestAllowed(slot) ? .read : [])
        }
        return table[slot].pointee.state != .free
    }

    /// Whether more bytes from this peer would have anywhere to go.
    ///
    /// They would not while a pooled request owns the connection (nothing will
    /// look at them until it finishes) or while a websocket has queued as many
    /// messages as it is allowed to. In both cases leaving read interest armed
    /// on a level-triggered poller would spin.
    @inline(__always)
    func readInterestAllowed(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.poolJob != nil { return false }
        if c.pointee.state == .websocket { return !websocketQueueFull(slot) }
        if c.pointee.state == .dispatching {
            // Nothing left to read for this request, and a level-triggered
            // poller would spin on the pipelined bytes behind it.
            if c.pointee.bodyRemaining == 0 { return false }
            return c.pointee.body.readableBytes < config.bodyHighWaterMark
        }
        return true
    }

    /// Re-evaluates read interest for a request whose body is still arriving.
    mutating func updateBodyReadInterest(_ slot: Int) {
        let c = table[slot]
        // HTTP/2 applies its backpressure with WINDOW_UPDATE instead: the
        // connection must keep reading, or control frames stop being answered.
        if c.pointee.isStream { return }
        guard appProtocol == .asgi, c.pointee.state == .dispatching,
              c.pointee.poolJob == nil else { return }
        var mask: PollMask = readInterestAllowed(slot) ? .read : []
        // A producer parked on backpressure is waiting for the socket, and the
        // write side of this connection is not ours to switch off here.
        if !c.pointee.write.isEmpty || c.pointee.drainWaiter != nil {
            mask.insert(.write)
        }
        setInterest(slot, mask)
    }

    /// Blocks the worker until the socket accepts more data. Used only when a
    /// synchronous WSGI response outgrows the high-water mark, where the choice
    /// is between stalling this worker and buffering without bound.
    /// Writes until the buffer is down to `target` bytes, waiting on the socket
    /// when it will not take any more.
    ///
    /// `target` is the high water mark for a producer that only has to be kept
    /// from running away with memory. It is 0 for one that has to be able to
    /// say the block has been sent -- a WSGI `write()`, or an iterator between
    /// yields -- because on the inline path the application runs on the loop
    /// thread, so anything left here has nothing to send it until the
    /// application returns. Stopping at the high water mark strands up to that
    /// much of the block for as long as the application cares to sleep.
    mutating func flushWithBackpressure(_ slot: Int, until target: Int? = nil) -> Bool {
        let c = table[slot]
        // A stream has no socket to wait on. Blocking the worker on the
        // connection underneath would be worse than useless for HTTP/3: the
        // acknowledgements that would let it drain arrive on the same loop
        // that is blocked. So the bytes go to the transport, which holds them
        // under the peer's flow control, and the producer keeps going.
        if c.pointee.isStream { return flush(slot) }
        let limit = target ?? config.writeHighWaterMark
        while c.pointee.write.readableBytes > limit {
            let n = connWrite(slot,
                              c.pointee.write.readPointer,
                              c.pointee.write.readableBytes)
            if n > 0 { c.pointee.write.consume(n); continue }
            let e = pg_errno()
            if pg_err_is_intr(e) != 0 { continue }
            if pg_err_is_again(e) != 0 {
                let r = pg_poll_single(c.pointee.fd, 1, 30_000)
                if r <= 0 { closeConnection(slot); return false }
                continue
            }
            closeConnection(slot)
            return false
        }
        return true
    }

    /// A last, non-blocking attempt to swallow the rest of a request body the
    /// application never read. Returns true when nothing of the request is
    /// left on the wire and the connection can be used again.
    mutating func discardRequestRemainder(_ slot: Int) -> Bool {
        let c = table[slot]
        if c.pointee.bodyRemaining == 0 { return true }
        // Chunked framing has to be decoded to find its end, and the decoder
        // belongs to a request that is over; those connections just close.
        if c.pointee.bodyRemaining < 0 { return false }
        // Waiting for an upload that has not been sent yet would mean holding
        // the connection open for a body nobody wants. Only what is already
        // here is worth taking.
        if c.pointee.bodyRemaining > config.bodyHighWaterMark { return false }
        c.pointee.body.clear()
        if !fill(slot, .body, limit: config.bodyHighWaterMark) { return false }
        c.pointee.body.clear()
        return c.pointee.bodyRemaining == 0
    }

    /// Called once a full response has been written out.
    mutating func finishResponse(_ slot: Int) {
        let c = table[slot]
        if c.pointee.isH3Stream {
            finishH3Response(slot)
            return
        }
        if c.pointee.isStream {
            // A response shorter than its Content-Length must not be ended
            // cleanly; the client would take the truncation for the whole
            // message.
            if c.pointee.flags.contains(.responseComplete)
                && !c.pointee.flags.contains(.suppressBody)
                && c.pointee.responseRemaining > 0 {
                // The flush has already turned a short response into a reset
                // unless it never got that far, so this is usually only the
                // tidy-up that follows one.
                closeStream(slot, resetWith:
                    c.pointee.flags.contains(.endStreamSent) ? nil : .internalError)
                return
            }
            if c.pointee.bodyRemaining == 0 {
                closeStream(slot, resetWith: nil)
                return
            }
            // Answering before the upload finished is ordinary in HTTP/2. If
            // what is left is small the stream stays open until it arrives --
            // the bytes are dropped, but they are still counted and still
            // checked against what the client promised. A large upload is not
            // worth the wait and the client is told to stop.
            let declared = c.pointee.head.flags.contains(.hasContentLength)
                ? c.pointee.head.contentLength - c.pointee.bodyReceived
                : 0
            if declared <= config.bodyHighWaterMark {
                c.pointee.state = .closing
                c.pointee.body.clear()
                releaseDrainWaiter(slot)
                releasePendingReceive(slot)
                return
            }
            closeStream(slot, resetWith: .noError)
            return
        }
        // An application that answers early -- a 401, a validation failure at
        // byte one -- is exactly what dispatching before the body arrives is
        // for. But the rest of that body is still coming and it is not a
        // request, so it is swallowed if it is small and already here, and
        // otherwise this response is the last one on the connection.
        if c.pointee.bodyRemaining != 0, c.pointee.flags.contains(.keepAlive) {
            if !discardRequestRemainder(slot) {
                if table[slot].pointee.state == .free { return }
                c.pointee.flags.remove(.keepAlive)
            }
        }
        c.pointee.body.clear()
        if !c.pointee.flags.contains(.keepAlive) || c.pointee.flags.contains(.peerClosed) {
            closeConnection(slot)
            return
        }
        c.pointee.state = .readingHead
        c.pointee.head = HTTPRequestHead()
        c.pointee.bodyRemaining = 0
        c.pointee.lastActivity = pg_monotonic_ms()
        setInterest(slot, .read)
        // A pipelined request may already be sitting in the read buffer.
        if c.pointee.read.readableBytes > 0 {
            processInput(slot)
        }
    }

    /// Emits a canned error response and closes.
    mutating func failRequest(_ slot: Int, status: Int) {
        let c = table[slot]
        if c.pointee.isH3Stream {
            h3FailRequest(slot, status: status)
            return
        }
        if c.pointee.isStream {
            h2FailRequest(slot, status: status)
            return
        }
        // With an application task still running, its next send() would append
        // to whatever we wrote here and produce two responses on one
        // connection. Closing is the only honest option.
        if appProtocol == .asgi && c.pointee.task != nil {
            Log.warn("closing connection after a request error with a live task")
            closeConnection(slot)
            return
        }
        c.pointee.flags.remove(.keepAlive)
        dates.refresh()
        c.pointee.write.clear()
        HTTPResponseWriter.writeError(&c.pointee.write, status: status,
                                      closeConnection: true, dateCache: dates)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    /// One line per request, when --access-log is set.
    ///
    /// The head slices are still valid here: a Content-Length body is read into
    /// its own buffer, and a chunked request keeps its head in `headStore`, so
    /// nothing has overwritten the request line.
    mutating func logAccess(_ slot: Int, status: Int) {
        guard config.accessLog, Log.enabled(.info) else { return }
        let c = table[slot]
        let base = c.pointee.headBase()
        let method = c.pointee.head.methodSlice
        let target = c.pointee.head.target
        // Measured to here, where the response head is settled and queued --
        // not to the last byte of the body, which for a streaming response is
        // the client's pace rather than the application's.
        let micros = c.pointee.requestStartUs == 0
            ? 0 : Int(pg_monotonic_us() &- c.pointee.requestStartUs)

        if !config.accessLogJSON {
            Log.emit(.info) { line in
                line.span(method.span(in: base))
                line.str(" ")
                line.span(target.span(in: base))
                line.str(" ")
                line.int(status)
                line.str(" ")
                line.int(micros)
                line.str("us")
            }
            return
        }

        // A target is the peer's bytes and need not be valid UTF-8, while a
        // JSON string must be. Checking costs one pass over a few dozen bytes,
        // and only when a JSON log was asked for.
        let targetSpan = target.span(in: base)
        var validator = UTF8Validator()
        let wellFormed = validator.feed(targetSpan.base, targetSpan.count) && validator.isComplete
        let proto = protocolName(slot)

        // Bare: the whole line is the object, prefix included as fields, so a
        // collector can read it without being told where the JSON starts.
        Log.emitBare(.info) { line in
            line.str("{\"level\":\"info\",\"pid\":")
            line.int(Log.pid)
            line.str(",\"method\":")
            let m = method.span(in: base)
            line.jsonString(m.base, m.count)
            line.str(",\"target\":")
            line.jsonString(targetSpan.base, targetSpan.count, asciiOnly: !wellFormed)
            line.str(",\"status\":")
            line.int(status)
            line.str(",\"duration_us\":")
            line.int(micros)
            line.str(",\"proto\":\"")
            line.str(proto)
            line.str("\"}")
        }
    }

    /// What the client is actually speaking, which the request head alone does
    /// not say: an HTTP/2 or HTTP/3 request was rebuilt as HTTP/1.1 text to be
    /// parsed, so its own head reads 1.1.
    func protocolName(_ slot: Int) -> StaticString {
        let c = table[slot]
        if c.pointee.isH3Stream { return "HTTP/3" }
        if c.pointee.isStream { return "HTTP/2" }
        return c.pointee.head.httpMinor == 0 ? "HTTP/1.0" : "HTTP/1.1"
    }

    // MARK: - Teardown

    public mutating func closeConnection(_ slot: Int) {
        let c = table[slot]
        if c.pointee.state == .free { return }

        // An HTTP/2 connection takes its streams with it. Detaching each one
        // first stops it from trying to tidy up a parent that is going away.
        if let h2 = c.pointee.h2 {
            let children = h2.streams
            h2.streams.removeAll()
            for (_, raw) in children {
                let child = Int(raw)
                if table[child].pointee.state != .free {
                    table[child].pointee.parentSlot = -1
                    closeConnection(child)
                }
            }
            h2.destroy()
            c.pointee.h2 = nil
        }
        // An HTTP/3 connection owns child streams the same way an HTTP/2 one
        // does, and its transport has to be told the connection is over.
        if let h3 = c.pointee.h3 {
            for (_, child) in h3.streams {
                if table[Int(child)].pointee.state != .free {
                    table[Int(child)].pointee.parentSlot = -1
                    closeConnection(Int(child))
                }
            }
            h3.destroy()
            c.pointee.h3 = nil
        }
        // A WebTransport session takes its streams with it, and they are the
        // transport's rather than the table's, so they are released here
        // before the parent link this needs is cut.
        if c.pointee.wt != nil { releaseWebTransport(slot) }
        if let connection = c.pointee.quicRef {
            connection.applicationSlot = -1
            if let quic { quic.close(connection, nowMs: pg_monotonic_ms()) }
            c.pointee.quicRef = nil
        }
        c.pointee.h3Protocol.destroy()

        let wasStream = c.pointee.isStream
        if wasStream {
            let parent = Int(c.pointee.parentSlot)
            c.pointee.parentSlot = -1
            if c.pointee.isH3Stream {
                if parent >= 0, let h3 = table[parent].pointee.h3 {
                    h3.streams.removeValue(forKey: c.pointee.qstreamID)
                    // Only worth asking a peer to stop if it might still be
                    // sending; a request that already ended has nothing left.
                    if let stream = h3.quic.stream(c.pointee.qstreamID),
                       !stream.receive.finished {
                        h3.quic.stopSending(c.pointee.qstreamID, code: HTTP3Error.noError)
                    }
                    h3.quic.releaseStream(c.pointee.qstreamID)
                }
            } else if parent >= 0, let h2 = table[parent].pointee.h2 {
                h2.streams.removeValue(forKey: c.pointee.streamID)
            }
        }

        // A producer parked in `await send()` has to be released, or its task
        // never finishes and the interpreter never shuts down.
        releaseDrainWaiter(slot)
        // Likewise a consumer parked in `await receive()`. The disconnect is
        // usually delivered when the peer hangs up, but a connection can also
        // be dropped for reasons the application never sees -- a write that
        // fails with EPIPE, or the shutdown deadline -- and a task left waiting
        // for a message that can no longer arrive stays pending forever.
        releasePendingReceive(slot)

        // A pool thread may still be inside the application. Telling it the
        // client is gone is all we can do; it unwinds and releases the job.
        if let job = c.pointee.poolJob {
            wsgiPool?.cancel(job)
            c.pointee.poolJob = nil
        }

        if let t = c.pointee.task { pg_decref(t); c.pointee.task = nil }
        if let f = c.pointee.pendingReceive { pg_decref(f); c.pointee.pendingReceive = nil }
        if let s = c.pointee.sendCallable { pg_decref(s); c.pointee.sendCallable = nil }
        if let r = c.pointee.receiveCallable { pg_decref(r); c.pointee.receiveCallable = nil }
        if let a = c.pointee.remoteAddrObj { pg_decref(a); c.pointee.remoteAddrObj = nil }
        if let p = c.pointee.remotePortObj { pg_decref(p); c.pointee.remotePortObj = nil }
        if let t = c.pointee.clientTuple { pg_decref(t); c.pointee.clientTuple = nil }
        if let k = c.pointee.ws.acceptKey { k.deallocate(); c.pointee.ws.acceptKey = nil }
        if !c.pointee.ws.queue.isEmpty {
            for message in c.pointee.ws.queue { pg_decref(message) }
            c.pointee.ws.queue.removeAll(keepingCapacity: false)
            c.pointee.ws.queuedBytes = 0
        }

        endTLS(slot)
        if c.pointee.fd >= 0 {
            _ = poller.remove(c.pointee.fd)
            _ = pg_close(c.pointee.fd)
            c.pointee.fd = -1
        }
        // A stream never took a buffer from the pool.
        if wasStream {
            c.pointee.read.destroy()
        } else {
            pool.give(c.pointee.read)
            c.pointee.read = ByteBuffer()
        }
        c.pointee.write.destroy()
        c.pointee.body.destroy()
        table.release(slot)

        if acceptSuspended && !draining {
            acceptSuspended = false
            _ = poller.modify(listenFD, .read, token: PollToken.listener)
        }
    }

    // MARK: - Timeouts

    mutating func sweepTimeouts() {
        let now = pg_monotonic_ms()
        if now &- lastSweep < 1000 { return }
        lastSweep = now
        dates.refresh()

        // Past the grace period, whatever is still in flight is not going to
        // finish. Dropping it is what turns "shut down when convenient" into a
        // bounded operation an init system can rely on.
        if draining && drainDeadline > 0 && now > drainDeadline {
            let stranded = table.liveCount
            if stranded > 0 {
                Log.warn { line in
                    line.str("graceful shutdown deadline reached with ")
                    line.int(stranded)
                    line.str(" connections still in flight; closing them")
                }
                var s = 0
                while s < table.capacity {
                    if table[s].pointee.state != .free { closeConnection(s) }
                    s += 1
                }
            }
            drainDeadline = 0
            running = false
            return
        }

        var slot = 0
        while slot < table.capacity {
            let c = table[slot]
            defer { slot += 1 }
            guard c.pointee.state != .free else { continue }
            let idle = now &- c.pointee.lastActivity
            switch c.pointee.state {
            case .readingHead:
                let limit = c.pointee.read.isEmpty
                    ? config.keepAliveTimeoutMs
                    : config.requestHeadTimeoutMs
                if idle > limit { closeConnection(slot) }
            case .readingBody, .writing:
                if idle > config.requestHeadTimeoutMs { closeConnection(slot) }
            case .websocket:
                sweepWebSocket(slot, now: now)
            case .closing where c.pointee.isStream:
                // A finished response still waiting for the rest of its
                // request. The client was asked to hurry, not given forever.
                if idle > config.requestHeadTimeoutMs {
                    if c.pointee.isH3Stream {
                        closeH3Stream(slot)
                    } else {
                        closeStream(slot, resetWith: .noError)
                    }
                }
            case .http3:
                // Idleness is the transport's business here: QUIC has its own
                // timeout, negotiated with the peer, and the listener runs it.
                break
            case .http2:
                // Only an idle connection times out; a stream that is still
                // running is the application's business, as in HTTP/1.
                if let h2 = c.pointee.h2, h2.streams.isEmpty,
                   idle > config.keepAliveTimeoutMs {
                    closeConnection(slot)
                }
            default:
                break
            }
        }
    }

    // MARK: - Signals

    mutating func handleSignals() {
        var buf = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
        while true {
            let n = withUnsafeMutableBytes(of: &buf) { raw in
                pg_read(signalFD, raw.baseAddress!, 8)
            }
            if n <= 0 { break }
            withUnsafeBytes(of: &buf) { raw in
                let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(n) {
                    switch Int32(p[i]) {
                    case SIGTERM, SIGINT, SIGQUIT:
                        beginDraining()
                    default:
                        break
                    }
                }
            }
        }
    }

    public mutating func beginDraining() {
        if draining { return }
        draining = true
        drainDeadline = config.gracefulShutdownMs > 0
            ? pg_monotonic_ms() &+ config.gracefulShutdownMs
            : 0
        // Every deadline above this one is cooperative: a task can swallow
        // cancellation, a C extension can sit in a syscall, and a worker with
        // no supervisor has nobody to escalate to. This one is not -- it fires
        // from a signal handler and calls _exit. The extra margin covers the
        // task drain, the lifespan shutdown and interpreter finalisation.
        if ownsExitWatchdog {
            let margin = config.gracefulShutdownMs / 1000 &+ 10
            pg_exit_after(UInt32(truncatingIfNeeded: margin), 0)
        }
        Log.info("worker draining")
        _ = poller.modify(listenFD, [], token: PollToken.listener)
        // Idle keep-alive connections have nothing in flight; drop them now.
        // Websockets are told the server is going away, which is what lets a
        // client reconnect to another worker instead of waiting for a timeout.
        var slot = 0
        while slot < table.capacity {
            let c = table[slot]
            if c.pointee.state == .websocket {
                sendCloseFrame(slot, code: WSCloseCode.goingAway,
                               reason: nil, reasonLength: 0)
            } else if c.pointee.state != .free && c.pointee.isIdle {
                closeConnection(slot)
            }
            slot += 1
        }
        if quiescent { running = false }
    }

    /// Nothing left to finish: no live connections, and no pooled request still
    /// running on a thread whose result the loop has yet to write out.
    @inlinable
    public var quiescent: Bool {
        table.liveCount == 0 && (wsgiPool == nil || wsgiPool!.inFlight == 0)
    }

    @inlinable
    public var hasWork: Bool { table.liveCount > 0 }

    // MARK: - Write backpressure

    /// Resolves a parked `await send()` once the buffer has drained enough to
    /// take another batch.
    mutating func resumeWriterIfDrained(_ slot: Int) {
        let c = table[slot]
        guard let waiter = c.pointee.drainWaiter else { return }
        if c.pointee.wt != nil {
            if wtOutstanding(slot) > config.writeLowWaterMark { return }
        } else if c.pointee.isH3Stream {
            if c.pointee.write.readableBytes > config.writeLowWaterMark { return }
            if h3Outstanding(slot) > config.writeLowWaterMark { return }
        } else if c.pointee.write.readableBytes > config.writeLowWaterMark {
            return
        }
        c.pointee.drainWaiter = nil
        if let r = pg_call2(ASGIRuntime.fnResolve, waiter, Interned.none) {
            pg_decref(r)
        } else {
            pg_err_clear()
        }
        pg_decref(waiter)
    }

    /// Hands a parked `await receive()` its disconnect, so the application
    /// task unwinds instead of waiting on a Future nothing will resolve.
    mutating func releasePendingReceive(_ slot: Int) {
        guard appProtocol == .asgi else { return }
        let c = table[slot]
        guard let future = c.pointee.pendingReceive else { return }
        c.pointee.pendingReceive = nil
        let message: PyObj?
        if let session = c.pointee.wt {
            session.disconnectDelivered = true
            message = ASGIWebTransportMessage.disconnect(code: session.closeCode,
                                                         reason: session.closeReason)
        } else if c.pointee.flags.contains(.websocketMode) {
            message = ASGIWebSocketMessage.disconnect(code: c.pointee.ws.closeCode)
        } else {
            message = ASGIMessage.httpDisconnect()
        }
        if let message {
            if let r = pg_call2(ASGIRuntime.fnResolve, future, message) {
                pg_decref(r)
            } else {
                pg_err_clear()
            }
            pg_decref(message)
        } else {
            pg_err_clear()
        }
        pg_decref(future)
    }

    /// Releases a parked producer without waiting for a drain that will never
    /// happen, because the connection is going away.
    mutating func releaseDrainWaiter(_ slot: Int) {
        let c = table[slot]
        guard let waiter = c.pointee.drainWaiter else { return }
        c.pointee.drainWaiter = nil
        if let r = pg_call2(ASGIRuntime.fnResolve, waiter, Interned.none) {
            pg_decref(r)
        } else {
            pg_err_clear()
        }
        pg_decref(waiter)
    }
}
