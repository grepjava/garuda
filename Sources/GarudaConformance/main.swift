//===----------------------------------------------------------------------===//
// garuda-conformance: the routes the end-to-end suites need a handler for.
//
// Not a benchmark and not an example to copy: each route exists to make one
// engine behaviour observable from outside. The suites that use it are listed
// in GARUDA.md, "Coverage waiting on the handler API".
//
//   POST /echo                   the request body back, with its content-type
//   GET  /headers                what the handler was given, as JSON
//   GET  /status/:code           that status, empty; ?header=name:value repeats
//   GET  /length/:declared/:n    Content-Length: declared, then n body bytes
//   GET  /throw                  a handler that throws
//   GET  /block/:ms              a handler that blocks the worker for ms
//   GET  /stuck                  a handler that waits forever
//   GET  /delay/:ms              200 after ms
//   GET  /stream/:n/:size        a streamed body: n pieces of size bytes, piece
//                                i filled with the letter i % 26 from a
//   GET  /stream-throw           streams "partial", then throws
//   GET  /stream-queued/:n/:size the same pieces as /stream, then a line with
//                                the most bytes ever queued after a write
//   GET  /events/:n              n server-sent events, "event i", 10 ms apart
//   GET  /                       200, empty
//
// WebTransport, for scripts/webtransport-test.py:
//   /wt         streams and datagrams echoed with "echo:" in front; a peer's
//               unidirectional stream is answered on a new one of ours
//   /wt-reject  refused by middleware with 403, so no session is made
//   /wt-push    opens a unidirectional and a bidirectional stream, then echoes
//   /wt-close   accepts, then closes with code 7 and "asked to"
//   /wt-return  accepts, and returns without closing
//   /wt-hold    accepts two streams, never reads the first, echoes the second
//   /wt-abort   reads one stream to its end, however it ends, and reports what
//               arrived, and whether the peer reset it, on a stream of its own
//   /wt-report  waits for the session to end, then keeps the peer's close code
//               and reason for GET /wt-last-close
//   /wt-room/:name  a typed route: middleware adds x-room, and the handler
//               opens a stream saying "welcome to <name>"
//   /wt-count/:n    Path<Int>, so a name that is not a number is a 400
//
// Hooks, driven by the environment:
//   GARUDA_START_MARKER=path     onStart appends "start <pid> <index>"
//   GARUDA_START_SLEEP_MS=n      and then sleeps n ms
//   GARUDA_SHUTDOWN_MARKER=path  onShutdown appends "shutdown <pid> <index> <us>"
//   GARUDA_SHUTDOWN_HANG=1       and then never returns
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

import GarudaCore
import GarudaHTTP
import Garuda

/// The worker index onStart ran with in this process, or -1.
nonisolated(unsafe) var startedWorker = -1

func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

