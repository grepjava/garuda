import Testing
@testable import Garuda
import GarudaTesting
import Vega

// Extractors of your own: plain, awaiting, optional and with their failure in
// hand. There is one extractor protocol, and it may await; these are the
// cases Garuda 1 split between `RequestExtractor` and `AsyncRequestExtractor`.

/// A tenant named by a header, refused 400 without one.
private struct Tenant: RequestExtractor {
    let name: String

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> Tenant {
        guard let name = request.header("x-tenant"), !name.isEmpty else {
            throw HTTPError(.badRequest, "no tenant")
        }
        return Tenant(name: name)
    }
}

/// Users by token, in the shard's state.
private final class Directory: @unchecked Sendable {
    var users = ["t1": "ada", "t2": "grace"]
    var lookups = 0
}

/// The user a bearer token belongs to, found after a wait, as a database
/// lookup would be.
private struct SignedIn: RequestExtractor {
    let name: String

    static func extract(from request: borrowing Request, parameter: inout Int) async throws -> SignedIn {
        guard let header = request.header("authorization"), header.hasPrefix("Bearer ") else {
            throw HTTPError.unauthorized
        }
        let token = String(header.dropFirst(7))
        let directory = try request.state(Directory.self)
        try await Runtime.sleep(for: .milliseconds(2))
        directory.lookups += 1
        guard let name = directory.users[token] else { throw HTTPError.unauthorized }
        return SignedIn(name: name)
    }
}

@Suite("Custom extractors")
struct CustomExtractorTests {
    private func app() -> Application {
        let app = Application()
        app.state { _ in Directory() }
        app.get("/tenant/:id") { (tenant: Tenant, id: Path<Int>) in "\(tenant.name) \(id.value)" }
        app.get("/me") { (me: SignedIn, tenant: Tenant) in "\(me.name) at \(tenant.name)" }
        app.get("/hello") { (me: SignedIn?) in "hello \(me?.name ?? "stranger")" }
        app.get("/maybe/:n/:m") { (n: Path<Int>?, raw: Path<String>) in "\(n.map { "\($0.value)" } ?? "nil") \(raw.value)" }
        app.get("/result") { (tenant: Result<Tenant, any Error>) -> String in
            switch tenant {
            case .success(let tenant): return "tenant \(tenant.name)"
            case .failure(let error): return "refused: \(error)"
            }
        }
        app.get("/lookups") { (directory: State<Directory>) in "\(directory.value.lookups)" }
        return app
    }

    @Test func anExtractorOfYourOwn() throws {
        let client = app().test
        #expect(try client.get("/tenant/7", headers: [("x-tenant", "acme")]).text == "acme 7")
        let refused = try client.get("/tenant/7")
        #expect(refused.status == 400)
    }

    @Test func anExtractorThatAwaits() throws {
        let client = app().test
        #expect(try client.get("/me", headers: [("authorization", "Bearer t2"), ("x-tenant", "acme")]).text
            == "grace at acme")
        #expect(try client.get("/me", headers: [("authorization", "Bearer nope"), ("x-tenant", "acme")]).status == 401)
        #expect(try client.get("/me", headers: [("x-tenant", "acme")]).status == 401)
        // One that refuses stops the extractors after it.
        #expect(try client.get("/me", headers: [("authorization", "Bearer t1")]).status == 400)
        #expect(try client.get("/lookups").text == "3")
    }

    @Test func optionalAndResultKeepTheRefusal() throws {
        let client = app().test
        #expect(try client.get("/hello", headers: [("authorization", "Bearer t1")]).text == "hello ada")
        #expect(try client.get("/hello").text == "hello stranger")
        #expect(try client.get("/hello", headers: [("authorization", "Bearer bad")]).text == "hello stranger")
        // A path parameter the optional could not take is left for the next.
        #expect(try client.get("/maybe/12/x").text == "12 x")
        #expect(try client.get("/maybe/twelve/x").text == "nil twelve")
        #expect(try client.get("/result", headers: [("x-tenant", "acme")]).text == "tenant acme")
        #expect(try client.get("/result").text.hasPrefix("refused: "))
    }
}
