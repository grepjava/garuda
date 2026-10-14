import Testing
import Garuda
import GarudaTesting

// A trailing slash no route has: exact by default, redirected, or ignored.

@Suite("Trailing slash")
struct TrailingSlashTests {
    private func app(_ policy: TrailingSlash?) -> Application {
        let app = Application()
        if let policy { app.trailingSlash(policy) }
        app.get("/users") { () in "users" }
        app.post("/users") { request, response in response.send("created \(request.body.count)") }
        app.get("/users/:id") { (id: Path<String>) in "user \(id.value)" }
        app.get("/docs/") { () in "docs with slash" }
        app.get("/") { () in "root" }
        app.put("/only-put") { () in "put" }
        app.group("/app") { app.get("/page") { () in "page" } }
        return app
    }

    @Test func routesMatchExactlyByDefault() throws {
        let client = app(nil).test
        #expect(try client.get("/users/").status == 404)
        #expect(try client.get("/users").text == "users")
        #expect(try client.get("/docs/").text == "docs with slash")
        #expect(try client.get("/docs").status == 404)
        #expect(try client.get("/app/page/").status == 404)
    }

    @Test func redirectSendsThePathWithoutItsSlashes() throws {
        let client = app(.redirect).test
        let users = try client.get("/users/?page=2&q=a%2Fb")
        #expect(users.status == 308)
        #expect(users.header("location") == "/users?page=2&q=a%2Fb")
        #expect(try client.get("/users/42///").header("location") == "/users/42")
        #expect(try client.post("/users/", body: "abc").header("location") == "/users")
        // A method the trimmed path is routed for only elsewhere still goes.
        #expect(try client.request("PUT", "/users/").status == 308)
        #expect(try client.get("/only-put/").header("location") == "/only-put")
        #expect(try client.get("/app/page/").header("location") == "/app/page")

        // What matched as it came is left alone.
        #expect(try client.get("/docs/").text == "docs with slash")
        #expect(try client.get("/").text == "root")
        #expect(try client.get("/users").text == "users")
        // Nothing routed without the slash: the usual answers.
        #expect(try client.get("/missing/").status == 404)
        // Never a Location another site could be read from.
        let doubled = try client.get("//users/")
        #expect(doubled.status == 404)
        #expect(doubled.header("location") == nil)
    }

    @Test func ignoreServesTheRouteWithoutTheSlash() throws {
        let client = app(.ignore).test
        #expect(try client.get("/users/").text == "users")
        #expect(try client.get("/users/42/").text == "user 42")
        #expect(try client.post("/users//", body: "abcd").text == "created 4")
        #expect(try client.get("/only-put/").status == 405)
        #expect(try client.get("/only-put/").header("allow") == "PUT")
        #expect(try client.get("/docs/").text == "docs with slash")
        #expect(try client.get("/missing/").status == 404)
    }

    @Test func aRedirectNeverPointsAtAnotherHost() throws {
        let app = Application()
        app.trailingSlash(.redirect)
        app.put("/*path") { () in "put" }
        let client = app.test
        #expect(try client.get("/files/").header("location") == "/files")
        let doubled = try client.get("//evil.example/")
        #expect(doubled.status == 405)
        #expect(doubled.header("location") == nil)
        // A browser reads the backslash as the slash that would follow it.
        let backslash = try client.get("/\\evil.example/")
        #expect(backslash.status == 405)
        #expect(backslash.header("location") == nil)
    }

    @Test func middlewareRunsForTheRouteAnIgnoredSlashReaches() throws {
        let app = Application()
        app.trailingSlash(.ignore)
        app.group("/api") {
            app.use { _, response, next in
                response.addHeader("x-layer", "api")
                try await next()
            }
            app.get("/items") { () in "items" }
        }
        let response = try app.test.get("/api/items/")
        #expect(response.text == "items")
        #expect(response.header("x-layer") == "api")
    }
}
