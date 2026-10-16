//===----------------------------------------------------------------------===//
// Seeing a response just before it is sent, and changing it.
//
//     app.use { request, response, next in
//         response.onSend { outgoing in
//             if outgoing.status.code >= 500 {
//                 try? outgoing.replaceBody(json: ["error": "internal"])
//             }
//             outgoing.addHeader("access-control-allow-origin", "*")
//         }
//         try await next()
//     }
//
// Middleware can already change a response after `next` returns. What it
// cannot see from there is an answer made after it has unwound: the 500 the
// connection gives for a handler that threw past it, or for one that never
// answered. A hook is run at the one point every answer to a route passes
// through -- the handler's own, a middleware's refusal, a thrown error, a 500
// for silence, a deadline's 504 -- once the status, headers and body are
// final and before a byte of the head is written.
//
// Hooks live in the exchange, in an array that stays empty, and unallocated,
// for a request that registers none: the connection pays one emptiness check.
// They run once, the last registered first, so middleware that ran first sees
// the response last, the way layers wrap one another. A hook can be added
// until the head is written; one added after that never runs.
//
// What no route answers does not run them: a 404 or a 405, and a request the
// connection refuses before it is routed (a head too large, a body too long).
//===----------------------------------------------------------------------===//

import GarudaWire

/// Sees the response a request is about to send, and may change it.
public typealias SendHook = (inout OutgoingResponse) -> Void

/// A response on its way out: its status, the headers the handler and
/// middleware added, and its body. The server's own headers -- Date, Server,
/// Content-Length, Connection -- are written after it, from what it ends up
/// as.
public struct OutgoingResponse: ~Copyable {
    let exchange: UnsafeMutablePointer<Exchange>

    init(_ exchange: UnsafeMutablePointer<Exchange>) {
        self.exchange = exchange
    }

    /// What will be sent. A status that forbids a body -- 204, 304 -- sends
    /// none, whatever the body holds.
    public var status: HTTPStatus {
        get { HTTPStatus(exchange.pointee.status) }
        set { exchange.pointee.status = newValue.code }
    }

    // MARK: Headers

    /// The first value of `name`, compared without regard to case, or nil.
    public func header(_ name: String) -> String? {
        var name = name
        return name.withUTF8 { n in
            var found: String? = nil
            exchange.pointee.forEachResponseHeader { key, value in
                if found == nil && sameName(key, n) { found = value.string }
            }
            return found
        }
    }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: StaticString) -> Bool {
        exchange.pointee.addHeader(ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                   ByteSpan(value.utf8Start, value.utf8CodeUnitCount))
    }

    /// Adds a header, as `Response.addHeader` does: false, and nothing added,
    /// for a name that is not a token or a value holding CR, LF or NUL.
    @discardableResult
    public func addHeader(_ name: String, _ value: String) -> Bool {
        Response(exchange).addHeader(name, value)
    }

    /// Removes every header named `name`, compared without regard to case.
    public func removeHeader(_ name: String) {
        var name = name
        name.withUTF8 { exchange.pointee.removeResponseHeaders(named: $0) }
    }

    /// Replaces every header named `name` with this one value.
    @discardableResult
    public func setHeader(_ name: String, _ value: String) -> Bool {
        removeHeader(name)
        return addHeader(name, value)
    }

    // MARK: Body

    /// The body, lent for as long as `body` runs.
    public func withBody<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R {
        exchange.pointee.settleHeldBody()
        let buffer = exchange.pointee.responseBody
        let count = buffer.readableBytes
        // An empty buffer may never have been given storage to point into.
        if count == 0 { return try body(UnsafeBufferPointer<UInt8>(start: nil, count: 0).span) }
        return try body(UnsafeBufferPointer(start: UnsafePointer(buffer.readPointer), count: count).span)
    }

    /// How many bytes the body holds.
    public var bodyCount: Int { exchange.pointee.responseBodyCount }

    /// Sends `bytes` instead of the body, with `contentType` in place of the
    /// content type when one is given. A Content-Length the handler set is
    /// dropped: the server states the new body's length.
    public mutating func replaceBody(_ bytes: [UInt8], contentType: String? = nil) {
        exchange.pointee.bodyReplaced = true
        exchange.pointee.touchedStream = true
        exchange.pointee.heldBody = nil
        exchange.pointee.responseBody.clear()
        bytes.withUnsafeBufferPointer { b in
            if let base = b.baseAddress, b.count > 0 { exchange.pointee.responseBody.write(base, b.count) }
        }
        removeHeader("content-length")
        if let contentType { setHeader("content-type", contentType) }
    }

    public mutating func replaceBody(_ text: String, contentType: String? = nil) {
        replaceBody(Array(text.utf8), contentType: contentType)
    }

    /// Sends `value` as JSON instead of the body.
    public mutating func replaceBody<Value: Encodable>(json value: Value) throws {
        replaceBody(try JSONCoder.encode(value), contentType: "application/json")
    }
}

extension Response {
    /// Runs `hook` just before this request's response is written, whoever
    /// made it: the handler, a middleware refusing the request, the 500 for a
    /// thrown error or the 504 for a deadline. Hooks run once, the last added
    /// first. A hook added once the response head is written never runs.
    public func onSend(_ hook: @escaping SendHook) {
        guard !exchange.pointee.committed else { return }
        exchange.pointee.sendHooks.append(hook)
    }
}

/// Runs the hooks the request registered over its response, the last first,
/// and lets them go. Called by the connection just before it writes the head.
func runSendHooks(_ x: UnsafeMutablePointer<Exchange>) {
    let hooks = x.pointee.sendHooks
    x.pointee.sendHooks = []
    var outgoing = OutgoingResponse(x)
    for hook in hooks.reversed() { hook(&outgoing) }
    // One a hook added while they ran has missed its turn.
    x.pointee.sendHooks = []
}

/// Whether a stored header name, already lower-case, is `name` in any case.
private func sameName(_ stored: ByteSpan, _ name: UnsafeBufferPointer<UInt8>) -> Bool {
    guard stored.count == name.count else { return false }
    var i = 0
    while i < name.count {
        if stored.base[i] != asciiLower(name[i]) { return false }
        i &+= 1
    }
    return true
}

extension Exchange {
    /// Removes every response header named `name`, keeping the rest in
    /// order, and works out again what the ones left say about the response.
    mutating func removeResponseHeaders(named name: UnsafeBufferPointer<UInt8>) {
        let total = responseHeaders.readableBytes
        if total == 0 { return }
        let base = responseHeaders.readPointer
        var read = 0
        var kept = 0
        while read &+ 4 <= total {
            let p = base + read
            let nameLength = Int(p[0]) | Int(p[1]) << 8
            let size = 4 &+ nameLength &+ (Int(p[2]) | Int(p[3]) << 8)
            if !sameName(ByteSpan(UnsafePointer(p + 4), nameLength), name) {
                if kept != read {
                    UnsafeMutableRawPointer(base + kept).copyMemory(from: p, byteCount: size)
                }
                kept &+= size
            }
            read &+= size
        }
        guard kept != read else { return }
        responseHeaders.truncate(to: kept)
        // A removed Date or Server is one the connection writes again, and a
        // removed Content-Type one a kind may set.
        var kinds: ResponseHeaderKind = []
        var contentType = false
        forEachResponseHeader { name, _ in
            kinds.formUnion(HTTPResponseWriter.classify(name))
            if name.count == 12, equalsLowercased(name.base, 12, "content-type") { contentType = true }
        }
        headerKinds = kinds
        hasContentType = contentType
    }
}