func append(_ path: String, _ line: String) {
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    var text = line + "\n"
    text.withUTF8 { _ = write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

func wallMicros() -> Int {
    var now = timespec()
    clock_gettime(CLOCK_REALTIME, &now)
    return now.tv_sec * 1_000_000 + now.tv_nsec / 1000
}

/// Percent-decoding for query values, with "+" as a space.
func decoded(_ span: ByteSpan) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    while i < span.count {
        let b = span.base[i]
        if b == 0x25, i + 2 < span.count, let hi = hexDigit(span.base[i + 1]),
           let lo = hexDigit(span.base[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
            continue
        }
        out.append(b == 0x2B ? 0x20 : b)
        i += 1
    }
    return out
}

func hexDigit(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

struct JSONOut {
    var bytes: [UInt8] = []

    mutating func raw(_ s: StaticString) {
        bytes.append(contentsOf: UnsafeBufferPointer(start: s.utf8Start, count: s.utf8CodeUnitCount))
    }

    mutating func raw(_ s: String) { bytes.append(contentsOf: Array(s.utf8)) }

    mutating func string(_ span: ByteSpan) {
        bytes.append(0x22)
        for i in 0..<span.count {
            let b = span.base[i]
            switch b {
            case 0x22: raw("\\\"")
            case 0x5C: raw("\\\\")
            case 0x00..<0x20:
                let digits = Array("0123456789abcdef".utf8)
                raw("\\u00")
                bytes.append(digits[Int(b >> 4)])
                bytes.append(digits[Int(b & 0xF)])
            default: bytes.append(b)
            }
        }
        bytes.append(0x22)
    }

    mutating func string(_ s: StaticString) {
        string(ByteSpan(s.utf8Start, s.utf8CodeUnitCount))
    }
}

func methodName(_ method: HTTPMethod) -> StaticString {
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
    case .other: return "OTHER"
    }
}

extension JSONOut {
    mutating func string(_ span: Span<UInt8>) {
        span.withUnsafeBufferPointer { buffer in
            let empty: StaticString = ""
            string(ByteSpan(buffer.baseAddress ?? empty.utf8Start, buffer.count))
        }
    }
}

/// Percent-decoding for query values, with "+" as a space.
func decodedQueryValue(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
    var out: [UInt8] = []
    var i = bytes.startIndex
    while i < bytes.endIndex {
        let b = bytes[i]
        if b == 0x25, i + 2 < bytes.endIndex, let hi = hexDigit(bytes[i + 1]),
           let lo = hexDigit(bytes[i + 2]) {
            out.append(hi << 4 | lo)
            i += 3
            continue
        }
        out.append(b == 0x2B ? 0x20 : b)
        i += 1
    }
    return out
}

struct HandlerFailure: Error {}

func stuck(_ request: borrowing Request, _ response: inout Response) throws {
    response.after(milliseconds: 1000, then: stuck)
}

let app = Application()

app.get("/") { _, response in
    response.send(status: 200)
}

app.post("/echo") { request, response in
    let typed = request.withHeader("content-type") { response.addHeader("content-type", $0) }
    if typed == nil {
        response.addHeader("content-type", "application/octet-stream")
    }
    request.withBody { response.send($0) }
}

app.get("/headers") { request, response in
    var json = JSONOut()
    json.raw("{\"method\":")
    json.string(methodName(request.method))
    json.raw(",\"path\":")
    request.withPath { json.string($0) }
    json.raw(",\"query\":")
    request.withQuery { json.string($0) }
    let version = request.version
    json.raw(",\"version\":\"")
    json.raw(version.major == 1 ? "1.\(version.minor)" : "\(version.major)")
    json.raw("\",\"scheme\":")
    json.string(request.scheme)
    json.raw(",\"authority\":")
    if request.withHeader("host", { json.string($0) }) == nil { json.raw("null") }
    json.raw(",\"remote\":")
    request.withRemoteAddress { json.string($0) }
    json.raw(",\"port\":")
    json.raw("\(request.remotePort)")
    json.raw(",\"requestID\":")
    if request.withRequestID({ json.string($0) }) == nil { json.raw("null") }
    json.raw(",\"requestStart\":")
    if let start = request.requestStart { json.raw("\(start)") } else { json.raw("null") }
    json.raw(",\"started\":")
    json.raw("\(startedWorker)")
    json.raw(",\"pid\":")
    json.raw("\(getpid())")
    json.raw(",\"headers\":[")
    var first = true
    request.forEachHeader { name, value in
        if !first { json.raw(",") }
        first = false
        json.raw("[")
        json.string(name)
        json.raw(",")
        json.string(value)
        json.raw("]")
    }
    json.raw("]}")
    response.addHeader("content-type", "application/json")
    response.send(json.bytes)
}

app.get("/status/:code") { request, response in
    guard let code = request.withParameter(0, { $0.integer }), code >= 100, code <= 999 else {
        response.send(status: 400)
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
    guard request.withParameter(0, { $0.integer }) != nil,
          let actual = request.withParameter(1, { $0.integer }), actual <= 16 * 1024 * 1024 else {
        response.send(status: 400)
        return
    }
    request.withParameter(0) { response.addHeader("content-length", $0) }
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
    let ms = min(10_000, request.withParameter(0) { $0.integer } ?? 0)
    usleep(UInt32(ms) * 1000)
    response.send(status: 200)
}

app.get("/stuck", stuck)


app.get("/delay/:ms") { request, response in
    let ms = UInt64(min(5000, max(1, request.withParameter(0) { $0.integer } ?? 1)))
    response.after(milliseconds: ms) { _, response in
        response.send(status: 200)
    }
}

app.get("/stream/:n/:size") { (n: Path<Int>, size: Path<Int>) async -> StreamingBody in
    let count = min(max(n.value, 0), 4096)
    let size = min(max(size.value, 0), 1 << 20)
    return StreamingBody(contentType: "application/octet-stream") { body in
        for i in 0..<count {
            try await body.write([UInt8](repeating: UInt8(97 + i % 26), count: size))
        }
    }
}

app.get("/stream-queued/:n/:size") { (n: Path<Int>, size: Path<Int>) async -> StreamingBody in
    let count = min(max(n.value, 0), 4096)
    let size = min(max(size.value, 0), 1 << 20)
    return StreamingBody(contentType: "application/octet-stream") { body in
        var most = 0
        for i in 0..<count {
            try await body.write([UInt8](repeating: UInt8(97 + i % 26), count: size))
            most = max(most, body.queuedBytes)
        }
        try await body.write("\nqueued \(most)")
    }
}

app.onAsync(.get, "/stream-throw") { _, response in
    try await response.stream(contentType: "text/plain").write("partial")
    throw HandlerFailure()
}

app.get("/events/:n") { (n: Path<Int>) async -> EventStream in
    let count = min(max(n.value, 0), 1000)
    return EventStream { events in
        for i in 0..<count {
            try await events.send("event \(i)", id: "\(i)")
            try await events.sleep(milliseconds: 10)
        }
    }
}

/// Answers every stream and datagram the session brings until it ends.
func echo(_ session: WebTransportSession) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while let datagram = try await session.receiveDatagram() {
                session.sendDatagram(Array("echo:".utf8) + datagram)
            }
        }
        while let stream = try await session.acceptStream() {
            group.addTask {
                let body = try await stream.readAll(maxBytes: 8 << 20)
                let out = stream.isBidirectional ? stream : try session.openStream(bidirectional: false)
                try await out.write(Array("echo:".utf8) + body)
                out.finish()
            }
        }
        // The session is over; the datagram reader has returned nil too.
        try await group.waitForAll()
    }
}

