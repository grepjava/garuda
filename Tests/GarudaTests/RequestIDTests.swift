import Testing
@testable import Garuda
import GarudaTesting
import GarudaWire

// --request-id: one ID per request, the same in the application, on the
// response and in the logs; a trusted proxy's kept, anyone else's replaced.

@Suite struct RequestIDTests {
    private func app() -> Application {
        let app = Application()
        app.get("/request-id") { request, response in
            if let id = request.requestID {
                response.send(id)
            } else {
                response.send(status: 200)
            }
        }
        app.get("/seen") { request, response in
            // What the application sees of the client's own header.
            response.send(request.header("x-request-id") ?? "none")
        }
        app.get("/own") { request, response in
            response.addHeader("x-request-id", "the-handlers")
            response.send("own")
        }
        app.get("/lent") { request, response in
            let count = request.withRequestID { $0.count } ?? -1
            response.send("\(count)")
        }
        return app
    }

    private func client(trusting proxies: String? = nil) -> TestClient {
        var config = ServerConfig()
        config.requestID = true
        if let proxies { _ = proxies.withCString { config.trust.parse($0) } }
        return app().testClient(configuration: config)
    }

    /// Whether `id` is a version 4 UUID in lowercase hex.
    private func isUUIDv4(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard bytes.count == 36 else { return false }
        for (i, c) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) {
                if c != UInt8(ascii: "-") { return false }
            } else if !((c >= 0x30 && c <= 0x39) || (c >= 0x61 && c <= 0x66)) {
                return false
            }
        }
        return bytes[14] == UInt8(ascii: "4") && [UInt8(ascii: "8"), UInt8(ascii: "9"),
                                                  UInt8(ascii: "a"), UInt8(ascii: "b")].contains(bytes[19])
    }

    @Test func aTestConfigurationReachesTheConnection() throws {
        let response = try client().get("/request-id")
        let id = response.header("x-request-id")
        #expect(id != nil)
        #expect(response.text == id)
    }

    @Test func anIDIsAVersion4UUIDAndEachIsNew() throws {
        let client = client()
        var seen: Set<String> = []
        for _ in 0..<50 {
            let id = try #require(try client.get("/request-id").header("x-request-id"))
            #expect(isUUIDv4(id))
            seen.insert(id)
        }
        // And on one connection, where the exchange is reused.
        let both = try client.sendPipelined(raw: Array(
            ("GET /request-id HTTP/1.1\r\nHost: t\r\n\r\n"
                + "GET /request-id HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n").utf8))
        for response in both { seen.insert(response.text) }
        #expect(seen.count == 52)
        #expect(try client.get("/lent").text == "36")
    }

    @Test func withoutTheFlagThereIsNone() throws {
        let response = try app().test.get("/request-id", headers: [("x-request-id", "mine")])
        #expect(response.header("x-request-id") == nil)
        #expect(response.text == "")
    }

    @Test func aClientsIDIsReplacedNotKept() throws {
        // A header a client can set is not an identifier anyone can rely on.
        let client = client()
        let response = try client.get("/request-id", headers: [("X-Request-ID", "chosen-to-collide")])
        let id = try #require(response.header("x-request-id"))
        #expect(id != "chosen-to-collide")
        #expect(response.text == id)
        #expect(response.headers(named: "x-request-id").count == 1)
        // And taken out of what the application sees, not left beside it.
        let seen = try client.get("/seen", headers: [("x-request-id", "a"), ("x-other", "b"), ("x-request-id", "c")])
        #expect(seen.text == "none")
    }

    @Test func aTrustedProxysIDIsKept() throws {
        let client = client(trusting: "127.0.0.1")
        let kept = try client.get("/request-id", headers: [("x-request-id", "proxy-7c9e:01")])
        #expect(kept.header("x-request-id") == "proxy-7c9e:01")
        #expect(kept.text == "proxy-7c9e:01")
        #expect(try client.get("/seen", headers: [("x-request-id", "proxy-1")]).text == "proxy-1")

        // Unless it does not look like an ID: a character a log line would
        // have to escape, or a length nothing needs.
        let odd = try client.get("/request-id", headers: [("x-request-id", "has space")])
        #expect(odd.header("x-request-id").map(isUUIDv4) == true)
        let long = try client.get("/request-id", headers: [("x-request-id", String(repeating: "a", count: 129))])
        #expect(long.header("x-request-id").map(isUUIDv4) == true)
        // A proxy that sent none gets one made.
        #expect(try client.get("/request-id").header("x-request-id").map(isUUIDv4) == true)
    }

    @Test func anUntrustedPeerIsNotAProxy() throws {
        let client = client(trusting: "10.0.0.0/8")
        let response = try client.get("/request-id", headers: [("x-request-id", "proxy-7c9e")])
        #expect(response.header("x-request-id").map(isUUIDv4) == true)
    }

    @Test func aHandlersOwnIDIsSentInsteadOfDoubled() throws {
        let response = try client().get("/own")
        #expect(response.headers(named: "x-request-id") == ["the-handlers"])
    }
}
