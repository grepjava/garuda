//===----------------------------------------------------------------------===//
// The handler API: the request a handler reads and the response it writes.
//
// A handler is a plain function value, called on the worker's own thread from
// inside dispatch. `Request` and `Response` are views of one connection slot,
// valid for the length of that call and no longer: both are ~Copyable, so a
// handler cannot keep either. Bytes the request already holds -- the path, a
// parameter, a header, the body -- are lent to a closure as a `Span`, which the
// compiler keeps inside that closure; a handler that wants to keep a value asks
// for an owned copy instead (`String`, `[UInt8]`). A handler that has to wait
// says so with `Response.after`, which calls a handler again later with fresh
// views of the same request, and what it needs across that wait goes in the
// request's typed context (RequestContext.swift).
//
// Lending allocates nothing. The engine side -- dispatch, the response sink,
// what a request reads -- is in Respond.swift.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

public typealias Handler = (borrowing Request, inout Response) throws -> Void

// MARK: - Routes

/// Routes as an `Application` registers them, compiled when it runs.
struct Routes {
    var table = RouteTable()
    var handlers: [Handler] = []

    /// Registers `handler` for `method` and `pattern`. A pattern that cannot
    /// be served is a mistake in the program, found before the server starts.
    mutating func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        do {
            try table.add(method, pattern, route: Int32(handlers.count))
        } catch {
            fatalError("route \(pattern): \(error)")
        }
        handlers.append(handler)
    }
}

// MARK: - Request

public struct Request: ~Copyable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int

    init(worker: UnsafeMutablePointer<Worker>, slot: Int) {
        self.worker = worker
        self.slot = slot
    }

    var connection: UnsafeMutablePointer<Connection> { worker.pointee.table[slot] }

    public var method: HTTPMethod { connection.pointee.head.method }

    /// 1.0, 1.1, 2 or 3.
    public var version: (major: Int, minor: Int) {
        let c = connection
        let major = Int(c.pointee.head.httpMajor)
        return (major, major == 1 ? Int(c.pointee.head.httpMinor) : 0)
    }

    /// "https" on TLS, on an HTTP/2 or HTTP/3 request whose :scheme said so,
    /// or when a trusted proxy said so; --scheme otherwise.
    public var scheme: StaticString { worker.pointee.requestScheme(slot) }

    /// How many parameters the matched route's pattern names.
    public var parameterCount: Int { connection.pointee.routeParameters.count }

    /// The client's port, or the one a trusted proxy forwarded for it.
    public var remotePort: Int { worker.pointee.requestClient(slot).port }

    /// With --request-start-header, when the request arrived, in microseconds
    /// since the epoch -- the kernel's receive time where it has one. Nil
    /// without the flag.
    public var requestStart: UInt64? { worker.pointee.requestStartMicros(slot) }

    // MARK: Lent bytes
    //
    // Each lends bytes the connection already holds to `body`, for as long as
    // `body` runs. The span cannot be stored, returned or captured by an
    // escaping closure: the compiler refuses it.

    /// The request target's path, still percent-encoded, as the client sent it.
    @discardableResult
    public borrowing func withPath<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try lend(pathBytes, body)
    }

    /// The query string without its "?", or empty.
    @discardableResult
    public borrowing func withQuery<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try lend(queryBytes, body)
    }

    /// Route parameter `index`, in the order the pattern names them, still
    /// percent-encoded.
    @discardableResult
    public borrowing func withParameter<R>(_ index: Int, _ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try lend(parameterBytes(index), body)
    }

    /// The first value of `name`, compared without regard to case. Nil, and
    /// `body` is not called, when the request has no such header.
    @discardableResult
    public borrowing func withHeader<R>(_ name: StaticString, _ body: (Span<UInt8>) throws -> R) rethrows -> R? {
        guard let value = headerBytes(name) else { return nil }
        return try lend(value, body)
    }

    @discardableResult
    public borrowing func withHeader<R>(_ name: String, _ body: (Span<UInt8>) throws -> R) rethrows -> R? {
        guard let value = headerBytes(name) else { return nil }
        return try lend(value, body)
    }

    /// Every header as received, in order and with repeats. HTTP/2 and
    /// HTTP/3 pseudo-headers are not among them: :authority arrives as Host,
    /// and :scheme is `scheme`.
    public borrowing func forEachHeader(_ body: (_ name: Span<UInt8>, _ value: Span<UInt8>) throws -> Void) rethrows {
        try worker.pointee.forEachRequestHeader(slot) { name, value in
            try body(UnsafeBufferPointer(start: name.base, count: name.count).span,
                     UnsafeBufferPointer(start: value.base, count: value.count).span)
        }
    }

    /// The whole request body, which arrived before the handler was called.
    @discardableResult
    public borrowing func withBody<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try lend(bodyBytes, body)
    }

    /// The client's address, or the one a trusted proxy forwarded for it.
    @discardableResult
    public borrowing func withRemoteAddress<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        try lend(worker.pointee.requestClient(slot).address, body)
    }

    /// The ID --request-id assigned or kept. Nil, and `body` is not called,
    /// without one.
    @discardableResult
    public borrowing func withRequestID<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R? {
        guard let id = requestIDBytes else { return nil }
        return try lend(id, body)
    }

    // MARK: Owned copies
    //
    // Each makes a value the handler owns, which it can keep, return, or take
    // across `Response.after`.

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
    public var remoteAddress: String { worker.pointee.requestClient(slot).address.string }
    public var requestID: String? { requestIDBytes?.string }

    // MARK: The bytes themselves, for the engine

    var pathBytes: ByteSpan {
        let c = connection
        return c.pointee.head.path.span(in: c.pointee.headBase())
    }

    var queryBytes: ByteSpan {
        let c = connection
        return c.pointee.head.query.span(in: c.pointee.headBase())
    }

    func parameterBytes(_ index: Int) -> ByteSpan {
        let c = connection
        precondition(index >= 0 && index < c.pointee.routeParameters.count,
                     "no such route parameter")
        let (start, count) = c.pointee.routeParameters[index]
        return ByteSpan(c.pointee.headBase() + Int(c.pointee.routeOffset) + start, count)
    }

    func headerBytes(_ name: StaticString) -> ByteSpan? {
        worker.pointee.requestHeader(slot, name.utf8Start, name.utf8CodeUnitCount)
    }

    func headerBytes(_ name: String) -> ByteSpan? {
        var name = name
        return name.withUTF8 { worker.pointee.requestHeader(slot, $0.baseAddress!, $0.count) }
    }

    var bodyBytes: ByteSpan {
        let c = connection
        guard c.pointee.body.readableBytes > 0 else { return ByteSpan(c.pointee.headBase(), 0) }
        return c.pointee.body.readableSpan
    }

    var requestIDBytes: ByteSpan? {
        let c = connection
        return c.pointee.requestID.readableBytes > 0 ? c.pointee.requestID.readableSpan : nil
    }
}

