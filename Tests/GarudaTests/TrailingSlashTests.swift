import Testing
@testable import Garuda
import AvianHTTP

// A trailing slash no route has: exact by default, redirected, or ignored.

@Suite("Trailing slash")
struct TrailingSlashTests {
    private func app(_ policy: TrailingSlash?) -> Application {
        let app = Application()
        if let policy { app.trailingSlash(policy) }
        app.get("/users") { "users" }
        app.post("/users") { request, response in response.send("created \(request.body.count)") }
        app.get("/users/:id") { (id: Path<String>) in "user \(id.value)" }
        app.get("/docs/") { "docs with slash" }
        app.get("/") { "root" }
        app.put("/only-put") { "put" }
        app.group("/app") {
            app.fallback { _, response in response.send(status: .notFound, "app fallback") }
        }
        app.group("/app") { app.get("/page") { "page" } }
        app.onStreamingBody(.post, "/upload") { _, response, body in
            var total = 0
            while let bytes = try await body.read(maxBytes: 1000) { total += bytes.count }
            response.send("streamed \(total)")
        }
        return app
    }

    @Test func routesMatchExactlyByDefault() throws {
        let client = app(nil).test
        #expect(try client.get("/users/").status == 404)
        #expect(try client.get("/users").text == "users")
        #expect(try client.get("/docs/").text == "docs with slash")
        #expect(try client.get("/docs").status == 404)
        #expect(try client.get("/app/page/").text == "app fallback")
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
        #expect(try client.get("/app/other/").text == "app fallback")
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
        #expect(try client.post("/upload/", body: [UInt8](repeating: 1, count: 5000)).text == "streamed 5000")
    }

    @Test func aStreamingRouteKeepsItsOwnLimitWithoutTheSlash() throws {
        let app = Application()
        app.trailingSlash(.ignore)
        app.onStreamingBody(.post, "/upload", maxBodySize: 1 << 20) { _, response, body in
            var total = 0
            while let bytes = try await body.read(maxBytes: 4096) { total += bytes.count }
            response.send("streamed \(total)")
        }
        var config = ServerConfig()
        config.maxConnections = 16
        config.maxBodySize = 1000
        let client = app.testClient(configuration: config)
        // Matched at the head, so --max-body does not apply to it.
        #expect(try client.post("/upload/", body: [UInt8](repeating: 1, count: 5000)).text == "streamed 5000")
    }

    @Test func aRedirectNeverPointsAtAnotherHost() throws {
        let app = Application()
        app.trailingSlash(.redirect)
        app.put("/*path") { "put" }
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
}
