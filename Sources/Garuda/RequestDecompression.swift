//===----------------------------------------------------------------------===//
// Request bodies a client compressed.
//
//     app.group("/ingest") {
//         app.requestDecompression()
//         app.post("/events") { (events: Body<[Event]>) in … }
//     }
//
// A middleware in the scope it is called in. A request whose Content-Encoding
// names gzip, deflate, br or zstd has its body decoded before the middleware
// after it and the handler read it, so `request.body`, `Body` and `Form` see
// what the client meant. The Content-Encoding and Content-Length headers are
// left as they arrived.
//
// The decoded body is held to the route's body limit -- `app.maxBodySize`,
// or --max-body -- as it grows, so a few kilobytes that would inflate to
// gigabytes stop at the limit with 413. A coding this process cannot decode
// is 415 with Accept-Encoding saying which it can (RFC 9110 section
// 15.5.16), and bytes that are not what the coding makes are 400.
//===----------------------------------------------------------------------===//

import CVegaCompress
import GarudaWire

extension RouteBuilder {
    /// Decodes the compressed request bodies of the routes in the current
    /// scope before their handlers read them.
    public func requestDecompression() {
        use { request, response, next in
            if let coding = request.header("content-encoding") {
                try decodeRequestBody(request.exchange, contentEncoding: coding, response: response)
            }
            try await next()
        }
    }
}

/// Replaces the request's body with what `contentEncoding` decodes it to.
func decodeRequestBody(_ x: UnsafeMutablePointer<Exchange>, contentEncoding: String,
                       response: borrowing Response) throws {
    guard RequestDecoder.canDecode(contentEncoding) else {
        response.addHeader("accept-encoding", RequestDecoder.acceptEncoding)
        throw HTTPError(.unsupportedMediaType, "a Content-Encoding this server cannot decode")
    }
    let count = x.pointee.bodyCount
    guard count > 0, let body = x.pointee.body else { return }
    let compressed = [UInt8](UnsafeBufferPointer(start: body, count: count))
    let decoded: [UInt8]
    do {
        decoded = try RequestDecoder.decode(compressed, contentEncoding: contentEncoding, limit: x.pointee.bodyLimit)
    } catch .tooLarge {
        throw HTTPError(.contentTooLarge)
    } catch {
        throw HTTPError(.badRequest, "a body that does not decode as its Content-Encoding says")
    }
    // The body was read already, framing and all: only where the handler
    // finds it changes.
    x.pointee.decodedBody.clear()
    decoded.withUnsafeBufferPointer { bytes in
        if let base = bytes.baseAddress { x.pointee.decodedBody.write(base, bytes.count) }
    }
    x.pointee.body = decoded.isEmpty ? nil : UnsafePointer(x.pointee.decodedBody.readPointer)
    x.pointee.bodyCount = decoded.count
}

/// Undoing a body's content codings, last applied first, with the decoded
/// size held to a limit as it grows.
enum RequestDecoder {
    enum Failure: Error, Equatable {
        case unsupported
        /// Bytes that are not what the coding produces, or a stream that
        /// stops before its end.
        case invalid
        /// The decoded body would be larger than the limit.
        case tooLarge
    }

    /// The codings this process can decode, for an Accept-Encoding header:
    /// gzip and deflate always, brotli and zstd when their libraries load.
    static var acceptEncoding: String {
        var codings: [String] = []
        if cv_dec_available(CV_CODEC_ZSTD) == 1 { codings.append("zstd") }
        if cv_dec_available(CV_CODEC_BR) == 1 { codings.append("br") }
        codings.append("gzip")
        codings.append("deflate")
        return codings.joined(separator: ", ")
    }

    /// Whether `contentEncoding` names only codings this process can decode.
    static func canDecode(_ contentEncoding: String) -> Bool {
        codings(contentEncoding).allSatisfy { codec($0) != nil }
    }

    static func decode(_ body: [UInt8], contentEncoding: String, limit: Int) throws(Failure) -> [UInt8] {
        var bytes = body
        for coding in codings(contentEncoding).reversed() {
            guard let codec = codec(coding) else { throw .unsupported }
            bytes = try decode(bytes, codec: codec, limit: limit)
        }
        return bytes
    }

    /// The codings named, lower-cased, without `identity`.
    static func codings(_ header: String) -> [String] {
        header.split(separator: ",").compactMap { part in
            var coding = Substring(part)
            while let first = coding.first, first == " " || first == "\t" { coding.removeFirst() }
            while let last = coding.last, last == " " || last == "\t" { coding.removeLast() }
            let name = coding.lowercased()
            return name.isEmpty || name == "identity" ? nil : name
        }
    }

    static func codec(_ coding: String) -> Int32? {
        let number: Int32
        switch coding {
        case "gzip", "x-gzip": number = CV_CODEC_GZIP
        case "deflate": number = CV_CODEC_DEFLATE
        case "br": number = CV_CODEC_BR
        case "zstd": number = CV_CODEC_ZSTD
        default: return nil
        }
        return cv_dec_available(number) == 1 ? number : nil
    }

    static func decode(_ input: [UInt8], codec: Int32, limit: Int) throws(Failure) -> [UInt8] {
        guard let decoder = cv_dec_new(codec) else { throw .unsupported }
        defer { cv_dec_free(decoder) }
        var output: [UInt8] = []
        output.reserveCapacity(min(limit, max(1024, input.count * 4)))
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        var offset = 0
        while true {
            var consumed = 0
            var produced = 0
            let rc = input.withUnsafeBufferPointer { inBuffer in
                chunk.withUnsafeMutableBufferPointer { out in
                    cv_dec_run(decoder, inBuffer.baseAddress.map { $0 + offset }, inBuffer.count - offset,
                               out.baseAddress, out.count, &consumed, &produced)
                }
            }
            offset += consumed
            if produced > 0 {
                guard output.count + produced <= limit else { throw .tooLarge }
                output.append(contentsOf: chunk[0..<produced])
            }
            switch rc {
            case 2:
                // Bytes after the end are not part of any coding named.
                guard offset == input.count else { throw .invalid }
                return output
            case 1:
                continue
            case 0:
                // No progress with the stream not over: it was cut short.
                if consumed == 0 && produced == 0 { throw .invalid }
            default:
                throw .invalid
            }
        }
    }
}
