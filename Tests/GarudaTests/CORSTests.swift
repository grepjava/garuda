import Testing
@testable import Garuda
import GarudaTesting

// CORS policies: preflights, the headers on answers, and scopes.

private let site = "https://app.example.com"

private func preflight(_ method: String = "POST", origin: String = site,
                       headers: String? = nil) -> [(String, String)] {
    var list = [("origin", origin), ("access-control-request-method", method)]
    if let headers { list.append(("access-control-request-headers", headers)) }
    return list
}

/// Refuses, 401, a request without Authorization.
private struct NeedsAuthorization: Middleware {
    func handle(_ request: borrowing Request, _ response: borrowing Response,
                next: () async throws -> Void) async throws {
        guard request.header("authorization") != nil else { return response.send(status: .unauthorized) }
        try await next()
    }
}

@Suite("CORS", .serialized)
struct CORSTests {

    @Test func aPreflightToAPathRoutedForOtherMethodsIsAnswered() throws {
        let app = Application()
        app.cors(CORSPolicy(origins: [site]))
        app.get("/items") { _, response in response.send("items") }
        app.post("/items") { _, response in response.send(status: .created) }
        let client = app.test

        let answer = try client.request("OPTIONS", "/items", headers: preflight(headers: "content-type, x-trace"))
        #expect(answer.status == 204)
        #expect(answer.header("access-control-allow-origin") == site)
        #expect(answer.header("access-control-allow-methods") == "GET, HEAD, POST")
        #expect(answer.header("access-control-allow-headers") == "content-type, x-trace")
        #expect(answer.header("access-control-max-age") == "600")
        #expect(answer.header("access-control-allow-credentials") == nil)
        #expect(answer.header("vary") == "Origin, Access-Control-Request-Method, Access-Control-Request-Headers")

        // An OPTIONS that is not a preflight is still 405 there.
        let plain = try client.request("OPTIONS", "/items")
        #expect(plain.status == 405)
        #expect(try client.request("OPTIONS", "/nothing", headers: preflight()).status == 404)
    }

    @Test func aPreflightDoesNotMeetTheScopesMiddleware() throws {
        let app = Application()
        app.use(NeedsAuthorization())
        app.cors(CORSPolicy(origins: [site]))
        app.get("/me") { _, response in response.send("me") }
        app.options("/me") { _, response in response.send("options") }
        let client = app.test
        #expect(try client.request("OPTIONS", "/me", headers: preflight("GET")).status == 204)
        // An OPTIONS route's own preflight is the policy's; any other OPTIONS
        // is the route's, behind the middleware.
        #expect(try client.request("OPTIONS", "/me", headers: [("origin", site)]).status == 401)
        #expect(try client.request("OPTIONS", "/me", headers: [("authorization", "x")]).text == "options")
    }

    @Test func answersToAnAllowedOriginCarryTheHeaders() throws {
        let app = Application()
        app.cors(CORSPolicy(origins: [site], exposedHeaders: ["x-total", "etag"], allowCredentials: true))
        app.use(NeedsAuthorization())
        app.get("/me") { _, response in response.send("me") }
        app.get("/boom") { _, _ in throw HTTPError(.conflict, "no") }
        let client = app.test

        let ok = try client.get("/me", headers: [("origin", site), ("authorization", "x")])
        #expect(ok.text == "me")
        #expect(ok.header("access-control-allow-origin") == site)
        #expect(ok.header("access-control-allow-credentials") == "true")
        #expect(ok.header("access-control-expose-headers") == "x-total, etag")
        #expect(ok.header("vary") == "Origin")

        // A refusal the page needs to read, and a thrown error.
        let refused = try client.get("/me", headers: [("origin", site)])
        #expect(refused.status == 401)
        #expect(refused.header("access-control-allow-origin") == site)
        let thrown = try client.get("/boom", headers: [("origin", site), ("authorization", "x")])
        #expect(thrown.status == 409)
        #expect(thrown.header("access-control-allow-origin") == site)

        let stranger = try client.get("/me", headers: [("origin", "https://evil.example"), ("authorization", "x")])
        #expect(stranger.text == "me")
        #expect(stranger.header("access-control-allow-origin") == nil)
        #expect(stranger.header("vary") == "Origin")
        let sameSite = try client.get("/me", headers: [("authorization", "x")])
        #expect(sameSite.header("access-control-allow-origin") == nil)
        #expect(sameSite.header("vary") == "Origin")

        let preflightFromStranger = try client.request("OPTIONS", "/me",
                                                       headers: preflight("GET", origin: "https://evil.example"))
        #expect(preflightFromStranger.status == 204)
        #expect(preflightFromStranger.header("access-control-allow-origin") == nil)
        #expect(preflightFromStranger.header("access-control-allow-methods") == nil)
    }

