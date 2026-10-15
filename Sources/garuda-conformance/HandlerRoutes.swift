//===----------------------------------------------------------------------===//
// Routes for scripts/handler-test.py: what a handler is given and what it can
// say, one behaviour a route.
//
//   POST /echo                   the request body back, with its content-type
//   GET  /headers                what the handler was given, as JSON
//   GET  /status/:code           that status, empty; ?header=name:value repeats
//   GET  /length/:declared/:n    Content-Length: declared, then n body bytes
//   GET  /throw                  a handler that throws
//   GET  /block/:ms              a handler that blocks its thread for ms
//   GET  /stuck                  a handler that waits forever
//   GET  /delay/:ms              200 after ms
//   GET  /blocking/sleep/:ms     "slept" after ms on the blocking pool
//   GET  /blocking/throw         work on the pool that throws a 409
//   GET  /stream/:n/:size        a streamed body: n pieces of size bytes, piece
//                                i filled with the letter i % 26 from a
//   GET  /stream-throw           streams "partial", then throws
//   GET  /stream-queued/:n/:size the same pieces as /stream, then a line with
//                                the most bytes ever queued after a write
//   GET  /events/:n              n server-sent events, "event i", 10 ms apart
//   POST /interim                a 103 with a Link, then 200 "final"
//
// Hooks, driven by the environment:
//   GARUDA_START_MARKER=path     onShardStart appends "start <pid> <index>"
//   GARUDA_START_SLEEP_MS=n      and then sleeps n ms
//   GARUDA_SHUTDOWN_MARKER=path  onShardStop appends "shutdown <pid> <index> <us>"
//   GARUDA_SHUTDOWN_HANG=1       and then never returns
//
// Garuda 1's /body-stream, /body-limited and /files read request bodies as
// they arrive and serve resumable uploads, which come with GarudaUploads.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
import WinSDK
#endif
import Garuda
import Vega

/// The shard index onShardStart ran with in this process, or -1.
nonisolated(unsafe) private var startedShard = -1

private func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

private func appendMarker(_ path: String, _ line: String) {
    guard let file = fopen(path, "a") else { return }
    defer { fclose(file) }
    fputs(line + "\n", file)
}

private func wallMicros() -> Int {
    #if os(Windows)
    var now = timespec()
    _ = timespec_get(&now, TIME_UTC)
    return Int(now.tv_sec) * 1_000_000 + Int(now.tv_nsec) / 1000
    #else
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    return now.tv_sec * 1_000_000 + now.tv_nsec / 1000
    #endif
}

private struct HandlerFailure: Error {}

/// JSON written by hand, so /headers shows bytes exactly as they arrived.
private struct JSONOut {
    var bytes: [UInt8] = []

    mutating func raw(_ s: String) { bytes += Array(s.utf8) }

    mutating func string(_ value: [UInt8]) {
        bytes.append(0x22)
        let digits = Array("0123456789abcdef".utf8)
        for b in value {
            switch b {
            case 0x22: raw("\\\"")
            case 0x5C: raw("\\\\")
            case 0x00..<0x20:
                raw("\\u00")
                bytes.append(digits[Int(b >> 4)])
                bytes.append(digits[Int(b & 0xF)])
            default: bytes.append(b)
            }
        }
        bytes.append(0x22)
    }

    mutating func string(_ value: String) { string(Array(value.utf8)) }

    mutating func optional(_ value: String?) {
        if let value { string(value) } else { raw("null") }
    }
}

private func bytes(_ span: Span<UInt8>) -> [UInt8] {
    span.withUnsafeBufferPointer { Array($0) }
}

private func methodName(_ method: HTTPMethod) -> String {
    switch method {
    case .get: return "GET"
    case .head: return "HEAD"
    case .post: return "POST"
    case .put: return "PUT"
    case .delete: return "DELETE"
    case .patch: return "PATCH"
    case .options: return "OPTIONS"
    case .connect: return "CONNECT"
    case .trace: return "TRACE"
    default: return "OTHER"
    }
}

