#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization
import Testing
@testable import Garuda
import GarudaTesting
import GarudaWire
import InMemoryTracing
import Tracing
import Vega
import VegaIO
import VegaTLS

// The HTTP client, against origins on loopback: a scripted one that answers
// each request with the next reply it was given -- what a server should
// never send included -- and Garuda's own server, for HTTP/2, TLS and
// compression as they really are.

enum ClientTestRuntime {
    static let shared = Runtime(workers: 2)
}

/// Runs `body` on the test runtime.
func onRuntime<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    try ClientTestRuntime.shared.block { () async throws -> T in try await body() }
}

/// What a scripted origin saw.
final class OriginLog: Sendable {
    let state = Mutex<(requests: [String], accepted: Int)>(([], 0))
    var requests: [String] { state.withLock { $0.requests } }
    var accepted: Int { state.withLock { $0.accepted } }
}

/// One reply of a scripted origin.
struct Reply: Sendable {
    var bytes: [UInt8]
    /// Closes the connection after it.
    var close = false
    /// Sends this many bytes, then the rest a moment later.
    var splitAfter = 0
    /// Says nothing at all, and holds the connection.
    var silent = false

    init(_ text: String, close: Bool = false, splitAfter: Int = 0) {
        bytes = Array(text.utf8)
        self.close = close
        self.splitAfter = splitAfter
    }

    static let silence: Reply = { var r = Reply(""); r.silent = true; return r }()

    static func ok(_ body: String, _ fields: [String] = []) -> Reply {
        Reply("HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n"
              + fields.map { $0 + "\r\n" }.joined() + "\r\n" + body)
    }
}

/// An origin answering each request, on any connection, with the next of
/// `script`; once that runs out, connections are closed.
struct ScriptedOrigin: Sendable {
    let port: Int
    let log: OriginLog
    let server: TCPServer

    var url: String { "http://127.0.0.1:\(port)" }

    static func start(_ script: [Reply]) throws -> ScriptedOrigin {
        let log = OriginLog()
        let next = Atomic<Int>(0)
        let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
        let port = listener.localPort
        let server = try TCPServer.serve(listener) { stream in
            log.state.withLock { $0.accepted += 1 }
            var buffer = IOBuffer(capacity: 64 * 1024)
            while true {
                guard let request = await readRequest(stream, &buffer) else { return }
                log.state.withLock { $0.requests.append(request) }
                let index = next.add(1, ordering: .relaxed).oldValue
                guard index < script.count else { return }
                let reply = script[index]
                if reply.silent {
                    try? await Runtime.sleep(for: .seconds(5))
                    return
                }
                let split = reply.splitAfter > 0 && reply.splitAfter < reply.bytes.count ? reply.splitAfter : reply.bytes.count
                do {
                    try await reply.bytes.withUnsafeBytesAsync { (b) async throws(IOError) in try await stream.write(UnsafeRawBufferPointer(rebasing: b[0..<split])) }
                    if split < reply.bytes.count {
                        try? await Runtime.sleep(for: .milliseconds(20))
                        try await reply.bytes.withUnsafeBytesAsync { (b) async throws(IOError) in try await stream.write(UnsafeRawBufferPointer(rebasing: b[split...])) }
                    }
                } catch {
                    return
                }
                if reply.close { return }
            }
        }
        return ScriptedOrigin(port: port, log: log, server: server)
    }

    func stop() async { await server.shutdown(gracePeriod: .milliseconds(100)) }
}

/// One request off `stream`, head and body, as text; nil once it closes.
private func readRequest(_ stream: borrowing TCPStream, _ buffer: inout IOBuffer) async -> String? {
    while true {
        let bytes = buffer.withUnsafeBytes { Array($0) }
        if let end = headEnd(bytes) {
            let head = String(decoding: bytes[..<end], as: UTF8.self)
            var length = 0
            for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: " ")) ?? 0
            }
            if bytes.count >= end + length {
                buffer.consume(end + length)
                return String(decoding: bytes[..<(end + length)], as: UTF8.self)
            }
        }
        if buffer.capacity - buffer.count < 4096 { buffer.reserveCapacity(buffer.capacity * 2) }
        guard let n = try? await stream.read(into: &buffer), n > 0 else { return nil }
    }
}

/// Where the head in `bytes` ends, past its blank line.
private func headEnd(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4) where bytes[i] == 13 && bytes[i + 1] == 10 && bytes[i + 2] == 13 && bytes[i + 3] == 10 {
        return i + 4
    }
    return nil
}

