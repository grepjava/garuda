//===----------------------------------------------------------------------===//
// What a typed handler may return.
//
// A handler that takes extractors returns a value rather than writing a
// response: `JSON(user)`, `HTML(page)`, a `String`, a status, a redirect. The
// engine writes it through the same response sink as everything else, so the
// framing, the server's headers and the content length are unchanged.
//
// `nil` is a 404: a handler whose answer is optional is saying "if there is
// one", and the absence is the ordinary not-found rather than a crash.
//===----------------------------------------------------------------------===//

/// A value that can be the whole response.
public protocol ResponseConvertible {
    func write(to response: borrowing Response) throws
}

/// A value sent as JSON.
public struct JSON<Value: Encodable>: ResponseConvertible {
    public var value: Value
    public var status: HTTPStatus?

    public init(_ value: Value, status: HTTPStatus? = nil) {
        self.value = value
        self.status = status
    }

    public func write(to response: borrowing Response) throws {
        try response.send(status: status, json: value)
    }
}

/// Markup sent as `text/html`. Whatever escaping the page needs is the
/// caller's: this does not touch the bytes.
public struct HTML: ResponseConvertible {
    public var markup: String
    public var status: HTTPStatus?

    public init(_ markup: String, status: HTTPStatus? = nil) {
        self.markup = markup
        self.status = status
    }

    public func write(to response: borrowing Response) throws {
        response.send(status: status, html: markup)
    }
}

/// Text sent as `text/plain`, when the status is not the default. A plain
/// `String` returned from a handler is the same thing with a 200.
public struct Text: ResponseConvertible {
    public var text: String
    public var status: HTTPStatus?

    public init(_ text: String, status: HTTPStatus? = nil) {
        self.text = text
        self.status = status
    }

    public func write(to response: borrowing Response) throws {
        response.send(status: status, text: text)
    }
}

/// Bytes, and what they are.
public struct Bytes: ResponseConvertible {
    public var bytes: [UInt8]
    public var contentType: StaticString
    public var status: HTTPStatus?

    public init(_ bytes: [UInt8], contentType: StaticString = "application/octet-stream",
                status: HTTPStatus? = nil) {
        self.bytes = bytes
        self.contentType = contentType
        self.status = status
    }

    public func write(to response: borrowing Response) throws {
        response.send(status: status, bytes: bytes, contentType: contentType)
    }
}

/// A redirect. 302 unless another is asked for, since 301 and 308 are
/// remembered by clients and proxies.
public struct Redirect: ResponseConvertible {
    public var location: String
    public var status: HTTPStatus

    public init(to location: String, status: HTTPStatus = .found) {
        self.location = location
        self.status = status
    }

    public func write(to response: borrowing Response) throws {
        response.redirect(to: location, status: status)
    }
}

extension String: ResponseConvertible {
    public func write(to response: borrowing Response) throws {
        response.send(text: self)
    }
}

extension HTTPStatus: ResponseConvertible {
    public func write(to response: borrowing Response) throws {
        response.send(status: self)
    }
}

extension Optional: ResponseConvertible where Wrapped: ResponseConvertible {
    public func write(to response: borrowing Response) throws {
        guard let self else { throw HTTPError.notFound }
        try self.write(to: response)
    }
}
