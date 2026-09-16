//===----------------------------------------------------------------------===//
// Seeing a response before it is sent, and changing it.
//
//     app.use { request, response in
//         response.onSend { outgoing in
//             if outgoing.status.code >= 500 {
//                 try? outgoing.replaceBody(json: ["error": "internal"])
//             }
//             outgoing.addHeader("access-control-allow-origin", "*")
//         }
//         return nil
//     }
//
// A handler answers by writing, not by returning a value a middleware could
// wrap, and an async one answers whenever it is done. So a middleware that
// wants the answer leaves a hook on the request instead, and the response
// sink runs it at the one point every answer passes through -- sync or async,
// HTTP/1.1, 2 or 3, the handler's own, a middleware's refusal, a thrown error,
// a 500 for a handler that said nothing, a deadline's 504 -- after the status,
// headers and body are final and before a byte of the head is written.
//
// Hooks live in the request's context, so a request that registers none pays
// one nil check at the sink and allocates nothing. They run once, the last
// registered first: middleware that ran first sees the response last, the way
// layers wrap one another.
//
// What does not pass through the sink does not run them: a static file, a
// response served from --cache-size's copy (which holds what the hooks made),
// and an answer the engine gives before any route is chosen, like a 404.
//===----------------------------------------------------------------------===//

import GarudaCore
import GarudaHTTP

/// Sees the response a request is about to send, and may change it.
public typealias SendHook = (inout OutgoingResponse) -> Void

/// A response on its way out: its status, the headers the handler and
/// middleware added, and its body. The server's own headers -- Date, Server,
/// Content-Length, Connection and the rest -- are written after it, from what
/// it ends up as.
public struct OutgoingResponse: ~Copyable {
    let worker: UnsafeMutablePointer<Worker>
    let slot: Int
    /// What will be sent. A status that forbids a body -- 204, 304 -- sends
    /// none, whatever the body holds.
    public var status: HTTPStatus
    let originalBody: UnsafePointer<UInt8>?
    let originalCount: Int
    /// A body a hook put in place of the original, which it no longer lends.
    var replacement: [UInt8]? = nil
    /// The body is written after the head, as the handler produces it
    /// (`Response.stream`), so the hook sees no body. Replacing the body
    /// sends that instead, whole, and the handler's writes are dropped.
    public let isStreaming: Bool

    init(worker: UnsafeMutablePointer<Worker>, slot: Int, status: HTTPStatus,
         body: UnsafePointer<UInt8>?, count: Int, isStreaming: Bool = false) {
        self.worker = worker
        self.slot = slot
        self.status = status
        originalBody = body
        originalCount = count
        self.isStreaming = isStreaming
    }

    // MARK: Headers

    /// The first value of `name`, compared without regard to case, or nil.
    public func header(_ name: String) -> String? {
        var name = name
        return name.withUTF8 { n in
            var found: String? = nil
            forEachHeaderRecord(worker.pointee.table[slot].pointee.responseHeaders) { key, value in
                if found == nil && sameName(key, n) { found = value.string }
            }
            return found
        }
    }