extension Substring {
    func trimmingCharacters(in set: String) -> String {
        var s = self
        while let c = s.first, set.contains(c) { s.removeFirst() }
        while let c = s.last, set.contains(c) { s.removeLast() }
        return String(s)
    }
}

/// `app`, served on loopback as a shard serves it: HTTP/1.1, HTTP/2 by prior
/// knowledge, and with `certificate`, TLS with ALPN.
struct LoopbackServer: Sendable {
    let port: Int
    let accepted: OriginLog
    let server: TCPServer

    static func start(_ app: Application, config: ServerConfig = ServerConfig(),
                      certificate: TestCertificate? = nil) throws -> LoopbackServer {
        let compiled = app.compile()
        compiled.runtime = ClientTestRuntime.shared
        let limits = ConnectionLimits(config)
        let http2 = HTTP2Service.forTesting(ClientTestRuntime.shared)
        let store = try certificate.map { try CertificateStore(files: [$0.files], protocols: Application.alpn, ticketKey: nil) }
        let log = OriginLog()
        let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
        let port = listener.localPort
        let server = try TCPServer.serve(listener) { stream in
            log.state.withLock { $0.accepted += 1 }
            if let store {
                await serveTLSConnection(stream, store, handshakeTimeout: .seconds(5), app: compiled,
                                         limits: limits, http2: http2)
            } else {
                await serveTCP(stream, app: compiled, limits: limits, http2: http2)
            }
        }
        return LoopbackServer(port: port, accepted: log, server: server)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func stop() async { await server.shutdown(gracePeriod: .milliseconds(100)) }
}

private func failure(_ body: () async throws(ClientError) -> ClientResponse) async -> ClientError? {
    do {
        _ = try await body()
        return nil
    } catch {
        return error
    }
}

// MARK: - HTTP/1.1

@Suite("HTTP client")
struct HTTPClientTests {

    @Test func aGetIsAnsweredAndItsConnectionKept() throws {
        let (first, second, log, url) = try onRuntime {
            let origin = try ScriptedOrigin.start([.ok("one", ["X-Kind: first"]), .ok("two")])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let first = try await client.get(origin.url + "/a?b=c")
            let second = try await client.get(origin.url + "/d")
            return (first, second, origin.log, origin.url)
        }
        #expect(first.status == 200)
        #expect(first.text == "one")
        #expect(first.header("x-kind") == "first")
        #expect(first.reusedConnection)
        #expect(first.url == url + "/a?b=c")
        #expect(second.text == "two")
        #expect(log.accepted == 1)
        let request = log.requests[0]
        #expect(request.hasPrefix("GET /a?b=c HTTP/1.1\r\n"))
        #expect(request.contains("\r\nHost: 127.0.0.1:\(url.split(separator: ":").last!)\r\n"))
        #expect(request.contains("\r\nUser-Agent: garuda\r\n"))
        #expect(request.contains("\r\nAccept-Encoding: \(RequestDecoder.acceptEncoding)\r\n"))
    }

