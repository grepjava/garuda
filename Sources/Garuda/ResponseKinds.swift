//===----------------------------------------------------------------------===//
// Answers with a type: JSON, text, HTML, bytes, a redirect.
//
// Each sets the content type the kind implies, unless the handler set one of
// its own, and then goes through the same response sink as everything else.
// JSON is encoded into a buffer the worker keeps and reuses, so answering a
// request costs no allocation for the buffer after the first.
//===----------------------------------------------------------------------===//

import AvianCore

extension Response {
    /// Answers with `value` as JSON, and `content-type: application/json`.
    /// Throws what the coder throws: a value that cannot be written, such as
    /// an infinite Double, is the handler's mistake and becomes a 500.
    public func send<T: Encodable>(status: HTTPStatus? = nil, json value: T) throws {
        guard isActive else { return }
        try worker.pointee.respond(slot, status: (status ?? self.status).code, json: value)
    }

    /// Answers with `body` as `text/plain; charset=utf-8`.
    public func send(status: HTTPStatus? = nil, text body: String) {
        setContentTypeIfUnset("text/plain; charset=utf-8")
        send(status: status, body)
    }

    /// Answers with `body` as `text/html; charset=utf-8`. The bytes are sent
    /// as they are: whatever escaping the page needs is the caller's.
    public func send(status: HTTPStatus? = nil, html body: String) {
        setContentTypeIfUnset("text/html; charset=utf-8")
        send(status: status, body)
    }

    /// Answers with bytes, and the content type they are.
    public func send(status: HTTPStatus? = nil, bytes body: [UInt8], contentType: StaticString) {
        setContentTypeIfUnset(contentType)
        send(status: status, body)
    }

    /// Answers with bytes lent by the request, and the content type they are.
    public func send(status: HTTPStatus? = nil, bytes body: Span<UInt8>, contentType: StaticString) {
        setContentTypeIfUnset(contentType)
        send(status: status, body)
    }

    /// Sends a redirect to `location`. 302 by default: 301 and 308 are
    /// remembered by clients and proxies, so they are asked for by name.
    public func redirect(to location: String, status: HTTPStatus = .found) {
        addHeader("location", location)
        send(status: status)
    }

    /// The content type this kind of answer implies, unless the handler has
    /// already said what it is sending.
    private func setContentTypeIfUnset(_ value: StaticString) {
        guard !worker.pointee.hasContentType(slot) else { return }
        addHeader("content-type", value)
    }
}

extension Worker {
    /// Whether the handler has set a content type of its own.
    func hasContentType(_ slot: Int) -> Bool {
        var found = false
        forEachHeaderRecord(table[slot].pointee.responseHeaders) { name, _ in
            if name.count == 12 && equalsLowercased(name.base, 12, "content-type") { found = true }
        }
        return found
    }

    /// Encodes `value` into the worker's own buffer and answers with it.
    mutating func respond(_ slot: Int, status: Int, json value: some Encodable) throws {
        jsonScratch.clear()
        try JSONCoder.encode(value, into: &jsonScratch)
        if !hasContentType(slot) {
            let name: StaticString = "content-type"
            let type: StaticString = "application/json"
            _ = addResponseHeader(slot, ByteSpan(name.utf8Start, name.utf8CodeUnitCount),
                                  ByteSpan(type.utf8Start, type.utf8CodeUnitCount))
        }
        let count = jsonScratch.readableBytes
        respond(slot, status: status, count > 0 ? UnsafePointer(jsonScratch.readPointer) : nil, count)
    }

    /// Answers a `ResponseError` with its status, and `{"error":"..."}` when
    /// it says why.
    mutating func respondError(_ slot: Int, status: HTTPStatus, reason: String?) {
        guard let reason else {
            respond(slot, status: status.code, nil, 0)
            return
        }
        // Through the coder, so that a reason holding a quote or a newline is
        // still one JSON string.
        do {
            try respond(slot, status: status.code, json: ErrorBody(error: reason))
        } catch {
            respond(slot, status: status.code, nil, 0)
        }
    }
}

/// The shape every error answer takes.
struct ErrorBody: Encodable {
    var error: String
}
