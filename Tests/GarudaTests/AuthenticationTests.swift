@testable import Garuda
import GarudaTesting
import Testing

// Bearer and Basic authentication, as middleware and as extractors, and with
// the shard's state handed to the check.

private enum SignedIn: RequestContextKey { typealias Value = String }

private let tokens = ["t0k3n.abc-_~+/=": "ada", "second": "grace"]

@Suite("Authentication", .serialized)
struct AuthenticationTests {

    @Test func aBearerTokenIsCheckedAndItsOwnerKept() throws {
        let app = Application()
        app.get("/health") { _, response in response.send("ok") }
        app.group("/api") {
            app.authenticate(bearer: SignedIn.self) { token in tokens[token] }
            app.get("/me") { (user: Context<SignedIn>) in "hello \(user.value)" }
        }
        let client = app.test

        #expect(try client.get("/health").text == "ok")
        let missing = try client.get("/api/me")
        #expect(missing.status == 401)
        #expect(missing.header("www-authenticate") == "Bearer")
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer wrong")]).status == 401)
        #expect(try client.get("/api/me", headers: [("authorization", "Basic YTpi")]).status == 401)
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer ")]).status == 401)
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer two words")]).status == 401)
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer t0k3n.abc-_~+/=")]).text == "hello ada")
        #expect(try client.get("/api/me", headers: [("authorization", "bearer   second")]).text == "hello grace")
    }

    @Test func anAsyncVerifierAndOneThatThrows() throws {
        let app = Application()
        app.authenticate(bearer: SignedIn.self) { token async throws -> String? in
            await Task.yield()
            if token == "banned" { throw HTTPError.forbidden("banned") }
            return tokens[token]
        }
        app.get("/me") { (user: Context<SignedIn>) in user.value }
        let client = app.test
        #expect(try client.get("/me", headers: [("authorization", "Bearer second")]).text == "grace")
        #expect(try client.get("/me", headers: [("authorization", "Bearer banned")]).status == 403)
        #expect(try client.get("/me").header("www-authenticate") == "Bearer")
    }

    @Test func aRefusedRequestNeverReachesTheHandler() throws {
        let ran = Counter()
        let app = Application()
        app.authenticate(bearer: SignedIn.self) { tokens[$0] }
        app.get("/me") { (user: Context<SignedIn>) in
            ran.increment()
            return user.value
        }
        let client = app.test
        #expect(try client.get("/me", headers: [("authorization", "Bearer wrong")]).status == 401)
        #expect(ran.value == 0)
        // And the identity does not outlive its request on the connection.
        let pipelined = try client.sendPipelined(raw: Array((
            "GET /me HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer second\r\n\r\n"
                + "GET /me HTTP/1.1\r\nHost: t\r\n\r\n").utf8))
        #expect(pipelined.map(\.status.code) == [200, 401])
        #expect(ran.value == 1)
    }

    @Test func basicCredentialsAreDecodedAndChallengedWithTheRealm() throws {
        let app = Application()
        app.authenticate(basic: SignedIn.self, realm: "the \"admin\" area") { username, password in
            username == "ada" && constantTimeEquals(password, "pass:word é") ? username : nil
        }
        app.get("/admin") { (user: Context<SignedIn>) in "admin \(user.value)" }
        let client = app.test

        let challenge = try client.get("/admin")
        #expect(challenge.status == 401)
        #expect(challenge.header("www-authenticate") == #"Basic realm="the \"admin\" area", charset="UTF-8""#)
        // ada:pass:word é
        let good = "Basic " + StandardBase64.encode(Array("ada:pass:word é".utf8))
        #expect(try client.get("/admin", headers: [("authorization", good)]).text == "admin ada")
        let wrong = "Basic " + StandardBase64.encode(Array("ada:password".utf8))
        #expect(try client.get("/admin", headers: [("authorization", wrong)]).status == 401)
        #expect(try client.get("/admin", headers: [("authorization", "Basic not*base64")]).status == 401)
        let noColon = "Basic " + StandardBase64.encode(Array("ada".utf8))
        #expect(try client.get("/admin", headers: [("authorization", noColon)]).status == 401)
    }

    @Test func aBearerHeaderIsReadAsTheToken68ItCarries() {
        let cases: [(String, String?)] = [
            ("Bearer abc.def-_~+/", "abc.def-_~+/"),
            ("bearer   abc", "abc"),
            ("BEARER abc==", "abc=="),
            ("Bearer abc=d", nil),
            ("Bearer a b", nil),
            ("Bearer ümlaut", nil),
            ("Bearer", nil),
            ("Bearer ", nil),
            ("Bearer    ", nil),
            ("Bearerabc", nil),
            ("Basic abc", nil),
            ("", nil),
        ]
        for (header, token) in cases {
            #expect(parseBearer(header) == token, "\(header)")
        }
    }

