import Testing
import Synchronization
@testable import Garuda
import GarudaTesting

// app.onResponse: what an observer sees for routes, misses, failures and
// planned errors.

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

private final class Seen: Sendable {
    let requests = Mutex<[CompletedRequest]>([])
    func take() -> [CompletedRequest] { requests.withLock { let out = $0; $0.removeAll(); return out } }
}

private let traceparent = "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"

@Suite("Response observers")
struct ResponseObserverTests {

    private func app(_ seen: Seen) -> Application {
        let app = Application()
        app.onResponse { completed in seen.requests.withLock { $0.append(completed) } }
        app.group("/api") {
            app.get("/users/:id") { request, response in response.send("user \(request.parameter(0))") }
            app.get("/boom") { _, _ in throw Boom() }
            app.get("/forbidden") { _, _ in throw HTTPError(.forbidden, "no") }
            app.get("/silent") { _, _ in }
            app.get("/later") { _, _ in
                await Task.yield()
                throw Boom()
            }
            app.deadline(.milliseconds(20)) {
                app.get("/stuck") { _, response in
                    try await waitForever()
                    response.send("unreached")
                }
            }
            app.post("/upload") { request, response in response.send("\(request.body.count)") }
        }
        return app
    }

    @Test func aRouteIsReportedByItsPattern() throws {
        let seen = Seen()
        var config = ServerConfig()
        config.requestID = true
        let client = app(seen).testClient(configuration: config)
        let response = try client.get("/api/users/42?full=1")
        #expect(response.text == "user 42")

        let completed = try #require(seen.take().first)
        #expect(completed.method == "GET")
        #expect(completed.path == "/api/users/42")
        #expect(completed.route == "/api/users/:id")
        #expect(completed.status == 200)
        #expect(completed.protocolName == "HTTP/1.1")
        #expect(completed.remoteAddress == "127.0.0.1")
        #expect(completed.requestID == response.header("x-request-id"))
        #expect(completed.traceID == nil)
        #expect(completed.failure == nil)
        #expect(completed.microseconds >= 0)
    }

    @Test func aMissHasNoRoute() throws {
        let seen = Seen()
        let client = app(seen).test
        _ = try client.get("/api/users/42")
        #expect(try client.get("/nowhere").status == 404)
        #expect(try client.post("/api/users/1").status == 405)
        let statuses = seen.take().map { "\($0.status) \($0.route ?? "-")" }
        #expect(statuses == ["200 /api/users/:id", "404 -", "405 -"])
    }

    @Test func aMissAfterARouteOnOneConnectionHasNoRoute() throws {
        // The miss after a routed request on the same connection is not
        // reported under the earlier route.
        let seen = Seen()
        let client = app(seen).test
        let both = try client.sendPipelined(raw: Array(
            ("GET /api/users/1 HTTP/1.1\r\nHost: t\r\n\r\n"
                + "GET /nowhere HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n").utf8))
        #expect(both.map(\.status.code) == [200, 404])
        #expect(seen.take().map { $0.route ?? "-" } == ["/api/users/:id", "-"])
    }

    @Test func failuresSayWhatWentWrongAndPlannedErrorsDoNot() throws {
        let seen = Seen()
        let client = app(seen).test
        #expect(try client.get("/api/boom").status == 500)
        #expect(try client.get("/api/forbidden").status == 403)
        #expect(try client.get("/api/silent").status == 500)
        #expect(try client.get("/api/later").status == 500)
        #expect(try client.get("/api/stuck").status == 504)
        #expect(try client.get("/api/users/1").status == 200)
        let reports = seen.take().map { "\($0.status) \($0.route ?? "-") \($0.failure ?? "-")" }
        #expect(reports == [
            "500 /api/boom handler threw: boom",
            "403 /api/forbidden -",
            "500 /api/silent the handler returned without answering",
            "500 /api/later handler threw: boom",
            "504 /api/stuck the handler passed its deadline",
            "200 /api/users/:id -",
        ])
    }

    @Test func aRequestRefusedBeforeRoutingIsReported() throws {
        // A body past the limit is answered by the connection, which no
        // route saw.
        let seen = Seen()
        var config = ServerConfig()
        config.maxBodySize = 4
        let client = app(seen).testClient(configuration: config)
        #expect(try client.post("/api/upload", body: "too long a body").status == 413)
        let completed = try #require(seen.take().first)
        #expect(completed.status == 413)
        #expect(completed.route == nil)
        #expect(completed.method == "POST")
        #expect(completed.path == "/api/upload")
    }

    @Test func aTraceIsReportedWithTheFlag() throws {
        let seen = Seen()
        var config = ServerConfig()
        config.traceContext = true
        let client = app(seen).testClient(configuration: config)
        _ = try client.get("/api/users/1", headers: [("traceparent", traceparent)])
        // One that is not valid is ignored, as the specification asks.
        _ = try client.get("/api/users/2", headers: [("traceparent", "00-xyz-01")])
        let reports = seen.take()
        #expect(reports.map(\.traceID) == ["4bf92f3577b34da6a3ce929d0e0e4736", nil])
        #expect(reports.map(\.parentID) == ["00f067aa0ba902b7", nil])

        // Without the flag, nothing is read.
        let plain = app(seen).test
        _ = try plain.get("/api/users/1", headers: [("traceparent", traceparent)])
        #expect(seen.take().first?.traceID == nil)
    }

    @Test func anHTTP10RequestSaysSo() throws {
        let seen = Seen()
        let client = app(seen).test
        let response = try client.send(raw: Array("GET /api/users/3 HTTP/1.0\r\nHost: t\r\n\r\n".utf8))
        #expect(response.status == 200)
        #expect(seen.take().first?.protocolName == "HTTP/1.0")
    }
}
