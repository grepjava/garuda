import Testing
@testable import Garuda
import AvianHTTP

// A host allow-list and a client address filter.

@Suite("Host and address filters")
struct HostAndAddressFilterTests {
    @Test(arguments: [
        ("example.com", 200),
        ("EXAMPLE.com:8443", 200),
        ("api.example.com", 200),
        ("deep.api.example.com", 200),
        ("[::1]:8080", 200),
        ("10.1.2.3", 200),
        ("evil.com", 400),
        ("example.com.evil.com", 400),
        ("notexample.com", 400),
        ("other.org", 400),
        ("[::2]", 400),
        ("[::1", 400),
        (":8080", 400),
    ])
    func onlyAllowedHostsAreAnswered(host: String, status: Int) throws {
        let app = Application()
        app.allowedHosts(["example.com", "*.example.com", "[::1]", "10.1.2.3"])
        app.get("/") { "hello" }
        #expect(try app.test.get("/", headers: [("host", host)]).status.code == status)
    }

    @Test func aDomainPatternDoesNotCoverTheDomainItself() throws {
        let app = Application()
        app.group("/tenant") {
            app.allowedHosts(["*.example.com"])
            app.get("/") { "tenant" }
        }
        app.get("/open") { "open" }
        let client = app.test
        #expect(try client.get("/tenant", headers: [("host", "a.example.com")]).text == "tenant")
        #expect(try client.get("/tenant", headers: [("host", "example.com")]).status == 400)
        #expect(try client.get("/open", headers: [("host", "anything")]).text == "open")
    }

    private func addressApp(allow: [String], deny: [String]) -> Application {
        let app = Application()
        app.group("/admin") {
            app.addressFilter(allow: allow, deny: deny)
            app.get("/") { request, response in response.send(request.remoteAddress) }
        }
        app.get("/open") { "open" }
        return app
    }

    private func status(_ app: Application, from address: String?) throws -> Int {
        var config = ServerConfig()
        config.maxConnections = 16
        #expect("127.0.0.1".withCString { config.trust.parse($0) })
        let headers = address.map { [("x-forwarded-for", $0)] } ?? []
        return try app.testClient(configuration: config).get("/admin", headers: headers).status.code
    }

    @Test func anAllowListLetsOnlyItsAddressesIn() throws {
        let app = addressApp(allow: ["10.0.0.0/8", "2001:db8::/32"], deny: [])
        #expect(try status(app, from: "10.20.30.40") == 200)
        #expect(try status(app, from: "::ffff:10.1.1.1") == 200)
        #expect(try status(app, from: "2001:db8::7") == 200)
        #expect(try status(app, from: "11.0.0.1") == 403)
        #expect(try status(app, from: "2001:db9::1") == 403)
        // The peer itself, with nothing forwarded.
        #expect(try status(app, from: nil) == 403)
        #expect(try app.test.get("/open").text == "open")
    }

    @Test func denyIsReadFirst() throws {
        let app = addressApp(allow: ["10.0.0.0/8"], deny: ["10.0.0.5", "10.9.0.0/16"])
        #expect(try status(app, from: "10.0.0.4") == 200)
        #expect(try status(app, from: "10.0.0.5") == 403)
        #expect(try status(app, from: "10.9.200.1") == 403)
        let denyOnly = addressApp(allow: [], deny: ["127.0.0.1"])
        #expect(try status(denyOnly, from: nil) == 403)
        #expect(try status(denyOnly, from: "192.0.2.1") == 200)
        let everyone = addressApp(allow: ["*"], deny: ["192.0.2.0/24"])
        #expect(try status(everyone, from: "198.51.100.1") == 200)
        #expect(try status(everyone, from: "192.0.2.9") == 403)
    }

    @Test func addressesAreMatchedAsTheyArePrinted() {
        #expect(clientAddressForMatching("") == "unix")
        #expect(clientAddressForMatching("::FFFF:192.0.2.1") == "192.0.2.1")
        #expect(clientAddressForMatching("::ffff:c000:201") == "::ffff:c000:201")
        #expect(hostWithoutPort("[::1]:80") == "[::1]")
        #expect(hostWithoutPort("[::1]x") == nil)
        #expect(hostWithoutPort("host:1") == "host")
    }
}