    @Test func aBasicHeaderIsReadAsTheCredentialsItCarries() {
        func parsed(_ header: String) -> String? {
            parseBasic(header).map { "\($0.username)/\($0.password)" }
        }
        #expect(parsed("Basic " + StandardBase64.encode(Array("u:p:q".utf8))) == "u/p:q")
        #expect(parsed("basic   " + StandardBase64.encode(Array("u:".utf8))) == "u/")
        #expect(parsed("Basic " + StandardBase64.encode([0x75, 0x3A, 0xFF])) == nil, "not UTF-8")
        #expect(parsed("Basic dTpw-_") == nil, "base64url is not Basic's alphabet")
        #expect(parsed("Basic") == nil)
        #expect(parsed("Basic ") == nil)
        #expect(parsed("BasicdTpw") == nil)
        #expect(parsed("Bearer dTpw") == nil)
    }

    @Test func theExtractorsParseTheSameHeaders() throws {
        let app = Application()
        app.get("/token") { (bearer: BearerToken) in bearer.token }
        app.get("/basic") { (credentials: BasicCredentials) in "\(credentials.username)/\(credentials.password)" }
        app.get("/maybe") { (bearer: BearerToken?) in bearer?.token ?? "anonymous" }
        let client = app.test

        #expect(try client.get("/token", headers: [("authorization", "Bearer abc")]).text == "abc")
        let noToken = try client.get("/token")
        #expect(noToken.status == 401)
        #expect(noToken.header("www-authenticate") == "Bearer")
        let basic = "Basic " + StandardBase64.encode(Array("u:p".utf8))
        #expect(try client.get("/basic", headers: [("authorization", basic)]).text == "u/p")
        let noBasic = try client.get("/basic")
        #expect(noBasic.status == 401)
        #expect(noBasic.header("www-authenticate") == #"Basic realm="restricted", charset="UTF-8""#)
        // Made optional, a missing token is no challenge: the route went on.
        let anonymous = try client.get("/maybe")
        #expect(anonymous.text == "anonymous")
        #expect(anonymous.header("www-authenticate") == nil)
    }

    @Test func aRouterGuardsItsOwnRoutes() throws {
        let users = Router()
        users.authenticate(bearer: SignedIn.self) { tokens[$0] }
        users.get("/me") { (user: Context<SignedIn>) in user.value }
        let app = Application()
        app.nest("/users", users)
        app.get("/open") { () in "open" }
        let client = app.test
        #expect(try client.get("/users/me", headers: [("authorization", "Bearer second")]).text == "grace")
        #expect(try client.get("/users/me").status == 401)
        #expect(try client.get("/open").text == "open")
    }

    @Test func constantTimeEqualsComparesBytes() {
        #expect(constantTimeEquals("secret", "secret"))
        #expect(!constantTimeEquals("secreT", "secret"))
        #expect(!constantTimeEquals("secret", "secrets"))
        #expect(!constantTimeEquals("secrets", "secret"))
        #expect(!constantTimeEquals("", "secret"))
        #expect(!constantTimeEquals("x", ""))
        #expect(constantTimeEquals("", ""))
    }
}

@Suite("State from middleware")
struct StateFromMiddlewareTests {
    final class Sessions: Sendable {
        let tokens: [String: String]
        init(_ tokens: [String: String]) { self.tokens = tokens }
    }

    enum Who: RequestContextKey { typealias Value = String }

    @Test func authenticateHandsTheShardsStateToItsCheck() throws {
        let app = Application()
        app.state { _ in Sessions(["t0k3n": "ada"]) }
        app.group("/api") {
            app.authenticate(bearer: Who.self, state: Sessions.self) { token, sessions in
                sessions.tokens[token]
            }
            app.get("/me") { (who: Context<Who>) in who.value }
        }
        app.group("/admin") {
            app.authenticate(basic: Who.self, realm: "admin", state: Sessions.self) { user, password, sessions in
                sessions.tokens[password] == user ? user : nil
            }
            app.get("/") { (who: Context<Who>) in "admin \(who.value)" }
        }
        let client = app.test
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer t0k3n")]).text == "ada")
        #expect(try client.get("/api/me", headers: [("authorization", "Bearer other")]).status == .unauthorized)
        let missing = try client.get("/api/me")
        #expect(missing.status == .unauthorized)
        #expect(missing.header("www-authenticate") == "Bearer")
        let basic = "Basic " + StandardBase64.encode(Array("ada:t0k3n".utf8))
        #expect(try client.get("/admin", headers: [("authorization", basic)]).text == "admin ada")
        #expect(try client.get("/admin").header("www-authenticate")?.hasPrefix("Basic realm=\"admin\"") == true)
    }

    @Test func middlewareReadsStateAndAMissingOneIsAServerFault() throws {
        let app = Application()
        app.state { _ in Sessions(["x": "y"]) }
        app.use { request, response, next in
            let sessions = try request.state(Sessions.self)
            guard sessions.tokens.count == 1 else { return response.send(status: .serviceUnavailable) }
            try await next()
        }
        app.get("/ok") { () in "ok" }
        #expect(try app.test.get("/ok").text == "ok")

        let bare = Application()
        bare.authenticate(bearer: Who.self, state: Sessions.self) { token, _ in token }
        bare.get("/ok") { () in "ok" }
        #expect(try bare.test.get("/ok", headers: [("authorization", "Bearer t")]).status == .internalServerError)
    }
}
