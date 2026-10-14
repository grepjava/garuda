@testable import Garuda
import GarudaTesting
import Testing

// Authorization: a named rule, what it answers, and where it runs.

private struct Person: Sendable {
    let name: String
    let roles: Set<String>
    let paid: Bool
}

private enum CurrentPerson: RequestContextKey { typealias Value = Person }

private let people = [
    "ada": Person(name: "ada", roles: ["admin", "billing"], paid: true),
    "grace": Person(name: "grace", roles: ["billing"], paid: true),
    "mary": Person(name: "mary", roles: [], paid: false),
]

extension Policy where Value == Person {
    fileprivate static let admin = Policy(needs: "an administrator") { $0.roles.contains("admin") }
    fileprivate static let billing = Policy(needs: "the billing role") { $0.roles.contains("billing") }
    fileprivate static let paid = Policy(needs: "a paid account") { $0.paid }
}

private struct ScopedToken: Codable, Sendable, ScopedClaims {
    let sub: String
    let exp: Int
    var scope: String?
}

/// An application whose scopes each require something different.
private func peopleApp() -> Application {
    let app = Application()
    app.get("/open") { () in "open" }
    app.group("/admin") {
        app.authenticate(bearer: CurrentPerson.self) { people[$0] }
        app.authorize(CurrentPerson.self, .admin)
        app.get("/stats") { (person: Context<CurrentPerson>) in "stats for \(person.value.name)" }
    }
    app.group("/invoices") {
        app.authenticate(bearer: CurrentPerson.self) { people[$0] }
        // Either role, and paid either way: the rule reads as the answer does.
        app.authorize(CurrentPerson.self, Policy.admin.or(.billing).and(.paid))
        app.get("/") { () in "invoices" }
    }
    app.group("/reports") {
        app.authenticate(bearer: CurrentPerson.self) { people[$0] }
        app.authorize(CurrentPerson.self, needs: "the reporting role") { $0.roles.contains("reports") }
        app.get("/") { () in "reports" }
    }
    return app
}

/// The body of an error answer.
private struct ErrorAnswer: Decodable {
    let error: String
}

@Suite("Authorization", .serialized)
struct AuthorizationTests {
    @Test func aRuleGuardsEveryRouteInItsScope() throws {
        let client = peopleApp().test
        #expect(try client.get("/open").text == "open", "a scope with no rule is untouched")

        let allowed = try client.get("/admin/stats", headers: [("authorization", "Bearer ada")])
        #expect(allowed.text == "stats for ada")

        // Authenticated, and still not allowed: 403, saying what would have
        // been enough.
        let refused = try client.get("/admin/stats", headers: [("authorization", "Bearer grace")])
        #expect(refused.status == .forbidden)
        #expect(refused.text == #"{"error":"this route needs an administrator"}"#, "\(refused.text)")

        // Nobody at all is 401, because signing in may be the answer.
        let anonymous = try client.get("/admin/stats")
        #expect(anonymous.status == .unauthorized)
        #expect(anonymous.header("www-authenticate") == "Bearer", "from the authenticate in front")
    }

