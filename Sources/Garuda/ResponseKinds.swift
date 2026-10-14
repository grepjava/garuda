//===----------------------------------------------------------------------===//
// Answers with a type: JSON, text, HTML, bytes, a redirect.
//
// Each sets the content type the kind implies, unless the handler set one of
// its own. JSON is encoded with a writer the connection keeps and reuses, so
// answering a request costs no allocation for it after the first.
//===----------------------------------------------------------------------===//

import GarudaWire

extension Response {
    /// Answers with `value` as JSON, and `content-type: application/json`.
    /// Throws what the coder throws: a value that cannot be written, such as
    /// an infinite Double, is the handler's mistake and becomes a 500.
    public func send<T: Encodable>(status: HTTPStatus? = nil, json value: T) throws {
        let x = exchange
        guard !x.pointee.answered else { return }
        let code = (status ?? self.status).code
        let writer: JSONWriter
        if let kept = x.pointee.jsonWriter {
            writer = kept
        } else {
            writer = JSONWriter()
            x.pointee.jsonWriter = writer
        }
        // Encoded before anything is added to the answer, so a value that
        // cannot be written leaves no JSON content type on the error.
        try JSONCoder.encode(value, with: writer) { bytes, count in
            if !x.pointee.hasContentType {
                _ = addHeader("content-type", "application/json")
            }
            x.pointee.answer(code, bytes, count)
        }
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
        guard !exchange.pointee.hasContentType else { return }
        addHeader("content-type", value)
    }

    /// Answers a `ResponseError` with its status, and `{"error":"..."}` when
    /// it says why -- with `"fields"` as well when it knows which fields are
    /// at fault.
    func sendError(status: HTTPStatus, reason: String?, fields: [ValidationProblem] = []) {
        guard let reason else {
            send(status: status)
            return
        }
        // Through the coder, so that a reason holding a quote or a newline is
        // still one JSON string.
        do {
            try send(status: status, json: ErrorBody(error: reason, fields: fields.isEmpty ? nil : fields))
        } catch {
            send(status: status)
        }
    }
}

/// The shape every error answer takes. `fields` is left out entirely when
/// there is nothing to put in it, so an error about the request as a whole
/// answers with the one key it always did.
struct ErrorBody: Codable, Equatable {
    var error: String
    var fields: [ValidationProblem]?
}
