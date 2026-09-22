//===----------------------------------------------------------------------===//
// multipart/form-data bodies.
//
//     app.post("/upload") { (form: Multipart) in
//         guard let file = form.file("avatar") else { throw HTTPError.badRequest }
//         ...
//     }
//
// The body has already been read whole by the engine, up to `--max-body`, so
// this is a parse over bytes it holds rather than a stream: the parts are cut
// out of the buffer and copied, because a handler keeps them past its request.
// Streaming uploads are a later step; until then the body limit is what bounds
// the work here, along with a cap on how many parts one body may have.
//===----------------------------------------------------------------------===//

import AvianCore

/// One part of a multipart body.
public struct MultipartPart: Equatable, Sendable {
    /// The form field's name, from `Content-Disposition`.
    public var name: String
    /// The client's name for an uploaded file, when it sent one.
    public var filename: String?
    /// The part's own content type, when it declared one.
    public var contentType: String?
    /// The part's bytes, copied out of the request.
    public var bytes: [UInt8]

    /// The bytes as text, with invalid UTF-8 repaired.
    public var text: String { String(decoding: bytes, as: UTF8.self) }

    /// Whether the client sent this part as a file.
    public var isFile: Bool { filename != nil }
}

/// A `multipart/form-data` body, in the order the client sent it.
public struct Multipart: RequestExtractor {
    /// How many parts one body may hold before it is refused.
    public static let partLimit = 1_000

    public var parts: [MultipartPart]

    public init(parts: [MultipartPart]) {
        self.parts = parts
    }

    /// The first part with this name.
    public subscript(name: String) -> MultipartPart? {
        parts.first { $0.name == name }
    }

    /// Every part with this name, in order, for a field that repeats.
    public func all(_ name: String) -> [MultipartPart] {
        parts.filter { $0.name == name }
    }

    /// The text of the first part with this name.
    public func text(_ name: String) -> String? {
        self[name]?.text
    }

    /// The first uploaded file with this name.
    public func file(_ name: String) -> MultipartPart? {
        parts.first { $0.name == name && $0.isFile }
    }

    public static func extract(from request: borrowing Request,
                               parameter: inout Int) throws -> Self {
        let contentType = request.header("content-type") ?? ""
        guard mediaType(of: contentType) == "multipart/form-data" else {
            throw MultipartError.wrongContentType(contentType)
        }
        guard let boundary = boundary(of: contentType), !boundary.isEmpty else {
            throw MultipartError.noBoundary
        }
        let parts = try request.withBody { body in
            try body.withUnsafeBufferPointer { bytes -> [MultipartPart] in
                guard let base = bytes.baseAddress, bytes.count > 0 else {
                    throw MultipartError.malformed("the body is empty")
                }
                return try MultipartParser.parse(base, bytes.count, boundary: Array(boundary.utf8))
            }
        }
        return Multipart(parts: parts)
    }

    /// The `boundary=` parameter of a content type, quoted or not.
    static func boundary(of contentType: String) -> String? {
        var rest = Substring(contentType)
        while let semicolon = rest.firstIndex(of: ";") {
            rest = rest[rest.index(after: semicolon)...]
            let parameter = rest.prefix { $0 != ";" }
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<equals].trimmingASCIISpace().lowercased()
            guard name == "boundary" else { continue }
            var value = parameter[parameter.index(after: equals)...].trimmingASCIISpace()
            if value.first == "\"" && value.last == "\"" && value.count >= 2 {
                value = value.dropFirst().dropLast()
            }
            return String(value)
        }
        return nil
    }
}

/// What a multipart body can be wrong about.
public enum MultipartError: Error, Equatable {
    /// The body is not the kind this route takes.
    case wrongContentType(String)
    /// `multipart/form-data` with no `boundary` parameter.
    case noBoundary
    /// The body does not hold the parts its boundary promises.
    case malformed(String)
    /// More parts than `Multipart.partLimit`.
    case tooManyParts(limit: Int)
}

extension MultipartError: ResponseError {
    public var status: HTTPStatus {
        switch self {
        case .wrongContentType: return .unsupportedMediaType
        case .noBoundary, .malformed, .tooManyParts: return .badRequest
        }
    }

    public var reason: String? {
        switch self {
        case .wrongContentType(let given):
            let what = given.isEmpty ? "no content type" : "\"\(given)\""
            return "this route takes multipart/form-data, and the body has \(what)"
        case .noBoundary:
            return "the content type is multipart/form-data with no boundary"
        case .malformed(let why):
            return "the multipart body is malformed: \(why)"
        case .tooManyParts(let limit):
            return "the multipart body has more than \(limit) parts"
        }
    }
}

