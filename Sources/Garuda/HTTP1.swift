//===----------------------------------------------------------------------===//
// HTTP/1.1: one task per connection.
//
// The task owns the connection's read buffer and its exchange, and runs a
// loop: parse a head out of the bytes already read (reading more only when
// they hold no whole head), take the body, find the route, call the handler,
// write the response into the output buffer. Requests a client pipelines are
// answered in one batch -- the output is flushed only when the task is about
// to wait for more input, or the batch is full -- so a pipelining client
// costs one write per batch rather than one per request.
//
// Nothing is copied on the way in: the parser records offsets into the read
// buffer, and the handler reads the request through those. The buffer is
// not touched while a handler runs, so the request stays valid across every
// `await` in it.
//
// Every wait on the client is bounded: for the next request on an idle
// connection by the keep-alive timeout, for the rest of a head once it has
// begun by the request-head timeout (slowloris), for a body by the body
// timeout.
//===----------------------------------------------------------------------===//

import GarudaWire
import Vega
import VegaIO

/// What every connection is held to, worked out once from the config.
struct ConnectionLimits: Sendable {
    var readBufferSize: Int
    var maxHeadSize: Int
    var maxHeaders: Int
    var maxBodySize: Int
    var maxRequests: Int
    var pipelineDepth: Int
    var keepAliveTimeout: Duration
    var requestHeadTimeout: Duration
    var bodyTimeout: Duration
    /// What a streamed body is held to (StreamingResponse.swift).
    var writeTimeout: Duration
    var writeHighWaterMark: Int
    var writeLowWaterMark: Int
    var eventKeepAlive: Duration
    /// --request-id, and the proxies whose ID is kept: nil when there are
    /// none, so a connection copies no list it would not read (RequestID.swift).
    var requestID: Bool
    var requestIDTrust: ForwardedTrust?
    /// The proxies whose forwarded headers are believed, nil when there are
    /// none (Forwarded.swift).
    var trust: ForwardedTrust?
    var traceContext: Bool
    /// --access-log, as text or JSON (Logging.swift).
    var accessLog: Bool
    var accessLogJSON: Bool
    /// HTTP/2's settings and limits (HTTP2.swift).
    var http2: HTTP2Limits
    /// --static-dir and --spa-fallback, or nil for neither (StaticFiles.swift).
    var site: StaticSite?
    /// --compress and --compress-min-size (Compression.swift).
    var compress: Bool
    var compressMinimum: Int

    init(_ config: ServerConfig) {
        http2 = HTTP2Limits(config)
        site = StaticSite(config)
        compress = config.compress
        compressMinimum = config.compressMinimumLength
        readBufferSize = max(1024, config.readBufferSize)
        maxHeadSize = config.maxHeadSize
        maxHeaders = max(1, config.maxHeaders)
        maxBodySize = config.maxBodySize
        maxRequests = config.maxRequestsPerConnection
        pipelineDepth = max(1, config.pipelineDepth)
        keepAliveTimeout = config.keepAliveTimeout
        requestHeadTimeout = config.requestHeadTimeout
        bodyTimeout = config.bodyTimeout
        writeTimeout = config.writeTimeout
        writeHighWaterMark = max(1, config.writeHighWaterMark)
        writeLowWaterMark = min(max(0, config.writeLowWaterMark), writeHighWaterMark)
        eventKeepAlive = config.eventKeepAlive
        requestID = config.requestID
        requestIDTrust = config.requestID && !config.trust.isEmpty ? config.trust : nil
        trust = config.trust.isEmpty ? nil : config.trust
        traceContext = config.traceContext
        accessLog = config.accessLog
        accessLogJSON = config.accessLogJSON
    }
}

/// Output past this is flushed even in the middle of a pipelined batch.
let outputFlushThreshold = 64 * 1024
/// A body this large is written from the response's own buffer rather than
/// copied behind the head.
let separateBodyThreshold = 16 * 1024

