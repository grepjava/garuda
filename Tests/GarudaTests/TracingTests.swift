import Testing
import CAvian
import AvianCore
import AvianHTTP
import Tracing
import InMemoryTracing
@testable import Garuda

// app.tracing: the spans a request, and what its handler does, leave behind.
//
// The in-memory tracer propagates its own two headers rather than W3C's
// traceparent, which is what a real tracer would send; the headers are the
// tracer's business, and what is tested here is that Garuda reads them from
// the request and hands them to the calls it makes.

private struct Boom: Error {}

private func tracedApp(_ tracer: InMemoryTracer) -> Application {
    let app = Application()
    app.tracing { _ in tracer }
    return app
}

private func duration(_ span: FinishedInMemorySpan) -> UInt64 {
    span.endInstant.nanosecondsSinceEpoch - span.startInstant.nanosecondsSinceEpoch
}

nonisolated(unsafe) private var seenContext: String? = nil

/// An origin that answers every request with a fixed response, and keeps
/// each request's head to be looked at.
private final class RecordingOrigin {
    let fd: Int32
    let port: UInt16
    var response = Array("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".utf8)
    private(set) var heads: [String] = []
    private var open: [Int32] = []

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        fd = opened
        port = av_local_port(opened)
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        _ = av_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 { open.append(peer) }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            let head = String(decoding: buffer.prefix(got), as: UTF8.self)
            guard head.contains("\r\n\r\n") else { continue }
            heads.append(head.lowercased())
            _ = response.withUnsafeBytes { av_write(peer, $0.baseAddress, $0.count) }
        }
    }
}

nonisolated(unsafe) private var callOutcome = ""

/// Runs `GET /call` on `app` while the origin answers.
private func call(_ app: Application, _ origin: RecordingOrigin, headers: String = "") throws -> String {
    callOutcome = ""
    let client = app.test
    let wire = try TestWire(client)
    wire.send("GET /call HTTP/1.1\r\nHost: test\r\n\(headers)\r\n")
    _ = wire.turn(until: {
        origin.pump()
        return !callOutcome.isEmpty
    }, turns: 40_000)
    // The answer goes out after the outcome is set; the request's span ends
    // with it.
    _ = wire.receive()
    return callOutcome
}

@Suite("Tracing", .serialized)
struct TracingTests {

    @Test func aRequestIsAServerSpanNamedForItsRoute() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/users/:id") { request, response in response.send("user \(request.parameter(0))") }
        let response = try app.test.get("/users/42", headers: [("User-Agent", "probe/1")])
        #expect(response.status == 200)

