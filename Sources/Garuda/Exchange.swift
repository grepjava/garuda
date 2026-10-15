//===----------------------------------------------------------------------===//
// Request and response: views of the connection's exchange.
//
// A connection task owns one `Exchange` for its whole life and reuses it for
// every request on it. The request's bytes stay where they arrived, in the
// connection's read buffer; the exchange records where each part is. The
// response collects its status, headers and body here until the connection
// writes it.
//
// `Request` and `Response` are each one pointer to the exchange, and neither
// can be copied: a handler cannot keep one past its return, because the next
// request on the connection reuses the same memory. Holding one across an
// `await` is fine -- the connection task is the one suspended in the handler,
// so nothing moves underneath it, whichever thread it resumes on.
//===----------------------------------------------------------------------===//

import GarudaWire

/// What one request and its answer are made of, reused for each request on a
/// connection.
@usableFromInline
struct Exchange: ~Copyable {
    // MARK: The request

    /// The connection's read buffer; every request slice is relative to it.
    @usableFromInline var base: UnsafePointer<UInt8>
    @usableFromInline var head = HTTPRequestHead()
    @usableFromInline let headers: UnsafeMutablePointer<HTTPHeaderRef>
    @usableFromInline let maxHeaders: Int
    /// Offsets relative to the start of the path.
    @usableFromInline var parameters = RouteParameters()
    @usableFromInline var body: UnsafePointer<UInt8>?
    @usableFromInline var bodyCount = 0
    /// The body's bytes as they arrived, framing and all: what to skip to
    /// reach the next request.
    @usableFromInline var consumedBody = 0
    /// A chunked body, decoded.
    @usableFromInline var decodedBody = ByteBuffer()
    /// The most the body may be, decoded as well (RequestDecompression.swift).
    /// Set as the body is read.
    var bodyLimit = Int.max
    /// The peer, as text, made when first asked for.
    @usableFromInline var remote: SocketPeer
    /// What middleware stored for this request (Context.swift).
    @usableFromInline var context = ContextSlots()
    /// The connection is TLS (TLS.swift).
    @usableFromInline var secure = false
    /// --scheme https: a request without TLS is taken as HTTPS all the same.
    /// Set per connection.
    @usableFromInline var assumeHTTPS = false
    /// With --request-start-header, when the request arrived, in microseconds
    /// since the epoch; 0 otherwise. Set by the connection as the request's
    /// first bytes arrive.
    @usableFromInline var requestStart: UInt64 = 0
    /// Alt-Svc and Strict-Transport-Security, as the connection's transport
    /// calls for them, or nil: set per connection (HTTP1.swift).
    var serverFields: ServerFields?
    /// The proxies whose forwarded headers are believed, or nil for none:
    /// set per connection, and only when there is a list (Forwarded.swift).
    @usableFromInline var trust: ForwardedTrust?
    /// What those headers said for this request, read when first asked for.
    @usableFromInline var forwardedState = ForwardedState.unknown
    /// --static-dir and --spa-fallback, set per connection (StaticFiles.swift).
    var site: StaticSite?
    /// --compress, set per connection, and the coding this request's client
    /// accepts (Compression.swift).
    @usableFromInline var compress = false
    var compressMinimum = 1024
    @usableFromInline var acceptedCoding = ContentCoding.identity
    /// The answer is not to be compressed here: a file, already as it should be.
    @usableFromInline var noCompress = false
    /// Where a body is compressed into, swapped with `responseBody`.
    var compressed = ByteBuffer()

    // MARK: The response cache (ResponseCache.swift)

    /// The copy of this answer being made for the cache.
    var capture: ResponseCapture?
    /// The target's mark, when this request changes what it names; 0 when
    /// it does not.
    var cacheInvalidates: UInt64 = 0
    /// Where a lookup copies a stored response.
    var cacheScratch = ByteBuffer()
    /// The application serving the connection, for its state. It outlives
    /// every connection it serves.
    var application: Unmanaged<CompiledApplication>?

    // MARK: The response