/// Serves HTTP/1.1 on `stream` until the client closes it, a request asks
/// for the connection to close, or it idles out. `secure`: the stream is TLS.
/// Gives the stream back, for the caller to close.
@discardableResult
func serveHTTP1<S: AsyncReader & AsyncWriter & ~Copyable>(
    _ stream: consuming S, app: CompiledApplication, limits: ConnectionLimits, peer: SocketPeer,
    secure: Bool = false, writer: (any HeldWriting.Type)? = nil
) async -> S {
    await serveHTTP1(stream, parts: app.connections.take(limits: limits, peer: peer), app: app, limits: limits,
                     secure: secure, writer: writer)
}

/// The same, on parts already taken, whose input may hold the connection's
/// first bytes: read while looking for the HTTP/2 preface (HTTP2.swift).
@discardableResult
func serveHTTP1<S: AsyncReader & AsyncWriter & ~Copyable>(
    _ stream: consuming S, parts: UnsafeMutablePointer<ConnectionParts>, app: CompiledApplication,
    limits: ConnectionLimits, secure: Bool, writer: (any HeldWriting.Type)? = nil
) async -> S {
    let x = parts.pointee.exchange
    x.pointee.application = Unmanaged.passUnretained(app)
    // The exchange is reused from connection to connection: set both.
    x.pointee.secure = secure
    if x.pointee.trust != nil || limits.trust != nil { x.pointee.trust = limits.trust }
    if x.pointee.site != nil || limits.site != nil { x.pointee.site = limits.site }
    x.pointee.compress = limits.compress
    x.pointee.compressMinimum = limits.compressMinimum
    // Held where a streamed body's writes can reach it while the handler
    // writing it runs (StreamingResponse.swift).
    let held = UnsafeMutablePointer<S>.allocate(capacity: 1)
    held.initialize(to: stream)
    x.pointee.link = .http1(HeldStream(pointer: UnsafeMutableRawPointer(held), writer: writer ?? HeldWriter<S>.self),
                            parts, StreamLimits(limits))
    var connection = HTTP1Connection(limits: limits, parts: parts, cache: app.connections,
                                     observing: limits.accessLog || !app.observers.isEmpty || app.metrics != nil)
    await connection.run(held.pointee, app: app)
    x.pointee.link = .none
    let back = held.move()
    held.deallocate()
    return back
}

struct HTTP1Connection: ~Copyable {
    let limits: ConnectionLimits
    /// The buffers and the exchange, borrowed from the cache for the
    /// connection's life (ConnectionCache.swift).
    let parts: UnsafeMutablePointer<ConnectionParts>
    let cache: ConnectionCache
    /// Where the next request starts in `input`.
    var start = 0
    /// The exchange, where it stays for the connection's life: handlers are
    /// lent pointers to it.
    let x: UnsafeMutablePointer<Exchange>
    /// Responses in `output` not yet flushed.
    var batched = 0
    var served = 0
    /// Something sees each answer -- the access log or `app.onResponse` --
    /// so requests are timed and reported (ResponseObservers.swift).
    let observing: Bool

    init(limits: ConnectionLimits, parts: UnsafeMutablePointer<ConnectionParts>, cache: ConnectionCache,
         observing: Bool = false) {
        self.limits = limits
        self.parts = parts
        self.cache = cache
        self.observing = observing
        x = parts.pointee.exchange
    }

    deinit {
        cache.give(parts, limits: limits)
    }

    mutating func run<S: AsyncReader & AsyncWriter & ~Copyable>(
        _ stream: borrowing S, app: CompiledApplication
    ) async {
        do {
            while try await serveOne(stream, app: app) {}
            try await flush(stream)
        } catch {
            // The client went away, timed out, or sent something that ended
            // the connection; whatever could be answered has been.
        }
    }

    // MARK: One request