        let spans = tracer.finishedSpans
        let span = try #require(spans.first)
        #expect(spans.count == 1)
        #expect(span.operationName == "GET /users/:id")
        #expect(span.kind == .server)
        #expect(span.parentSpanID == nil)
        #expect(span.attributes.get("http.request.method") == .string("GET"))
        #expect(span.attributes.get("http.route") == .string("/users/:id"))
        #expect(span.attributes.get("url.path") == .string("/users/42"))
        #expect(span.attributes.get("url.scheme") == .string("http"))
        #expect(span.attributes.get("network.protocol.version") == .string("1.1"))
        #expect(span.attributes.get("http.response.status_code") == .int64(200))
        #expect(span.attributes.get("user_agent.original") == .string("probe/1"))
        #expect(span.status == nil)
    }

    @Test func aMissIsNamedForItsMethodAlone() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/here") { _, response in response.send("here") }
        #expect(try app.test.get("/users/42").status == 404)
        let span = try #require(tracer.finishedSpans.first)
        // Never the path: every path a scanner tries would be a name.
        #expect(span.operationName == "GET")
        #expect(span.attributes.get("http.route") == nil)
        #expect(span.attributes.get("http.response.status_code") == .int64(404))
        // A 4xx is the client's fault, not the server's.
        #expect(span.status == nil)
    }

    @Test func aTraceTheCallerSentIsContinued() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/") { _, response in response.send("ok") }
        _ = try app.test.get("/", headers: [(InMemoryTracer.traceIDKey, "trace-7"),
                                            (InMemoryTracer.spanIDKey, "caller-3")])
        let span = try #require(tracer.finishedSpans.first)
        #expect(span.traceID == "trace-7")
        #expect(span.parentSpanID == "caller-3")
    }

    @Test func aHandlerThatThrowsFailsItsSpanAndAPlannedErrorDoesNot() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/boom") { _, _ in throw Boom() }
        app.get("/forbidden") { _, _ in throw HTTPError.forbidden("no") }
        let client = app.test
        #expect(try client.get("/boom").status == 500)
        #expect(try client.get("/forbidden").status == 403)

        let spans = tracer.finishedSpans
        #expect(spans.count == 2)
        let boom = try #require(spans.first { $0.operationName == "GET /boom" })
        #expect(boom.status?.code == .error)
        #expect(boom.status?.message == "handler threw: Boom()")
        #expect(boom.errors.count == 1)
        #expect(boom.attributes.get("error.type") == .string("500"))
        let forbidden = try #require(spans.first { $0.operationName == "GET /forbidden" })
        #expect(forbidden.status == nil)
        #expect(forbidden.errors.isEmpty)
    }

    @Test func aSpanTheHandlerStartsIsAChildOfTheRequest() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/sync") { _, response in
            tracer.withSpan("render") { _ in response.send("ok") }
        }
        app.onAsync(.get, "/async") { _, response in
            await Task.yield()
            try await response.sleep(milliseconds: 1)
            await tracer.withSpan("load") { _ in await Task.yield() }
            response.send("ok")
        }
        let client = app.test
        _ = try client.get("/sync")
        _ = try client.get("/async")

        let spans = tracer.finishedSpans
        for (child, parent) in [("render", "GET /sync"), ("load", "GET /async")] {
            let inner = try #require(spans.first { $0.operationName == child })
            let outer = try #require(spans.first { $0.operationName == parent })
            #expect(inner.parentSpanID == outer.spanID)
            #expect(inner.traceID == outer.traceID)
        }
    }

    @Test func theContextIsTheRequestsOwnOnATaskThatServedAnotherBefore() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.onAsync(.get, "/who") { _, response in
            await Task.yield()
            response.send(ServiceContext.current?.inMemorySpanContext?.spanID ?? "none")
        }
        let client = app.test
        let first = try client.get("/who").text
        let second = try client.get("/who").text
        let ids = tracer.finishedSpans.map(\.spanID)
        #expect(ids == [first, second])
        #expect(first != second)
    }

    @Test func aStreamedResponsesSpanEndsWithItsBody() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.onAsync(.get, "/lines") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("one\n")
            try await response.sleep(milliseconds: 30)
            try await body.write("two\n")
        }
        let response = try app.test.get("/lines")
        #expect(response.text == "one\ntwo\n")
        let span = try #require(tracer.finishedSpans.first)
        #expect(tracer.finishedSpans.count == 1)
        #expect(span.operationName == "GET /lines")
        #expect(span.attributes.get("http.response.status_code") == .int64(200))
        // Not ended with the head, which went out before the wait.
        #expect(duration(span) >= 30_000_000)
    }

    @Test func aStreamThatFailsPartWayFailsItsSpan() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.onAsync(.get, "/half") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("one\n")
            throw Boom()
        }
        _ = try? app.test.get("/half")
        let span = try #require(tracer.finishedSpans.first)
        #expect(span.status?.code == .error)
        #expect(span.errors.count == 1)
    }

    @Test func anOutboundCallIsAClientSpanThatCarriesTheTraceOn() throws {
        guard let origin = RecordingOrigin() else { Issue.record("no socket"); return }
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        let url = origin.url + "/upstream?token=secret&page=2"
        app.onAsync(.get, "/call") { request, response in
            do {
                let answer = try await request.client.send(.get, url)
                callOutcome = answer.text
            } catch {
                callOutcome = "\(error)"
            }
            response.send(callOutcome)
        }
        #expect(try call(app, origin) == "ok")

        let spans = tracer.finishedSpans
        let server = try #require(spans.first { $0.kind == .server })
        let client = try #require(spans.first { $0.kind == .client })
        #expect(client.operationName == "GET")
        #expect(client.parentSpanID == server.spanID)
        #expect(client.traceID == server.traceID)
        #expect(client.attributes.get("http.request.method") == .string("GET"))
        #expect(client.attributes.get("http.response.status_code") == .int64(200))
        #expect(client.attributes.get("server.address") == .string("127.0.0.1"))
        #expect(client.attributes.get("server.port") == .int64(Int64(origin.port)))
        // The query's names are kept, its values -- a token, often -- not.
        #expect(client.attributes.get("url.full")
                == .string(origin.url + "/upstream?token=REDACTED&page=REDACTED"))

        // The upstream is told which span called it.
        let head = try #require(origin.heads.first)
        #expect(head.contains("\(InMemoryTracer.traceIDKey): \(client.traceID)"))
        #expect(head.contains("\(InMemoryTracer.spanIDKey): \(client.spanID)"))
    }

    @Test func aCallAnswered4xxOrThatFailsFailsItsSpan() throws {
        guard let origin = RecordingOrigin() else { Issue.record("no socket"); return }
        origin.response = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".utf8)
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        let url = origin.url + "/gone"
        app.onAsync(.get, "/call") { request, response in
            var client = request.client
            client.timeoutMilliseconds = 2_000
            let found = try await client.send(.get, url)
            do {
                // Nothing listens on port 1.
                _ = try await client.send(.get, "http://127.0.0.1:1/")
                callOutcome = "\(found.status) connected"
            } catch {
                callOutcome = "\(found.status) \((error as? ClientError)?.kind ?? "other")"
            }
            response.send(callOutcome)
        }
        #expect(try call(app, origin) == "404 connect")

        let clients = tracer.finishedSpans.filter { $0.kind == .client }
        #expect(clients.count == 2)
        let gone = try #require(clients.first { $0.attributes.get("server.port") == .int64(Int64(origin.port)) })
        #expect(gone.status?.code == .error)
        #expect(gone.attributes.get("error.type") == .string("404"))
        let refused = try #require(clients.first { $0.attributes.get("server.port") == .int64(1) })
        #expect(refused.status?.code == .error)
        #expect(refused.attributes.get("error.type") == .string("connect"))
        #expect(refused.errors.count == 1)
    }

    @Test func aStreamedCallsSpanEndsWithItsBody() throws {
        guard let origin = RecordingOrigin() else { Issue.record("no socket"); return }
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        let url = origin.url + "/stream"
        app.onAsync(.get, "/call") { request, response in
            let upstream = try await request.client.stream(.get, url)
            // Open while the body is still to be read.
            let openBefore = tracer.activeSpans.filter { $0.kind == .client }.count
            let body = try await upstream.collect()
            let openAfter = tracer.activeSpans.filter { $0.kind == .client }.count
            callOutcome = "\(String(decoding: body, as: UTF8.self)) \(openBefore) \(openAfter)"
            response.send(callOutcome)
        }
        #expect(try call(app, origin) == "ok 1 0")
        let client = try #require(tracer.finishedSpans.first { $0.kind == .client })
        #expect(client.attributes.get("http.response.status_code") == .int64(200))
        #expect(client.status == nil)
    }

    @Test func withoutTracingNothingIsTraced() throws {
        let tracer = InMemoryTracer()
        let app = Application()
        app.get("/") { _, response in
            response.send(ServiceContext.current == nil ? "none" : "some")
        }
        #expect(try app.test.get("/").text == "none")
        #expect(tracer.finishedSpans.isEmpty)
    }

    // MARK: Pieces

    @Test func aURLLosesItsCredentialsAndQueryValues() {
        #expect(redactedURL("https://user:pw@example.com/a?x=1&y=&z") == "https://example.com/a?x=REDACTED&y=REDACTED&z")
        #expect(redactedURL("http://example.com:8080/a/b") == "http://example.com:8080/a/b")
        #expect(redactedURL("http://example.com/a#part") == "http://example.com/a")
        // An @ in the path is not a user.
        #expect(redactedURL("http://example.com/users/@me") == "http://example.com/users/@me")
    }

    @Test func aStatementIsNamedForItsFirstWord() {
        #expect(sqlOperation("select * from users") == "SELECT")
        #expect(sqlOperation("  \n(SELECT 1)") == "SELECT")
        #expect(sqlOperation("with recent as (select 1) select * from recent") == "WITH")
        #expect(sqlOperation("-- a comment first\nselect 1") == nil)
        #expect(sqlOperation("") == nil)
    }
}