/// Lends `bytes` to `body` as a span that cannot outlive the call.
@inline(__always)
func lend<R>(_ bytes: ByteSpan, _ body: (Span<UInt8>) throws -> R) rethrows -> R {
    try body(UnsafeBufferPointer(start: bytes.base, count: bytes.count).span)
}

/// The span's bytes as a `ByteSpan`, for the engine, for the length of `body`.
@inline(__always)
func withByteSpan<R>(_ span: Span<UInt8>, _ body: (ByteSpan) -> R) -> R {
    span.withUnsafeBufferPointer { buffer in
        let empty: StaticString = ""
        return body(ByteSpan(buffer.baseAddress ?? empty.utf8Start, buffer.count))
    }
}

// MARK: - Response

public struct Response: ~Copyable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    let generation: UInt32
    let requestId: UInt32

    init(worker: UnsafeMutablePointer<Worker>, slot: Int, generation: UInt32, requestId: UInt32) {
        self.worker = worker
        self.slot = slot
        self.generation = generation
        self.requestId = requestId
    }

    /// The status `send` uses when it is not given one. 200 to begin with.
    public var status: HTTPStatus {
        get { HTTPStatus(Int(worker.pointee.table[slot].pointee.handlerStatus)) }
        nonmutating set { worker.pointee.table[slot].pointee.handlerStatus = UInt16(clamping: newValue.code) }
    }

    /// Whether this request has been answered, or has a continuation waiting.
    public var isFinished: Bool {
        worker.pointee.handlerFinished(slot, generation: generation, requestId: requestId)
    }

    /// Adds a header. Returns false, and adds nothing, once the response has
    /// been sent, or for a name that is not a token, a value holding CR, LF or
    /// NUL, or a Content-Length that is not a number. The bytes are copied.
    @discardableResult
    public func addHeader(_ name: StaticString, _ value: StaticString) -> Bool {
        worker.pointee.addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                         ByteSpan(value.utf8Start, value.utf8CodeUnitCount))
    }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: Span<UInt8>) -> Bool {
        withByteSpan(value) { v in
            worker.pointee.addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount), v)
        }
    }

    @discardableResult
    public func addHeader(_ name: Span<UInt8>, _ value: Span<UInt8>) -> Bool {
        withByteSpan(name) { n in
            withByteSpan(value) { v in worker.pointee.addResponseHeader(slot, n, v) }
        }
    }

    @discardableResult
    public func addHeader(_ name: String, _ value: String) -> Bool {
        var name = name
        var value = value
        return name.withUTF8 { n in
            value.withUTF8 { v in
                worker.pointee.addResponseHeader(slot, ByteSpan(n.baseAddress!, n.count),
                                                 ByteSpan(v.baseAddress!, v.count))
            }
        }
    }

    // One-shot answers. Each writes the whole response through the engine's
    // response sink, which frames it for the protocol, merges in the server's
    // own headers, and holds the body to any Content-Length the handler set.

    public func send(status: HTTPStatus) {
        worker.pointee.respond(slot, status: status.code, nil, 0)
    }

    public func send(status: HTTPStatus? = nil, _ body: StaticString) {
        worker.pointee.respond(slot, status: (status ?? self.status).code,
                               body.utf8Start, body.utf8CodeUnitCount)
    }

    /// Sends bytes lent by the request, or any other span, without copying
    /// them first.
    public func send(status: HTTPStatus? = nil, _ body: Span<UInt8>) {
        let code = (status ?? self.status).code
        withByteSpan(body) { worker.pointee.respond(slot, status: code, $0.base, $0.count) }
    }

    public func send(status: HTTPStatus? = nil, _ body: String) {
        let code = (status ?? self.status).code
        var body = body
        body.withUTF8 { worker.pointee.respond(slot, status: code, $0.baseAddress, $0.count) }
    }

    public func send(status: HTTPStatus? = nil, _ body: [UInt8]) {
        let code = (status ?? self.status).code
        body.withUnsafeBufferPointer {
            worker.pointee.respond(slot, status: code, $0.baseAddress, $0.count)
        }
    }

    /// Calls `then` after `milliseconds`, with this request, unless the
    /// request is cancelled first. Answers 503 when the worker has no room
    /// left to wait in.
    public func after(milliseconds: UInt64, then: @escaping Handler) {
        worker.pointee.suspend(slot, milliseconds: milliseconds, then: then)
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
    var string: String {
        String(decoding: UnsafeBufferPointer(start: base, count: count), as: UTF8.self)
    }

    /// The span as a non-negative decimal integer of up to 18 digits, or nil.
    var integer: Int? {
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
