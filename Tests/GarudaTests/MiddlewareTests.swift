import Garuda
import GarudaTesting
import Synchronization
import Testing

/// How many times something ran, from any thread.
final class Counter: Sendable {
    private let count = Atomic<Int>(0)
    func increment() { count.add(1, ordering: .relaxed) }
    var value: Int { count.load(ordering: .relaxed) }
}

/// Adds `x-trace: name` on the way in and `x-trace: name-out` on the way out,
/// so the order layers ran in shows in the response.
struct Trace: Middleware {
    let name: String

    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        response.addHeader("x-trace", name)
        try await next()
        response.addHeader("x-trace", name + "-out")
    }
}

struct RequireToken: Middleware {
    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard request.header("authorization") == "Bearer good" else {
            return response.send(status: .unauthorized, "no")
        }
        try await next()
    }
}

@Suite struct MiddlewareTests {
    @Test func runsAroundTheHandler() throws {
        let app = Application()
        app.use(Trace(name: "a"))
        app.get("/") { () in "hi" }
        let response = try app.test.get("/")
        #expect(response.text == "hi")
        #expect(response.headers(named: "x-trace") == ["a", "a-out"])
    }

    @Test func globalThenGroupsFromTheOutsideIn() throws {
        let app = Application()
        app.use(Trace(name: "global"))
        app.group("/api") {
            app.use(Trace(name: "api"))
            app.group("/admin") {
                app.use(Trace(name: "admin"))
                app.get("/x") { () in "x" }
            }
        }
        let response = try app.test.get("/api/admin/x")
        #expect(response.text == "x")
        #expect(response.headers(named: "x-trace")
                == ["global", "api", "admin", "admin-out", "api-out", "global-out"])
    }

    @Test func useAfterTheRoutesStillCoversThem() throws {
        let app = Application()
        app.get("/early") { () in "early" }
        app.use(Trace(name: "late"))
        #expect(try app.test.get("/early").headers(named: "x-trace") == ["late", "late-out"])
    }

    @Test func orderWithinAScopeIsTheOrderOfUse() throws {
        let app = Application()
        app.use(Trace(name: "1"))
        app.use(Trace(name: "2"))
        app.get("/") { () in "" }
        #expect(try app.test.get("/").headers(named: "x-trace") == ["1", "2", "2-out", "1-out"])
    }

    @Test func aGroupsMiddlewareStaysInTheGroup() throws {
        let app = Application()
        app.group("/private") {
            app.use(RequireToken())
            app.get("/data") { () in "secret" }
        }
        app.get("/public") { () in "open" }
        let client = app.test
        #expect(try client.get("/public").text == "open")
        #expect(try client.get("/private/data").status == 401)
        #expect(try client.get("/private/data", headers: [("authorization", "Bearer good")]).text == "secret")
    }

    @Test func answeringWithoutNextSkipsTheHandler() throws {
        let app = Application()
        let ran = Counter()
        app.use(RequireToken())
        app.get("/") { () in
            ran.increment()
            return "ran"
        }
        let response = try app.test.get("/")
        #expect(response.status == 401)
        #expect(response.text == "no")
        #expect(ran.value == 0)
    }

    @Test func changesTheResponseAfterTheHandler() throws {
        let app = Application()
        app.use { _, response, next in
            try await next()
            response.status = .accepted
            response.addHeader("x-after", "yes")
        }
        app.get("/") { () in "body" }
        let response = try app.test.get("/")
        #expect(response.status == 202)
        #expect(response.header("x-after") == "yes")
        #expect(response.text == "body")
    }

    @Test func catchesWhatTheHandlerThrew() throws {
        let app = Application()
        app.use { _, response, next in
            do {
                try await next()
            } catch {
                response.send(status: .serviceUnavailable, "caught")
            }
        }
        app.get("/fails") { () throws -> String in throw HTTPError.conflict("taken") }
        let response = try app.test.get("/fails")
        #expect(response.status == 503)
        #expect(response.text == "caught")
    }

    @Test func aThrowingMiddlewareIsAnsweredLikeAThrowingHandler() throws {
        let app = Application()
        app.use { _, _, _ in throw HTTPError.forbidden("not you") }
        app.get("/") { () in "unreached" }
        let response = try app.test.get("/")
        #expect(response.status == 403)
    }

    @Test func awaitsBeforeAndAfterNext() throws {
        let app = Application()
        app.use { _, response, next in
            await Task.yield()
            try await next()
            await Task.yield()
            response.addHeader("x-yielded", "twice")
        }
        app.get("/") { () async in
            await Task.yield()
            return "ok"
        }
        let response = try app.test.get("/")
        #expect(response.text == "ok")
        #expect(response.header("x-yielded") == "twice")
    }

    @Test func unmatchedRequestsSkipMiddleware() throws {
        let app = Application()
        app.use(Trace(name: "a"))
        app.get("/") { () in "" }
        let response = try app.test.get("/nowhere")
        #expect(response.status == 404)
        #expect(response.headers(named: "x-trace").isEmpty)
    }

    @Test func rawHandlersAreWrappedToo() throws {
        let app = Application()
        app.use(Trace(name: "a"))
        app.get("/raw") { _, response in response.send("raw") }
        let response = try app.test.get("/raw")
        #expect(response.text == "raw")
        #expect(response.headers(named: "x-trace") == ["a", "a-out"])
    }

    @Test func middlewareSeesTheRequest() throws {
        let app = Application()
        app.use { request, response, next in
            response.addHeader("x-seen", "\(request.method.name) \(request.path)")
            try await next()
        }
        app.post("/items/:id") { (id: Path<Int>) in "\(id.value)" }
        let response = try app.test.post("/items/7", body: "x")
        #expect(response.text == "7")
        #expect(response.header("x-seen") == "POST /items/7")
    }
}

