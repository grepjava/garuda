import Testing
import CGaruda
import GarudaCore
@testable import Garuda

// Groups and middleware. A middleware runs before a route's handler: it can
// answer instead of it, or add headers that stay on whatever the handler sends.

nonisolated(unsafe) private var handlerRan = 0

/// Answers 401 unless the request carries the right token.
nonisolated(unsafe) private let requireToken: Middleware = { request, _ in
    request.header("authorization") == "Bearer letmein" ? nil : HTTPStatus.unauthorized
}

private enum Caller: RequestContextKey { typealias Value = String }

/// Waits on the worker's timers, then answers 401 unless the request carries
/// the right token -- the shape of a session looked up in a database.
nonisolated(unsafe) private let lookUpToken: AsyncMiddleware = { request, response in
    asyncMiddlewareRan += 1
    try await response.sleep(milliseconds: 1)
    guard request.header("authorization") == "Bearer letmein" else { return HTTPStatus.unauthorized }
    request[context: Caller.self] = "ada"
    return nil
}

nonisolated(unsafe) private var asyncMiddlewareRan = 0

/// Leaves a mark, so a test can see which middleware ran and in what order.
private func mark(_ name: StaticString) -> Middleware {
    { _, response in
        response.addHeader("x-trace", name)
        return nil
    }
}

@Suite("Groups and middleware", .serialized)
struct MiddlewareTests {

    // MARK: Groups

    @Test func aGroupMountsItsRoutesUnderItsPrefix() throws {
        let app = Application()
        app.group("/api") {
            app.get("/users/:id") { request, response in request.withParameter(0) { response.send($0) } }
        }
        let client = app.test
        #expect(try client.get("/api/users/7").text == "7")
        #expect(try client.get("/users/7").status == 404)
    }

    @Test func nestedGroupsJoinTheirPrefixes() throws {
        let app = Application()
        app.group("/api") {
            app.group("/admin/") {
                app.get("/ping") { _, response in response.send("pong") }
            }
        }
        #expect(try app.test.get("/api/admin/ping").text == "pong")
    }

    @Test func aGroupsOwnRootIsItsPrefix() throws {
        // Not /api/ -- the route a group registers at "/" is the prefix itself.
        let app = Application()
        app.group("/api") {
            app.get("/") { _, response in response.send("root") }
        }
        #expect(try app.test.get("/api").text == "root")
    }

    @Test func aWrongMethodUnderAGroupIsStill405() throws {
        let app = Application()
        app.group("/api") {
            app.get("/users/:id") { _, response in response.send(status: 200) }
        }
        let response = try app.test.request("POST", "/api/users/7")
        #expect(response.status == 405)
        #expect(response.header("allow") == "GET, HEAD")
    }

    // MARK: Middleware

    @Test func middlewareAnswersInsteadOfTheHandler() throws {
        handlerRan = 0
        let app = Application()
        app.group("/api") {
            app.use(requireToken)
            app.get("/secret") { _, response in
                handlerRan += 1
                response.send("s3cret")
            }
        }
        let client = app.test
        let refused = try client.get("/api/secret")
        #expect(refused.status == 401)
        #expect(handlerRan == 0)
        let allowed = try client.get("/api/secret", headers: [("Authorization", "Bearer letmein")])
        #expect(allowed.status == 200)
        #expect(allowed.text == "s3cret")
        #expect(handlerRan == 1)
    }

    @Test func middlewareAppliesWhetherUsedBeforeOrAfterTheRoutes() throws {
        // A layer that covers only the routes registered before it is a
        // well-known way to leave a route unprotected by moving one line. Here
        // `use` covers its whole scope, wherever in it it is called.
        let app = Application()
        app.group("/api") {
            app.get("/secret") { _, response in response.send("s3cret") }
            app.use(requireToken)
        }
        #expect(try app.test.get("/api/secret").status == 401)
    }

    @Test func middlewareStaysInsideItsGroup() throws {
        let app = Application()
        app.group("/api") {
            app.use(requireToken)
            app.get("/secret") { _, response in response.send("s3cret") }
        }
        app.get("/public") { _, response in response.send("hello") }
        let client = app.test
        #expect(try client.get("/public").text == "hello")
        #expect(try client.get("/api/secret").status == 401)
    }

    @Test func middlewareRunsGlobalFirstThenGroupsFromTheOutsideIn() throws {
        let app = Application()
        app.group("/api") {
            app.group("/admin") {
                app.use(mark("inner"))
                app.get("/x") { _, response in response.send("x") }
            }
            app.use(mark("outer"))
        }
        app.use(mark("global"))
        let response = try app.test.get("/api/admin/x")
        #expect(response.headers(named: "x-trace") == ["global", "outer", "inner"])
    }

    @Test func aHeaderAMiddlewareAddsStaysOnTheHandlersResponse() throws {
        let app = Application()
        app.use { _, response in
            response.addHeader("x-frame-options", "DENY")
            return nil
        }
        app.get("/page") { () -> JSON<[String: String]> in JSON(["page": "home"]) }
        let response = try app.test.get("/page")
        #expect(response.status == 200)
        #expect(response.text == #"{"page":"home"}"#)
        #expect(response.header("x-frame-options") == "DENY")
    }

