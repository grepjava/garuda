//===----------------------------------------------------------------------===//
// Typed extraction: what a handler asks for, taken from the request.
//
// A typed handler declares its inputs and gets them already decoded:
//
//     app.get("/user/:id") { (id: Path<Int>) in JSON(user(id.value)) }
//
// Extractors run on the worker thread before the handler is called, straight
// from the request's own bytes. A failure is thrown, and because these errors
// conform to `ResponseError` it becomes one consistent 400 saying what was
// wrong, rather than each handler inventing its own.
//===----------------------------------------------------------------------===//

import AvianCore

/// Something a handler can ask for by declaring it as a parameter.
public protocol RequestExtractor {
    /// Takes this value from the request. `parameter` is the index of the next
    /// path parameter not yet claimed; an extractor that reads one advances it.
    static func extract(from request: borrowing Request, parameter: inout Int) throws -> Self
}

/// A path parameter, in the order the pattern declares it: the first `Path` in
/// a handler's parameters takes `:id` in `/user/:id`, the second the next one.
/// Percent-escapes are undone before the value is made.
public struct Path<Value: LosslessStringConvertible>: RequestExtractor {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        let index = parameter
        parameter += 1
        guard index < request.parameterCount else {
            // The route has fewer parameters than the handler asks for, which
            // is the program's mistake and not the client's.
            throw HTTPError(.internalServerError,
                            "the route has no path parameter \(index)")
        }
        let text = percentDecoded(request.parameter(index))
        guard let value = Value(text) else {
            throw ExtractionError.pathNotConvertible(index: index, value: text,
                                                     expected: "\(Value.self)")
        }
        return Path(value)
    }
}

/// The query string, decoded into a type: `?q=swift&page=3&tag=a&tag=b` fills
/// `q`, `page` and a `tag` array. A name that is absent is nil where the type
/// allows it, and missing where it does not.
public struct Query<Value: Decodable>: RequestExtractor {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        let items = request.withQuery { query in
            query.withUnsafeBufferPointer { bytes -> [(name: String, value: String)] in
                guard let base = bytes.baseAddress, bytes.count > 0 else { return [] }
                return QueryString.items(base, bytes.count)
            }
        }
        return Query(try Value(from: QueryDecoding(items: items)))
    }
}

/// The request body, decoded from JSON.
public struct Body<Value: Decodable>: RequestExtractor {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        try request.withBody { bytes in
            guard bytes.count > 0 else { throw ExtractionError.noBody }
            return Body(try JSONCoder.decode(Value.self, from: bytes))
        }
    }
}

/// What extraction itself can find wrong. A body or query that will not decode
/// throws `JSONError` or `QueryError` instead, which say which key is at fault.
public enum ExtractionError: Error, Equatable {
    /// A path parameter that is not the type the handler asked for.
    case pathNotConvertible(index: Int, value: String, expected: String)
    /// A body was needed and the request has none.
    case noBody
}

extension ExtractionError: ResponseError {
    public var status: HTTPStatus { .badRequest }

    public var reason: String? {
        switch self {
        case .pathNotConvertible(let index, let value, let expected):
            return "the path parameter at \(index) is \"\(value)\", which is not \(expected)"
        case .noBody:
            return "the request has no body"
        }
    }
}

/// `%XX` undone. A path keeps `+` as it is: only a query string means a space
/// by it.
func percentDecoded(_ text: String) -> String {
    guard text.utf8.contains(cPercent) else { return text }
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count)
    let bytes = Array(text.utf8)
    var i = 0
    while i < bytes.count {
        if bytes[i] == cPercent, i + 2 < bytes.count {
            let high = hexValue(bytes[i + 1])
            let low = hexValue(bytes[i + 2])
            if high >= 0 && low >= 0 {
                out.append(UInt8(high << 4 | low))
                i += 3
                continue
            }
        }
        out.append(bytes[i])
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

extension Path: Sendable where Value: Sendable {}
extension Query: Sendable where Value: Sendable {}
extension Body: Sendable where Value: Sendable {}