    @Test func rulesCombineAndSoDoTheirNames() throws {
        let client = peopleApp().test
        #expect(try client.get("/invoices", headers: [("authorization", "Bearer ada")]).text == "invoices")
        #expect(try client.get("/invoices", headers: [("authorization", "Bearer grace")]).text == "invoices")
        let refused = try client.get("/invoices", headers: [("authorization", "Bearer mary")])
        #expect(refused.status == .forbidden)
        #expect(try refused.json(ErrorAnswer.self).error
                    == "this route needs an administrator or the billing role and a paid account")
    }

    @Test func aRuleWrittenWhereItIsUsed() throws {
        let client = peopleApp().test
        let refused = try client.get("/reports", headers: [("authorization", "Bearer ada")])
        #expect(refused.status == .forbidden)
        #expect(try refused.json(ErrorAnswer.self).error == "this route needs the reporting role")
    }

    @Test func aRuleThatAwaits() throws {
        let app = Application()
        app.authenticate(bearer: CurrentPerson.self) { people[$0] }
        app.authorize(CurrentPerson.self, needs: "a member") { person async throws -> Bool in
            await Task.yield()
            return person.name != "mary"
        }
        app.get("/project") { () in "project" }
        let client = app.test
        #expect(try client.get("/project", headers: [("authorization", "Bearer ada")]).text == "project")
        #expect(try client.get("/project", headers: [("authorization", "Bearer mary")]).status == .forbidden)
    }

    @Test func aRuleWithNobodyToJudgeIs401() throws {
        // An `authorize` with no `authenticate` in front: nothing under the
        // key, so nothing is known about who is asking.
        let app = Application()
        app.authorize(CurrentPerson.self, .admin)
        app.get("/x") { () in "x" }
        let answer = try app.test.get("/x")
        #expect(answer.status == .unauthorized)
        #expect(answer.header("www-authenticate") == nil)
    }

    @Test func aRuleAboutPartOfAValue() throws {
        // A rule written about one thing, guarding a route that holds another.
        let admin = Policy<Set<String>>(needs: "an administrator") { $0.contains("admin") }
        let app = Application()
        app.authenticate(bearer: CurrentPerson.self) { people[$0] }
        app.authorize(CurrentPerson.self, admin.about { (person: Person) in person.roles })
        app.get("/thing") { () in "thing" }
        let client = app.test
        #expect(try client.get("/thing", headers: [("authorization", "Bearer ada")]).text == "thing")
        #expect(try client.get("/thing", headers: [("authorization", "Bearer grace")]).status == .forbidden)
    }

    @Test func aHandlerWithARuleAboutOneRowAnswersTheSameWay() throws {
        let app = Application()
        app.get("/orders/:id") { (id: Path<Int>) throws -> String in
            guard id.value == 1 else { throw AuthorizationError(needs: "the customer") }
            return "order"
        }
        let client = app.test
        #expect(try client.get("/orders/1").text == "order")
        let refused = try client.get("/orders/2")
        #expect(refused.status == .forbidden)
        #expect(refused.text == #"{"error":"this route needs the customer"}"#)

        // And without saying what, when saying would tell them too much.
        #expect(AuthorizationError().reason == "you may not do this")
        #expect(AuthorizationError().status == .forbidden)
    }

    @Test func aPolicyIsARuleThatCanBeTestedOnItsOwn() throws {
        // No request, no server: the reason to have a policy at all.
        #expect(Policy.admin(people["ada"]!))
        #expect(!Policy.admin(people["grace"]!))
        #expect(Policy.admin.needs == "an administrator")
        #expect(Policy.admin.or(.billing).needs == "an administrator or the billing role")
        #expect(Policy.admin.and(.paid)(people["ada"]!))
        #expect(!Policy.admin.and(.paid)(people["mary"]!))
        #expect(Policy.billing.or(.admin)(people["grace"]!))
    }
}

@Suite("Authorization by scope", .serialized)
struct ScopeAuthorizationTests {
    @Test func whatAScopeClaimCarries() throws {
        let token = ScopedToken(sub: "ada", exp: 0, scope: "orders:read orders:write profile")
        #expect(token.hasScope("orders:write"))
        #expect(token.hasScope("profile"))
        #expect(token.scopes == ["orders:read", "orders:write", "profile"])
        // Whole scopes only: a prefix is a different permission.
        #expect(!token.hasScope("orders"))
        #expect(!token.hasScope("write"))
        #expect(!token.hasScope("orders:writer"))
        #expect(!token.hasScope(""))
        // A token carrying none.
        let none = ScopedToken(sub: "ada", exp: 0, scope: nil)
        #expect(!none.hasScope("orders:read"))
        #expect(none.scopes.isEmpty)
    }

