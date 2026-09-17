//===----------------------------------------------------------------------===//
// Routes for scripts/compress-test.sh and scripts/cache-test.sh: a response
// per case the compression decision has to get right, and responses a shared
// cache must keep or refuse.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import AvianCore
import AvianHTTP
import Garuda

/// The text every compressible body is, so the test compares what it decodes
/// with one expected file.
let compressibleText: [UInt8] = {
    var text = ""
    for i in 0..<2000 { text += "line \(i) of a compressible response\n" }
    return Array(text.utf8)
}()

/// `bytes` gzipped, for a body the application encoded itself.
func gzipped(_ bytes: [UInt8]) -> [UInt8] {
    var encoder = ResponseEncoder()
    var out = ByteBuffer()
    defer { out.destroy() }
    guard encoder.start(.gzip),
          bytes.withUnsafeBufferPointer({ encoder.encode($0.baseAddress!, $0.count, flush: false,
                                                        into: &out, chunked: false) }),
          encoder.finish(into: &out, chunked: false) else { return [] }
    return Array(UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes))
}

func addCompressionRoutes(_ app: Application) {
    let text = compressibleText
    let packed = gzipped(text)

    func plain(_ pattern: String, _ headers: [(String, String)] = [], body: [UInt8]? = nil) {
        app.get(pattern) { _, response in
            response.addHeader("content-type", "text/plain; charset=utf-8")
            for (name, value) in headers { response.addHeader(name, value) }
            response.send(body ?? text)
        }
    }

    plain("/compress/text")
    plain("/compress/declared", [("content-length", "\(text.count)")])
    plain("/compress/small", [("content-length", "4")], body: Array("tiny".utf8))
    plain("/compress/encoded", [("content-encoding", "gzip")], body: packed)
    plain("/compress/no-transform", [("cache-control", "public, no-transform")])
    plain("/compress/vary", [("vary", "Accept-Encoding")])
    plain("/compress/etag", [("etag", "\"v1\"")])
    plain("/compress/weak-etag", [("etag", "W/\"v1\"")])
    app.get("/compress/png") { _, response in
        response.addHeader("content-type", "image/png")
        response.send(text)
    }
    app.get("/compress/events") { _, response in
        response.addHeader("content-type", "text/event-stream")
        response.send(text)
    }
    app.get("/compress/pieces") { () async -> StreamingBody in
        StreamingBody(contentType: "text/plain; charset=utf-8") { body in
            let step = text.count / 10 + 1
            var at = 0
            while at < text.count {
                try await body.write(Array(text[at..<min(text.count, at + step)]))
                at += step
            }
        }
    }
    // The first piece has to reach the client while the handler still sleeps,
    // which is what flushing each write through the compressor is for.
    app.get("/compress/stream") { () async -> StreamingBody in
        StreamingBody(contentType: "text/plain; charset=utf-8") { body in
            try await body.write(Array(text[0..<100]))
            try await body.sleep(milliseconds: 1500)
            try await body.write(Array(text[100...]))
        }
    }
}

// MARK: - The cache

/// Calls each target received in this worker process.
nonisolated(unsafe) var cacheCalls: [String: Int] = [:]

private let cachePadding = Array(String(repeating: "cacheable text, repeated so that compression has something to do. ",
                                        count: 40).utf8)

/// The headers each cache route answers with, beyond its content type.
private let cacheRoutes: [String: [(String, String)]] = [
    "fresh": [("cache-control", "public, s-maxage=60")],
    "maxage": [("cache-control", "max-age=60")],
    "short": [("cache-control", "s-maxage=1")],
    "private": [("cache-control", "private, max-age=60")],
    "nostore": [("cache-control", "no-store, max-age=60")],
    "cookie": [("cache-control", "max-age=60"), ("set-cookie", "id=1")],
    "vary-ua": [("cache-control", "max-age=60"), ("vary", "User-Agent")],
    "vary-ae": [("cache-control", "max-age=60"), ("vary", "Accept-Encoding")],
    "plain": [],
    // Two minutes old by its own account, with a minute's lifetime.
    "aged": [("cache-control", "max-age=60"), ("age", "120")],
    "half-aged": [("cache-control", "max-age=60"), ("age", "30")],
    // Dated long ago, with a minute's lifetime.
    "dated": [("cache-control", "max-age=60"), ("date", "Sun, 06 Nov 1994 08:49:37 GMT")],
    "etag": [("cache-control", "s-maxage=60"), ("etag", "\"v1\""),
             ("last-modified", "Sun, 06 Nov 1994 08:49:37 GMT")],
]

/// The call as the application sees it: logged to CACHE_LOG, so the test can
/// count what reached the application, and numbered in the body, so a copy
/// served from the cache is byte for byte the response that was stored.
private func cacheCall(_ request: borrowing Request, _ name: String) -> String {
    let query = request.query
    let target = "/cache/" + name + (query.isEmpty ? "" : "?" + query)
    let method: String
    switch request.method {
    case .get: method = "GET"
    case .head: method = "HEAD"
    case .post: method = "POST"
    case .put: method = "PUT"
    case .delete: method = "DELETE"
    default: method = "OTHER"
    }
    if let log = environment("CACHE_LOG") { append(log, "\(method) \(target)") }
    let call = (cacheCalls[target] ?? 0) + 1
    cacheCalls[target] = call
    return "call=\(call) pid=\(getpid()) target=\(target)\n"
}

func addCacheRoutes(_ app: Application) {
    app.get("/cache/ready") { _, response in response.send("ready") }

    app.get("/cache/:name") { request, response in
        let name = request.parameter(0)
        let line = cacheCall(request, name)
        response.addHeader("content-type", "text/plain")
        for (header, value) in cacheRoutes[name] ?? cacheRoutes["fresh"]! {
            response.addHeader(header, value)
        }
        var body = Array(line.utf8)
        switch name {
        case "big":
            response.send(body + [UInt8](repeating: 120, count: 2 * 1024 * 1024))
        case "missing":
            response.send(status: .notFound, body)
        case "broken":
            response.send(status: .internalServerError, body)
        case "nothing":
            response.send(status: .noContent)
        case "etag":
            if let ifMatch = request.header("if-match"), ifMatch != "\"v1\"" {
                response.send(status: HTTPStatus(412))
                return
            }
            response.send(body + cachePadding)
        case "short-length":
            // Declares more than it sends, which nobody should keep.
            body += cachePadding
            response.addHeader("content-length", "\(body.count + 10)")
            response.send(body)
        case "slow-item":
            // Still answering when the test changes the target.
            response.after(milliseconds: 1000) { _, response in
                response.send(body + cachePadding)
            }
        default:
            response.send(body + cachePadding)
        }
    }

    app.onAsync(.get, "/cache/stream/pieces") { request, response in
        let line = cacheCall(request, "stream/pieces")
        response.addHeader("cache-control", "s-maxage=60")
        let body = Array(line.utf8) + cachePadding
        let writer = response.stream(contentType: "text/plain")
        try await writer.write(Array(body[0..<100]))
        try await writer.write(Array(body[100...]))
    }

    for method in [HTTPMethod.post, .put, .delete] {
        app.on(method, "/cache/:name") { request, response in
            _ = cacheCall(request, request.parameter(0))
            response.addHeader("content-type", "text/plain")
            if request.header("x-deny") != nil {
                response.send(status: .forbidden, "denied\n")
            } else {
                response.send("changed\n")
            }
        }
    }
}