    /// Serves the next request. False when the connection is done.
    mutating func serveOne<S: AsyncReader & AsyncWriter & ~Copyable>(
        _ stream: borrowing S, app: CompiledApplication
    ) async throws -> Bool {
        x.pointee.reset()
        guard try await readHead(stream) else { return false }

        let head = x.pointee.head
        // A route matched before its body was read, for its scope's body
        // limit; -1 when the dispatch matches (RequestLimits.swift).
        var matched: Int32 = -1
        if head.hasBody {
            let limit = app.hasBodyLimits ? bodyLimit(app, matched: &matched) : limits.maxBodySize
            x.pointee.bodyLimit = limit
            guard try await readBody(stream, limit: limit) else { return false }
        }

        var keepAlive = head.isKeepAlive
        served &+= 1
        if limits.maxRequests > 0 && served >= limits.maxRequests { keepAlive = false }
        x.pointee.keepAlive = keepAlive

        // Before anything can answer, so every answer carries them.
        if limits.requestID { x.pointee.assignRequestID(trusting: limits.requestIDTrust) }
        if limits.traceContext { x.pointee.readTraceParent() }
        if observing { x.pointee.started = monotonicNanos() }

        await dispatch(app, matched: matched)

        if let channel = x.pointee.channel {
            // Streamed: the head and most of the body have gone; the rest
            // and the end of it go with the next flush (StreamingResponse.swift).
            if await !channel.close(into: parts, failed: channel.handlerFailed) { keepAlive = false }
            if !x.pointee.keepAlive { keepAlive = false }
            if observing { report(status: x.pointee.status) }
        } else {
            // A handler's body is only sent when there is room for it to be
            // framed: never on HEAD, 1xx, 204 or 304.
            writeResponse(keepAlive: keepAlive, omitBody: head.method == .head)
            if observing { report(status: x.pointee.status) }
        }
        start &+= head.headEnd &+ x.pointee.consumedBody
        batched &+= 1

        if !keepAlive {
            try await flush(stream)
            return false
        }
        if batched >= limits.pipelineDepth || parts.pointee.output.readableBytes >= outputFlushThreshold {
            try await flush(stream)
        }
        return true
    }

    /// Finds the route and runs its handler (Dispatch.swift).
    mutating func dispatch(_ app: CompiledApplication, matched: Int32 = -1) async {
        await Garuda.dispatch(x, app, matched: matched, observing: observing)
    }

    // MARK: Reading