    @usableFromInline var status = 200
    /// Header records: name length and value length as two little-endian
    /// UInt16s, then the lowercased name, then the value.
    @usableFromInline var responseHeaders = ByteBuffer()
    @usableFromInline var headerKinds: ResponseHeaderKind = []
    @usableFromInline var hasContentType = false
    @usableFromInline var responseBody = ByteBuffer()
    @usableFromInline var answered = false
    /// The head has gone to the connection: nothing in it can change. Until
    /// then middleware may add headers and set the status after the handler
    /// has answered.
    @usableFromInline var committed = false
    /// Kept for the next JSON answer on this connection.
    var jsonWriter: JSONWriter?

    // MARK: A streamed body (StreamingResponse.swift)

    /// Where a streamed body goes, set by the connection.
    var link = BodyLink.none
    /// The body being streamed, once the head is made.
    var channel: BodyChannel?
    /// A returned `StreamingBody`'s producer, run once the handler returns.
    var producer: StreamProducer?
    /// HTTP/1: the connection may serve another request after this one.
    var keepAlive = true
    /// An `onSend` hook gave the response a body of its own.
    var bodyReplaced = false
    /// The hooks are running over a streamed head.
    var streamStarting = false
    /// Something above was set, for `reset` to undo.
    @usableFromInline var touchedStream = false
    /// An accepted WebSocket upgrade, for the connection to carry out once
    /// the handler has returned (WebSocket.swift).
    var upgrade: WebSocketUpgrade?
    /// An accepted WebTransport session, for the stream's task to run once
    /// the handler has returned (WebTransport.swift).
    var webTransport: WTAcceptance?
    /// The connection can become a WebSocket's: HTTP/1, served where its
    /// stream can be split. Set per connection.
    var canUpgrade = false
    /// --no-websockets.
    var websocketsRefused = false
    /// --ws-*, set per connection that can upgrade.
    var websocketLimits = WebSocketLimits()
    /// HTTP/2 and HTTP/3: the `:protocol` of an extended CONNECT (RFC 8441,
    /// RFC 9220), routed as the GET it stands for -- a WebTransport session
    /// as the CONNECT it is. Set per stream.
    var connectProtocol = ConnectProtocol.none

    @usableFromInline
    mutating func resetStream() {
        touchedStream = false
        upgrade = nil
        webTransport = nil
        channel = nil
        producer = nil
        bodyReplaced = false
        if capture != nil { capture = nil }
        cacheInvalidates = 0
    }

    /// `Response.onSend` hooks, run before the head is written. Empty, and
    /// unallocated, for a request that registers none (ResponseHooks.swift).
    @usableFromInline var sendHooks: [SendHook] = []

    // MARK: What watches the request
    //
    // Each is left as it is -- empty, nil, -1, 0 -- by a request nothing is
    // watching, and costs it no allocation.

    /// The request's ID with --request-id, or empty (RequestID.swift).
    @usableFromInline var requestID = ByteBuffer()
    /// What this exchange's generated IDs are made from, kept from one
    /// request to the next.
    var requestIDKey: (UInt64, UInt64) = (0, 0)
    var requestIDCount: UInt64 = 0
    /// With --trace-context, the value of a valid traceparent the request
    /// carries (RequestID.swift).
    @usableFromInline var traceParent: UnsafePointer<UInt8>?
    /// The route that matched, or -1.
    @usableFromInline var route: Int32 = -1
    /// When dispatch began, in monotonic nanoseconds, when something is timing
    /// the request; 0 otherwise.
    @usableFromInline var started: UInt64 = 0
    /// Why the route answered 5xx on its own account, for the response
    /// observers (ResponseObservers.swift).
    @usableFromInline var failure: String?
    /// The request's server span, while it is traced (Tracing.swift).
    var span: RequestSpan?

    init(maxHeaders: Int, remote: SocketPeer) {
        self.maxHeaders = maxHeaders
        headers = .allocate(capacity: maxHeaders)
        let empty: StaticString = ""
        base = empty.utf8Start
        self.remote = remote
    }

    deinit {
        headers.deallocate()
        // A ByteBuffer is a handle to its storage: a copy frees it.
        var buffer = decodedBody
        buffer.destroy()
        buffer = responseHeaders
        buffer.destroy()
        buffer = responseBody
        buffer.destroy()
        buffer = requestID
        buffer.destroy()
        buffer = compressed
        buffer.destroy()
        buffer = cacheScratch
        buffer.destroy()
        jsonWriter?.destroy()
    }

