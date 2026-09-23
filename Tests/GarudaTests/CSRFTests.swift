import Testing
@testable import Garuda
import AvianHTTP

// Cross-site request forgery protection from Sec-Fetch-Site and Origin.

@Suite("CSRF protection")
struct CSRFTests {
    private func app() -> Application {
        let app = Application()
        app.group("/form") {
            app.csrfProtection(trustedOrigins: ["https://Admin.example.com"])
            app.get("/") { "read" }
            app.post("/") { "posted" }
            app.put("/") { "put" }
            app.delete("/") { "deleted" }
            app.patch("/") { "patched" }
        }
        app.post("/open") { "open" }
        return app
    }

    @Test func aSafeMethodAlwaysPasses() throws {
        let client = app().test
        let crossSite = [("sec-fetch-site", "cross-site"), ("origin", "https://evil.example")]
        #expect(try client.get("/form", headers: crossSite).text == "read")
        #expect(try client.request("HEAD", "/form", headers: crossSite).status == 200)
    }

    // Typed apart from @Test: inline, this many tuples can outrun the type
    // checker.
    static let judged: [([(String, String)], String)] = [
        // Sec-Fetch-Site decides when it is there.
        ([("sec-fetch-site", "same-origin")], "posted"),
        ([("sec-fetch-site", "none")], "posted"),
        ([("sec-fetch-site", "cross-site")], "403"),
        ([("sec-fetch-site", "same-site")], "403"),
        ([("sec-fetch-site", "Cross-Site"), ("origin", "http://test")], "403"),
        ([("sec-fetch-site", "same-origin"), ("origin", "https://evil.example")], "posted"),
        // Without it, Origin against Host.
        ([], "posted"),
        ([("origin", "http://test")], "posted"),
        ([("origin", "HTTPS://TEST:443")], "posted"),
        ([("origin", "https://test"), ("host", "test:443")], "posted"),
        ([("origin", "http://test"), ("host", "test:80")], "posted"),
        ([("origin", "https://test:8443"), ("host", "test:8443")], "posted"),
        // A port is the origin's default only for the origin's own scheme.
        ([("origin", "https://test:80"), ("host", "test:443")], "403"),
        ([("origin", "http://test:443"), ("host", "test:80")], "403"),
        ([("origin", "https://test:80")], "403"),
        ([("origin", "http://test:443")], "403"),
        ([("origin", "https://[::1]:8443"), ("host", "[::1]:8443")], "posted"),
        ([("origin", "https://[::1]"), ("host", "[::1]:443")], "posted"),
        ([("origin", "https://[::1]:80"), ("host", "[::1]")], "403"),
        ([("origin", "http://test:8080")], "403"),
        ([("origin", "https://evil.example")], "403"),
        ([("origin", "null")], "403"),
        ([("origin", "http://test/path")], "403"),
        ([("origin", "http://evil.example@test")], "403"),
        ([("sec-fetch-site", "someday"), ("origin", "https://evil.example")], "403"),
        // A trusted origin passes whatever the browser says.
        ([("sec-fetch-site", "cross-site"), ("origin", "https://admin.example.com")], "posted"),
        ([("origin", "https://admin.example.com")], "posted"),
        ([("sec-fetch-site", "cross-site"), ("origin", "https://admin.example.com:8443")], "403"),
    ]

    @Test(arguments: judged)
    func anUnsafeRequestIsJudgedByWhereTheBrowserSaysItCameFrom(headers: [(String, String)], expected: String) throws {
        let response = try app().test.post("/form", headers: headers)
        #expect((response.status == 403 ? "403" : response.text) == expected)
    }

    @Test func everyUnsafeMethodIsCheckedAndOnlyInItsScope() throws {
        let client = app().test
        let crossSite = [("sec-fetch-site", "cross-site")]
        #expect(try client.request("PUT", "/form", headers: crossSite).status == 403)
        #expect(try client.request("DELETE", "/form", headers: crossSite).status == 403)
        #expect(try client.request("PATCH", "/form", headers: crossSite).status == 403)
        #expect(try client.post("/open", headers: crossSite).text == "open")
    }
}
