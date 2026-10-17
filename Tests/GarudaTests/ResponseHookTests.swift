import Testing
@testable import Garuda
import GarudaTesting
import Vega

// `Response.onSend`: a hook that sees the response a request is about to
// send, whoever made it, and may change it.

/// Registers a hook that leaves a mark, so a test can see the order hooks ran.
private struct MarkOnSend: Middleware {
    let name: String

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        let name = self.name
        response.onSend { $0.addHeader("x-trace", name) }
        try await next()
    }
}

@Suite("Response hooks")
struct ResponseHookTests {

    @Test func aHookAddsAHeaderToTheHandlersAnswer() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.addHeader("access-control-allow-origin", "*") }
            try await next()
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.text == "x")
        #expect(response.header("access-control-allow-origin") == "*")
    }

    @Test func aHookSeesTheStatusAndCanChangeIt() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { outgoing in
                outgoing.addHeader("x-seen", String(outgoing.status.code))
                if outgoing.status == .created { outgoing.status = .accepted }
            }
            try await next()
        }
        app.post("/things") { _, response in response.send(status: .created, "made") }
        let response = try app.test.request("POST", "/things")
        #expect(response.status == 202)
        #expect(response.header("x-seen") == "201")
        #expect(response.text == "made")
    }

    @Test func aHookSeesTheBody() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { outgoing in
                let text = outgoing.withBody { $0.string }
                outgoing.addHeader("x-body", text.uppercased())
                outgoing.addHeader("x-count", String(outgoing.bodyCount))
            }
            try await next()
        }
        app.get("/x") { _, response in response.send("hello") }
        app.get("/empty") { _, response in response.send(status: .ok) }
        let client = app.test
        let response = try client.get("/x")
        #expect(response.header("x-body") == "HELLO")
        #expect(response.header("x-count") == "5")
        // An empty body is lent as an empty span.
        let empty = try client.get("/empty")
        #expect(empty.header("x-count") == "0")
    }

    @Test func aReplacedBodyIsFramedByItsOwnLength() throws {
        // The handler stated a length for its own body. Keeping that header
        // would frame the new body wrongly and end the connection.
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.replaceBody("goodbye, world") }
            try await next()
        }
        app.get("/x") { _, response in
            response.addHeader("content-length", "5")
            response.send("hello")
        }
        let response = try app.test.get("/x")
        #expect(response.text == "goodbye, world")
        #expect(response.header("content-length") == "14")
    }

    @Test func aBodyReplacedWithJSONSaysSo() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { outgoing in
                guard outgoing.status.code >= 500 else { return }
                try? outgoing.replaceBody(json: ["error": "internal"])
            }
            try await next()
        }
        app.get("/boom") { _, response in
            response.addHeader("content-type", "text/plain")
            response.send(status: .internalServerError, "stack trace nobody should see")
        }
        app.get("/fine") { _, response in response.send("fine") }
        let client = app.test
        let failed = try client.get("/boom")
        #expect(failed.status == 500)
        #expect(failed.text == #"{"error":"internal"}"#)
        #expect(failed.headers(named: "content-type") == ["application/json"])
        #expect(try client.get("/fine").text == "fine")
    }

    @Test func aHookRemovesAHeader() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.removeHeader("X-Internal") }
            try await next()
        }
        app.get("/x") { _, response in
            response.addHeader("x-internal", "a")
            response.addHeader("x-kept", "b")
            response.addHeader("X-Internal", "c")
            response.send("x")
        }
        let response = try app.test.get("/x")
        #expect(response.header("x-internal") == nil)
        #expect(response.header("x-kept") == "b")
    }

    @Test func aRemovedServerHeaderIsTheServersAgain() throws {
        // What the handler's own Date or Server stood in for is written by the
        // connection once the hook takes it away, rather than left out.
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.removeHeader("server") }
            try await next()
        }
        app.get("/x") { _, response in
            response.addHeader("server", "mine")
            response.send("x")
        }
        let response = try app.test.get("/x")
        #expect(response.headers(named: "server") == ["garuda"])
    }

    @Test func setHeaderLeavesOneValue() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { outgoing in
                outgoing.addHeader("x-was", outgoing.header("Cache-Control") ?? "none")
                outgoing.setHeader("cache-control", "no-store")
            }
            try await next()
        }
        app.get("/x") { _, response in
            response.addHeader("cache-control", "public")
            response.addHeader("cache-control", "max-age=60")
            response.send("x")
        }
        let response = try app.test.get("/x")
        #expect(response.headers(named: "cache-control") == ["no-store"])
        #expect(response.header("x-was") == "public")
    }

    @Test func hooksRunLastAddedFirst() throws {
        // Middleware that ran first sees the response last, as layers wrap.
        let app = Application()
        app.use(MarkOnSend(name: "global"))
        app.group("/api") {
            app.use(MarkOnSend(name: "outer"))
            app.get("/x") { _, response in
                response.onSend { $0.addHeader("x-trace", "handler") }
                response.send("x")
            }
        }
        let response = try app.test.get("/api/x")
        #expect(response.headers(named: "x-trace") == ["handler", "outer", "global"])
    }

    @Test func aHookRunsOnAMiddlewaresRefusal() throws {
        let app = Application()
        app.use(MarkOnSend(name: "cors"))
        app.use { _, response, _ in response.send(status: .unauthorized) }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.status == 401)
        #expect(response.headers(named: "x-trace") == ["cors"])
    }

    @Test func aHookRunsOnThrownErrors() throws {
        let app = Application()
        app.use(MarkOnSend(name: "seen"))
        app.get("/planned") { _, _ in throw HTTPError(.forbidden, "no") }
        app.get("/fault") { _, _ in throw CancellationError() }
        app.get("/silent") { _, _ in }
        let client = app.test
        let planned = try client.get("/planned")
        #expect(planned.status == 403)
        #expect(planned.header("x-trace") == "seen")
        let fault = try client.get("/fault")
        #expect(fault.status == 500)
        #expect(fault.header("x-trace") == "seen")
        let silent = try client.get("/silent")
        #expect(silent.status == 500)
        #expect(silent.header("x-trace") == "seen")
    }

    @Test func aHookRunsWhenAnAsyncHandlerAnswersLater() throws {
        let app = Application()
        app.use(MarkOnSend(name: "later"))
        app.get("/slow") { _, response in
            try await Runtime.sleep(for: .milliseconds(2))
            response.send("slept")
        }
        let response = try app.test.get("/slow")
        #expect(response.text == "slept")
        #expect(response.header("x-trace") == "later")
    }

    @Test func aHookRunsOnADeadlinesAnswer() throws {
        let app = Application()
        app.use(MarkOnSend(name: "timed"))
        app.deadline(.milliseconds(20)) {
            app.get("/slow") { _, response in
                try await waitForever()
                response.send("unreached")
            }
        }
        let response = try app.test.get("/slow")
        #expect(response.status == 504)
        #expect(response.header("x-trace") == "timed")
    }

    @Test func aHookRunsOnce() throws {
        let ran = Counter()
        let app = Application()
        app.use { _, response, next in
            response.onSend { _ in ran.increment() }
            try await next()
        }
        app.get("/x") { _, response in
            response.send("x")
            // A second answer is dropped, and does not run the hook again.
            response.send("y")
        }
        let client = app.test
        #expect(try client.get("/x").text == "x")
        #expect(ran.value == 1)
        // Nor does the next request on a connection that ran one.
        let both = try client.sendPipelined(raw: Array(
            "GET /x HTTP/1.1\r\nHost: t\r\n\r\nGET /x HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n".utf8))
        #expect(both.count == 2)
        #expect(ran.value == 3)
    }

    @Test func aHookCanBeAddedUntilTheHeadIsWritten() throws {
        // Garuda 2 writes the head after the handler and its middleware have
        // returned, so a hook added after the answer still runs: until then
        // the answer can change, as a header added after `next` can.
        let ran = Counter()
        let app = Application()
        app.get("/x") { _, response in
            response.send("x")
            response.onSend { outgoing in
                ran.increment()
                outgoing.addHeader("x-late", "yes")
            }
        }
        let late = try app.test.get("/x")
        #expect(late.text == "x")
        #expect(late.header("x-late") == "yes")
        #expect(ran.value == 1)
    }

    @Test func aHeadResponseStillSendsNoBody() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.replaceBody("a longer body than before") }
            try await next()
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.request("HEAD", "/x")
        #expect(response.status == 200)
        #expect(response.text == "")
        #expect(response.header("content-length") == "25")
    }

    @Test func aMissRunsNoHooks() throws {
        // A 404 is the connection's answer, made before any middleware runs.
        let ran = Counter()
        let app = Application()
        app.use { _, response, next in
            response.onSend { _ in ran.increment() }
            try await next()
        }
        app.get("/x") { _, response in response.send("x") }
        #expect(try app.test.get("/nowhere").status == 404)
        #expect(ran.value == 0)
    }
}
