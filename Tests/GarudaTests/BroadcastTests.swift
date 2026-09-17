import Testing
import CAvian
@testable import Garuda

// Topics and subscriptions within one worker: delivery, reading back after a
// Last-Event-ID, a subscriber that falls behind, publishing from a blocking
// thread, WebSockets, and an event stream's keep-alive. Every worker hearing
// every other is scripts/broadcast-test.py's, against a server with several.

/// A topic of its own for each test: the ring is one for the whole process.
private func topic(_ name: String) -> Topic {
    Topic("test/\(name)/\(av_monotonic_us())")
}

@Suite("Broadcast")
struct BroadcastTests {
    @Test func aSubscriberHearsWhatIsPublishedAfterItSubscribed() throws {
        let room = topic("hear")
        let app = Application()
        app.get("/listen") { () async in
            EventStream { events in
                try room.publish("before")
                let messages = try events.subscribe(room)
                try room.publish("one", event: "said")
                try Topic("test/elsewhere").publish("not for this stream")
                try room.publish("two")
                for _ in 0..<2 {
                    if case .message(let message) = try await messages.next() {
                        try await events.send(message)
                    }
                }
            }
        }
        let text = try app.test.get("/listen").text
        let ids = text.split(separator: "\n").filter { $0.hasPrefix("id: ") }.map { String($0.dropFirst(4)) }
        #expect(ids.count == 2)
        let first = try #require(ids.first.flatMap { BroadcastID($0) })
        #expect(text == "event: said\nid: \(first)\ndata: one\n\nid: \(first.rawValue + 2)\ndata: two\n\n")
    }

    @Test func lastEventIDSendsWhatWasMissedFirst() throws {
        let room = topic("replay")
        let app = Application()
        app.post("/publish") { () in
            var ids: [String] = []
            for i in 1...4 { ids.append(try room.publish("m\(i)").description) }
            return ids.joined(separator: " ")
        }
        app.get("/listen") { (last: LastEventID) async in
            EventStream { events in
                let messages = try events.subscribe(room, after: last)
                try room.publish("live")
                while true {
                    guard case .message(let message) = try await messages.next() else { continue }
                    try await events.send(message.text)
                    if message.text == "live" { return }
                }
            }
        }
        let client = app.test
        let ids = try client.post("/publish", body: []).text.split(separator: " ").map(String.init)
        #expect(ids.count == 4)
        let resumed = try client.get("/listen", headers: [("last-event-id", ids[1])])
        #expect(resumed.text == "data: m3\n\ndata: m4\n\ndata: live\n\n")
        let fresh = try client.get("/listen")
        #expect(fresh.text == "data: live\n\n")
    }

    @Test func anIDOlderThanTheRingIsAGap() throws {
        let room = topic("old")
        let app = Application()
        app.get("/listen") { () async in
            EventStream { events in
                // A number from before this ring was mapped: long gone.
                let messages = try events.subscribe(room, after: LastEventID("5"))
                try room.publish("live")
                #expect(try await messages.next() == .missed)
                if case .message(let message) = try await messages.next() {
                    try await events.send(message.text)
                }
            }
        }
        #expect(try app.test.get("/listen").text == "data: live\n\n")
    }

    @Test func aSubscriberThatFallsBehindIsToldItMissedSome() throws {
        let room = topic("behind")
        let app = Application()
        app.get("/listen") { () async in
            EventStream { events in
                let messages = try events.subscribe(room)
                for i in 1...5 { try room.publish("m\(i)") }
                var seen: [String] = []
                for _ in 0..<3 {
                    switch try await messages.next() {
                    case .message(let message): seen.append(message.text)
                    case .missed: seen.append("missed")
                    }
                }
                try room.publish("after")
                if case .message(let message) = try await messages.next() { seen.append(message.text) }
                try await events.send(seen.joined(separator: ","))
            }
        }
        var config = ServerConfig()
        config.maxConnections = 16
        config.broadcastQueue = 2
        let response = try app.testClient(configuration: config).get("/listen")
        #expect(response.text == "data: m1,m2,missed,after\n\n")
    }

    @Test func aWaitWithATimeoutEndsEmpty() throws {
        let room = topic("timeout")
        let app = Application()
        app.onAsync(.get, "/poll") { _, response in
            let messages = try response.subscribe(room)
            let event = try await messages.next(timeoutMilliseconds: 20)
            response.send(event == nil ? "nothing" : "something")
        }
        #expect(try app.test.get("/poll").text == "nothing")
    }

    @Test func aMessagePublishedOffTheWorkerIsHeard() throws {
        let room = topic("blocking")
        let app = Application()
        app.onAsync(.get, "/poll") { _, response in
            let messages = try response.subscribe(room)
            try await blocking { try room.publish("from a pool thread") }
            if case .message(let message) = try await messages.next() {
                response.send(message.text)
            }
        }
        #expect(try app.test.get("/poll").text == "from a pool thread")
    }

    @Test func aCancelledSubscriptionHearsNothingMore() throws {
        let room = topic("cancel")
        let app = Application()
        app.onAsync(.get, "/poll") { _, response in
            let messages = try response.subscribe(room)
            messages.cancel()
            try room.publish("unheard")
            do {
                _ = try await messages.next()
                response.send("heard")
            } catch is CancellationError {
                response.send("cancelled")
            }
        }
        #expect(try app.test.get("/poll").text == "cancelled")
    }

    @Test func aWebSocketSubscribes() throws {
        let room = topic("ws")
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

    @Test func aQuietEventStreamIsSentKeepAliveComments() throws {
        let app = Application()
        app.get("/quiet") { () async in
            EventStream(keepAlive: 1) { events in
                try await events.sleep(milliseconds: 2300)
                try await events.send("done")
            }
        }
        let text = try app.test.get("/quiet").text
        #expect(text.hasPrefix(":\n\n"))
        #expect(text.hasSuffix("data: done\n\n"))
    }

    @Test func keepAliveCanBeTurnedOff() throws {
        let app = Application()
        app.get("/quiet") { () async in
            EventStream(keepAlive: 0) { events in
                try await events.sleep(milliseconds: 1300)
                try await events.send("done")
            }
        }
        #expect(try app.test.get("/quiet").text == "data: done\n\n")
    }

    @Test func broadcastIDsAreDecimalDigitsOnly() {
        #expect(BroadcastID("1700000000000001")?.rawValue == 1_700_000_000_000_001)
        #expect(BroadcastID("") == nil)
        #expect(BroadcastID("+5") == nil)
        #expect(BroadcastID(" 5") == nil)
        #expect(BroadcastID("18446744073709551616") == nil)
        #expect(LastEventID("12").broadcastID == BroadcastID(12))
        #expect(LastEventID("abc").broadcastID == nil)
        #expect(LastEventID(nil).broadcastID == nil)
    }

    @Test func aMessageTooLargeIsRefused() throws {
        let room = topic("large")
        #expect(throws: BroadcastError.tooLarge) {
            _ = TestClient.broadcastRing
            try room.publish([UInt8](repeating: 0, count: Int(av_bus_max_message()) + 1))
        }
    }
}
