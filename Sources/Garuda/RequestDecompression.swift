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
// The decoded body is held to the route's body limit -- `app.maxBodySize`, or
// --max-body -- as it grows, so a few kilobytes that would inflate to
// gigabytes stop at the limit with 413. A coding this process cannot decode is
// 415 with Accept-Encoding saying which it can (RFC 9110 section 15.5.16), and
// bytes that are not what the coding makes are 400.
//
// A route that streams its body reads it as it arrives, before any of it could
// be decoded here: it is left as it came.
//===----------------------------------------------------------------------===//

import AvianCore
import AvianHTTP

extension RouteBuilder {
    /// Decodes the compressed request bodies of the routes in the current
    /// scope before their handlers read them.
    public func requestDecompression() {
        use { request, _ in
            guard let coding = request.header("content-encoding") else { return nil }
            try request.worker.pointee.decodeRequestBody(request.slot, contentEncoding: coding)
            return nil
        }
    }
}

extension Worker {
    /// Replaces the whole body of the request on `slot` with what
    /// `contentEncoding` decodes it to.
    mutating func decodeRequestBody(_ slot: Int, contentEncoding: String) throws {
        let c = table[slot]
        guard !c.pointee.flags.contains(.bodyStreaming) else { return }
        guard ContentDecoder.canDecode(contentEncoding) else {
            addHeader(slot, "accept-encoding", ContentDecoder.acceptEncoding)
            throw HTTPError(.unsupportedMediaType, "a Content-Encoding this server cannot decode")
        }
        let count = c.pointee.body.readableBytes
        guard count > 0 else { return }
        var limit = config.maxBodySize
        let route = Int(c.pointee.routeIndex)
        if route >= 0, let installed = application, installed.pointee.wholeBodyLimits[route] >= 0 {
            limit = installed.pointee.wholeBodyLimits[route]
        }
        let compressed = [UInt8](UnsafeBufferPointer(start: UnsafePointer(c.pointee.body.readPointer), count: count))
        let decoded: [UInt8]
        do {
            decoded = try ContentDecoder.decode(compressed, contentEncoding: contentEncoding, limit: limit)
        } catch .tooLarge {
            throw HTTPError(.contentTooLarge)
        } catch {
            throw HTTPError(.badRequest, "a body that does not decode as its Content-Encoding says")
        }
        c.pointee.body.clear()
        decoded.withUnsafeBufferPointer { bytes in
            if let base = bytes.baseAddress { c.pointee.body.write(base, bytes.count) }
        }
    }
}
