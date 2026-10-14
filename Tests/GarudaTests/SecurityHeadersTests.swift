import Testing
@testable import Garuda
import GarudaTesting

// Security headers on every answer of a scope.

@Suite("Security headers")
struct SecurityHeadersTests {
    private let defaults = [
        "x-content-type-options: nosniff",
        "x-frame-options: SAMEORIGIN",
        "referrer-policy: no-referrer",
        "cross-origin-opener-policy: same-origin",
        "cross-origin-resource-policy: same-origin",
    ]

    private func sent(_ response: TestResponse) -> [String] {
        ["strict-transport-security", "x-content-type-options", "x-frame-options", "referrer-policy",
         "cross-origin-opener-policy", "cross-origin-resource-policy", "content-security-policy",
         "permissions-policy"].flatMap { name in response.headers(named: name).map { "\(name): \($0)" } }
    }

    private func app(_ headers: SecurityHeaders = SecurityHeaders()) -> Application {
        let app = Application()
        app.group("/site") {
            app.securityHeaders(headers)
            app.get("/page") { () in "page" }
            app.get("/embed") { _, response in
                response.addHeader("x-frame-options", "DENY")
                response.send("embed")
            }
            app.get("/fails") { _, _ in throw HTTPError(.conflict) }
            app.use { request, response, next in
                if request.header("refuse") != nil { return response.send(status: .unauthorized) }
                try await next()
            }
        }
        app.get("/plain") { () in "plain" }
        return app
    }

    @Test func everyAnswerInTheScopeCarriesThem() throws {
        let client = app().test
        #expect(sent(try client.get("/site/page")) == defaults)
        #expect(sent(try client.get("/site/fails")) == defaults)
        let refused = try client.get("/site/page", headers: [("refuse", "1")])
        #expect(refused.status == 401)
        #expect(sent(refused) == defaults)
        #expect(sent(try client.get("/plain")).isEmpty)
    }

    @Test func aHeaderTheResponseSetsWins() throws {
        let embed = try app().test.get("/site/embed")
        #expect(embed.headers(named: "x-frame-options") == ["DENY"])
        #expect(sent(embed).count == defaults.count)
    }

    @Test func strictTransportSecurityIsNotSentOverPlainHTTP() throws {
        let response = try app().test.get("/site/page")
        #expect(response.headers(named: "strict-transport-security").isEmpty)
    }

    @Test func eachHeaderCanBeChangedOrLeftOut() throws {
        var headers = SecurityHeaders()
        headers.frameOptions = "DENY"
        headers.referrerPolicy = nil
        headers.crossOriginOpenerPolicy = nil
        headers.crossOriginResourcePolicy = nil
        headers.strictTransportSecurity = nil
        headers.contentSecurityPolicy = "default-src 'self'"
        headers.permissionsPolicy = "camera=()"
        let response = try app(headers).test.get("/site/page")
        #expect(sent(response) == [
            "x-content-type-options: nosniff",
            "x-frame-options: DENY",
            "content-security-policy: default-src 'self'",
            "permissions-policy: camera=()",
        ])
    }
}
