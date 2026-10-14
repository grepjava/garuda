import Testing
import GarudaTesting
@testable import Garuda

@Suite("Server-sent events")
struct EventStreamTests {

    @Test func eventsAreFramedAsTheFormatSays() {
        #expect(EventSink.encode("hello", event: nil, id: nil, retry: nil) == "data: hello\n\n")
        #expect(EventSink.encode("a\nb\r\nc\rd", event: "update", id: "7", retry: 3000)
                == "event: update\nid: 7\nretry: 3000\ndata: a\ndata: b\ndata: c\ndata: d\n\n")
        #expect(EventSink.encode("", event: nil, id: nil, retry: nil) == "data: \n\n")
        // A line break cannot smuggle a field of its own into a name or an ID.
        #expect(EventSink.encode("x", event: "a\ndata: forged", id: "1\r\n2\0", retry: -1)
                == "event: a data: forged\nid: 1 2\ndata: x\n\n")
    }

    @Test func anEventStreamIsSentAsItIsProduced() throws {
        let app = Application()
        app.get("/events") { () async -> EventStream in
            EventStream { events in
                try await events.comment("hi")
                for i in 1...2 {
                    try await events.send("tick \(i)", event: "tick", id: "\(i)")
                    try await events.sleep(milliseconds: 5)
                }
            }
        }
        let response = try app.test.get("/events")
        #expect(response.header("content-type") == "text/event-stream")
        #expect(response.header("cache-control") == "no-cache")
        #expect(response.text == ": hi\n\nevent: tick\nid: 1\ndata: tick 1\n\nevent: tick\nid: 2\ndata: tick 2\n\n")
    }

    @Test func aHandlersOwnCacheControlIsKept() throws {
        let app = Application()
        app.get("/events") { _, response in
            response.addHeader("cache-control", "no-store")
            try await response.eventStream().send("x")
        }
        let response = try app.test.get("/events")
        #expect(response.headers(named: "cache-control") == ["no-store"])
        #expect(response.text == "data: x\n\n")
    }

    @Test func aQuietStreamIsSentKeepAliveComments() throws {
        let app = Application()
        app.get("/quiet") { () async -> EventStream in
            EventStream(keepAlive: .milliseconds(20)) { events in
                try await events.send("first")
                try await events.sleep(for: .milliseconds(150))
                try await events.send("last")
            }
        }
        let text = try app.test.get("/quiet").text
        // Comments come whenever the stream is quiet, never inside an event.
        #expect(text.contains(":\n\n"))
        #expect(text.removingAll(":\n\n") == "data: first\n\ndata: last\n\n")
    }

    @Test func noKeepAliveWhenAskedForNone() throws {
        let app = Application()
        app.get("/quiet") { () async -> EventStream in
            EventStream(keepAlive: .zero) { events in
                try await events.send("first")
                try await events.sleep(for: .milliseconds(60))
                try await events.send("last")
            }
        }
        #expect(try app.test.get("/quiet").text == "data: first\n\ndata: last\n\n")
    }

    @Test func overHTTP2TheEventsAndTheKeepAliveArrive() throws {
        let app = Application()
        app.get("/quiet") { () async -> EventStream in
            EventStream(keepAlive: .milliseconds(20)) { events in
                try await events.send("first")
                try await events.sleep(for: .milliseconds(150))
                try await events.send("last")
            }
        }
        let response = try app.test.http2().get("/quiet")
        #expect(response.ended)
        #expect(response.header("content-type") == "text/event-stream")
        #expect(response.text.contains(":\n\n"))
        #expect(response.text.removingAll(":\n\n") == "data: first\n\ndata: last\n\n")
    }
}

extension String {
    /// The string with every `piece` taken out.
    fileprivate func removingAll(_ piece: String) -> String {
        replacing(piece, with: "")
    }
}
