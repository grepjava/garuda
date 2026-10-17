//===----------------------------------------------------------------------===//
// Routes for scripts/cache-test.sh: responses a shared cache must keep or
// refuse, each call logged to CACHE_LOG so the test can count what reached
// the application.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import Garuda
import Synchronization
import Vega

/// Calls each target received in this process.
private let cacheCalls = Mutex<[String: Int]>([:])

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

/// Appends `line` to the file at `path`.
func appendLine(_ path: String, _ line: String) {
    var text = line + "\n"
    #if os(Windows)
    // ucrt's open is variadic, which Swift cannot call.
    guard let file = fopen(path, "ab") else { return }
    text.withUTF8 { _ = fwrite($0.baseAddress, 1, $0.count, file) }
    fclose(file)
    #else
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    text.withUTF8 { _ = write(fd, $0.baseAddress, $0.count) }
    close(fd)
    #endif
}

/// The call as the application sees it: logged to CACHE_LOG, and numbered in
/// the body, so a copy served from the cache is byte for byte the response
/// that was stored.
private func cacheCall(_ request: borrowing Request, _ name: String) -> String {
    let query = request.query
    let target = "/cache/" + name + (query.isEmpty ? "" : "?" + query)
    if let log = getenv("CACHE_LOG").map({ String(cString: $0) }) {
        appendLine(log, "\(request.method.name) \(target)")
    }
    let call = cacheCalls.withLock { calls -> Int in
        let n = (calls[target] ?? 0) + 1
        calls[target] = n
        return n
    }
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
            try await Runtime.sleep(for: .seconds(1))
            response.send(body + cachePadding)
        default:
            response.send(body + cachePadding)
        }
    }

    app.get("/cache/stream/pieces") { request, response in
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
