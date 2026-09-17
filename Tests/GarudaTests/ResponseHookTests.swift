import Testing
import CAvian
import AvianCore
@testable import Garuda

// `Response.onSend`: a hook that sees the response a request is about to
// send, whoever sends it, and may change it.

nonisolated(unsafe) private var hooksRan = 0

/// Registers a hook that leaves a mark, so a test can see the order hooks ran.
private func markOnSend(_ name: String) -> Middleware {
    { _, response in
        response.onSend { $0.addHeader("x-trace", name) }
        return nil
    }
}

@Suite("Response hooks", .serialized)
struct ResponseHookTests {

    @Test func aHookAddsAHeaderToTheHandlersAnswer() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { $0.addHeader("access-control-allow-origin", "*") }
            return nil
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.text == "x")
        #expect(response.header("access-control-allow-origin") == "*")
    }

    @Test func aHookSeesTheStatusAndCanChangeIt() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { outgoing in
                outgoing.addHeader("x-seen", String(outgoing.status.code))
                if outgoing.status == .created { outgoing.status = .accepted }
            }
            return nil
        }
        app.post("/things") { _, response in response.send(status: .created, "made") }
        let response = try app.test.request("POST", "/things")
        #expect(response.status == 202)
        #expect(response.header("x-seen") == "201")
        #expect(response.text == "made")
    }

    @Test func aHookSeesTheBody() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { outgoing in
                let text = outgoing.withBody { $0.string }
                outgoing.addHeader("x-body", text.uppercased())
                outgoing.addHeader("x-count", String(outgoing.bodyCount))
            }
            return nil
        }
        app.get("/x") { _, response in response.send("hello") }
        let response = try app.test.get("/x")
        #expect(response.header("x-body") == "HELLO")
        #expect(response.header("x-count") == "5")
    }

    @Test func aReplacedBodyIsFramedByItsOwnLength() throws {
        // The handler stated a length for its own body. Keeping that header
        // would frame the new body wrongly and end the connection.
        let app = Application()
        app.use { _, response in
            response.onSend { $0.replaceBody("goodbye, world") }
            return nil
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
        app.use { _, response in
            response.onSend { outgoing in
                guard outgoing.status.code >= 500 else { return }
                try? outgoing.replaceBody(json: ["error": "internal"])
            }
            return nil
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
        app.use { _, response in
            response.onSend { $0.removeHeader("X-Internal") }
            return nil
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

    @Test func setHeaderLeavesOneValue() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { outgoing in
                outgoing.addHeader("x-was", outgoing.header("Cache-Control") ?? "none")
                outgoing.setHeader("cache-control", "no-store")
            }
            return nil
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
        app.use(markOnSend("global"))
        app.group("/api") {
            app.use(markOnSend("outer"))
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
        app.use(markOnSend("cors"))
        app.use { _, _ in HTTPStatus.unauthorized }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.status == 401)
        #expect(response.headers(named: "x-trace") == ["cors"])
    }

    @Test func aHookRunsOnThrownErrors() throws {
        let app = Application()
        app.use(markOnSend("seen"))
        app.get("/planned") { _, _ in throw HTTPError(.forbidden, "no") }
        app.get("/fault") { _, _ in throw CancellationError() }
        let client = app.test
        let planned = try client.get("/planned")
        #expect(planned.status == 403)
        #expect(planned.header("x-trace") == "seen")
        let fault = try client.get("/fault")
        #expect(fault.status == 500)
        #expect(fault.header("x-trace") == "seen")
    }

    @Test func aHookRunsWhenAnAsyncHandlerAnswersLater() throws {
        let app = Application()
        app.use(markOnSend("later"))
        app.onAsync(.get, "/slow") { _, response in
            try await response.sleep(milliseconds: 2)
            response.send("slept")
        }
        let response = try app.test.get("/slow")
        #expect(response.text == "slept")
        #expect(response.header("x-trace") == "later")
    }

    @Test func aHookRunsOnADeadlinesAnswer() throws {
        let app = Application()
        app.use(markOnSend("timed"))
        app.deadline(milliseconds: 20) {
            app.onAsync(.get, "/slow") { _, response in
                try await response.sleep(milliseconds: 5_000)
                response.send("slept")
            }
        }
        let response = try app.test.get("/slow")
        #expect(response.status == 504)
        #expect(response.header("x-trace") == "timed")
    }

    @Test func aHookRunsOnce() throws {
        hooksRan = 0
        let app = Application()
        app.use { _, response in
            response.onSend { _ in hooksRan += 1 }
            return nil
        }
        app.get("/x") { _, response in
            response.send("x")
            // A second answer is dropped, and does not run the hook again.
            response.send("y")
        }
        #expect(try app.test.get("/x").text == "x")
        #expect(hooksRan == 1)
    }

    @Test func aHookAddedAfterTheAnswerDoesNothing() throws {
        hooksRan = 0
        let app = Application()
        app.get("/x") { _, response in
            response.send("x")
            response.onSend { _ in hooksRan += 1 }
        }
        #expect(try app.test.get("/x").text == "x")
        #expect(hooksRan == 0)
    }

    @Test func aHeadResponseStillSendsNoBody() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { $0.replaceBody("a longer body than before") }
            return nil
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.request("HEAD", "/x")
        #expect(response.status == 200)
        #expect(response.text == "")
        #expect(response.header("content-length") == "25")
    }
}