    @Test func anyOriginIsAStarAndListsAreStatedAsGiven() throws {
        let app = Application()
        app.cors(CORSPolicy(origins: .any, methods: [.get, .put], headers: ["content-type"], maxAge: nil))
        app.get("/open") { _, response in response.send("open") }
        let client = app.test

        let answer = try client.get("/open", headers: [("origin", "https://anyone.example")])
        #expect(answer.header("access-control-allow-origin") == "*")
        #expect(answer.header("vary") == nil)
        let pre = try client.request("OPTIONS", "/open", headers: preflight("PUT", origin: "https://anyone.example",
                                                                             headers: "x-other"))
        #expect(pre.header("access-control-allow-origin") == "*")
        #expect(pre.header("access-control-allow-methods") == "GET, PUT")
        #expect(pre.header("access-control-allow-headers") == "content-type")
        #expect(pre.header("access-control-max-age") == nil)
        #expect(pre.header("vary") == nil)
    }

    @Test func theInnermostScopesPolicyWins() throws {
        let app = Application()
        app.cors(CORSPolicy(origins: [site]))
        app.get("/outer") { _, response in response.send("outer") }
        app.group("/partners") {
            app.cors(CORSPolicy(origins: .matching { $0.hasSuffix(".partner.example") }))
            app.get("/feed") { _, response in response.send("feed") }
            app.group("/inner") {
                app.get("/deep") { _, response in response.send("deep") }
            }
        }
        let api = Router()
        api.cors(CORSPolicy(origins: .any))
        api.get("/status") { _, response in response.send("up") }
        app.nest("/public", api)
        let client = app.test

        let partner = "https://a.partner.example"
        #expect(try client.get("/outer", headers: [("origin", partner)]).header("access-control-allow-origin") == nil)
        #expect(try client.get("/partners/feed", headers: [("origin", partner)])
            .header("access-control-allow-origin") == partner)
        #expect(try client.get("/partners/inner/deep", headers: [("origin", partner)])
            .header("access-control-allow-origin") == partner)
        #expect(try client.get("/partners/feed", headers: [("origin", site)])
            .header("access-control-allow-origin") == nil)
        #expect(try client.get("/public/status", headers: [("origin", partner)])
            .header("access-control-allow-origin") == "*")
        #expect(try client.request("OPTIONS", "/partners/feed", headers: preflight("GET", origin: partner))
            .header("access-control-allow-origin") == partner)
    }

    @Test func aPathWithoutAPolicyIsStill405() throws {
        let app = Application()
        app.group("/api") {
            app.cors(CORSPolicy(origins: [site]))
            app.get("/x") { _, response in response.send("x") }
        }
        app.get("/plain") { _, response in response.send("plain") }
        let client = app.test
        #expect(try client.request("OPTIONS", "/plain", headers: preflight("GET")).status == 405)
        #expect(try client.request("OPTIONS", "/api/x", headers: preflight("GET")).status == 204)
    }

    @Test func aPolicyAfterTheMiddlewareAndTheRoutesStillRunsFirst() throws {
        let app = Application()
        app.group("/api") {
            app.use(NeedsAuthorization())
            app.get("/me") { () in "me" }
            app.cors(CORSPolicy(origins: [site]))
        }
        let client = app.test
        let refused = try client.get("/api/me", headers: [("origin", site)])
        #expect(refused.status == 401)
        #expect(refused.header("access-control-allow-origin") == site)
        #expect(try client.request("OPTIONS", "/api/me", headers: preflight("GET")).status == 204)
    }

    @Test func anApplicationWithoutAPolicyAnswersAPreflight405() throws {
        let app = Application()
        app.get("/x") { () in "x" }
        let answer = try app.test.request("OPTIONS", "/x", headers: preflight("GET"))
        #expect(answer.status == 405)
        #expect(answer.header("allow") == "GET, HEAD")
        #expect(answer.header("access-control-allow-origin") == nil)
    }
}