    /// Reads until `input` holds a whole head at `start`, and parses it into
    /// the x.pointee. False when the client closed the connection between
    /// requests or must be closed on.
    mutating func readHead<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S) async throws -> Bool {
        while true {
            if start > 0 && start == parts.pointee.input.count {
                parts.pointee.input.clear()
                start = 0
            }
            let available = parts.pointee.input.count &- start
            if available > 0 {
                let base = parts.pointee.input.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) } + start
                x.pointee.base = base
                switch HTTPParser.parse(base, available, maxHeadSize: limits.maxHeadSize,
                                        maxHeaders: limits.maxHeaders, headers: x.pointee.headers,
                                        head: &x.pointee.head) {
                case .complete:
                    return true
                case .failure(let error):
                    try await failAndClose(stream, status: error.status, headParsed: false)
                    return false
                case .incomplete:
                    break
                }
            }
            // Waiting: whatever has been answered goes out first.
            try await flush(stream)
            if available >= limits.maxHeadSize {
                try await failAndClose(stream, status: 431, headParsed: false)
                return false
            }
            makeRoom(for: limits.maxHeadSize)
            let timeout = available == 0 ? limits.keepAliveTimeout : limits.requestHeadTimeout
            let n = try await Runtime.withIODeadline(timeout) { () async throws(IOError) -> Int in
                try await stream.read(into: &parts.pointee.input)
            }
            if n == 0 { return false }
        }
    }

    /// Reads the request's body, of at most `limit` bytes: in place for a
    /// Content-Length, decoded into the exchange for chunked. False when the
    /// request cannot be served.
    mutating func readBody<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S, limit: Int) async throws -> Bool {
        let head = x.pointee.head
        if head.isChunked {
            return try await readChunkedBody(stream, limit: limit)
        }
        let length = head.contentLength
        guard length <= limit else {
            try await failAndClose(stream, status: 413)
            return false
        }
        let need = head.headEnd &+ length
        if parts.pointee.input.count &- start < need {
            try await sendContinueIfAsked(stream)
            compact()
            parts.pointee.input.reserveCapacity(need)
            while parts.pointee.input.count < need {
                let n = try await Runtime.withIODeadline(limits.bodyTimeout) { () async throws(IOError) -> Int in
                    try await stream.read(into: &parts.pointee.input)
                }
                if n == 0 { return false }
            }
        }
        rebase()
        x.pointee.body = x.pointee.base + head.headEnd
        x.pointee.bodyCount = length
        x.pointee.consumedBody = length
        return true
    }

    mutating func readChunkedBody<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S, limit: Int) async throws -> Bool {
        var decoder = ChunkedDecoder()
        var at = x.pointee.head.headEnd
        var asked = false
        while true {
            let base = parts.pointee.input.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) } + start
            var consumed = 0
            let outcome = decoder.decode(base + at, parts.pointee.input.count &- start &- at, consumed: &consumed) { p, n in
                x.pointee.decodedBody.write(p, n)
            }
            at &+= consumed
            switch outcome {
            case .finished:
                // A body that arrived whole in one read never reached the
                // check below.
                if decoder.decodedBytes > limit {
                    try await failAndClose(stream, status: 413)
                    return false
                }
                rebase()
                x.pointee.body = x.pointee.decodedBody.readableBytes > 0
                    ? UnsafePointer(x.pointee.decodedBody.readPointer) : nil
                x.pointee.bodyCount = x.pointee.decodedBody.readableBytes
                x.pointee.consumedBody = at &- x.pointee.head.headEnd
                return true
            case .failure(let error):
                try await failAndClose(stream, status: error.status)
                return false
            case .needMore:
                if decoder.decodedBytes > limit {
                    try await failAndClose(stream, status: 413)
                    return false
                }
                if !asked {
                    try await sendContinueIfAsked(stream)
                    asked = true
                }
                // The raw chunks read so far are decoded; only what is still
                // undecoded needs to stay, but the head ahead of it does too.
                compact()
                if parts.pointee.input.spareCapacity < 4096 { parts.pointee.input.reserveCapacity(parts.pointee.input.capacity * 2) }
                let n = try await Runtime.withIODeadline(limits.bodyTimeout) { () async throws(IOError) -> Int in
                    try await stream.read(into: &parts.pointee.input)
                }
                if n == 0 { return false }
            }
        }
    }

    /// `Expect: 100-continue`: the client is waiting to be told to send.
    mutating func sendContinueIfAsked<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S) async throws {
        guard x.pointee.head.flags.contains(.expectContinue) else { return }
        parts.pointee.output.write("HTTP/1.1 100 Continue\r\n\r\n")
        try await flush(stream)
    }

    /// Moves the request at `start` to the front of `input`.
    mutating func compact() {
        guard start > 0 else { return }
        parts.pointee.input.consume(start)
        start = 0
        rebase()
    }

    /// Room in `input` for a head of up to `limit` bytes.
    mutating func makeRoom(for limit: Int) {
        if parts.pointee.input.spareCapacity > 0 { return }
        if start > 0 {
            compact()
            if parts.pointee.input.spareCapacity > 0 { return }
        }
        parts.pointee.input.reserveCapacity(min(max(parts.pointee.input.capacity * 2, 1024), limit + 1024))
        rebase()
    }

    /// Points the exchange at `input` again, after it may have moved.
    mutating func rebase() {
        x.pointee.base = parts.pointee.input.withUnsafeBytes { $0.baseAddress!.assumingMemoryBound(to: UInt8.self) } + start
    }

    // MARK: Writing

    /// Writes the exchange's response into `output`.
    mutating func writeResponse(keepAlive: Bool, omitBody: Bool) {
        // `Response.onSend` hooks see the answer once it is final, while it
        // can still change (ResponseHooks.swift).
        if !x.pointee.sendHooks.isEmpty { runSendHooks(x) }
        if x.pointee.compress && !x.pointee.noCompress { x.pointee.compressAnswer(omitBody: omitBody) }
        let forbids = HTTPResponseWriter.statusForbidsBody(x.pointee.status)
        let count = forbids ? 0 : x.pointee.responseBody.readableBytes
        writeHTTP1Head(x, parts, keepAlive: keepAlive, framing: forbids ? .none : .length(count))
        if count > 0 && !omitBody {
            parts.pointee.output.write(x.pointee.responseBody.readPointer, count)
        }
    }

    /// Writes whatever `output` holds.
    mutating func flush<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S) async throws {
        batched = 0
        let pending = parts.pointee.output.readableBytes
        guard pending > 0 else { return }
        let bytes = UnsafeRawBufferPointer(start: parts.pointee.output.readPointer, count: pending)
        try await stream.write(bytes)
        parts.pointee.output.clear()
    }

    /// Answers `status` to a request that cannot be read, and closes.
    mutating func failAndClose<S: AsyncReader & AsyncWriter & ~Copyable>(
        _ stream: borrowing S, status: Int, headParsed: Bool = true
    ) async throws {
        if observing { report(status: status, headParsed: headParsed) }
        parts.pointee.dates.refresh()
        HTTPResponseWriter.writeError(&parts.pointee.output, status: status, closeConnection: true,
                                      dateCache: parts.pointee.dates, serverName: "garuda")
        try await flush(stream)
    }
}

