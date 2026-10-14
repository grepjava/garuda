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

    init(_ config: ServerConfig) {
        readBufferSize = max(1024, config.readBufferSize)
        maxHeadSize = config.maxHeadSize
        maxHeaders = max(1, config.maxHeaders)
        maxBodySize = config.maxBodySize
        maxRequests = config.maxRequestsPerConnection
        pipelineDepth = max(1, config.pipelineDepth)
        keepAliveTimeout = config.keepAliveTimeout
        requestHeadTimeout = config.requestHeadTimeout
        bodyTimeout = config.bodyTimeout
    }
}

/// Output past this is flushed even in the middle of a pipelined batch.
let outputFlushThreshold = 64 * 1024
/// A body this large is written from the response's own buffer rather than
/// copied behind the head.
let separateBodyThreshold = 16 * 1024

/// Serves HTTP/1.1 on `stream` until the client closes it, a request asks
/// for the connection to close, or it idles out.
func serveHTTP1<S: AsyncReader & AsyncWriter & ~Copyable>(
    _ stream: borrowing S, app: CompiledApplication, limits: ConnectionLimits, peer: SocketPeer
) async {
    let parts = app.connections.take(limits: limits, peer: peer)
    parts.pointee.exchange.pointee.application = Unmanaged.passUnretained(app)
    var connection = HTTP1Connection(limits: limits, parts: parts, cache: app.connections)
    await connection.run(stream, app: app)
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

    init(limits: ConnectionLimits, parts: UnsafeMutablePointer<ConnectionParts>, cache: ConnectionCache) {
        self.limits = limits
        self.parts = parts
        self.cache = cache
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
        if head.hasBody {
            guard try await readBody(stream) else { return false }
        }

        var keepAlive = head.isKeepAlive
        served &+= 1
        if limits.maxRequests > 0 && served >= limits.maxRequests { keepAlive = false }

        await dispatch(app)

        // A handler's body is only sent when there is room for it to be
        // framed: never on HEAD, 1xx, 204 or 304.
        writeResponse(keepAlive: keepAlive, omitBody: head.method == .head)
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

    /// Finds the route and runs its handler, answering for it when it throws
    /// or returns without answering.
    mutating func dispatch(_ app: CompiledApplication) async {
        let path = x.pointee.head.path
        let base = x.pointee.base + Int(path.offset)
        let route = app.table.match(x.pointee.head.method, base, path.count, into: &x.pointee.parameters)
        guard route >= 0 else {
            let allowed = app.table.allowedMethods(base, path.count, into: &x.pointee.parameters)
            x.pointee.parameters = RouteParameters()
            if allowed.isEmpty {
                x.pointee.answer(404, nil, 0)
            } else {
                var list = ""
                for method in allowed {
                    if !list.isEmpty { list += ", " }
                    list += method.name
                }
                Response(x).addHeader("allow", list)
                x.pointee.answer(405, nil, 0)
            }
            return
        }
        let index = Int(route)
        let handler = app.handlers[index]
        let costs = app.costs
        let heavy = costs.isHeavy(index)
        let lane = heavy ? costs.lane : nil
        // Only fails once the lane is closed, at shutdown: run regardless.
        if let lane { try? await lane.acquireIgnoringCancellation() }
        let start = monotonicNanos()
        let sampled = costs.shouldSample(index, heavy: heavy, now: start)
        let stamp = sampled ? Runtime.currentJobStamp : .none
        do {
            try await handler(Request(x), Response(x))
            if !x.pointee.answered {
                Log.error("a handler returned without answering; answering 500")
                x.pointee.answer(500, nil, 0)
            }
        } catch let error as any ResponseError {
            answerError(x, error)
        } catch {
            Log.error("handler threw: \(error)")
            answerFailure(x)
        }
        // A handler that suspended gave its thread up; its time says nothing.
        if sampled && Runtime.currentJobStamp == stamp {
            costs.record(index, nanos: monotonicNanos() &- start)
        }
        lane?.release()
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
                    try await failAndClose(stream, status: error.status)
                    return false
                case .incomplete:
                    break
                }
            }
            // Waiting: whatever has been answered goes out first.
            try await flush(stream)
            if available >= limits.maxHeadSize {
                try await failAndClose(stream, status: 431)
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

    /// Reads the request's body: in place for a Content-Length, decoded into
    /// the exchange for chunked. False when the request cannot be served.
    mutating func readBody<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S) async throws -> Bool {
        let head = x.pointee.head
        if head.isChunked {
            return try await readChunkedBody(stream)
        }
        let length = head.contentLength
        guard length <= limits.maxBodySize else {
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

    mutating func readChunkedBody<S: AsyncReader & AsyncWriter & ~Copyable>(_ stream: borrowing S) async throws -> Bool {
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
                if decoder.decodedBytes > limits.maxBodySize {
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
                if decoder.decodedBytes > limits.maxBodySize {
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
        x.pointee.committed = true
        parts.pointee.dates.refresh()
        let status = x.pointee.status
        let forbids = HTTPResponseWriter.statusForbidsBody(status)
        let count = forbids ? 0 : x.pointee.responseBody.readableBytes
        parts.pointee.output.reserve(256 &+ x.pointee.responseHeaders.readableBytes)
        HTTPResponseWriter.writeStatusLine(&parts.pointee.output, status: status)
        let kinds = x.pointee.headerKinds
        if !kinds.contains(.date) { HTTPResponseWriter.writeDate(&parts.pointee.output, parts.pointee.dates) }
        if !kinds.contains(.server) { parts.pointee.output.write("Server: garuda\r\n") }
        x.pointee.forEachResponseHeader { name, value in
            let kind = HTTPResponseWriter.classify(name)
            // The server frames the message and manages the connection.
            if kind == .contentLength || kind == .transferEncoding || kind == .connection { return }
            _ = HTTPResponseWriter.writeHeader(&parts.pointee.output, name: name, value: value)
        }
        if !forbids { HTTPResponseWriter.writeContentLength(&parts.pointee.output, count) }
        if !keepAlive {
            parts.pointee.output.write("Connection: close\r\n")
        } else if x.pointee.head.httpMinor == 0 {
            parts.pointee.output.write("Connection: keep-alive\r\n")
        }
        HTTPResponseWriter.endHead(&parts.pointee.output)
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
        _ stream: borrowing S, status: Int
    ) async throws {
        parts.pointee.dates.refresh()
        HTTPResponseWriter.writeError(&parts.pointee.output, status: status, closeConnection: true,
                                      dateCache: parts.pointee.dates, serverName: "garuda")
        try await flush(stream)
    }
}

/// A `ResponseError` as the answer.
func answerError(_ x: UnsafeMutablePointer<Exchange>, _ error: any ResponseError) {
    guard !x.pointee.answered else { return }
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
