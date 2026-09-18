//===----------------------------------------------------------------------===//
// Errors that are answers.
//
// A handler that throws something conforming to `ResponseError` answers with
// that status and reason; anything else is a 500 and a line in the log, since
// an error the application did not plan for is not something to describe to
// whoever is on the other end.
//
// The body is JSON -- `{"error":"..."}` -- because the typed API is JSON
// first. A handler wanting another shape catches its own error and sends it.
//
// An error that knows which field is at fault says so in `fields`, and the
// body gains `"fields":[{"field":"email","message":"is missing"}]`. Decoding
// failures and validation both fill it, so a form can put every message where
// it belongs from one answer, whichever of the two refused it. An error with
// nothing to add there -- most of them -- answers as it always did.
//===----------------------------------------------------------------------===//

/// An error a handler can throw that becomes the response.
public protocol ResponseError: Error {
    /// The status to answer with.
    var status: HTTPStatus { get }
    /// What to tell the client, or nil to answer with no body.
    var reason: String? { get }
    /// Which fields are at fault, when the error knows. Empty for an error
    /// about the request as a whole, which is most of them.
    var fields: [ValidationProblem] { get }
}

extension ResponseError {
    public var fields: [ValidationProblem] { [] }
}

/// The ordinary way to fail a request: a status, and optionally why.
public struct HTTPError: ResponseError, Equatable, Hashable, Sendable {
    public var status: HTTPStatus
    public var reason: String?

    public init(_ status: HTTPStatus, _ reason: String? = nil) {
        self.status = status
        self.reason = reason
    }

    public static let badRequest = HTTPError(.badRequest)
    public static let unauthorized = HTTPError(.unauthorized)
    public static let forbidden = HTTPError(.forbidden)
    public static let notFound = HTTPError(.notFound)
    public static let methodNotAllowed = HTTPError(.methodNotAllowed)
    public static let conflict = HTTPError(.conflict)
    public static let gone = HTTPError(.gone)
    public static let contentTooLarge = HTTPError(.contentTooLarge)
    public static let unsupportedMediaType = HTTPError(.unsupportedMediaType)
    public static let unprocessableContent = HTTPError(.unprocessableContent)
    public static let tooManyRequests = HTTPError(.tooManyRequests)
    public static let internalServerError = HTTPError(.internalServerError)
    public static let serviceUnavailable = HTTPError(.serviceUnavailable)

    public static func badRequest(_ reason: String) -> HTTPError {
        HTTPError(.badRequest, reason)
    }

    public static func unauthorized(_ reason: String) -> HTTPError {
        HTTPError(.unauthorized, reason)
    }

    public static func forbidden(_ reason: String) -> HTTPError {
        HTTPError(.forbidden, reason)
    }

    public static func notFound(_ reason: String) -> HTTPError {
        HTTPError(.notFound, reason)
    }

    public static func conflict(_ reason: String) -> HTTPError {
        HTTPError(.conflict, reason)
    }

    public static func unprocessableContent(_ reason: String) -> HTTPError {
        HTTPError(.unprocessableContent, reason)
    }
}

/// A body that is not what it said it was is the client's mistake, so a
/// decoding failure answers 400 wherever it happens -- a handler decoding by
/// hand, or the typed extraction built on it.
extension JSONError: ResponseError {
    public var status: HTTPStatus { .badRequest }

    public var reason: String? {
        switch self {
        case .syntax(let offset):
            return "the body is not JSON, at byte \(offset)"
        case .depthExceeded(let offset):
            return "the body nests deeper than \(JSONCoder.depthLimit), at byte \(offset)"
        case .trailingBytes(let offset):
            return "the body has more after the JSON value, at byte \(offset)"
        case .typeMismatch(let path, let expected):
            return path.isEmpty ? "the body is not \(expected)"
                                : "\(path) is not \(expected)"
        case .missingKey(let path):
            return "\(path) is missing"
        case .valueNotFound(let path, let expected):
            return path.isEmpty ? "\(expected) was expected and the value is null"
                                : "\(path) is null, and \(expected) was expected"
        case .numberOutOfRange(let path):
            return path.isEmpty ? "the number does not fit" : "\(path) does not fit"
        case .invalidValue(let path, let why):
            return path.isEmpty ? why : "\(path): \(why)"
        }
    }

    /// The field at fault, where the failure is about one. The path is the one
    /// the decoder reports -- `items[0].sku` -- which is the name the form
    /// that sent it has for the same place.
    public var fields: [ValidationProblem] {
        switch self {
        case .syntax, .depthExceeded, .trailingBytes:
            // About the bytes, not about a field: there is no path to give.
            return []
        case .typeMismatch(let path, let expected):
            return JSONError.at(path, "is not \(expected)")
        case .missingKey(let path):
            return JSONError.at(path, "is missing")
        case .valueNotFound(let path, let expected):
            return JSONError.at(path, "is null, and \(expected) was expected")
        case .numberOutOfRange(let path):
            return JSONError.at(path, "does not fit")
        case .invalidValue(let path, let why):
            return JSONError.at(path, why)
        }
    }

    private static func at(_ path: String, _ message: String) -> [ValidationProblem] {
        path.isEmpty ? [] : [ValidationProblem(field: path, message: message)]
    }
}