    @discardableResult
    public func addHeader(_ name: StaticString, _ value: StaticString) -> Bool {
        worker.pointee.addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                         ByteSpan(value.utf8Start, value.utf8CodeUnitCount))
    }

    /// Adds a header, as `Response.addHeader` does: false, and nothing added,
    /// for a name that is not a token or a value holding CR, LF or NUL.
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

    /// Removes every header named `name`, compared without regard to case.
    public func removeHeader(_ name: String) {
        var name = name
        name.withUTF8 { worker.pointee.removeResponseHeaders(slot, named: $0) }
    }

    /// Replaces every header named `name` with this one value.
    @discardableResult
    public func setHeader(_ name: String, _ value: String) -> Bool {
        removeHeader(name)
        return addHeader(name, value)
    }

    // MARK: Body

    /// The body, lent for as long as `body` runs.
    public func withBody<R>(_ body: (Span<UInt8>) throws -> R) rethrows -> R {
        if let replacement {
            return try replacement.withUnsafeBufferPointer { try body($0.span) }
        }
        return try body(UnsafeBufferPointer(start: originalBody, count: originalCount).span)
    }

    /// How many bytes the body holds.
    public var bodyCount: Int { replacement?.count ?? originalCount }

    /// Sends `bytes` instead of the body, with `contentType` in place of the
    /// content type when one is given. A Content-Length the handler set is
    /// dropped: the server states the new body's length.
    public mutating func replaceBody(_ bytes: [UInt8], contentType: String? = nil) {
        replacement = bytes
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

extension Response {
    /// Runs `hook` just before this request's response is sent, whoever sends
    /// it and whenever: the handler, a middleware refusing it, the 500 for a
    /// thrown error or the 504 for a deadline. Hooks run once, the last added
    /// first. A hook added once the response has been sent never runs.
    public func onSend(_ hook: @escaping SendHook) {
        guard isActive else { return }
        worker.pointee.requestContext(slot).sendHooks.append(hook)
    }
}

extension Worker {
    /// The request's context, made now if it has none.
    func requestContext(_ slot: Int) -> RequestContext {
        let c = table[slot]
        if let context = c.pointee.context, context.generation == c.pointee.generation,
           context.requestId == c.pointee.requestId {
            return context
        }
        let context = RequestContext(generation: c.pointee.generation,
                                     requestId: c.pointee.requestId)
        c.pointee.context = context
        return context
    }

    /// The hooks the request on `slot` is waiting to run, taken so they run
    /// once, or nil when it has none.
    @inline(__always)
    func takeSendHooks(_ slot: Int) -> [SendHook]? {
        let c = table[slot]
        guard let context = c.pointee.context, !context.sendHooks.isEmpty,
              context.generation == c.pointee.generation,
              context.requestId == c.pointee.requestId else { return nil }
        let hooks = context.sendHooks
        context.sendHooks = []
        return hooks
    }

    /// Runs `hooks` over the response, then sends what they leave.
    mutating func respond(_ slot: Int, through hooks: [SendHook], status: Int,
                          _ body: UnsafePointer<UInt8>?, _ count: Int, streaming: Bool = false) {
        withUnsafeMutablePointer(to: &self) { worker in
            var outgoing = OutgoingResponse(worker: worker, slot: slot, status: HTTPStatus(status),
                                            body: body, count: count, isStreaming: streaming)
            for hook in hooks.reversed() { hook(&outgoing) }
            let code = outgoing.status.code
            if let replacement = outgoing.replacement {
                // A hook that gives a streamed response a body of its own has
                // answered in its place, and the handler's writes go nowhere.
                replacement.withUnsafeBufferPointer {
                    worker.pointee.respond(slot, status: code, $0.baseAddress, $0.count)
                }
            } else {
                worker.pointee.respond(slot, status: code, body, count, streaming: streaming)
            }
        }
    }

    /// Removes every response header named `name`, keeping the rest in order.
    func removeResponseHeaders(_ slot: Int, named name: UnsafeBufferPointer<UInt8>) {
        let c = table[slot]
        let records = UnsafeMutablePointer(mutating: c).pointer(to: \.responseHeaders)!
        let total = records.pointee.readableBytes
        if total == 0 { return }
        let base = records.pointee.readPointer
        var read = 0
        var kept = 0
        while read &+ 4 <= total {
            let p = base + read
            let nameLength = Int(p[0]) | Int(p[1]) << 8
            let size = 4 &+ nameLength &+ (Int(p[2]) | Int(p[3]) << 8)
            if !sameName(ByteSpan(p + 4, nameLength), name) {
                if kept != read {
                    UnsafeMutableRawPointer(base + kept).copyMemory(from: p, byteCount: size)
                }
                kept &+= size
            }
            read &+= size
        }
        records.pointee.truncate(to: kept)
    }
}
