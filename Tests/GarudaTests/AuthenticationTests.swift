import Testing
@testable import Garuda
import GarudaPostgres

// Bearer and Basic authentication, as middleware and as extractors.

private enum CurrentUser: RequestContextKey { typealias Value = String }

private let tokens = ["t0k3n.abc-_~+/=": "ada", "second": "grace"]

@Suite("Authentication", .serialized)
struct AuthenticationTests {

    @Test func aBearerTokenIsCheckedAndItsOwnerKept() throws {
        let app = Application()
        app.get("/health") { _, response in response.send("ok") }
        app.group("/api") {
            app.authenticate(bearer: CurrentUser.self) { token in tokens[token] }
            app.get("/me") { (user: Context<CurrentUser>) in "hello \(user.value)" }
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
        app.authenticate(bearer: CurrentUser.self) { token async throws -> String? in
            await loopYield()
            if token == "banned" { throw HTTPError.forbidden("banned") }
            return tokens[token]
        }
        app.get("/me") { (user: Context<CurrentUser>) in user.value }
        let client = app.test
        #expect(try client.get("/me", headers: [("authorization", "Bearer second")]).text == "grace")
        #expect(try client.get("/me", headers: [("authorization", "Bearer banned")]).status == 403)
        #expect(try client.get("/me").header("www-authenticate") == "Bearer")
    }

    @Test func basicCredentialsAreDecodedAndChallengedWithTheRealm() throws {
        let app = Application()
        app.authenticate(basic: CurrentUser.self, realm: "the \"admin\" area") { username, password in
            username == "ada" && constantTimeEquals(password, "pass:word é") ? username : nil
        }
        app.get("/admin") { (user: Context<CurrentUser>) in "admin \(user.value)" }
        let client = app.test

        let challenge = try client.get("/admin")
        #expect(challenge.status == 401)
        #expect(challenge.header("www-authenticate") == #"Basic realm="the \"admin\" area", charset="UTF-8""#)
        // ada:pass:word é
        let good = "Basic " + Base64.encode(Array("ada:pass:word é".utf8))
        #expect(try client.get("/admin", headers: [("authorization", good)]).text == "admin ada")
        let wrong = "Basic " + Base64.encode(Array("ada:password".utf8))
        #expect(try client.get("/admin", headers: [("authorization", wrong)]).status == 401)
        #expect(try client.get("/admin", headers: [("authorization", "Basic not*base64")]).status == 401)
        let noColon = "Basic " + Base64.encode(Array("ada".utf8))
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

    @Test func theExtractorsParseTheSameHeaders() throws {
        let app = Application()
        app.get("/token") { (bearer: BearerToken) in bearer.token }
        app.get("/basic") { (credentials: BasicCredentials) in "\(credentials.username)/\(credentials.password)" }
        let client = app.test

        #expect(try client.get("/token", headers: [("authorization", "Bearer abc")]).text == "abc")
        let noToken = try client.get("/token")
        #expect(noToken.status == 401)
        #expect(noToken.header("www-authenticate") == "Bearer")
        let basic = "Basic " + Base64.encode(Array("u:p".utf8))
        #expect(try client.get("/basic", headers: [("authorization", basic)]).text == "u/p")
        let noBasic = try client.get("/basic")
        #expect(noBasic.status == 401)
        #expect(noBasic.header("www-authenticate") == #"Basic realm="restricted", charset="UTF-8""#)
    }

    @Test func aRefusalReachesACrossOriginPage() throws {
        let app = Application()
        app.cors(CORSPolicy(origins: ["https://app.example.com"]))
        app.authenticate(bearer: CurrentUser.self) { tokens[$0] }
        app.get("/me") { (user: Context<CurrentUser>) in user.value }
        let client = app.test
        let refused = try client.get("/me", headers: [("origin", "https://app.example.com")])
        #expect(refused.status == 401)
        #expect(refused.header("access-control-allow-origin") == "https://app.example.com")
        #expect(try client.request("OPTIONS", "/me",
                                   headers: [("origin", "https://app.example.com"),
                                             ("access-control-request-method", "GET"),
                                             ("access-control-request-headers", "authorization")]).status == 204)
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
