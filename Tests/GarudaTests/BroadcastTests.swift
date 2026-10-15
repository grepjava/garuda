import Testing
import CGarudaShared
import GarudaTesting
import Synchronization
import Vega
@testable import Garuda

// Topics and subscriptions within one process: delivery, reading back after
// a Last-Event-ID, a subscriber that falls behind, publishing from a thread
// that is not the runtime's, and a writer that died holding the ring. Every
// shard hearing every other is scripts/broadcast-test.py's, against a server
// with several.

/// A topic of its own for each test: the ring is one for the whole process.
private func topic(_ name: String) -> Topic {
    Topic("test/\(name)/\(monotonicNanos())")
}

/// A ring of its own, for a test that needs settings the process's lacks.
private func ownBus(queue: Int) -> TopicBus {
    let size = gb_bus_region_size(1 << 16, 4)
    let memory = UnsafeMutableRawBufferPointer.allocate(byteCount: size, alignment: 64)
    memory.initializeMemory(as: UInt8.self, repeating: 0)
    return TopicBus(region: memory, ringBytes: 1 << 16, slots: 4, queueLimit: queue)!
}

@Suite("Broadcast")
struct BroadcastTests {
    @Test func aSubscriberHearsWhatIsPublishedAfterItSubscribed() throws {
        let room = topic("hear")
        let app = Application()
        app.get("/listen") { () async -> EventStream in
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
        app.post("/publish") { () throws -> String in
            var ids: [String] = []
            for i in 1...4 { ids.append(try room.publish("m\(i)").description) }
            return ids.joined(separator: " ")
        }
        app.get("/listen") { (last: LastEventID) async -> EventStream in
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
        let ids = try client.post("/publish", body: "").text.split(separator: " ").map(String.init)
        #expect(ids.count == 4)
        let resumed = try client.get("/listen", headers: [("last-event-id", ids[1])])
        #expect(resumed.text == "data: m3\n\ndata: m4\n\ndata: live\n\n")
        let fresh = try client.get("/listen")
        #expect(fresh.text == "data: live\n\n")
    }

    @Test func anIDOlderThanTheRingIsAGap() throws {
        let room = topic("old")
        let app = Application()
        app.get("/listen") { () async -> EventStream in
            EventStream { events in
                // A number from before this ring was laid out: long gone.
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

    @Test func aSubscriberThatFallsBehindIsToldItMissedSome() async throws {
        let bus = ownBus(queue: 2)
        let room = Topic("behind")
        let messages = try bus.subscribe([room], after: nil) { true }
        var seen: [String] = []
        for i in 1...5 { _ = try bus.publish(room.name, event: nil, Array("m\(i)".utf8)) }
        // Delivered by the listener thread: all five, before any is taken.
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<3 {
            switch try await messages.next() {
            case .message(let message): seen.append(message.text)
            case .missed: seen.append("missed")
            }
        }
        _ = try bus.publish(room.name, event: nil, Array("after".utf8))
        if case .message(let message) = try await messages.next() { seen.append(message.text) }
        #expect(seen == ["m1", "m2", "missed", "after"])
    }

    @Test func aWaitWithATimeoutEndsEmpty() throws {
        let room = topic("timeout")
        let app = Application()
        app.get("/poll") { _, response in
            let messages = try response.subscribe(room)
            let started = monotonicNanos()
            let event = try await messages.next(timeoutMilliseconds: 40)
            let waited = (monotonicNanos() - started) / 1_000_000
            response.send(event == nil && waited >= 40 && waited < 1000 ? "nothing" : "something \(waited)")
        }
        #expect(try app.test.get("/poll").text == "nothing")
    }

    @Test func aMessagePublishedOffTheRuntimeIsHeard() throws {
        let room = topic("blocking")
        let app = Application()
        app.get("/poll") { _, response in
            let messages = try response.subscribe(room)
            try await Runtime.blocking { try room.publish("from a pool thread") }
            if case .message(let message) = try await messages.next() {
                response.send(message.text)
            }
        }
        #expect(try app.test.get("/poll").text == "from a pool thread")
    }

    @Test func aCancelledSubscriptionHearsNothingMore() throws {
        let room = topic("cancel")
        let app = Application()
        app.get("/poll") { _, response in
            let messages = try response.subscribe(room)
            messages.cancel()
            try room.publish("unheard")
            do {
                _ = try await messages.next()
                response.send("heard")
            } catch {
                response.send("cancelled")
            }
        }
        #expect(try app.test.get("/poll").text == "cancelled")
    }

    @Test func aSubscriptionLetGoOfIsForgotten() async throws {
        let bus = ownBus(queue: 8)
        do {
            let messages = try bus.subscribe([Topic("gone")], after: nil) { true }
            #expect(!messages.isCancelled)
        }
        // Nothing holds it now: a publish finds nobody to queue for.
        _ = try bus.publish("gone", event: nil, Array("x".utf8))
        let again = try bus.subscribe([Topic("gone")], after: nil) { true }
        #expect(try await again.next(timeoutMilliseconds: 20) == nil)
    }

    @Test func aStreamThatEndsEndsItsWait() async throws {
        let bus = ownBus(queue: 8)
        let open = Mutex(true)
        let messages = try bus.subscribe([Topic("ends")], after: nil) { open.withLock { $0 } }
        let waiting = Task { () -> Bool in
            do {
                _ = try await messages.next()
                return false
            } catch {
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        open.withLock { $0 = false }
        // The listener looks at least every quarter of a second.
        #expect(await waiting.value)
    }

    @Test func aWriterThatDiedHoldingTheRingIsTakenOver() async throws {
        let bus = ownBus(queue: 8)
        let messages = try bus.subscribe([Topic("dead")], after: nil) { true }
        // A process ID nothing has: past Linux's and Darwin's limits.
        gb_bus_test_abandon(bus.handle, 0x3FFF_FFF0)
        let id = try bus.publish("dead", event: nil, Array("after".utf8))
        guard case .message(let message) = try await messages.next() else {
            Issue.record("expected a message")
            return
        }
        #expect(message.id == id)
        #expect(message.text == "after")
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
        let max = try TopicBus.current().maxMessage
        #expect(throws: BroadcastError.tooLarge) {
            try room.publish([UInt8](repeating: 0, count: max + 1))
        }
    }
}
