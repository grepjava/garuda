//===----------------------------------------------------------------------===//
// A status as a type rather than a number.
//
// `response.send(status: .notFound)` says what 404 is, and a test reads
// `response.status == .ok`. It is still an integer underneath, and takes an
// integer literal, so a status the list below does not name -- or one an
// application invents -- is written as the number it is.
//===----------------------------------------------------------------------===//

public struct HTTPStatus: Equatable, Hashable, Sendable,
                          ExpressibleByIntegerLiteral, CustomStringConvertible {
    public let code: Int

    public init(_ code: Int) {
        self.code = code
    }

    public init(integerLiteral value: Int) {
        code = value
    }

    /// 1xx: the response before the response.
    public var isInformational: Bool { code >= 100 && code < 200 }
    /// 2xx.
    public var isSuccess: Bool { code >= 200 && code < 300 }
    /// 3xx.
    public var isRedirect: Bool { code >= 300 && code < 400 }
    /// 4xx: the client's mistake.
    public var isClientError: Bool { code >= 400 && code < 500 }
    /// 5xx: ours.
    public var isServerError: Bool { code >= 500 && code < 600 }

    public var description: String { String(code) }

    public static let `continue` = HTTPStatus(100)
    public static let switchingProtocols = HTTPStatus(101)

    public static let ok = HTTPStatus(200)
    public static let created = HTTPStatus(201)
    public static let accepted = HTTPStatus(202)
    public static let noContent = HTTPStatus(204)
    public static let partialContent = HTTPStatus(206)

    public static let movedPermanently = HTTPStatus(301)
    public static let found = HTTPStatus(302)
    public static let seeOther = HTTPStatus(303)
    public static let notModified = HTTPStatus(304)
    public static let temporaryRedirect = HTTPStatus(307)
    public static let permanentRedirect = HTTPStatus(308)

    public static let badRequest = HTTPStatus(400)
    public static let unauthorized = HTTPStatus(401)
    public static let paymentRequired = HTTPStatus(402)
    public static let forbidden = HTTPStatus(403)
    public static let notFound = HTTPStatus(404)
    public static let methodNotAllowed = HTTPStatus(405)
    public static let notAcceptable = HTTPStatus(406)
    public static let requestTimeout = HTTPStatus(408)
    public static let conflict = HTTPStatus(409)
    public static let gone = HTTPStatus(410)
    public static let lengthRequired = HTTPStatus(411)
    public static let preconditionFailed = HTTPStatus(412)
    public static let contentTooLarge = HTTPStatus(413)
    public static let uriTooLong = HTTPStatus(414)
    public static let unsupportedMediaType = HTTPStatus(415)
    public static let rangeNotSatisfiable = HTTPStatus(416)
    public static let expectationFailed = HTTPStatus(417)
    public static let unprocessableContent = HTTPStatus(422)
    public static let tooManyRequests = HTTPStatus(429)
    public static let requestHeaderFieldsTooLarge = HTTPStatus(431)

    public static let internalServerError = HTTPStatus(500)
    public static let notImplemented = HTTPStatus(501)
    public static let badGateway = HTTPStatus(502)
    public static let serviceUnavailable = HTTPStatus(503)
    public static let gatewayTimeout = HTTPStatus(504)
    public static let httpVersionNotSupported = HTTPStatus(505)
}
