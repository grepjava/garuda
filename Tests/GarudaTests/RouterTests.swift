import Testing
@testable import Garuda

// Routers built on their own and merged, and fallbacks for requests no route
// matches.

/// Leaves a mark, so a test can see which middleware ran and in what order.
private func mark(_ name: StaticString) -> Middleware {
    { _, response in
        response.addHeader("x-trace", name)
        return nil
    }
}

private func users() -> Router {
    let router = Router()
    router.use(mark("users"))
    router.get("/:id") { (id: Path<Int>) in "user \(id.value)" }
    router.post("/") { () in HTTPStatus.created }
    router.group("/admin") {
        router.use(mark("admin"))
        router.get("/ping") { _, response in response.send("pong") }
    }
    return router
}

@Suite("Routers and fallbacks", .serialized)
struct RouterTests {

    // MARK: Routers

    @Test func aNestedRouterTakesThePrefix() throws {
        let app = Application()
        app.nest("/users", users())
        let client = app.test
        #expect(try client.get("/users/7").text == "user 7")
        #expect(try client.post("/users").status == 201)
        #expect(try client.get("/users/admin/ping").text == "pong")
        #expect(try client.get("/7").status == 404)
    }

    @Test func aMergedRouterIsAsIfRegisteredThere() throws {
        let app = Application()
        app.group("/v1") {
            app.use(mark("v1"))
            app.merge(users())
        }
        let response = try app.test.get("/v1/admin/ping")
        #expect(response.text == "pong")
        #expect(response.headers(named: "x-trace") == ["v1", "users", "admin"])
    }

    @Test func aRoutersMiddlewareStaysInsideIt() throws {
        let app = Application()
        app.nest("/users", users())
        app.get("/other") { _, response in response.send("other") }
        let response = try app.test.get("/other")
        #expect(response.headers(named: "x-trace").isEmpty)
    }

    @Test func oneRouterMergesUnderTwoPrefixes() throws {
        let app = Application()
        let router = users()
        app.nest("/a", router)
        app.nest("/b", router)
        let client = app.test
        #expect(try client.get("/a/1").text == "user 1")
        #expect(try client.get("/b/2").text == "user 2")
    }

    @Test func routersNest() throws {
        let api = Router()
        api.nest("/users", users())
        api.get("/health") { () in "ok" }
        let app = Application()
        app.nest("/api", api)
        let client = app.test
        #expect(try client.get("/api/users/3").text == "user 3")
        #expect(try client.get("/api/health").text == "ok")
    }

    @Test func aRouterTakesAsyncRoutesDeadlinesAndStreamingBodies() throws {
        let router = Router()
        router.deadline(milliseconds: 20) {
            router.onAsync(.get, "/wait") { _, response in
                try await response.sleep(milliseconds: 500)
                response.send("late")
            }
        }
        router.onStreamingBody(.post, "/upload") { _, response, body in
            let bytes = try await body.readAll(maxBytes: 1 << 20)
            response.send("\(bytes.count)")
        }
        let app = Application()
        app.nest("/r", router)
        let client = app.test
        #expect(try client.get("/r/wait").status == 504)
        #expect(try client.post("/r/upload", body: [UInt8](repeating: 1, count: 3000)).text == "3000")
    }

    // MARK: Fallbacks

    @Test func aFallbackAnswersInsteadOf404() throws {
        let app = Application()
        app.get("/known") { _, response in response.send("known") }
        app.fallback { request, response in
            response.send(status: .notFound, "no \(request.path)")
        }
        let client = app.test
        #expect(try client.get("/known").text == "known")
        let missing = try client.get("/nowhere/at/all")
        #expect(missing.status == 404)
        #expect(missing.text == "no /nowhere/at/all")
        #expect(try client.request("DELETE", "/elsewhere").text == "no /elsewhere")
    }

    @Test func aPathAnotherMethodHasIsStill405() throws {
        let app = Application()
        app.get("/known") { _, response in response.send("known") }
        app.fallback { _, response in response.send("fallback") }
        let response = try app.test.request("POST", "/known")
        #expect(response.status == 405)
    }

    @Test func theMostSpecificScopesFallbackAnswers() throws {
        let app = Application()
        app.fallback { _, response in response.send("root") }
        app.group("/api") {
            app.use(mark("api"))
            app.get("/users") { _, response in response.send("users") }
            app.fallback { _, response in response.send(status: .notFound, "api") }
        }
        let client = app.test
        let api = try client.get("/api/nothing")
        #expect(api.text == "api")
        #expect(api.headers(named: "x-trace") == ["api"])
        #expect(try client.get("/api").text == "api")
        #expect(try client.get("/apiary").text == "root")
        #expect(try client.get("/").text == "root")
    }

    @Test func anAsyncFallbackWaits() throws {
        let app = Application()
        app.fallback { _, response async throws in
            try await response.sleep(milliseconds: 1)
            response.send("waited")
        }
        #expect(try app.test.get("/x").text == "waited")
    }

    @Test func aRoutersFallbackTakesItsPrefix() throws {
        let router = Router()
        router.get("/one") { _, response in response.send("one") }
        router.fallback { _, response in response.send(status: .notFound, "in router") }
        let app = Application()
        app.nest("/r", router)
        let client = app.test
        #expect(try client.get("/r/two").text == "in router")
        #expect(try client.get("/two").status == 404)
        #expect(try client.get("/two").text.isEmpty)
    }
}