    @Test func aRouterGuardsItsOwnRoutesWithoutBeingHandedTheKeys() throws {
        // What a feature module needs: the verifier comes from the shard, so
        // the router can be built and mounted on its own.
        let set = try JWTKeys([try JWTKey.generate(.ES256, keyID: "k")])
        let orders = Router()
        orders.authenticate(jwt: ScopedToken.self)
        orders.authorize(jwt: ScopedToken.self, .scope("orders:write"))
        orders.post("/") { (jwt: JWT<ScopedToken>) async in "made for \(jwt.claims.sub)" }

        let app = Application()
        app.jwtVerifier { _ in set }
        app.nest("/orders", orders)
        let client = app.test

        let future = Int(epochSeconds()) + 3600
        func bearer(_ scope: String) throws -> [(String, String)] {
            [("authorization",
              "Bearer " + (try set.sign(ScopedToken(sub: "ada", exp: future, scope: scope))))]
        }
        #expect(try client.post("/orders", body: "", headers: try bearer("orders:write")).text == "made for ada")
        #expect(try client.post("/orders", body: "", headers: try bearer("orders:read")).status == .forbidden)
        let anonymous = try client.post("/orders", body: "")
        #expect(anonymous.status == .unauthorized)
        #expect(anonymous.header("www-authenticate") == "Bearer")
        // A token that will not verify is 401 and says so, not 403.
        let bad = try client.post("/orders", body: "", headers: [("authorization", "Bearer nonsense")])
        #expect(bad.status == .unauthorized)
        #expect(bad.header("www-authenticate") == #"Bearer error="invalid_token""#)
    }

    @Test func aScopeGuardsARouteThroughTheTokenTheScopeChecked() throws {
        let set = try JWTKeys([try JWTKey.generate(.ES256, keyID: "k")])
        let app = Application()
        app.jwtVerifier { _ in set }
        app.group("/orders") {
            app.authenticate(jwt: ScopedToken.self, verifier: set)
            app.authorize(jwt: ScopedToken.self, .scope("orders:write"))
            app.post("/") { (jwt: JWT<ScopedToken>) async in "made for \(jwt.claims.sub)" }
        }
        let client = app.test

        let future = Int(epochSeconds()) + 3600
        func bearer(_ scope: String?) throws -> [(String, String)] {
            [("authorization",
              "Bearer " + (try set.sign(ScopedToken(sub: "ada", exp: future, scope: scope))))]
        }

        #expect(try client.post("/orders", body: "", headers: try bearer("orders:read orders:write")).text
                    == "made for ada")
        let readOnly = try client.post("/orders", body: "", headers: try bearer("orders:read"))
        #expect(readOnly.status == .forbidden)
        #expect(readOnly.text == #"{"error":"this route needs the scope orders:write"}"#, "\(readOnly.text)")
        #expect(try client.post("/orders", body: "", headers: try bearer(nil)).status == .forbidden)
        // No token at all is the authentication's answer, not this one.
        #expect(try client.post("/orders", body: "").status == .unauthorized)
    }

    @Test func aRuleWrittenWhereItIsUsedAboutClaims() throws {
        let set = try JWTKeys([try JWTKey.generate(.HS256)])
        let app = Application()
        app.authenticate(jwt: ScopedToken.self, verifier: set)
        app.authorize(jwt: ScopedToken.self, needs: "ada") { $0.sub == "ada" }
        app.get("/x") { () in "x" }
        let client = app.test
        let future = Int(epochSeconds()) + 3600
        let ada = try set.sign(ScopedToken(sub: "ada", exp: future, scope: nil))
        let bob = try set.sign(ScopedToken(sub: "bob", exp: future, scope: nil))
        #expect(try client.get("/x", headers: [("authorization", "Bearer \(ada)")]).text == "x")
        let refused = try client.get("/x", headers: [("authorization", "Bearer \(bob)")])
        #expect(refused.status == .forbidden)
        #expect(refused.text == #"{"error":"this route needs ada"}"#)
    }
}
