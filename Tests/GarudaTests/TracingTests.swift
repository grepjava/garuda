import Testing
@testable import Garuda
import GarudaTesting
import InMemoryTracing
import Tracing
import VegaDBTracing

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

    @Test func anHTTP2StreamIsASpanToo() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/users/:id") { request, response in
            await Task.yield()
            response.send("user \(request.parameter(0))")
        }
        let h2 = try app.test.http2()
        #expect(try h2.get("/users/7").text == "user 7")
        #expect(try h2.get("/users/8").text == "user 8")
        let spans = tracer.finishedSpans
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.operationName == "GET /users/:id" })
        #expect(spans.allSatisfy { $0.attributes.get("network.protocol.version") == .string("2") })
        let paths = spans.compactMap { span -> String? in
            if case .string(let path)? = span.attributes.get("url.path") { return path }
            return nil
        }
        #expect(paths.sorted() == ["/users/7", "/users/8"])
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
        app.get("/forbidden") { _, _ in throw HTTPError(.forbidden, "no") }
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
        app.get("/async") { _, response in
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
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
        app.get("/who") { _, response in
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
        app.get("/lines") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("one\n")
            try await Task.sleep(for: .milliseconds(30))
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
        app.get("/half") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("one\n")
            throw Boom()
        }
        _ = try? app.test.get("/half")
        let span = try #require(tracer.finishedSpans.first)
        #expect(span.status?.code == .error)
        #expect(span.errors.count == 1)
    }

    @Test func aDatabaseRoundTripIsAClientSpanUnderTheRequest() throws {
        let tracer = InMemoryTracer()
        let app = tracedApp(tracer)
        app.get("/query") { _, response in
            // As a vega-db client does with each statement.
            let configured = DatabaseTracing.installed
            if let span = configured?.start({
                var operation = DatabaseOperation(system: "postgresql", name: "SELECT")
                operation.operation = "SELECT"
                operation.queryText = "select 1"
                operation.serverAddress = "db"
                operation.serverPort = 5432
                return operation
            }) {
                span.end()
            }
            if let span = configured?.start({ DatabaseOperation(system: "redis", name: "GET") }) {
                span.fail(DatabaseFailure(Boom(), type: "WRONGTYPE", statusCode: "WRONGTYPE"))
            }
            response.send(configured == nil ? "untraced" : "traced")
        }
        #expect(try app.test.get("/query").text == "traced")
        let spans = tracer.finishedSpans
        let request = try #require(spans.first { $0.operationName == "GET /query" })
        let select = try #require(spans.first { $0.operationName == "SELECT" })
        let get = try #require(spans.first { $0.operationName == "GET" })
        #expect(select.parentSpanID == request.spanID)
        #expect(select.kind == .client)
        #expect(select.attributes.get("db.system.name") == .string("postgresql"))
        #expect(select.attributes.get("db.query.text") == .string("select 1"))
        #expect(select.attributes.get("server.port") == .int64(5432))
        #expect(select.status == nil)
        #expect(get.parentSpanID == request.spanID)
        #expect(get.status?.code == .error)
        #expect(get.attributes.get("db.response.status_code") == .string("WRONGTYPE"))
        #expect(get.attributes.get("error.type") == .string("WRONGTYPE"))
        DatabaseTracing.installed = nil
    }

    @Test func withoutTracingNothingIsTraced() throws {
        let tracer = InMemoryTracer()
        let app = Application()
        app.get("/") { _, response in
            tracer.withSpan("inner") { _ in }
            response.send(ServiceContext.current == nil ? "none" : "some")
        }
        #expect(try app.test.get("/").text == "none")
        // The span started by hand is a root of its own; no request span.
        #expect(tracer.finishedSpans.map(\.operationName) == ["inner"])
    }

    @Test func aURLLosesItsCredentialsAndQueryValues() {
        #expect(redactedURL("https://ana:secret@api.example/v1/x?token=abc&page=2#top")
                == "https://api.example/v1/x?token=REDACTED&page=REDACTED")
        #expect(redactedURL("http://h/p?flag&k=v") == "http://h/p?flag&k=REDACTED")
        #expect(redactedURL("http://h/p") == "http://h/p")
    }
}