private func hexDigit(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

/// Percent-decoding for query values, with "+" as a space.
private func decodedQueryValue(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
        let b = bytes[i]
        if b == 0x25, i + 2 < bytes.endIndex, let hi = hexDigit(bytes[i + 1]), let lo = hexDigit(bytes[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
            continue
        }
        out.append(b == 0x2B ? 0x20 : b)
        i += 1
    }
    return out
}

/// The pieces /stream and /stream-queued send.
private func piece(_ i: Int, _ size: Int) -> [UInt8] {
    [UInt8](repeating: UInt8(97 + i % 26), count: size)
}

func addHandlerRoutes(_ app: Application) {
    app.post("/echo") { request, response in
        if let type = request.header("content-type") {
            response.addHeader("content-type", type)
        } else {
            response.addHeader("content-type", "application/octet-stream")
        }
        response.send(request.body)
    }

    app.get("/headers") { request, response in
        var json = JSONOut()
        json.raw("{\"method\":")
        json.string(methodName(request.method))
        json.raw(",\"path\":")
        json.string(request.path)
        json.raw(",\"query\":")
        json.string(request.query)
        let version = request.version
        json.raw(",\"version\":")
        json.string(version.major == 1 ? "1.\(version.minor)" : "\(version.major)")
        json.raw(",\"scheme\":")
        json.string(request.arrivedOverHTTPS ? "https" : "http")
        json.raw(",\"authority\":")
        json.optional(request.authority)
        json.raw(",\"remote\":")
        json.string(request.remoteAddress)
        json.raw(",\"port\":\(request.remotePort)")
        json.raw(",\"requestID\":")
        json.optional(request.requestID)
        // Garuda 2 has no --request-start-header.
        json.raw(",\"requestStart\":null")
        json.raw(",\"started\":\(startedShard)")
        json.raw(",\"pid\":\(getpid())")
        json.raw(",\"headers\":[")
        var first = true
        request.forEachHeader { name, value in
            if !first { json.raw(",") }
            first = false
            json.raw("[")
            json.string(bytes(name))
            json.raw(",")
            json.string(bytes(value))
            json.raw("]")
        }
        json.raw("]}")
        response.addHeader("content-type", "application/json")
        response.send(json.bytes)
    }

    app.get("/status/:code") { request, response in
        guard let code = Int(request.parameter(0)), code >= 100, code <= 999 else {
            response.send(status: .badRequest)
            return
        }
        // ?header=name:value, repeatable.
        let query = Array(request.query.utf8)
        let prefix = Array("header=".utf8)
        var start = 0
        while start <= query.count {
            var end = start
            while end < query.count && query[end] != 0x26 { end += 1 }
            if end - start > prefix.count && query[start..<(start + prefix.count)].elementsEqual(prefix) {
                let pair = decodedQueryValue(query[(start + prefix.count)..<end])
                if let colon = pair.firstIndex(of: 0x3A) {
                    var valueStart = colon + 1
                    while valueStart < pair.count && pair[valueStart] == 0x20 { valueStart += 1 }
                    response.addHeader(String(decoding: pair[..<colon], as: UTF8.self),
                                       String(decoding: pair[valueStart...], as: UTF8.self))
                }
            }
            start = end + 1
        }
        response.send(status: HTTPStatus(code))
    }

    app.get("/length/:declared/:actual") { request, response in
        guard Int(request.parameter(0)) != nil, let actual = Int(request.parameter(1)),
              actual >= 0, actual <= 16 * 1024 * 1024 else {
            response.send(status: .badRequest)
            return
        }
        response.addHeader("content-length", request.parameter(0))
        let pattern = Array("abcdefghijklmnopqrstuvwxyz".utf8)
        var body = [UInt8]()
        body.reserveCapacity(actual)
        for i in 0..<actual { body.append(pattern[i % pattern.count]) }
        response.send(body)
    }

    app.get("/throw") { _, _ in
        throw HandlerFailure()
    }

    app.get("/block/:ms") { request, response in
        let ms = min(10_000, max(0, Int(request.parameter(0)) ?? 0))
        usleep(UInt32(ms) * 1000)
        response.send(status: .ok)
    }

    app.get("/stuck") { _, _ in
        while true { try await Runtime.sleep(for: .seconds(1)) }
    }

    app.get("/delay/:ms") { (ms: Path<Int>) async throws in
        try await Runtime.sleep(for: .milliseconds(min(5000, max(1, ms.value))))
        return HTTPStatus.ok
    }

    // Work on the blocking pool: a sleep that would stop the worker, and
    // work that throws.
    app.get("/blocking/sleep/:ms") { (ms: Path<Int>) async throws -> String in
        let micros = UInt32(min(5000, max(1, ms.value))) * 1000
        return try await Runtime.blocking { () throws -> String in
            usleep(micros)
            return "slept"
        }
    }

    app.get("/blocking/throw") { () async throws -> String in
        try await Runtime.blocking { () throws -> String in throw HTTPError.conflict("from the pool") }
    }

    app.get("/stream/:n/:size") { (n: Path<Int>, size: Path<Int>) async in
        let count = min(max(n.value, 0), 4096)
        let size = min(max(size.value, 0), 1 << 20)
        return StreamingBody(contentType: "application/octet-stream") { body in
            for i in 0..<count { try await body.write(piece(i, size)) }
        }
    }

    app.get("/stream-queued/:n/:size") { (n: Path<Int>, size: Path<Int>) async in
        let count = min(max(n.value, 0), 4096)
        let size = min(max(size.value, 0), 1 << 20)
        return StreamingBody(contentType: "application/octet-stream") { body in
            var most = 0
            for i in 0..<count {
                try await body.write(piece(i, size))
                most = max(most, body.queuedBytes)
            }
            try await body.write("\nqueued \(most)")
        }
    }

    app.get("/stream-throw") { _, response in
        try await response.stream(contentType: "text/plain").write("partial")
        throw HandlerFailure()
    }

    app.get("/events/:n") { (n: Path<Int>) async in
        let count = min(max(n.value, 0), 1000)
        return EventStream { events in
            for i in 0..<count {
                try await events.send("event \(i)", id: "\(i)")
                try await events.sleep(milliseconds: 10)
            }
        }
    }

    app.post("/interim") { _, response in
        await response.sendInterim(status: HTTPStatus(103), headers: [("Link", "</style.css>; rel=preload")])
        response.send("final")
    }

    app.onShardStart { start in
        let index = start.shard.index
        startedShard = index
        if let path = environment("GARUDA_START_MARKER") {
            appendMarker(path, "start \(getpid()) \(index)")
        }
        if let ms = environment("GARUDA_START_SLEEP_MS").flatMap({ Int($0) }), ms > 0 {
            usleep(UInt32(ms) * 1000)
        }
    }

    app.onShardStop { stop in
        if let path = environment("GARUDA_SHUTDOWN_MARKER") {
            appendMarker(path, "shutdown \(getpid()) \(stop.shard.index) \(wallMicros())")
        }
        if environment("GARUDA_SHUTDOWN_HANG") != nil {
            #if os(Windows)
            while true { Sleep(1000) }
            #else
            while true { sleep(1) }
            #endif
        }
    }
}