    @Test func bodiesAreFramedEveryWayAServerFramesThem() throws {
        let (chunked, closed, informational, head, after, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n4\r\ndefg\r\n0\r\n\r\n", splitAfter: 45),
                Reply("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok"),
                Reply("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"),
                .ok("after"),
                Reply("HTTP/1.1 200 OK\r\n\r\nuntil the end", close: true),
            ])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let chunked = try await client.get(origin.url + "/chunked")
            let informational = try await client.get(origin.url + "/continue")
            let head = try await client.head(origin.url + "/head")
            let after = try await client.get(origin.url + "/after")
            let closed = try await client.get(origin.url + "/close")
            return (chunked, closed, informational, head, after, origin.log)
        }
        #expect(chunked.text == "abcdefg")
        #expect(chunked.reusedConnection)
        #expect(informational.status == 201)
        #expect(informational.text == "ok")
        // A HEAD's Content-Length describes a body that never comes: the
        // next response on the connection is read as itself.
        #expect(head.body.isEmpty)
        #expect(head.reusedConnection)
        #expect(after.text == "after")
        #expect(closed.text == "until the end")
        #expect(!closed.reusedConnection)
        #expect(log.accepted == 1)
    }

    @Test func aPostSaysHowLongItsBodyIs() throws {
        let (answer, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([.ok("thanks")])
            defer { Task { await origin.stop() } }
            let answer = try await HTTPClient().post(origin.url + "/in", body: Array("a=1&b=2".utf8),
                                                     contentType: "application/x-www-form-urlencoded")
            return (answer, origin.log)
        }
        #expect(answer.text == "thanks")
        let request = log.requests[0]
        #expect(request.hasPrefix("POST /in HTTP/1.1\r\n"))
        #expect(request.contains("\r\nContent-Type: application/x-www-form-urlencoded\r\n"))
        #expect(request.contains("\r\nContent-Length: 7\r\n"))
        #expect(request.hasSuffix("\r\n\r\na=1&b=2"))
    }

    @Test func whatCannotBeFramedOrIsTooLargeIsRefused() throws {
        let (malformed, tooLarge, headTooLarge) = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 abc\r\n\r\n"),
                Reply("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n0123456789"),
                Reply("HTTP/1.1 200 OK\r\nX-Big: " + String(repeating: "x", count: 4096) + "\r\n\r\n"),
            ])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            let malformed = await failure { () async throws(ClientError) in try await client.get(origin.url + "/1") }
            client.maxBodyBytes = 4
            let tooLarge = await failure { () async throws(ClientError) in try await client.get(origin.url + "/2") }
            client.maxHeadBytes = 1024
            let headTooLarge = await failure { () async throws(ClientError) in try await client.get(origin.url + "/3") }
            return (malformed, tooLarge, headTooLarge)
        }
        if case .malformedResponse = malformed {} else { Issue.record("\(String(describing: malformed))") }
        #expect(tooLarge == .bodyTooLarge)
        #expect(headTooLarge == .headTooLarge)
    }

    @Test func aSilentServerTimesOut() throws {
        let error = try onRuntime {
            let origin = try ScriptedOrigin.start([.silence])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            client.timeout = .milliseconds(100)
            return await failure { () async throws(ClientError) in try await client.get(origin.url) }
        }
        #expect(error == .timedOut)
    }

    @Test func theWholeBudgetEndsAnExchangeThatEveryWaitWouldAllow() throws {
        let error = try onRuntime {
            // A head, then the body a piece at a time, each well inside the
            // per-wait timeout.
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nab", splitAfter: 40),
            ])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            client.totalTimeout = .milliseconds(150)
            return await failure { () async throws(ClientError) in try await client.get(origin.url) }
        }
        #expect(error == .timedOut)
    }

    @Test func headersThatCouldSplitTheRequestAreRefusedBeforeConnecting() throws {
        let (crlf, expect, encoding, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let crlf = await failure { () async throws(ClientError) in
                try await client.get(origin.url, headers: [("X-A", "1\r\nX-B: 2")])
            }
            let expect = await failure { () async throws(ClientError) in
                try await client.get(origin.url, headers: [("Expect", "100-continue")])
            }
            let encoding = await failure { () async throws(ClientError) in
                try await client.get(origin.url, headers: [("Accept-Encoding", "gzip")])
            }
            try await Runtime.sleep(for: .milliseconds(20))
            return (crlf, expect, encoding, origin.log)
        }
        #expect(crlf == .refusedHeader)
        #expect(expect == .refusedHeader)
        #expect(encoding == .refusedHeader)
        #expect(log.accepted == 0)
    }

    @Test func aKeptConnectionTheServerClosedIsNotUsedAgain() throws {
        let (first, second, log) = try onRuntime {
            // Kept by the client -- the reply said nothing of closing -- and
            // closed by the server straight after.
            let origin = try ScriptedOrigin.start([Reply.ok("one").closing, .ok("two")])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let first = try await client.get(origin.url + "/1")
            try await Runtime.sleep(for: .milliseconds(50))
            let second = try await client.get(origin.url + "/2")
            return (first, second, origin.log)
        }
        #expect(first.text == "one")
        #expect(second.text == "two")
        #expect(log.accepted == 2)
    }

    @Test func connectingFailsAsItFails() throws {
        let (refused, unresolved) = try onRuntime {
            // A port nothing listens on: bound, read, and let go.
            let listener = try TCPListener.bind(host: "127.0.0.1", port: 0)
            let port = listener.localPort
            _ = consume listener
            let client = HTTPClient()
            let refused = await failure { () async throws(ClientError) in try await client.get("http://127.0.0.1:\(port)/") }
            let unresolved = await failure { () async throws(ClientError) in try await client.get("http://no-such-host.invalid/") }
            return (refused, unresolved)
        }
        if case .connect(.failed) = refused {} else { Issue.record("\(String(describing: refused))") }
        #expect(unresolved == .connect(.unresolved))
    }

    @Test func aCompressedBodyIsDecoded() throws {
        let text = String(repeating: "decoded ", count: 400)
        let (answer, plain) = try onRuntime {
            let app = Application()
            app.get("/text") { _, response in
                response.send(bytes: Array(text.utf8), contentType: "text/plain; charset=utf-8")
            }
            var config = ServerConfig()
            config.compress = true
            let server = try LoopbackServer.start(app, config: config)
            defer { Task { await server.stop() } }
            let answer = try await HTTPClient().get(server.url + "/text")
            var raw = HTTPClient()
            raw.decompress = false
            let plain = try await raw.get(server.url + "/text", headers: [("Accept-Encoding", "gzip")])
            return (answer, plain)
        }
        #expect(answer.text == text)
        #expect(answer.header("content-encoding") == nil)
        #expect(plain.header("content-encoding") == "gzip")
        #expect(plain.body.count < text.utf8.count)
    }
}