app.onWebTransport("/wt") { _, session in
    try await echo(session)
}

app.group("/wt-reject") {
    app.use { _, _ in HTTPStatus.forbidden }
    app.onWebTransport("/") { _, session in try await echo(session) }
}

app.group("/wt-room") {
    app.use { _, response in
        response.addHeader("x-room", "yes")
        return nil
    }
    app.webTransport("/:name") { (session: WebTransportSession, name: Path<String>) async throws in
        let out = try session.openStream(bidirectional: false)
        try await out.write(Array("welcome to \(name.value)".utf8))
        out.finish()
        while try await session.acceptStream() != nil {}
    }
}

app.webTransport("/wt-count/:n") { (session: WebTransportSession, n: Path<Int>) async throws in
    session.close(code: UInt32(clamping: n.value))
}

app.onWebTransport("/wt-push") { _, session in
    let uni = try session.openStream(bidirectional: false)
    try await uni.write(Array("push-uni".utf8))
    uni.finish()
    let bidi = try session.openStream(bidirectional: true)
    try await bidi.write(Array("push-bidi".utf8))
    bidi.finish()
    try await echo(session)
}

app.onWebTransport("/wt-return") { _, _ in }

app.onWebTransport("/wt-close") { _, session in
    session.close(code: 7, reason: "asked to")
}

app.onWebTransport("/wt-hold") { _, session in
    guard let _ = try await session.acceptStream(),
          let live = try await session.acceptStream() else { return }
    let body = try await live.readAll()
    try await live.write(Array("echo:".utf8) + body)
    live.finish()
    // Stay open until the client has had its answer, so the held stream is
    // not simply abandoned with the session.
    while try await live.read() != nil {}
    while try await session.acceptStream() != nil {}
}

app.onWebTransport("/wt-abort") { _, session in
    guard let stream = try await session.acceptStream() else { return }
    let body = try await stream.readAll()
    let out = try session.openStream(bidirectional: false)
    try await out.write(Array((stream.wasAborted ? "aborted:" : "ended:").utf8) + body)
    out.finish()
    while try await session.acceptStream() != nil {}
}

/// How the last /wt-report session ended, as "<code> <reason>". A QUIC
/// connection stays on one worker, so a GET on it reads this worker's.
nonisolated(unsafe) var lastWebTransportClose = ""

app.onWebTransport("/wt-report") { _, session in
    // Returns only once the session has ended and every wait on it with it.
    while try await session.acceptStream() != nil {}
    lastWebTransportClose = "\(session.closeCode) \(session.closeReason)"
}

app.get("/wt-last-close") { _, response in
    response.send(lastWebTransportClose)
}

app.onWorkerStart { index in
    startedWorker = index
    if let path = environment("GARUDA_START_MARKER") {
        append(path, "start \(getpid()) \(index)")
    }
    if let ms = environment("GARUDA_START_SLEEP_MS").flatMap({ Int($0) }), ms > 0 {
        usleep(UInt32(ms) * 1000)
    }
}

app.onWorkerShutdown { index in
    if let path = environment("GARUDA_SHUTDOWN_MARKER") {
        append(path, "shutdown \(getpid()) \(index) \(wallMicros())")
    }
    if environment("GARUDA_SHUTDOWN_HANG") != nil {
        while true { sleep(1) }
    }
}

exit(app.run())