enum MultipartParser {
    /// Cuts a multipart body into its parts. Everything before the first
    /// boundary and after the closing one is preamble and epilogue, which RFC
    /// 2046 says to ignore.
    static func parse(_ base: UnsafePointer<UInt8>, _ count: Int,
                      boundary: [UInt8]) throws -> [MultipartPart] {
        // The delimiter as it appears in the body: "--" and the boundary.
        var delimiter: [UInt8] = [0x2D, 0x2D]
        delimiter.append(contentsOf: boundary)

        guard var at = findDelimiter(base, count, delimiter, from: 0) else {
            throw MultipartError.malformed("no boundary in the body")
        }
        var parts: [MultipartPart] = []
        while true {
            at += delimiter.count
            // "--" after the delimiter closes the body.
            if at + 1 < count && base[at] == 0x2D && base[at + 1] == 0x2D { return parts }
            // The delimiter is followed by CRLF, and by nothing else.
            guard at + 1 < count, base[at] == cCR, base[at + 1] == cLF else {
                throw MultipartError.malformed("a boundary is not followed by a line ending")
            }
            at += 2
            guard let headersEnd = findHeadersEnd(base, count, from: at) else {
                throw MultipartError.malformed("a part has no end to its headers")
            }
            let header = try headers(base, from: at, to: headersEnd)
            let bodyStart = headersEnd + 4
            guard let next = findDelimiter(base, count, delimiter, from: bodyStart) else {
                throw MultipartError.malformed("a part has no closing boundary")
            }
            // The CRLF before the delimiter belongs to the framing, not the part.
            var bodyEnd = next
            if bodyEnd >= bodyStart + 2 && base[bodyEnd - 2] == cCR && base[bodyEnd - 1] == cLF {
                bodyEnd -= 2
            }
            guard parts.count < Multipart.partLimit else {
                throw MultipartError.tooManyParts(limit: Multipart.partLimit)
            }
            guard let name = header.name else {
                throw MultipartError.malformed("a part has no name")
            }
            parts.append(MultipartPart(
                name: name, filename: header.filename, contentType: header.contentType,
                bytes: Array(UnsafeBufferPointer(start: base + bodyStart,
                                                 count: bodyEnd - bodyStart))))
            at = next
        }
    }

    /// Where the blank line ending a part's headers begins, or nil.
    private static func findHeadersEnd(_ base: UnsafePointer<UInt8>, _ count: Int,
                                       from start: Int) -> Int? {
        var i = start
        while i + 3 < count {
            if base[i] == cCR && base[i + 1] == cLF && base[i + 2] == cCR && base[i + 3] == cLF {
                return i
            }
            i += 1
        }
        return nil
    }

    private struct PartHeader {
        var name: String?
        var filename: String?
        var contentType: String?
    }

    /// The part's `Content-Disposition` and `Content-Type`.
    private static func headers(_ base: UnsafePointer<UInt8>, from start: Int,
                                to end: Int) throws -> PartHeader {
        var header = PartHeader()
        var lineStart = start
        while lineStart < end {
            var lineEnd = lineStart
            while lineEnd < end && base[lineEnd] != cCR { lineEnd += 1 }
            let line = String(decoding: UnsafeBufferPointer(start: base + lineStart,
                                                            count: lineEnd - lineStart),
                              as: UTF8.self)
            if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].trimmingASCIISpace().lowercased()
                let value = line[line.index(after: colon)...].trimmingASCIISpace()
                switch name {
                case "content-disposition":
                    header.name = parameter("name", in: value)
                    header.filename = parameter("filename", in: value)
                case "content-type":
                    header.contentType = String(value)
                default:
                    break
                }
            }
            lineStart = lineEnd + 2
        }
        return header
    }

    /// A `name="value"` parameter of a header, quoted or not.
    private static func parameter(_ wanted: String, in value: Substring) -> String? {
        var rest = value
        while let semicolon = rest.firstIndex(of: ";") {
            rest = rest[rest.index(after: semicolon)...]
            let parameter = rest.prefix { $0 != ";" }
            guard let equals = parameter.firstIndex(of: "=") else { continue }
            let name = parameter[..<equals].trimmingASCIISpace().lowercased()
            guard name == wanted else { continue }
            var text = parameter[parameter.index(after: equals)...].trimmingASCIISpace()
            if text.first == "\"" && text.last == "\"" && text.count >= 2 {
                text = text.dropFirst().dropLast()
            }
            return String(text)
        }
        return nil
    }

    /// Where a boundary delimiter that frames a line next appears at or after
    /// `from`. RFC 2046 gives the delimiter a line of its own: one that does
    /// not begin the body follows a CRLF, and every one is followed either by
    /// a line ending or by the `--` that closes the body. The same bytes
    /// mid-line inside a part's content meet neither test, and are content: a
    /// file that happens to hold `--boundary--` within a line is stored whole
    /// rather than cut there. Content carrying the framing as well is the same
    /// bytes in the same place as a real delimiter, so it does end the part:
    /// framing alone cannot tell the two apart, which is why RFC 2046 puts
    /// choosing a boundary absent from the content on the sender.
    private static func findDelimiter(_ base: UnsafePointer<UInt8>, _ count: Int,
                                      _ delimiter: [UInt8], from: Int) -> Int? {
        var at = from
        while let i = find(base, count, delimiter, from: at) {
            let opensLine = i == 0 || (i >= 2 && base[i - 2] == cCR && base[i - 1] == cLF)
            let end = i + delimiter.count
            let closesLine = end + 1 < count
                && ((base[end] == 0x2D && base[end + 1] == 0x2D)
                    || (base[end] == cCR && base[end + 1] == cLF))
            if opensLine && closesLine { return i }
            at = i + 1
        }
        return nil
    }

    /// Where `needle` next appears at or after `from`.
    private static func find(_ base: UnsafePointer<UInt8>, _ count: Int,
                             _ needle: [UInt8], from: Int) -> Int? {
        guard !needle.isEmpty, count >= needle.count else { return nil }
        let last = count - needle.count
        var i = from
        while i <= last {
            if base[i] == needle[0] {
                var k = 1
                while k < needle.count && base[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}