/// `pieces` as a chunked body, the last chunk included.
func chunked(_ pieces: [String]) -> String {
    pieces.map { String($0.utf8.count, radix: 16) + "\r\n" + $0 + "\r\n" }.joined() + "0\r\n\r\n"
}

extension Reply {
    /// The same reply, with the connection closed after it.
    var closing: Reply {
        var copy = self
        copy.close = true
        return copy
    }
}

// MARK: - Redirects

@Suite("HTTP client redirects")
struct HTTPClientRedirectTests {

    @Test func aRedirectIsTheResponseUnlessThePolicyFollowsIt() throws {
        let (unfollowed, followed, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 302 Found\r\nLocation: /b\r\nContent-Length: 0\r\n\r\n"),
                Reply("HTTP/1.1 302 Found\r\nLocation: /b\r\nContent-Length: 0\r\n\r\n"),
                .ok("at b"),
            ])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            let unfollowed = try await client.get(origin.url + "/a")
            client.redirects = .sameOrigin()
            let followed = try await client.get(origin.url + "/a")
            return (unfollowed, followed, origin.log)
        }
        #expect(unfollowed.status == 302)
        #expect(followed.text == "at b")
        #expect(followed.url.hasSuffix("/b"))
        #expect(log.requests.last?.hasPrefix("GET /b HTTP/1.1") == true)
    }

    @Test func a303TurnsAPostIntoAGetWithoutItsBody() throws {
        let (answer, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 303 See Other\r\nLocation: /done\r\nContent-Length: 0\r\n\r\n"),
                .ok("done"),
            ])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            client.redirects = .sameOrigin()
            let answer = try await client.post(origin.url + "/form", body: Array("x=1".utf8), contentType: "text/plain")
            return (answer, origin.log)
        }
        #expect(answer.text == "done")
        let second = log.requests[1]
        #expect(second.hasPrefix("GET /done HTTP/1.1"))
        #expect(!second.contains("Content-Type"))
        #expect(!second.contains("x=1"))
    }

    @Test func leavingTheOriginNeedsAPolicyThatAllowsItAndDropsCredentials() throws {
        let (same, any, log) = try onRuntime {
            let elsewhere = try ScriptedOrigin.start([.ok("elsewhere")])
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 302 Found\r\nLocation: \(elsewhere.url)/x\r\nContent-Length: 0\r\n\r\n"),
                Reply("HTTP/1.1 302 Found\r\nLocation: \(elsewhere.url)/x\r\nContent-Length: 0\r\n\r\n"),
            ])
            defer { Task { await origin.stop(); await elsewhere.stop() } }
            var client = HTTPClient()
            client.redirects = .sameOrigin()
            let same = try await client.get(origin.url + "/a", headers: [("Authorization", "Bearer t")])
            client.redirects = .any()
            let any = try await client.get(origin.url + "/a", headers: [("Authorization", "Bearer t"), ("X-Keep", "1")])
            return (same, any, elsewhere.log)
        }
        #expect(same.status == 302)
        #expect(any.text == "elsewhere")
        #expect(!log.requests[0].contains("Authorization"))
        #expect(log.requests[0].contains("X-Keep: 1"))
    }

    @Test func tooManyRedirectsIsAnError() throws {
        let error = try onRuntime {
            let loop = Reply("HTTP/1.1 302 Found\r\nLocation: /again\r\nContent-Length: 0\r\n\r\n")
            let origin = try ScriptedOrigin.start([loop, loop, loop, loop])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            client.redirects = .sameOrigin(limit: 2)
            return await failure { () async throws(ClientError) in try await client.get(origin.url + "/a") }
        }
        #expect(error == .tooManyRedirects)
    }

    @Test func locationsResolveAgainstTheURLAsked() {
        let base = "http://example.com:8080/a/b/c?q=1#f"
        #expect(resolveReference("/x", against: base) == "http://example.com:8080/x")
        #expect(resolveReference("d", against: base) == "http://example.com:8080/a/b/d")
        #expect(resolveReference("../d?e=f", against: base) == "http://example.com:8080/a/d?e=f")
        #expect(resolveReference("./", against: base) == "http://example.com:8080/a/b/")
        #expect(resolveReference("../../../../x", against: base) == "http://example.com:8080/x")
        #expect(resolveReference("?z=2", against: base) == "http://example.com:8080/a/b/c?z=2")
        #expect(resolveReference("//other.example/p", against: base) == "http://other.example/p")
        #expect(resolveReference("HTTPS://secure.example/p#frag", against: base) == "https://secure.example/p")
        #expect(resolveReference(" /spaced ", against: base) == "http://example.com:8080/spaced")
        #expect(resolveReference("ftp://files.example/", against: base) == nil)
        #expect(resolveReference("javascript:alert(1)", against: base) == nil)
        #expect(resolveReference("/x", against: "http://example.com") == "http://example.com/x")
        #expect(resolveReference("y", against: "http://example.com") == "http://example.com/y")
    }

    @Test func httpsIsNeverLeftForHTTP() {
        var client = HTTPClient()
        client.redirects = .any()
        #expect(client.redirect(302, "http://example.com/x", from: "https://example.com/a") == nil)
        #expect(client.redirect(302, "https://example.com/x", from: "http://example.com/a") == "https://example.com/x")
    }
}