    /// Readies the exchange for the next request, keeping its buffers.
    @inlinable
    mutating func reset() {
        head = HTTPRequestHead()
        parameters = RouteParameters()
        body = nil
        bodyCount = 0
        consumedBody = 0
        decodedBody.clear()
        status = 200
        responseHeaders.clear()
        headerKinds = []
        hasContentType = false
        responseBody.clear()
        answered = false
        committed = false
        if !context.isEmpty { context.clear() }
        if !sendHooks.isEmpty { sendHooks = [] }
        if touchedStream { resetStream() }
        if compress {
            acceptedCoding = .identity
            noCompress = false
        }
        requestID.clear()
        traceParent = nil
        route = -1
        started = 0
        if failure != nil { failure = nil }
        if case .unknown = forwardedState {} else { forwardedState = .unknown }
    }

    @inlinable
    func slice(_ s: HTTPSlice) -> ByteSpan { s.span(in: base) }

    /// The first header named `name` (any case), or nil.
    @inlinable
    func header(_ name: UnsafePointer<UInt8>, _ count: Int) -> ByteSpan? {
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            if h.name.count == count, equalsIgnoringCase(base + Int(h.name.offset), name, count) {
                return h.value.span(in: base)
            }
            i &+= 1
        }
        return nil
    }

    /// Adds a response header, refusing what could not be sent: a name that
    /// is not a token, a value with CR, LF or NUL, a Content-Length that is
    /// not a number, or anything once the head has been written.
    @usableFromInline
    mutating func addHeader(_ name: ByteSpan, _ value: ByteSpan) -> Bool {
        guard !committed, name.count > 0, name.count <= 0xFFFF, value.count <= 0xFFFF else { return false }
        var i = 0
        while i < name.count {
            if !isTokenChar(name.base[i]) { return false }
            i &+= 1
        }
        i = 0
        while i < value.count {
            if !isFieldValueChar(value.base[i]) { return false }
            i &+= 1
        }
        let kind = HTTPResponseWriter.classify(name)
        if kind == .contentLength, value.integer == nil { return false }
        headerKinds.formUnion(kind)
        if name.count == 12, equalsLowercased(name.base, 12, "content-type") { hasContentType = true }
        responseHeaders.reserve(4 &+ name.count &+ value.count)
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: name.count))
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: name.count >> 8))
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: value.count))
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: value.count >> 8))
        i = 0
        while i < name.count {
            responseHeaders.writeByte(asciiLower(name.base[i]))
            i &+= 1
        }
        if value.count > 0 { responseHeaders.write(value) }
        return true
    }

    /// Adds `content-type: value` for an answer that implies its type -- text,
    /// JSON, HTML, bytes -- as `addHeader` would, without looking again at a
    /// name known to be good: most answers carry one, and every byte of the
    /// name was checked, lowered and copied one at a time.
    @usableFromInline
    mutating func addContentType(_ value: StaticString) -> Bool {
        let count = value.utf8CodeUnitCount
        guard !committed, count <= 0xFFFF else { return false }
        let v = value.utf8Start
        var i = 0
        while i < count {
            if !isFieldValueChar(v[i]) { return false }
            i &+= 1
        }
        hasContentType = true
        let name: StaticString = "content-type"
        responseHeaders.reserve(16 &+ count)
        responseHeaders.writeByte(12)
        responseHeaders.writeByte(0)
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: count))
        responseHeaders.writeByte(UInt8(truncatingIfNeeded: count >> 8))
        responseHeaders.write(name.utf8Start, 12)
        if count > 0 { responseHeaders.write(v, count) }
        return true
    }

    /// Answers: the status, and a copy of the body. Only the first answer
    /// counts.
    @usableFromInline
    mutating func answer(_ code: Int, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
        guard !answered else { return }
        answered = true
        status = code
        if count > 0, let bytes { responseBody.write(bytes, count) }
    }

    /// Calls `body` with each response header record.
    @inlinable
    func forEachResponseHeader(_ body: (ByteSpan, ByteSpan) -> Void) {
        guard responseHeaders.readableBytes > 0 else { return }
        var p = UnsafePointer(responseHeaders.readPointer)
        let end = p + responseHeaders.readableBytes
        while p < end {
            let n = Int(p[0]) | Int(p[1]) << 8
            let v = Int(p[2]) | Int(p[3]) << 8
            body(ByteSpan(p + 4, n), ByteSpan(p + 4 + n, v))
            p += 4 + n + v
        }
    }
}

