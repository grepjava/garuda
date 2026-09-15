//===----------------------------------------------------------------------===//
// The handler API: routes, the request a handler reads, the response it writes.
//
// A handler is a plain function value, called on the worker's own thread from
// inside dispatch. `Request` and `Response` are views of one connection slot,
// valid for the length of that call and no longer: both are ~Copyable, so a
// handler cannot keep either, and a handler that has to wait says so with
// `Response.after`, which parks a continuation and calls a handler again later
// with fresh views of the same request (HANDLER-API.md, "Suspension").
//
// Nothing here allocates on the way to an answer. Header values, parameters and
// the body are byte spans into memory the connection already owns; a handler
// that wants a String asks for one. The engine side -- dispatch, the response
// sink, what a request reads -- is in Respond.swift.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

public typealias Handler = (borrowing Request, inout Response) throws -> Void

// MARK: - Routes

public struct Routes {
    var table = RouteTable()
    var handlers: [Handler] = []

    public init() {}

    public mutating func get(_ pattern: String, _ handler: @escaping Handler) { on(.get, pattern, handler) }
    public mutating func head(_ pattern: String, _ handler: @escaping Handler) { on(.head, pattern, handler) }
    public mutating func post(_ pattern: String, _ handler: @escaping Handler) { on(.post, pattern, handler) }
    public mutating func put(_ pattern: String, _ handler: @escaping Handler) { on(.put, pattern, handler) }
    public mutating func delete(_ pattern: String, _ handler: @escaping Handler) { on(.delete, pattern, handler) }
    public mutating func patch(_ pattern: String, _ handler: @escaping Handler) { on(.patch, pattern, handler) }
    public mutating func options(_ pattern: String, _ handler: @escaping Handler) { on(.options, pattern, handler) }

    /// Registers `handler` for `method` and `pattern`. A pattern that cannot
    /// be served is a mistake in the program, found before the server starts.
    public mutating func on(_ method: HTTPMethod, _ pattern: String, _ handler: @escaping Handler) {
        do {
            try table.add(method, pattern, route: Int32(handlers.count))
        } catch {
            fatalError("route \(pattern): \(error)")
        }
        handlers.append(handler)
    }
}

/// The routes every worker serves: compiled before the first fork, only read
/// after it, and never freed.
struct InstalledRoutes {
    let routes: CompiledRoutes
    let handlers: UnsafeMutablePointer<Handler>
}

nonisolated(unsafe) var installedRoutes: UnsafeMutablePointer<InstalledRoutes>? = nil

func install(_ routes: Routes) {
    let handlers = UnsafeMutablePointer<Handler>.allocate(capacity: max(1, routes.handlers.count))
    for (i, handler) in routes.handlers.enumerated() { (handlers + i).initialize(to: handler) }
    let installed = UnsafeMutablePointer<InstalledRoutes>.allocate(capacity: 1)
    installed.initialize(to: InstalledRoutes(routes: routes.table.compile(), handlers: handlers))
    installedRoutes = installed
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

    /// The request target's path, still percent-encoded, as the client sent it.
    public var path: ByteSpan {
        let c = connection
        return c.pointee.head.path.span(in: c.pointee.headBase())
    }

    /// The query string without its "?", or empty.
    public var query: ByteSpan {
        let c = connection
        return c.pointee.head.query.span(in: c.pointee.headBase())
    }

    public var parameterCount: Int { connection.pointee.routeParameters.count }

    /// Route parameter `index`, in the order the pattern names them, still
    /// percent-encoded.
    public func parameter(_ index: Int) -> ByteSpan {
        let c = connection
        precondition(index >= 0 && index < c.pointee.routeParameters.count,
                     "no such route parameter")
        let (start, count) = c.pointee.routeParameters[index]
        return ByteSpan(c.pointee.headBase() + Int(c.pointee.routeOffset) + start, count)
    }

    /// 1.0, 1.1, 2 or 3.
    public var version: (major: Int, minor: Int) {
        let c = connection
        let major = Int(c.pointee.head.httpMajor)
        return (major, major == 1 ? Int(c.pointee.head.httpMinor) : 0)
    }

    /// "https" on TLS, on an HTTP/2 or HTTP/3 request whose :scheme said so,
    /// or when a trusted proxy said so; --scheme otherwise.
    public var scheme: StaticString { worker.pointee.requestScheme(slot) }

    /// The first value of `name`, compared without regard to case, or nil.
    public func header(_ name: StaticString) -> ByteSpan? {
        worker.pointee.requestHeader(slot, name.utf8Start, name.utf8CodeUnitCount)
    }

    public func header(_ name: String) -> ByteSpan? {
        var name = name
        return name.withUTF8 { worker.pointee.requestHeader(slot, $0.baseAddress!, $0.count) }
    }

    /// Every header as received, in order and with repeats. HTTP/2 and
    /// HTTP/3 pseudo-headers are not among them: :authority arrives as Host,
    /// and :scheme is `scheme`.
    public func forEachHeader(_ body: (_ name: ByteSpan, _ value: ByteSpan) throws -> Void) rethrows {
        try worker.pointee.forEachRequestHeader(slot, body)
    }

    /// Host, which is where HTTP/2's and HTTP/3's :authority arrives.
    public var authority: ByteSpan? { header("host") }

    /// The whole request body, which arrived before the handler was called.
    public var body: ByteSpan {
        let c = connection
        guard c.pointee.body.readableBytes > 0 else { return ByteSpan(c.pointee.headBase(), 0) }
        return c.pointee.body.readableSpan
    }

    /// The client, or the address a trusted proxy forwarded for it.
    public var remoteAddress: ByteSpan { worker.pointee.requestClient(slot).address }

    public var remotePort: Int { worker.pointee.requestClient(slot).port }

    /// The ID --request-id assigned or kept, or nil.
    public var requestID: ByteSpan? {
        let c = connection
        return c.pointee.requestID.readableBytes > 0 ? c.pointee.requestID.readableSpan : nil
    }

    /// With --request-start-header, when the request arrived, in microseconds
    /// since the epoch -- the kernel's receive time where it has one. Nil
    /// without the flag.
    public var requestStart: UInt64? { worker.pointee.requestStartMicros(slot) }

    /// Four words that survive a suspension, for a handler's own state.
    public var locals: RequestLocals { RequestLocals(connection: connection) }
}