// MARK: - Streams

@Suite("HTTP client streams")
struct HTTPClientStreamTests {

    @Test func aChunkedBodyIsHandedOverAsItArrivesAndItsEventsRead() throws {
        let (pieces, events, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nfirst \r\n6\r\nsecond\r\n0\r\n\r\n", splitAfter: 50),
                Reply("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
                      + chunked(["data: one\n\n", "\r\n: tick\nevent: ", "end\ndata: 2\n", "\n"]), splitAfter: 90),
            ])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let upstream = try await client.stream(.get, origin.url + "/pieces")
            var pieces: [String] = []
            while let piece = try await upstream.next() { pieces.append(String(decoding: piece, as: UTF8.self)) }
            let events = try await client.stream(.get, origin.url + "/events")
            var seen: [ServerSentEvent] = []
            while let event = try await events.nextEvent() { seen.append(event) }
            return (pieces, seen, origin.log)
        }
        #expect(pieces.joined() == "first second")
        #expect(events == [ServerSentEvent(data: "one"), ServerSentEvent(event: "end", data: "2")])
        // Read to their ends, both on one connection, which asked for no
        // compression.
        #expect(log.accepted == 1)
        #expect(!log.requests[0].contains("Accept-Encoding"))
    }

    @Test func aStreamGivenUpOnClosesItsConnection() throws {
        let log = try onRuntime {
            let origin = try ScriptedOrigin.start([
                Reply("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nfirst", splitAfter: 0),
                .ok("next"),
            ])
            defer { Task { await origin.stop() } }
            let client = HTTPClient()
            let upstream = try await client.stream(.get, origin.url + "/big")
            _ = try await upstream.next()
            upstream.cancel()
            _ = try await client.get(origin.url + "/next")
            return origin.log
        }
        #expect(log.accepted == 2)
    }

    @Test func aStreamIsNotHeldToTheBodyLimitButCollectIs() throws {
        let (streamed, collected) = try onRuntime {
            let body = String(repeating: "x", count: 1000)
            let origin = try ScriptedOrigin.start([.ok(body), .ok(body)])
            defer { Task { await origin.stop() } }
            var client = HTTPClient()
            client.maxBodyBytes = 100
            let upstream = try await client.stream(.get, origin.url + "/1")
            var count = 0
            while let piece = try await upstream.next() { count += piece.count }
            let again = try await client.stream(.get, origin.url + "/2")
            let collected: ClientError?
            do throws(ClientError) {
                _ = try await again.collect()
                collected = nil
            } catch {
                collected = error
            }
            return (count, collected)
        }
        #expect(streamed == 1000)
        #expect(collected == .bodyTooLarge)
    }
}

