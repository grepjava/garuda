//===----------------------------------------------------------------------===//
// Form bodies.
//
// `application/x-www-form-urlencoded` is a query string in the body, so it
// decodes through the same reader: names and values percent-decoded, `+` a
// space, a repeated name a list, an absent one nil where the type allows it.
//
//     app.post("/login") { (form: Form<Credentials>) in ... }
//
// A body sent as something else is a 415 rather than a 400: the client sent a
// kind of document this route does not take, which is not the same as sending
// a malformed one.
//===----------------------------------------------------------------------===//

import AvianCore

/// A `application/x-www-form-urlencoded` body, decoded into a type.
public struct Form<Value: Decodable>: RequestExtractor {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        let contentType = request.header("content-type") ?? ""
        guard mediaType(of: contentType) == "application/x-www-form-urlencoded" else {
            throw FormError.wrongContentType(contentType)
        }
        let items = request.withBody { body in
            body.withUnsafeBufferPointer { bytes -> [(name: String, value: String)] in
                guard let base = bytes.baseAddress, bytes.count > 0 else { return [] }
                return QueryString.items(base, bytes.count)
            }
        }
        let value = try Value(from: QueryDecoding(items: items))
        try Validation.check(value)
        return Form(value)
    }
}

/// What a form body can be wrong about before it is even decoded.
public enum FormError: Error, Equatable {
    /// The body is not the kind this route takes.
    case wrongContentType(String)
}

extension FormError: ResponseError {
    public var status: HTTPStatus { .unsupportedMediaType }

    public var reason: String? {
        switch self {
        case .wrongContentType(let given):
            let what = given.isEmpty ? "no content type" : "\"\(given)\""
            return "this route takes application/x-www-form-urlencoded, and the body has \(what)"
        }
    }
}

/// The media type alone, lowercased: `text/plain; charset=utf-8` is
/// `text/plain`.
func mediaType(of contentType: String) -> String {
    let head = contentType.prefix { $0 != ";" }
    return head.trimmingASCIISpace().lowercased()
}

extension Substring {
    /// Without leading and trailing spaces and tabs.
    func trimmingASCIISpace() -> Substring {
        var slice = self
        while let first = slice.first, first == " " || first == "\t" { slice = slice.dropFirst() }
        while let last = slice.last, last == " " || last == "\t" { slice = slice.dropLast() }
        return slice
    }
}
