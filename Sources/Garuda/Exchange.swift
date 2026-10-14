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
    /// The peer, as text, made when first asked for.
    @usableFromInline var remote: SocketPeer

    // MARK: The response

    @usableFromInline var status = 200
    /// Header records: name length and value length as two little-endian
    /// UInt16s, then the lowercased name, then the value.
    @usableFromInline var responseHeaders = ByteBuffer()
    @usableFromInline var headerKinds: ResponseHeaderKind = []
    @usableFromInline var hasContentType = false
    @usableFromInline var responseBody = ByteBuffer()
    @usableFromInline var answered = false
    /// Kept for the next JSON answer on this connection.
    var jsonWriter: JSONWriter?

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
    /// not a number, or anything once the response has been answered.
    @usableFromInline
    mutating func addHeader(_ name: ByteSpan, _ value: ByteSpan) -> Bool {
        guard !answered, name.count > 0, name.count <= 0xFFFF, value.count <= 0xFFFF else { return false }
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

/// The address of the peer of a connection, as the connection knows it.
@usableFromInline
struct SocketPeer: Sendable {
    @usableFromInline var address: String
    @usableFromInline var port: Int

    @usableFromInline init(address: String, port: Int) {
        self.address = address
        self.port = port
    }

    static let none = SocketPeer(address: "", port: 0)
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

    /// The client's port.
    public var remotePort: Int { exchange.pointee.remote.port }

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
    public var remoteAddress: String { exchange.pointee.remote.address }

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