@Suite("Server-sent events, read")
struct ServerSentEventParserTests {
    private func parse(_ parts: [String], limit: Int = 1 << 20) -> [ServerSentEvent]? {
        var parser = ServerSentEventParser()
        var out: [ServerSentEvent] = []
        for part in parts {
            guard parser.feed(Array(part.utf8), limit: limit) else { return nil }
            while let event = parser.take() { out.append(event) }
        }
        return out
    }

    @Test func linesEndWithCRLFOrLFOrCR() {
        #expect(parse(["data: a\r\n\r\ndata: b\n\ndata: c\r\r"]) ==
                [ServerSentEvent(data: "a"), ServerSentEvent(data: "b"), ServerSentEvent(data: "c")])
    }

    @Test func aCRAndItsLFSplitAcrossReadsEndOneLine() {
        #expect(parse(["data: a\r", "\ndata: b\r", "\n\r", "\n"]) == [ServerSentEvent(data: "a\nb")])
    }

    @Test func fieldsAreReadAsTheFormatSays() {
        let events = parse(["\u{FEFF}event: tick\ndata:no space\ndata:  two spaces\nid: 7\nretry: 1500\n\n",
                            "data: later\n\n", "id\ndata: cleared\n\n"])
        #expect(events == [
            ServerSentEvent(event: "tick", data: "no space\n two spaces", id: "7", retry: 1500),
            ServerSentEvent(data: "later", id: "7"),
            ServerSentEvent(data: "cleared", id: ""),
        ])
    }

    @Test func commentsAndEventsWithoutDataAreNotEvents() {
        #expect(parse([": keep-alive\n\nevent: nothing\n\nretry: x\ndata: yes\n\n"]) == [ServerSentEvent(data: "yes")])
    }

    @Test func anEventCutOffByTheEndIsNotReturned() {
        #expect(parse(["data: whole\n\ndata: cut"]) == [ServerSentEvent(data: "whole")])
    }

    @Test func aLineWithNoEndIsHeldToTheLimit() {
        #expect(parse([String(repeating: "x", count: 100)], limit: 50) == nil)
        #expect(parse(["data: " + String(repeating: "x", count: 40) + "\n"], limit: 50) != nil)
    }
}

// MARK: - HTTP/2

@Suite("HTTP client over HTTP/2")
struct HTTP2ClientTests {
    private func app() -> Application {
        let app = Application()
        app.get("/n/:n") { request, response in
            await Task.yield()
            response.send("n=\(request.parameter(0)) ok")
        }
        app.get("/big") { _, response in response.send(String(repeating: "0123456789", count: 100_000)) }
        app.post("/echo") { request, response in
            let body = request.body
            response.send("\(body.count):\(body.count > 0 ? Int(body[body.count - 1]) : -1)")
        }
        app.get("/stream") { _, response in
            let body = response.stream(contentType: "text/plain")
            for i in 0..<20 { try await body.write(String(repeating: "\(i % 10)", count: 10_000)) }
        }
        return app
    }

    private var forced: HTTPClient {
        var client = HTTPClient()
        client.forceHTTP2 = true
        client.decompress = false
        return client
    }

    @Test func requestsAtOnceShareOneConnection() throws {
        let client = forced
        let (answers, accepted) = try onRuntime {
            let server = try LoopbackServer.start(app())
            defer { Task { await server.stop() } }
            let answers = try await withThrowingTaskGroup(of: (Int, String).self) { group in
                for i in 0..<20 {
                    group.addTask(executorPreference: ClientTestRuntime.shared.executor) {
                        (i, try await client.get(server.url + "/n/\(i)").text)
                    }
                }
                var all: [Int: String] = [:]
                for try await (i, text) in group { all[i] = text }
                return all
            }
            return (answers, server.accepted.accepted)
        }
        #expect(answers.count == 20)
        #expect((0..<20).allSatisfy { answers[$0]?.hasPrefix("n=\($0) ") == true })
        #expect(accepted == 1)
    }

