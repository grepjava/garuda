import Testing
import Synchronization
@testable import Garuda

// app.onResponse: what an observer sees for routes, misses, failures and
// planned errors.

private struct Boom: Error, CustomStringConvertible {
    var description: String { "boom" }
}

private final class Seen: Sendable {
    let requests = Mutex<[CompletedRequest]>([])
    func take() -> [CompletedRequest] { requests.withLock { let out = $0; $0.removeAll(); return out } }
}

@Suite("Response observers")
struct ResponseObserverTests {

    private func app(_ seen: Seen) -> Application {
        let app = Application()
        app.onResponse { completed in seen.requests.withLock { $0.append(completed) } }
        app.group("/api") {
            app.get("/users/:id") { request, response in response.send("user \(request.parameter(0))") }
            app.get("/boom") { _, _ in throw Boom() }
            app.get("/forbidden") { _, _ in throw HTTPError.forbidden("no") }
            app.get("/silent") { _, _ in }
            app.onAsync(.get, "/later") { _, _ in
                await Task.yield()
                throw Boom()
            }
        }
        return app
    }

    @Test func aRouteIsReportedByItsPattern() throws {
        let seen = Seen()
        var config = ServerConfig()
        config.maxConnections = 16
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
        // The miss after a routed request on the same connection is not
        // reported under the earlier route.
        #expect(statuses == ["200 /api/users/:id", "404 -", "405 -"])
    }

    @Test func failuresSayWhatWentWrongAndPlannedErrorsDoNot() throws {
        let seen = Seen()
        let client = app(seen).test
        #expect(try client.get("/api/boom").status == 500)
        #expect(try client.get("/api/forbidden").status == 403)
        #expect(try client.get("/api/silent").status == 500)
        #expect(try client.get("/api/later").status == 500)
        #expect(try client.get("/api/users/1").status == 200)
        let reports = seen.take().map { "\($0.status) \($0.route ?? "-") \($0.failure ?? "-")" }
        #expect(reports == [
            "500 /api/boom handler threw: boom",
            "403 /api/forbidden -",
            "500 /api/silent the handler returned without answering",
            "500 /api/later handler threw: boom",
            "200 /api/users/:id -",
        ])
    }

    @Test func aFallbackAnswersWithNoRoute() throws {
        let seen = Seen()
        let app = Application()
        app.onResponse { completed in seen.requests.withLock { $0.append(completed) } }
        app.fallback { _, response in response.send(status: .notFound, "custom") }
        let client = app.test
        #expect(try client.get("/anything").text == "custom")
        let completed = try #require(seen.take().first)
        #expect(completed.status == 404 && completed.route == nil)
    }
}