/// The address of the peer of a connection: given, or looked up from the
/// socket the first time a handler asks. Most never do, and a lookup is a
/// system call and a String for every connection.
@usableFromInline
struct SocketPeer: Sendable {
    private var fd: Int32 = -1
    private var known: (address: String, port: Int)?

    @usableFromInline init(address: String, port: Int) {
        known = (address, port)
    }

    /// The peer of socket `fd`, looked up when asked for.
    init(socket fd: Int32) {
        self.fd = fd
    }

    static let none = SocketPeer(address: "", port: 0)

    @usableFromInline var address: String { mutating get { resolved().address } }
    @usableFromInline var port: Int { mutating get { resolved().port } }

    private mutating func resolved() -> (address: String, port: Int) {
        if let known { return known }
        let found = peerName(of: fd) ?? ("", 0)
        known = found
        return found
    }
}

@inlinable
func equalsIgnoringCase(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    var i = 0
    while i < n {
        if asciiLower(a[i]) != asciiLower(b[i]) { return false }
        i &+= 1
    }
    return true
}

// MARK: - Request

/// The request a handler is answering. It lends the bytes the connection
/// holds; the `with` methods hand them out as spans that cannot escape the
/// call, and the plain properties make owned copies.
public struct Request: ~Copyable {
    @usableFromInline let exchange: UnsafeMutablePointer<Exchange>

    @usableFromInline
    init(_ exchange: UnsafeMutablePointer<Exchange>) {
        self.exchange = exchange
    }

    public var method: HTTPMethod { exchange.pointee.head.method }

    /// 1.0, 1.1, 2 or 3.
    public var version: (major: Int, minor: Int) {
        let major = Int(exchange.pointee.head.httpMajor)
        return (major, major == 1 ? Int(exchange.pointee.head.httpMinor) : 0)
    }

    /// How many parameters the matched route's pattern names.
    public var parameterCount: Int { exchange.pointee.parameters.count }

    /// With --request-start-header, when the request arrived, in microseconds
    /// since the epoch; nil without it. For an APM agent that reports queue
    /// time: everything that happened before the handler was called. A
    /// proxy's own X-Request-Start is still among the headers, and is the
    /// better time when there is one, the proxy having seen the request first.
    public var requestStart: UInt64? {
        let start = exchange.pointee.requestStart
        return start == 0 ? nil : start
    }

    // MARK: Lent bytes