    @Test func aBodyLargerThanEveryWindowArrivesWhole() throws {
        let client = forced
        let (whole, streamed, echoed) = try onRuntime {
            let server = try LoopbackServer.start(app())
            defer { Task { await server.stop() } }
            let whole = try await client.get(server.url + "/big")
            let upstream = try await client.stream(.get, server.url + "/stream")
            var streamed = 0
            while let piece = try await upstream.next() {
                streamed += piece.count
                try await Runtime.sleep(for: .milliseconds(1))
            }
            let payload = [UInt8]((0..<300_000).map { UInt8(truncatingIfNeeded: $0) })
            let echoed = try await client.post(server.url + "/echo", body: payload, contentType: "application/octet-stream")
            return (whole, streamed, echoed.text)
        }
        #expect(whole.status == 200)
        #expect(whole.body.count == 1_000_000)
        #expect(whole.reason == "")
        #expect(streamed == 200_000)
        #expect(echoed == "300000:\(Int(UInt8(truncatingIfNeeded: 299_999)))")
    }

    @Test func httpsChoosesHTTP2ByALPNAndSharesTheConnection() throws {
        let certificate = try TestCertificate(["localhost"], tag: "client-h2")
        defer { certificate.remove() }
        var configured = HTTPClient()
        configured.caFile = certificate.files.chain
        let client = configured
        let (texts, accepted, http1, http1Accepted) = try onRuntime {
            let server = try LoopbackServer.start(app(), certificate: certificate)
            defer { Task { await server.stop() } }
            var texts: [String] = []
            for i in 0..<3 { texts.append(try await client.get("https://localhost:\(server.port)/n/\(i)").text) }
            let accepted = server.accepted.accepted
            // Offered HTTP/1.1 alone, it is HTTP/1.1, kept as such.
            var old = HTTPClient()
            old.caFile = certificate.files.chain
            old.alpn = ["http/1.1"]
            var http1: [String] = []
            for i in 0..<3 { http1.append(try await old.get("https://localhost:\(server.port)/n/\(i)").text) }
            return (texts, accepted, http1, server.accepted.accepted - accepted)
        }
        #expect(texts.count == 3)
        #expect(texts.allSatisfy { $0.hasPrefix("n=") })
        #expect(accepted == 1)
        #expect(http1.count == 3)
        #expect(http1Accepted == 1)
    }

    @Test func anUntrustedCertificateIsRefused() throws {
        let certificate = try TestCertificate(["localhost"], tag: "client-untrusted")
        defer { certificate.remove() }
        let error = try onRuntime {
            let server = try LoopbackServer.start(app(), certificate: certificate)
            defer { Task { await server.stop() } }
            return await failure { () async throws(ClientError) in
                try await HTTPClient().get("https://localhost:\(server.port)/n/1")
            }
        }
        if case .connect(.failed) = error {} else { Issue.record("\(String(describing: error))") }
    }
}

// MARK: - Tracing

@Suite("HTTP client tracing", .serialized)
struct HTTPClientTracingTests {
    @Test func anOutboundCallIsAClientSpanThatCarriesTheTraceOn() throws {
        let tracer = InMemoryTracer()
        let (text, log) = try onRuntime {
            let origin = try ScriptedOrigin.start([.ok("upstream")])
            defer { Task { await origin.stop() } }
            let app = Application()
            app.tracing { _ in tracer }
            app.get("/call") { _, response in
                let answer = try await HTTPClient().get(origin.url + "/u?token=secret")
                response.send(answer.text)
            }
            let server = try LoopbackServer.start(app)
            defer { Task { await server.stop() } }
            let compiled = app.compile()
            compiled.tracer = tracer
            let text = try await HTTPClient().get(server.url + "/call").text
            return (text, origin.log)
        }
        #expect(text == "upstream")
        let spans = tracer.ownSpans
        let request = try #require(spans.first { $0.operationName == "GET /call" })
        let call = try #require(spans.first { $0.kind == .client })
        #expect(call.operationName == "GET")
        #expect(call.parentSpanID == request.spanID)
        #expect(call.attributes.get("http.response.status_code") == .int64(200))
        if case .string(let url)? = call.attributes.get("url.full") {
            #expect(url.hasSuffix("/u?token=REDACTED"))
        } else {
            Issue.record("no url.full")
        }
        let head = log.requests[0]
        #expect(head.contains("\(InMemoryTracer.traceIDKey): \(call.traceID)"))
        #expect(head.contains("\(InMemoryTracer.spanIDKey): \(call.spanID)"))
    }
}
