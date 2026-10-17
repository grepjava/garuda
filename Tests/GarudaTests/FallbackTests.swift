import Testing
import Vega
import Garuda
import GarudaTesting

// Fallbacks for requests no route matches, and what routers carry besides
// routes and middleware.

private func users() -> Router {
    let router = Router()
    router.use(Trace(name: "users"))
    router.get("/:id") { (id: Path<Int>) in "user \(id.value)" }
    router.post("/") { () in HTTPStatus.created }
    router.group("/admin") {
        router.use(Trace(name: "admin"))
        router.get("/ping") { _, response in response.send("pong") }
    }
    return router
}

@Suite("Fallbacks and routers")
struct FallbackTests {

    // MARK: Routers

    @Test func aNestedRouterTakesThePrefixRootAndAll() throws {
        let app = Application()
        app.nest("/users", users())
        let client = app.test
        #expect(try client.get("/users/7").text == "user 7")
        #expect(try client.post("/users").status == 201)
        #expect(try client.get("/users/admin/ping").text == "pong")
        #expect(try client.get("/7").status == 404)
    }

    @Test func aMergedRoutersGroupsRunInsideTheOpenOnes() throws {
        let app = Application()
        app.group("/v1") {
            app.use(Trace(name: "v1"))
            app.merge(users())
        }
        let response = try app.test.get("/v1/admin/ping")
        #expect(response.text == "pong")
        #expect(response.headers(named: "x-trace") == ["v1", "users", "admin", "admin-out", "users-out", "v1-out"])
    }

    @Test func aRouterTakesDeadlines() throws {
        let router = Router()
        router.deadline(.milliseconds(20)) {
            router.get("/wait") { () async throws -> String in
                try await waitForever()
                return "late"
            }
        }
        let app = Application()
        app.nest("/r", router)
        #expect(try app.test.get("/r/wait").status == 504)
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
        #expect(response.header("allow") == "GET, HEAD")
    }

    @Test func theMostSpecificScopesFallbackAnswers() throws {
        let app = Application()
        app.fallback { _, response in response.send("root") }
        app.group("/api") {
            app.use(Trace(name: "api"))
            app.get("/users") { _, response in response.send("users") }
            app.fallback { _, response in response.send(status: .notFound, "api") }
        }
        let client = app.test
        let api = try client.get("/api/nothing")
        #expect(api.text == "api")
        #expect(api.headers(named: "x-trace") == ["api", "api-out"])
        #expect(try client.get("/api").text == "api")
        #expect(try client.get("/apiary").text == "root")
        #expect(try client.get("/").text == "root")
        #expect(try client.get("/").headers(named: "x-trace").isEmpty)
    }

    @Test func aFallbackThatWaits() throws {
        let app = Application()
        app.fallback { _, response in
            try await Runtime.sleep(for: .milliseconds(1))
            response.send("waited")
        }
        #expect(try app.test.get("/x").text == "waited")
    }

    @Test func aTypedFallbackTakesWhatItNeeds() throws {
        struct Search: Decodable { let q: String }
        let app = Application()
        app.fallback { (search: Query<Search>?) in
            search.map { "looked for \($0.value.q)" } ?? "nothing asked"
        }
        let client = app.test
        #expect(try client.get("/find?q=owl").text == "looked for owl")
        #expect(try client.get("/find").text == "nothing asked")
    }

    @Test func aFallbackIsAnsweredForLikeAnyHandler() throws {
        let app = Application()
        app.group("/thrown") {
            app.fallback { () throws -> String in throw HTTPError.conflict("taken") }
        }
        app.group("/silent") {
            app.fallback { _, _ in }
        }
        let client = app.test
        #expect(try client.get("/thrown/x").status == 409)
        #expect(try client.get("/silent/x").status == 500)
    }

    @Test func aFallbackRunsUnderItsScopesDeadline() throws {
        let app = Application()
        app.deadline(.milliseconds(20)) {
            app.fallback { _, response in
                try await waitForever()
                response.send("unreached")
            }
        }
        #expect(try app.test.get("/anything").status == 504)
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

    @Test func aFallbackIsNotInTheOpenAPIDocument() throws {
        let app = Application()
        app.get("/known") { () in "known" }
        app.group("/api") {
            app.fallback { () in "fallback" }
        }
        let json = app.openAPIJSON(OpenAPIInfo(title: "t", version: "1"))
        #expect(json.contains("\"/known\""))
        #expect(!json.contains("\"/api\""))
        #expect(app.problems().isEmpty)
    }

    @Test func aHeavyFallbackIsServed() throws {
        let app = Application()
        app.heavy.fallback { () in "heavy" }
        #expect(try app.test.get("/anywhere").text == "heavy")
    }
}