    /// The request target's path, still percent-encoded, as the client sent it.
    @discardableResult @inlinable
    public borrowing func withPath<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try lend(pathBytes, body)
    }

    /// The query string without its "?", or empty.
    @discardableResult @inlinable
    public borrowing func withQuery<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try lend(queryBytes, body)
    }

    /// Route parameter `index`, in the order the pattern names them, still
    /// percent-encoded.
    @discardableResult @inlinable
    public borrowing func withParameter<R, E: Error>(_ index: Int, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try lend(parameterBytes(index), body)
    }

    /// The first value of `name`, compared without regard to case. Nil, and
    /// `body` is not called, when the request has no such header.
    @discardableResult @inlinable
    public borrowing func withHeader<R, E: Error>(_ name: StaticString, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R? {
        guard let value = headerBytes(name) else { return nil }
        return try lend(value, body)
    }

    @discardableResult
    public borrowing func withHeader<R, E: Error>(_ name: String, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R? {
        guard let value = headerBytes(name) else { return nil }
        return try lend(value, body)
    }

    /// Every header as received, in order and with repeats.
    public borrowing func forEachHeader<E: Error>(_ body: (_ name: Span<UInt8>, _ value: Span<UInt8>) throws(E) -> Void) throws(E) {
        let x = exchange
        var i = 0
        while i < x.pointee.head.headerCount {
            let h = x.pointee.headers[i]
            let name = x.pointee.slice(h.name)
            let value = x.pointee.slice(h.value)
            try body(UnsafeBufferPointer(start: name.base, count: name.count).span,
                     UnsafeBufferPointer(start: value.base, count: value.count).span)
            i &+= 1
        }
    }

    /// The whole request body, which arrived before the handler was called.
    @discardableResult @inlinable
    public borrowing func withBody<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        try lend(bodyBytes, body)
    }

    // MARK: Owned copies

    public var path: String { pathBytes.string }
    public var query: String { queryBytes.string }
    public func parameter(_ index: Int) -> String { parameterBytes(index).string }
    public func header(_ name: StaticString) -> String? { headerBytes(name)?.string }
    public func header(_ name: String) -> String? { headerBytes(name)?.string }
    /// Host, which is where HTTP/2's and HTTP/3's :authority arrives.
    public var authority: String? { headerBytes("host")?.string }
    public var body: [UInt8] {
        let bytes = bodyBytes
        return Array(UnsafeBufferPointer(start: bytes.base, count: bytes.count))
    }

    // MARK: The bytes themselves

    @usableFromInline var pathBytes: ByteSpan { exchange.pointee.slice(exchange.pointee.head.path) }

    @usableFromInline var queryBytes: ByteSpan { exchange.pointee.slice(exchange.pointee.head.query) }

    @usableFromInline
    func parameterBytes(_ index: Int) -> ByteSpan {
        let x = exchange
        precondition(index >= 0 && index < x.pointee.parameters.count, "no such route parameter")
        let (start, count) = x.pointee.parameters[index]
        return ByteSpan(x.pointee.base + Int(x.pointee.head.path.offset) + start, count)
    }

    @usableFromInline
    func headerBytes(_ name: StaticString) -> ByteSpan? {
        exchange.pointee.header(name.utf8Start, name.utf8CodeUnitCount)
    }

    func headerBytes(_ name: String) -> ByteSpan? {
        var name = name
        return name.withUTF8 { exchange.pointee.header($0.baseAddress!, $0.count) }
    }

    @usableFromInline
    var bodyBytes: ByteSpan {
        let x = exchange
        if let body = x.pointee.body { return ByteSpan(body, x.pointee.bodyCount) }
        return ByteSpan(x.pointee.base, 0)
    }
}

/// Lends `bytes` to `body` as a span that cannot outlive the call.
@inlinable @inline(__always)
func lend<R, E: Error>(_ bytes: ByteSpan, _ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
    try body(UnsafeBufferPointer(start: bytes.base, count: bytes.count).span)
}

/// The span's bytes as a `ByteSpan`, for the length of `body`.
@inlinable @inline(__always)
func withByteSpan<R>(_ span: Span<UInt8>, _ body: (ByteSpan) -> R) -> R {
    span.withUnsafeBufferPointer { buffer in
        let empty: StaticString = ""
        return body(ByteSpan(buffer.baseAddress ?? empty.utf8Start, buffer.count))
    }
}

// MARK: - Response

/// The answer being made. Its status and headers can be changed until the
/// connection writes it, after the handler returns; the first `send` is the
/// answer, and any after it are ignored.
public struct Response: ~Copyable {
    @usableFromInline let exchange: UnsafeMutablePointer<Exchange>

    @usableFromInline
    init(_ exchange: UnsafeMutablePointer<Exchange>) {
        self.exchange = exchange
    }

    /// The status `send` uses when it is not given one. 200 to begin with.
    public var status: HTTPStatus {
        get { HTTPStatus(exchange.pointee.status) }
        nonmutating set { exchange.pointee.status = newValue.code }
    }