@Suite struct GroupTests {
    @Test func prefixesJoin() throws {
        let app = Application()
        app.group("/api") {
            app.get("/users/:id") { (id: Path<Int>) in "user \(id.value)" }
            app.group("/v2") {
                app.get("/users/:id") { (id: Path<Int>) in "v2 user \(id.value)" }
            }
        }
        let client = app.test
        #expect(try client.get("/api/users/3").text == "user 3")
        #expect(try client.get("/api/v2/users/4").text == "v2 user 4")
        #expect(try client.get("/users/3").status == 404)
    }

    @Test func aGroupsRootIsItsPrefix() throws {
        let app = Application()
        app.group("/api/") {
            app.get("/") { () in "api root" }
        }
        let client = app.test
        #expect(try client.get("/api").text == "api root")
    }

    @Test func aSlashPrefixAddsNothing() throws {
        let app = Application()
        app.group("/") {
            app.use(Trace(name: "g"))
            app.get("/x") { () in "x" }
        }
        let response = try app.test.get("/x")
        #expect(response.text == "x")
        #expect(response.headers(named: "x-trace") == ["g", "g-out"])
    }

    @Test func problemsSeeTypedRoutesInsideGroups() {
        let app = Application()
        app.group("/api") {
            app.get("/one/:id") { (a: Path<Int>, b: Path<Int>) in "\(a.value)\(b.value)" }
        }
        #expect(app.problems() == ["GET /api/one/:id takes 2 Path parameters, and its pattern has 1"])
    }
}

@Suite struct RouterTests {
    func usersRouter() -> Router {
        let users = Router()
        users.use(Trace(name: "users"))
        users.get("/:id") { (id: Path<Int>) in "user \(id.value)" }
        users.group("/admin") {
            users.use(RequireToken())
            users.delete("/:id") { (id: Path<Int>) in "deleted \(id.value)" }
        }
        return users
    }

    @Test func nestsUnderAPrefix() throws {
        let app = Application()
        app.nest("/users", usersRouter())
        let client = app.test
        let response = try client.get("/users/9")
        #expect(response.text == "user 9")
        #expect(response.headers(named: "x-trace") == ["users", "users-out"])
        #expect(try client.delete("/users/admin/9").status == 401)
        #expect(try client.delete("/users/admin/9", headers: [("authorization", "Bearer good")]).text
                == "deleted 9")
    }

    @Test func oneRouterMountsTwice() throws {
        let app = Application()
        let users = usersRouter()
        app.nest("/v1/users", users)
        app.nest("/v2/users", users)
        let client = app.test
        #expect(try client.get("/v1/users/1").text == "user 1")
        #expect(try client.get("/v2/users/2").text == "user 2")
    }

    @Test func mergesIntoTheOpenGroup() throws {
        let app = Application()
        app.group("/api") {
            app.use(Trace(name: "api"))
            app.merge(usersRouter())
        }
        let response = try app.test.get("/api/5")
        #expect(response.text == "user 5")
        #expect(response.headers(named: "x-trace") == ["api", "users", "users-out", "api-out"])
    }

    @Test func aRoutersMiddlewareStaysInsideIt() throws {
        let app = Application()
        app.nest("/users", usersRouter())
        app.get("/other") { () in "other" }
        #expect(try app.test.get("/other").headers(named: "x-trace").isEmpty)
    }

    @Test func routersNestInRouters() throws {
        let outer = Router()
        outer.use(Trace(name: "outer"))
        outer.nest("/users", usersRouter())
        let app = Application()
        app.nest("/api", outer)
        let response = try app.test.get("/api/users/8")
        #expect(response.text == "user 8")
        #expect(response.headers(named: "x-trace") == ["outer", "users", "users-out", "outer-out"])
    }
}
