import Testing
@testable import Garuda

// WebSocket handlers through the test client. The protocol's edges -- bad
// frames, compression, pings, TLS -- are scripts/websocket-test.py's; these
// check the handler API.

private enum Who: RequestContextKey { typealias Value = String }

@Suite("WebSocket handlers", .serialized)
struct WebSocketHandlerTests {

    @Test func messagesRoundTrip() throws {
        let app = Application()
        app.webSocket("/echo") { (ws: WebSocket) async throws in
            for try await message in ws { try await ws.send(message) }
        }
        let ws = try app.test.webSocket("/echo")
        #expect(ws.response.status == 101)
        #expect(ws.response.header("sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        try ws.send("hello")
        #expect(try ws.receive() == .text("hello"))
        try ws.send([0, 1, 2, 255])
        #expect(try ws.receive() == .binary([0, 1, 2, 255]))
        let large = [UInt8](repeating: 7, count: 200_000)
        try ws.send(large)
        #expect(try ws.receive() == .binary(large))
        try ws.close()
        #expect(ws.closeCode == 1000)
    }

    @Test func extractorsAndMiddlewareRunBeforeTheUpgrade() throws {
        let app = Application()
        app.group("/rooms") {
            app.use { request, response in
                guard request.header("authorization") == "yes" else { return HTTPStatus.forbidden }
                request[context: Who.self] = "ada"
                response.addHeader("set-cookie", "seen=1")
                return nil
            }
            app.webSocket("/:name") { (ws: WebSocket, name: Path<String>, who: Context<Who>) async throws in
                try await ws.send("\(who.value) in \(name.value)")
            }
        }
        let client = app.test
        let refused = try client.webSocket("/rooms/lobby")
        #expect(refused.response.status == 403)

        let ws = try client.webSocket("/rooms/lobby", headers: [("authorization", "yes")])
        #expect(ws.response.status == 101)
        #expect(ws.response.header("set-cookie") == "seen=1")
        #expect(try ws.receive() == .text("ada in lobby"))
        #expect(try ws.receive() == nil)
        #expect(ws.closeCode == 1000)
    }

    @Test func aPlainRequestToTheRouteIs426() throws {
        let app = Application()
        app.webSocket("/ws") { (_: WebSocket) async throws in }
        let response = try app.test.get("/ws")
        #expect(response.status == 426)
        #expect(response.header("upgrade") == "websocket")
    }

    @Test func subprotocolsAreAgreedInTheRoutesOrder() throws {
        let app = Application()
        app.webSocket("/ws", subprotocols: ["v2", "v1"]) { (ws: WebSocket) async throws in
            try await ws.send(ws.subprotocol ?? "none")
        }
        let client = app.test
        let ws = try client.webSocket("/ws", headers: [("sec-websocket-protocol", "v1, v2")])
        #expect(ws.response.header("sec-websocket-protocol") == "v2")
        #expect(try ws.receive() == .text("v2"))
        let none = try client.webSocket("/ws", headers: [("sec-websocket-protocol", "v9")])
        #expect(none.response.header("sec-websocket-protocol") == nil)
        #expect(try none.receive() == .text("none"))
    }

    @Test func theHandlerSeesThePeersClose() throws {
        nonisolated(unsafe) var seen = ""
        let app = Application()
        app.webSocket("/ws") { (ws: WebSocket) async throws in
            while try await ws.receive() != nil {}
            seen = "\(ws.closeCode ?? 0) \(ws.closeReason)"
        }
        let client = app.test
        let ws = try client.webSocket("/ws")
        try ws.close(code: 4001, reason: "done")
        #expect(ws.closeCode == 4001)
        for _ in 0..<100 where seen.isEmpty { client.turn() }
        #expect(seen == "4001 done")
    }

    @Test func aHandlerClosesWithItsCodeOrForItself() throws {
        let app = Application()
        app.webSocket("/close") { (ws: WebSocket) async throws in
            ws.close(code: 4000, reason: "bye")
            while try await ws.receive() != nil {}
        }
        app.webSocket("/throw") { (ws: WebSocket) async throws in
            _ = try await ws.receive()
            throw HTTPError(.internalServerError, "on purpose")
        }
        let client = app.test
        let closing = try client.webSocket("/close")
        #expect(try closing.receive() == nil)
        #expect(closing.closeCode == 4000)
        #expect(closing.closeReason == "bye")

        let throwing = try client.webSocket("/throw")
        try throwing.send("go")
        #expect(try throwing.receive() == nil)
        #expect(throwing.closeCode == 1011)
    }

    @Test func aHandlerSleepsBetweenSends() throws {
        let app = Application()
        app.webSocket("/ticks") { (ws: WebSocket) async throws in
            for i in 1...3 {
                try await ws.send("tick \(i)")
                try await ws.sleep(milliseconds: 5)
            }
        }
        let ws = try app.test.webSocket("/ticks")
        #expect(try ws.receive() == .text("tick 1"))
        #expect(try ws.receive() == .text("tick 2"))
        #expect(try ws.receive() == .text("tick 3"))
        #expect(try ws.receive() == nil)
    }

    @Test func anUnreadMessageIsNotLost() throws {
        let app = Application()
        app.webSocket("/late") { (ws: WebSocket) async throws in
            try await ws.sleep(milliseconds: 30)
            var count = 0
            while let _ = try await ws.receive() {
                count += 1
                if count == 20 { break }
            }
            try await ws.send("\(count)")
        }
        let ws = try app.test.webSocket("/late")
        for i in 0..<20 { try ws.send("m\(i)") }
        #expect(try ws.receive() == .text("20"))
    }

    @Test func aRoutersWebSocketTakesThePrefix() throws {
        let router = Router()
        router.webSocket("/live") { (ws: WebSocket) async throws in try await ws.send("live") }
        let app = Application()
        app.nest("/v1", router)
        let ws = try app.test.webSocket("/v1/live")
        #expect(try ws.receive() == .text("live"))
    }
}
