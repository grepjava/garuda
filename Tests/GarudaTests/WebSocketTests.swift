import Testing
import GarudaTesting
import Synchronization
import Vega
@testable import Garuda

// WebSocket handlers through the test client. The protocol's edges -- bad
// frames, compression, pings, TLS -- are scripts/websocket-test.py's; these
// check the handler API.

private enum Who: RequestContextKey { typealias Value = String }

/// Somewhere for a handler to record what it saw.
private final class Seen: Sendable {
    let text = Mutex("")
}

@Suite("WebSocket handlers")
struct WebSocketTests {

    @Test func messagesRoundTrip() throws {
        let app = Application()
        app.webSocket("/echo") { (ws: WebSocket) async throws in
            for try await message in ws { try await ws.send(message) }
        }
        let ws = try app.test.webSocket("/echo")
        #expect(ws.response.status == 101)
        #expect(ws.response.header("sec-websocket-accept") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        #expect(ws.response.header("connection") == "Upgrade")
        #expect(ws.response.header("content-length") == nil)
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
            app.use { request, response, next in
                guard request.header("authorization") == "yes" else { return response.send(status: .forbidden) }
                request[context: Who.self] = "ada"
                response.addHeader("set-cookie", "seen=1")
                try await next()
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

    @Test func aRequestThatIsNotAnUpgradeIsRefused() throws {
        let app = Application()
        app.webSocket("/ws") { (_: WebSocket) async throws in }
        let client = app.test
        let plain = try client.get("/ws")
        #expect(plain.status == 426)
        #expect(plain.header("upgrade") == "websocket")
        let version = try client.webSocket("/ws", headers: [("sec-websocket-version", "8")])
        #expect(version.response.status == 426)
        let short = try client.get("/ws", headers: [("upgrade", "websocket"), ("connection", "Upgrade"),
                                                     ("sec-websocket-version", "13"), ("sec-websocket-key", "c2hvcnQ=")])
        #expect(short.status == 400)
    }

    @Test func websocketsCanBeTurnedOff() throws {
        let app = Application()
        app.webSocket("/ws") { (_: WebSocket) async throws in }
        var config = ServerConfig()
        config.websocketsEnabled = false
        let ws = try app.testClient(configuration: config).webSocket("/ws")
        #expect(ws.response.status == 501)
    }

    @Test func subprotocolsAreAgreedInTheRoutesOrder() throws {
        let app = Application()
        app.webSocket("/ws", subprotocols: ["v2", "v1"]) { (ws: WebSocket) async throws in
            try await ws.send("\(ws.subprotocol ?? "none") of \(ws.offeredSubprotocols.joined(separator: ","))")
        }
        let client = app.test
        let ws = try client.webSocket("/ws", headers: [("sec-websocket-protocol", "v1, v2")])
        #expect(ws.response.header("sec-websocket-protocol") == "v2")
        #expect(try ws.receive() == .text("v2 of v1,v2"))
        let none = try client.webSocket("/ws", headers: [("sec-websocket-protocol", "v9")])
        #expect(none.response.header("sec-websocket-protocol") == nil)
        #expect(try none.receive() == .text("none of v9"))
    }

    @Test func theHandlerSeesThePeersClose() async throws {
        let seen = Seen()
        let app = Application()
        app.webSocket("/ws") { (ws: WebSocket) async throws in
            while try await ws.receive() != nil {}
            seen.text.withLock { $0 = "\(ws.closeCode ?? 0) \(ws.closeReason)" }
        }
        let ws = try app.test.webSocket("/ws")
        try ws.close(code: 4001, reason: "done")
        #expect(ws.closeCode == 4001)
        for _ in 0..<200 where seen.text.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(seen.text.withLock { $0 } == "4001 done")
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
        app.webSocket("/return") { (_: WebSocket) async throws in }
        let client = app.test
        let closing = try client.webSocket("/close")
        #expect(try closing.receive() == nil)
        #expect(closing.closeCode == 4000)
        #expect(closing.closeReason == "bye")

        let throwing = try client.webSocket("/throw")
        try throwing.send("go")
        #expect(try throwing.receive() == nil)
        #expect(throwing.closeCode == 1011)

        let returning = try client.webSocket("/return")
        #expect(try returning.receive() == nil)
        #expect(returning.closeCode == 1000)
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

    @Test func unreadMessagesWaitPastTheQueueAndNoneIsLost() throws {
        let app = Application()
        app.webSocket("/late") { (ws: WebSocket) async throws in
            try await ws.sleep(milliseconds: 30)
            var count = 0
            while let _ = try await ws.receive() {
                count += 1
                if count == 40 { break }
            }
            try await ws.send("\(count)")
        }
        var config = ServerConfig()
        config.maxWebsocketQueue = 4
        let ws = try app.testClient(configuration: config).webSocket("/late")
        for i in 0..<40 { try ws.send("m\(i)") }
        #expect(try ws.receive() == .text("40"))
    }

    @Test func aPingIsAnsweredWhileTheHandlerIsNotReading() throws {
        let app = Application()
        app.webSocket("/silent") { (ws: WebSocket) async throws in
            try await ws.sleep(milliseconds: 200)
        }
        let ws = try app.test.webSocket("/silent")
        try ws.ping([1, 2, 3])
        // The pong is not a message: the next thing to arrive is the close.
        #expect(try ws.receive() == nil)
        #expect(ws.closeCode == 1000)
    }

    @Test func oneTaskReceivesWhileAnotherSends() throws {
        let app = Application()
        app.webSocket("/both") { (ws: WebSocket) async throws in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for i in 1...3 {
                        try await ws.send("tick \(i)")
                        try await ws.sleep(milliseconds: 10)
                    }
                }
                group.addTask {
                    if case .text(let text)? = try await ws.receive() { try await ws.send("got \(text)") }
                }
                try await group.waitForAll()
            }
        }
        let ws = try app.test.webSocket("/both")
        try ws.send("hi")
        var seen: Set<String> = []
        for _ in 0..<4 {
            if case .text(let text)? = try ws.receive() { seen.insert(text) }
        }
        #expect(seen == ["tick 1", "tick 2", "tick 3", "got hi"])
    }

    @Test func aWebSocketSubscribesToATopic() throws {
        let room = Topic("test/ws/\(monotonicNanos())")
        let app = Application()
        app.webSocket("/chat") { (ws: WebSocket) async throws in
            let messages = try ws.subscribe(room)
            while let incoming = try await ws.receive() {
                guard case .text(let text) = incoming else { continue }
                try room.publish(text, event: "said")
                guard case .message(let message) = try await messages.next() else { continue }
                try await ws.send("\(message.event ?? "") \(message.text)")
            }
        }
        let ws = try app.test.webSocket("/chat")
        try ws.send("hello")
        #expect(try ws.receive() == .text("said hello"))
        try ws.send("again")
        #expect(try ws.receive() == .text("said again"))
        try ws.close()
    }

    @Test func theAcceptValueIsRFC6455s() {
        let offer = WebSocketOffer(key: Array("dGhlIHNhbXBsZSBub25jZQ==".utf8), subprotocols: [], extensions: [])
        #expect(offer.acceptValue() == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        #expect(sha1(Array("abc".utf8)).map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
                == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }
}