/// Writes the head of `x`'s response into the connection's output, the
/// body delimited as `framing` says, and commits it.
func writeHTTP1Head(_ x: UnsafeMutablePointer<Exchange>, _ parts: UnsafeMutablePointer<ConnectionParts>,
                    keepAlive: Bool, framing: H1Framing) {
    x.pointee.committed = true
    parts.pointee.dates.refresh()
    parts.pointee.output.reserve(256 &+ x.pointee.responseHeaders.readableBytes)
    HTTPResponseWriter.writeStatusLine(&parts.pointee.output, status: x.pointee.status)
    let kinds = x.pointee.headerKinds
    if !kinds.contains(.date) { HTTPResponseWriter.writeDate(&parts.pointee.output, parts.pointee.dates) }
    if !kinds.contains(.server) { parts.pointee.output.write("Server: garuda\r\n") }
    // --request-id's, unless the handler set its own (RequestID.swift).
    if x.pointee.requestID.readableBytes > 0 && !kinds.contains(.requestID) {
        parts.pointee.output.write("X-Request-ID: ")
        parts.pointee.output.write(x.pointee.requestID.readableSpan)
        parts.pointee.output.writeCRLF()
    }
    x.pointee.forEachResponseHeader { name, value in
        let kind = HTTPResponseWriter.classify(name)
        // The server frames the message and manages the connection.
        if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
        _ = HTTPResponseWriter.writeHeader(&parts.pointee.output, name: name, value: value)
    }
    switch framing {
    case .length(let count): HTTPResponseWriter.writeContentLength(&parts.pointee.output, count)
    case .chunked: HTTPResponseWriter.writeChunkedEncoding(&parts.pointee.output)
    case .none: break
    }
    if !keepAlive {
        parts.pointee.output.write("Connection: close\r\n")
    } else if x.pointee.head.httpMinor == 0 {
        parts.pointee.output.write("Connection: keep-alive\r\n")
    }
    HTTPResponseWriter.endHead(&parts.pointee.output)
}

/// A `ResponseError` as the answer.
func answerError(_ x: UnsafeMutablePointer<Exchange>, _ error: any ResponseError) {
    guard !x.pointee.answered else { return }
    // A refused credential carries its WWW-Authenticate challenge, added only
    // now that it is the answer: an optional extractor that swallowed it
    // leaves no challenge on a response that went on (Authentication.swift).
    if let refused = error as? Unauthenticated {
        Response(x).addHeader("www-authenticate", refused.challenge)
    }
    Response(x).sendError(status: error.status, reason: error.reason, fields: error.fields)
}

/// Anything else a handler threw: a 500, with nothing about it told to the
/// client.
func answerFailure(_ x: UnsafeMutablePointer<Exchange>) {
    guard !x.pointee.answered else { return }
    x.pointee.responseHeaders.clear()
    x.pointee.headerKinds = []
    x.pointee.hasContentType = false
    x.pointee.answer(500, nil, 0)
}

extension HTTPMethod {
    /// The method as it is written on the wire.
    public var name: String {
        switch self {
        case .get: "GET"
        case .head: "HEAD"
        case .post: "POST"
        case .put: "PUT"
        case .delete: "DELETE"
        case .patch: "PATCH"
        case .options: "OPTIONS"
        case .connect: "CONNECT"
        case .trace: "TRACE"
        case .other: "OTHER"
        }
    }
}