public struct RequestLocals {
    let connection: UnsafeMutablePointer<Connection>

    public subscript(index: Int) -> UInt64 {
        get { connection.pointee.locals[index] }
        nonmutating set { connection.pointee.locals[index] = newValue }
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
    public var status: Int {
        get { Int(worker.pointee.table[slot].pointee.handlerStatus) }
        nonmutating set { worker.pointee.table[slot].pointee.handlerStatus = UInt16(clamping: newValue) }
    }

    /// Whether this request has been answered, or has a continuation waiting.
    public var isFinished: Bool {
        worker.pointee.handlerFinished(slot, generation: generation, requestId: requestId)
    }

    /// Adds a header. Returns false, and adds nothing, once the response has
    /// been sent, or for a name that is not a token, a value holding CR, LF or
    /// NUL, or a Content-Length that is not a number.
    @discardableResult
    public func addHeader(_ name: StaticString, _ value: StaticString) -> Bool {
        worker.pointee.addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                         ByteSpan(value.utf8Start, value.utf8CodeUnitCount))
    }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: ByteSpan) -> Bool {
        worker.pointee.addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount), value)
    }

    @discardableResult
    public func addHeader(_ name: ByteSpan, _ value: ByteSpan) -> Bool {
        worker.pointee.addResponseHeader(slot, name, value)
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

    public func send(status: Int) {
        worker.pointee.respond(slot, status: status, nil, 0)
    }

    public func send(status: Int? = nil, _ body: StaticString) {
        worker.pointee.respond(slot, status: status ?? self.status,
                               body.utf8Start, body.utf8CodeUnitCount)
    }

    public func send(status: Int? = nil, _ body: ByteSpan) {
        worker.pointee.respond(slot, status: status ?? self.status, body.base, body.count)
    }

    public func send(status: Int? = nil, _ body: String) {
        let code = status ?? self.status
        var body = body
        body.withUTF8 { worker.pointee.respond(slot, status: code, $0.baseAddress, $0.count) }
    }

    public func send(status: Int? = nil, _ body: [UInt8]) {
        let code = status ?? self.status
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

extension ByteSpan {
    /// A copy as a String, with invalid UTF-8 repaired.
    public var string: String {
        String(decoding: UnsafeBufferPointer(start: base, count: count), as: UTF8.self)
    }

    /// The span as a non-negative decimal integer of up to 18 digits, or nil.
    public var integer: Int? {
        guard count > 0, count <= 18 else { return nil }
        var value = 0
        for i in 0..<count {
            let d = base[i]
            guard d >= 0x30 && d <= 0x39 else { return nil }
            value = value * 10 + Int(d - 0x30)
        }
        return value
    }

    public func equals(_ literal: StaticString) -> Bool {
        count == literal.utf8CodeUnitCount && equalsExact(base, count, literal)
    }
}

// MARK: - Serving

extension Garuda {
    /// Parses the process's command line as the `garuda` executable does,
    /// then serves `routes` until shut down. Returns the process exit code.
    ///
    /// `onStart` runs in each worker before it accepts a connection -- a
    /// replacement worker is not handed its slot until it returns -- and
    /// `onShutdown` in each worker once its in-flight requests have finished
    /// or --graceful-timeout has run out. Both get the worker's index.
    public static func serve(_ routes: Routes,
                             onStart: ((Int) -> Void)? = nil,
                             onShutdown: ((Int) -> Void)? = nil) -> Int32 {
        install(routes)
        lifecycle = Lifecycle(onStart: onStart, onShutdown: onShutdown)
        return GarudaCLI.main(argc: Int(CommandLine.argc), argv: CommandLine.unsafeArgv)
    }
}

struct Lifecycle {
    var onStart: ((Int) -> Void)?
    var onShutdown: ((Int) -> Void)?
}

nonisolated(unsafe) var lifecycle = Lifecycle()