    /// Whether this request has been answered.
    public var isFinished: Bool { exchange.pointee.answered }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: StaticString) -> Bool {
        exchange.pointee.addHeader(ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                   ByteSpan(value.utf8Start, value.utf8CodeUnitCount))
    }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: Span<UInt8>) -> Bool {
        withByteSpan(value) { v in
            exchange.pointee.addHeader(ByteSpan(name.utf8Start, name.utf8CodeUnitCount), v)
        }
    }

    @discardableResult
    public func addHeader(_ name: Span<UInt8>, _ value: Span<UInt8>) -> Bool {
        withByteSpan(name) { n in
            withByteSpan(value) { v in exchange.pointee.addHeader(n, v) }
        }
    }

    @discardableResult
    public func addHeader(_ name: String, _ value: String) -> Bool {
        var name = name
        var value = value
        return name.withUTF8 { n in
            value.withUTF8 { v in
                let empty: StaticString = ""
                return exchange.pointee.addHeader(ByteSpan(n.baseAddress ?? empty.utf8Start, n.count),
                                                  ByteSpan(v.baseAddress ?? empty.utf8Start, v.count))
            }
        }
    }

    @inlinable
    func answer(_ code: Int, _ base: UnsafePointer<UInt8>?, _ count: Int) {
        exchange.pointee.answer(code, base, count)
    }

    public func send(status: HTTPStatus) {
        answer(status.code, nil, 0)
    }

    @inlinable
    public func send(status: HTTPStatus? = nil, _ body: StaticString) {
        answer((status ?? self.status).code, body.utf8Start, body.utf8CodeUnitCount)
    }

    /// Sends bytes lent by the request, or any other span.
    public func send(status: HTTPStatus? = nil, _ body: Span<UInt8>) {
        let code = (status ?? self.status).code
        withByteSpan(body) { answer(code, $0.base, $0.count) }
    }

    public func send(status: HTTPStatus? = nil, _ body: String) {
        let code = (status ?? self.status).code
        var body = body
        body.withUTF8 { answer(code, $0.baseAddress, $0.count) }
    }

    public func send(status: HTTPStatus? = nil, _ body: [UInt8]) {
        let code = (status ?? self.status).code
        body.withUnsafeBufferPointer { answer(code, $0.baseAddress, $0.count) }
    }

    /// Writes the body straight into the response's buffer, for a writer --
    /// JSON's -- that produces it piece by piece.
    @usableFromInline
    func send(status: HTTPStatus?, writing: (inout ByteBuffer) throws -> Void) rethrows {
        guard !exchange.pointee.answered else { return }
        let code = (status ?? self.status).code
        try writing(&exchange.pointee.responseBody)
        exchange.pointee.answered = true
        exchange.pointee.status = code
    }
}

// MARK: - Bytes

extension Span where Element == UInt8 {
    /// A copy as a String, with invalid UTF-8 repaired.
    public var string: String {
        withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    }

    /// The bytes as a non-negative decimal integer of up to 18 digits, or nil.
    public var integer: Int? {
        guard count > 0, count <= 18 else { return nil }
        var value = 0
        for i in indices {
            let d = self[i]
            guard d >= 0x30 && d <= 0x39 else { return nil }
            value = value * 10 + Int(d - 0x30)
        }
        return value
    }

    /// Whether the bytes are exactly `literal`'s.
    public func equals(_ literal: StaticString) -> Bool {
        guard count == literal.utf8CodeUnitCount else { return false }
        for i in indices where self[i] != literal.utf8Start[i] { return false }
        return true
    }
}

extension ByteSpan {
    /// A copy as a String, with invalid UTF-8 repaired.
    @usableFromInline var string: String {
        String(decoding: UnsafeBufferPointer(start: base, count: count), as: UTF8.self)
    }

    /// The span as a non-negative decimal integer of up to 18 digits, or nil.
    @usableFromInline var integer: Int? {
        guard count > 0, count <= 18 else { return nil }
        var value = 0
        for i in 0..<count {
            let d = base[i]
            guard d >= 0x30 && d <= 0x39 else { return nil }
            value = value * 10 + Int(d - 0x30)
        }
        return value
    }

    func equals(_ literal: StaticString) -> Bool {
        count == literal.utf8CodeUnitCount && equalsExact(base, count, literal)
    }
}

/// What an HTTP/2 or HTTP/3 extended CONNECT asked to become.
enum ConnectProtocol: UInt8 {
    /// An ordinary request.
    case none
    case websocket
    /// HTTP/3 only: a WebTransport session, routed as the CONNECT it is
    /// (WebTransport.swift).
    case webtransport
    /// A protocol nothing here speaks: 501 at a WebSocket route, and at
    /// once over HTTP/3.
    case other
}
