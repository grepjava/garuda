import Testing
@testable import Garuda
import AvianHTTP

// Reading cookies, Set-Cookie, and signed and encrypted cookies.

private let secret = [UInt8](repeating: 7, count: 32)
private let older = [UInt8](repeating: 9, count: 32)

@Suite("Cookies")
struct CookiesTests {

    @Test func cookiesAreReadFromEveryCookieHeader() throws {
        let app = Application()
        app.get("/") { request, response in
            let all = request.cookies.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            response.send("\(request.cookie("theme") ?? "-") \(request.cookie("missing") ?? "-") \(all)")
        }
        app.get("/extract") { (cookies: Cookies) in cookies["a"] ?? "none" }
        let client = app.test
        let text = try client.get("/", headers: [
            ("cookie", "theme=dark;  a=1 ; quoted=\"x y\"; broken; =nameless"),
            ("Cookie", "a=2; b=3"),
        ]).text
        #expect(text == #"dark - ["a=1", "b=3", "quoted=x y", "theme=dark"]"#)
        #expect(try client.get("/extract", headers: [("cookie", "a=b=c")]).text == "b=c")
        #expect(try client.get("/extract").text == "none")
    }

    @Test func aCookieIsSetWithSafeDefaults() throws {
        let app = Application()
        app.get("/set") { _, response in
            response.setCookie(Cookie("theme", "dark"))
            var session = Cookie("sid", "abc", maxAge: 3600, sameSite: .strict)
            session.domain = "example.com"
            response.setCookie(session)
            response.setCookie(Cookie("embed", "1", httpOnly: false, sameSite: Cookie.SameSite.none))
            var old = Cookie("legacy", "v", path: nil, sameSite: nil)
            old.expires = Timestamp(secondsSinceEpoch: 784_111_777)
            old.partitioned = true
            response.setCookie(old)
            response.removeCookie("gone")
            response.send("ok")
        }
        app.get("/bad") { _, response in
            let refused = [
                response.setCookie(Cookie("", "v")),
                response.setCookie(Cookie("a b", "v")),
                response.setCookie(Cookie("a", "has space")),
                response.setCookie(Cookie("a", "semi;colon")),
                response.setCookie(Cookie("a", "quote\"")),
                response.setCookie(Cookie("a", "é")),
                response.setCookie(Cookie("a", "v", path: "/x; Domain=evil")),
            ]
            response.send("\(refused)")
        }
        let client = app.test
        let response = try client.get("/set")
        #expect(response.headers(named: "set-cookie") == [
            "theme=dark; Path=/; HttpOnly; SameSite=Lax",
            "sid=abc; Path=/; Domain=example.com; Max-Age=3600; HttpOnly; SameSite=Strict",
            "embed=1; Path=/; Secure; SameSite=None",
            "legacy=v; Expires=Sun, 06 Nov 1994 08:49:37 GMT; HttpOnly; Partitioned",
            "gone=; Path=/; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; HttpOnly; SameSite=Lax",
        ])
        #expect(try client.get("/bad").text == "[false, false, false, false, false, false, false]")
        #expect(try client.get("/bad").headers(named: "set-cookie").isEmpty)
    }

    @Test func aCookieIsSecureOverHTTPSFromATrustedProxy() throws {
        let app = Application()
        app.get("/") { _, response in
            response.setCookie(Cookie("a", "1"))
            response.setCookie(Cookie("b", "2", secure: false))
            response.send("ok")
        }
        var config = ServerConfig()
        config.maxConnections = 16
        #expect("127.0.0.1".withCString { config.trust.parse($0) })
        let headers = try app.testClient(configuration: config)
            .get("/", headers: [("x-forwarded-proto", "https")]).headers(named: "set-cookie")
        #expect(headers == ["a=1; Path=/; Secure; HttpOnly; SameSite=Lax", "b=2; Path=/; HttpOnly; SameSite=Lax"])
    }

    private func protectedApp(_ key: CookieKey) -> Application {
        let app = Application()
        app.get("/set/:kind") { request, response in
            let kind: CookieProtection = request.parameter(0) == "signed" ? .signed : .encrypted
            response.setCookie(Cookie("user", "ada; admin=\"yes\" é"), key: key, kind)
            response.send("ok")
        }
        app.get("/read/:kind") { request, response in
            let kind: CookieProtection = request.parameter(0) == "signed" ? .signed : .encrypted
            response.send(request.cookie("user", key: key, kind) ?? "nil")
        }
        return app
    }

    private func cookieValue(_ header: String?) -> String {
        guard let header, let equals = header.firstIndex(of: "="), let semi = header.firstIndex(of: ";") else { return "" }
        return String(header[header.index(after: equals)..<semi])
    }

    @Test(arguments: ["signed", "encrypted"])
    func aProtectedCookieRoundTripsAndResistsTampering(kind: String) throws {
        let key = CookieKey(secret: secret)
        let client = protectedApp(key).test
        let value = cookieValue(try client.get("/set/\(kind)").header("set-cookie"))
        #expect(!value.isEmpty)
        #expect(isCookieValue(value))
        if kind == "encrypted" { #expect(!value.contains("ada")) }

        #expect(try client.get("/read/\(kind)", headers: [("cookie", "user=\(value)")]).text == "ada; admin=\"yes\" é")

        // Changed by one character, moved to another name, or read the other way.
        var chars = Array(value)
        chars[chars.count / 2] = chars[chars.count / 2] == "A" ? "B" : "A"
        #expect(try client.get("/read/\(kind)", headers: [("cookie", "user=\(String(chars))")]).text == "nil")
        let other = kind == "signed" ? "encrypted" : "signed"
        #expect(try client.get("/read/\(other)", headers: [("cookie", "user=\(value)")]).text == "nil")
        #expect(unprotectCookie(name: "admin", value: value, key: key, kind == "signed" ? .signed : .encrypted) == nil)
        #expect(try client.get("/read/\(kind)", headers: [("cookie", "user=garbage")]).text == "nil")

        // A different secret does not read it; one that lists it as previous does.
        #expect(try protectedApp(CookieKey(secret: older)).test
            .get("/read/\(kind)", headers: [("cookie", "user=\(value)")]).text == "nil")
        #expect(try protectedApp(CookieKey(secret: older, previous: [secret])).test
            .get("/read/\(kind)", headers: [("cookie", "user=\(value)")]).text == "ada; admin=\"yes\" é")

        // A forged copy first does not hide the genuine one after it.
        #expect(try client.get("/read/\(kind)", headers: [("cookie", "user=forged; user=\(value)")]).text
            == "ada; admin=\"yes\" é")
    }

    @Test func keysComeFromBase64AndRandomSecretsAreFresh() {
        let text = CookieKey.randomSecret()
        #expect(text.utf8.count == 43)
        #expect(text != CookieKey.randomSecret())
        #expect(CookieKey(base64: text) != nil)
        #expect(CookieKey(base64: "c2hvcnQ=") == nil)
        #expect(CookieKey(base64: "not base64!") == nil)
        #expect(CookieKey(base64: text, previous: ["c2hvcnQ="]) == nil)
    }
}