    @Test func aResponseErrorThrownByMiddlewareIsTheAnswer() throws {
        let app = Application()
        app.use { _, _ in throw HTTPError(.forbidden, "not today") }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.status == 403)
        #expect(response.text == #"{"error":"not today"}"#)
    }

    @Test func middlewareGuardsAsyncRoutesBeforeTheirTaskStarts() throws {
        // An async route is a handler that starts a task. The chain runs in
        // front of that, so a refused request never costs a task at all.
        handlerRan = 0
        let app = Application()
        app.use(requireToken)
        app.get("/slow") { () async throws -> String in
            handlerRan += 1
            return "done"
        }
        let client = app.test
        #expect(try client.get("/slow").status == 401)
        #expect(handlerRan == 0)
        let allowed = try client.get("/slow", headers: [("Authorization", "Bearer letmein")])
        #expect(allowed.text == "done")
        #expect(handlerRan == 1)
    }

    // MARK: Async middleware

    @Test func asyncMiddlewareRefusesAfterAwaiting() throws {
        handlerRan = 0
        let app = Application()
        app.use(lookUpToken)
        app.get("/secret") { _, response in
            handlerRan += 1
            response.send("s3cret")
        }
        let client = app.test
        #expect(try client.get("/secret").status == 401)
        #expect(handlerRan == 0)
        let allowed = try client.get("/secret", headers: [("Authorization", "Bearer letmein")])
        #expect(allowed.text == "s3cret")
        #expect(handlerRan == 1)
    }

    @Test func whatAsyncMiddlewareStoresReachesATypedHandler() throws {
        let app = Application()
        app.use(lookUpToken)
        app.get("/me") { (caller: Context<Caller>) in caller.value }
        let response = try app.test.get("/me", headers: [("Authorization", "Bearer letmein")])
        #expect(response.status == 200)
        #expect(response.text == "ada")
    }

    @Test func anAsyncRouteBehindAsyncMiddlewareRunsOnTheSameTask() throws {
        // The chain is already on a task, so the route's async handler is
        // awaited there rather than handed to a second one: one request at a
        // time never needs more than one task.
        let app = Application()
        app.use(lookUpToken)
        app.get("/me") { (caller: Context<Caller>) async throws -> String in
            "hello " + caller.value
        }
        let client = app.test
        let response = try client.get("/me", headers: [("Authorization", "Bearer letmein")])
        #expect(response.status == 200)
        #expect(response.text == "hello ada")
        let pool = try #require(client.worker.pointee.handlerTasks)
        #expect(pool.count == 1)
    }

    @Test func aClosureThatAwaitsIsAsyncMiddleware() throws {
        let app = Application()
        app.use { _, response in
            try await response.sleep(milliseconds: 1)
            response.addHeader("x-waited", "yes")
            return nil
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.text == "x")
        #expect(response.header("x-waited") == "yes")
    }

    @Test func syncAndAsyncMiddlewareRunInTheOrderUsed() throws {
        let app = Application()
        app.use(mark("first"))
        app.use { _, response in
            try await response.sleep(milliseconds: 1)
            response.addHeader("x-trace", "second")
            return nil
        }
        app.use(mark("third"))
        app.group("/api") {
            app.use(mark("fourth"))
            app.get("/x") { _, response in response.send("x") }
        }
        let response = try app.test.get("/api/x")
        #expect(response.headers(named: "x-trace") == ["first", "second", "third", "fourth"])
    }

    @Test func syncMiddlewareInFrontRefusesBeforeTheAsyncOneRuns() throws {
        asyncMiddlewareRan = 0
        let app = Application()
        app.use(requireToken)
        app.use(lookUpToken)
        app.get("/secret") { _, response in response.send("s3cret") }
        let client = app.test
        #expect(try client.get("/secret").status == 401)
        #expect(asyncMiddlewareRan == 0)
        // Refused on the worker: no task was ever needed.
        #expect(client.worker.pointee.handlerTasks == nil)
        #expect(try client.get("/secret", headers: [("Authorization", "Bearer letmein")]).text == "s3cret")
        #expect(asyncMiddlewareRan == 1)
    }

    @Test func aResponseErrorThrownByAsyncMiddlewareIsTheAnswer() throws {
        let app = Application()
        app.use { _, response in
            try await response.sleep(milliseconds: 1)
            throw HTTPError(.forbidden, "not today")
        }
        app.get("/x") { _, response in response.send("x") }
        let response = try app.test.get("/x")
        #expect(response.status == 403)
        #expect(response.text == #"{"error":"not today"}"#)
    }

    @Test func aHandlerThatWaitsOnATimerStillWorksBehindAsyncMiddleware() throws {
        // `after` parks the request for the worker to resume, which takes it
        // off the task the chain ran on.
        let app = Application()
        app.use(lookUpToken)
        app.get("/later") { _, response in
            response.after(milliseconds: 1) { _, later in later.send("later") }
        }
        let response = try app.test.get("/later", headers: [("Authorization", "Bearer letmein")])
        #expect(response.status == 200)
        #expect(response.text == "later")
    }

    @Test func aDeadlineCoversAsyncMiddleware() throws {
        let app = Application()
        app.deadline(milliseconds: 20) {
            app.use { _, response in
                try await response.sleep(milliseconds: 5_000)
                return nil
            }
            app.get("/x") { _, response in response.send("x") }
        }
        #expect(try app.test.get("/x").status == 504)
    }

    @Test func aMissingContextValueIsTheProgramsFault() throws {
        let app = Application()
        app.get("/me") { (caller: Context<Caller>) in caller.value }
        #expect(try app.test.get("/me").status == 500)
    }
}
