import Testing
import CAvian
import AvianCore
@testable import Garuda

// `Response.stream` and `StreamingBody`: a body written as it is produced.

nonisolated(unsafe) private var streamEvents: [String] = []
nonisolated(unsafe) private var largestBacklog = 0

private func closedEarly(_ error: TestClientError?) -> Bool {
    if case .closed = error { return true }
    return false
}

private func pattern(_ count: Int, from start: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 + start) &* 31 &+ 7) }
}

@Suite("Streaming responses", .serialized)
struct StreamingResponseTests {

    @Test func writesArriveInOrderAsAChunkedBody() throws {
        let app = Application()
        app.onAsync(.get, "/lines") { _, response in
            let body = response.stream(contentType: "text/plain")
            for i in 1...3 { try await body.write("line \(i)\n") }
        }
        let response = try app.test.get("/lines")
        #expect(response.status == 200)
        #expect(response.text == "line 1\nline 2\nline 3\n")
        #expect(response.header("transfer-encoding") == "chunked")
        #expect(response.header("content-length") == nil)
        #expect(response.header("content-type") == "text/plain")
    }

    @Test func aTypedHandlerReturnsAStreamingBody() throws {
        let app = Application()
        app.get("/typed") { () async -> StreamingBody in
            StreamingBody(status: .accepted, contentType: "text/plain") { body in
                try await body.write("a")
                try await body.write([0x62])
            }
        }
        let response = try app.test.get("/typed")
        #expect(response.status == 202)
        #expect(response.text == "ab")
        #expect(response.header("content-type") == "text/plain")
    }

    @Test func aSynchronousHandlerCannotReturnOne() throws {
        let app = Application()
        app.get("/sync") { () -> StreamingBody in
            StreamingBody { body in try await body.write("never") }
        }
        #expect(try app.test.get("/sync").status == 500)
    }

    @Test func aDeclaredLengthIsSentUnframed() throws {
        let app = Application()
        app.onAsync(.get, "/fixed") { _, response in
            response.addHeader("content-length", "5")
            let body = response.stream()
            try await body.write("hel")
            try await body.write("lo")
        }
        let response = try app.test.get("/fixed")
        #expect(response.text == "hello")
        #expect(response.header("content-length") == "5")
        #expect(response.header("transfer-encoding") == nil)
    }

    @Test func writesPastTheDeclaredLengthAreCutAndThrow() throws {
        streamEvents = []
        let app = Application()
        app.onAsync(.get, "/over") { _, response in
            response.addHeader("content-length", "3")
            let body = response.stream()
            do {
                try await body.write("abcdef")
                streamEvents.append("accepted")
            } catch {
                streamEvents.append("refused")
            }
        }
        let response = try app.test.get("/over")
        #expect(response.text == "abc")
        #expect(streamEvents == ["refused"])
    }

    @Test func aBodyShortOfItsLengthClosesTheConnection() throws {
        let app = Application()
        app.onAsync(.get, "/short") { _, response in
            response.addHeader("content-length", "10")
            try await response.stream().write("abc")
        }
        // Closed, not left open for a client to wait on for the rest.
        let error = #expect(throws: TestClientError.self) { try app.test.get("/short") }
        #expect(closedEarly(error))
    }

    @Test func throwingPartWayCutsTheBodyOff() throws {
        struct Broke: Error {}
        let app = Application()
        app.onAsync(.get, "/broke") { _, response in
            try await response.stream().write("partial")
            throw Broke()
        }
        // Chunked, and the last chunk never comes: the client sees a close in
        // the middle of the body rather than a complete response.
        #expect(throws: TestClientError.self) { try app.test.get("/broke") }
        #expect(try app.test.get("/nothing").status == 404)
    }

    @Test func finishEndsTheBodyBeforeTheHandlerReturns() throws {
        streamEvents = []
        let app = Application()
        app.onAsync(.get, "/early") { _, response in
            let body = response.stream()
            try await body.write("done")
            body.finish()
            streamEvents.append(body.isOpen ? "open" : "closed")
            do {
                try await body.write("late")
            } catch {
                streamEvents.append("late write refused")
            }
        }
        let response = try app.test.get("/early")
        #expect(response.text == "done")
        #expect(streamEvents == ["closed", "late write refused"])
    }

    @Test func headSendsTheHeadAndDropsTheWrites() throws {
        streamEvents = []
        let app = Application()
        app.onAsync(.get, "/both") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("not for HEAD")
            streamEvents.append("returned")
        }
        let response = try app.test.head("/both")
        #expect(response.status == 200)
        #expect(response.body.isEmpty)
        #expect(response.header("content-type") == "text/plain")
        // No chunks will follow a HEAD, so it is not framed as if they would.
        #expect(response.header("transfer-encoding") == nil)
        #expect(streamEvents == ["returned"])
    }

    @Test func anHTTP10BodyEndsWithTheConnection() throws {
        let app = Application()
        app.onAsync(.get, "/old") { _, response in
            let body = response.stream()
            try await body.write("one ")
            try await body.write("two")
        }
        let response = try app.test.send(raw: Array("GET /old HTTP/1.0\r\nHost: x\r\n\r\n".utf8))
        #expect(response.text == "one two")
        #expect(response.header("transfer-encoding") == nil)
        #expect(response.header("connection")?.lowercased() == "close")

        // Asking to keep the connection does not help: the close is the
        // only end an HTTP/1.0 body of no length has.
        let kept = try app.test.send(raw: Array("GET /old HTTP/1.0\r\nHost: x\r\nConnection: keep-alive\r\n\r\n".utf8))
        #expect(kept.text == "one two")
        #expect(kept.header("connection")?.lowercased() == "close")
    }

    @Test func middlewareHeadersAndHooksReachAStreamedHead() throws {
        let app = Application()
        app.use { _, response in
            response.addHeader("x-middleware", "yes")
            response.onSend { outgoing in
                outgoing.addHeader("x-streaming", outgoing.isStreaming ? "true" : "false")
            }
            return nil
        }
        app.onAsync(.get, "/hooked") { _, response in
            try await response.stream().write("body")
        }
        let response = try app.test.get("/hooked")
        #expect(response.text == "body")
        #expect(response.header("x-middleware") == "yes")
        #expect(response.header("x-streaming") == "true")
    }

    @Test func aHookThatReplacesTheBodyAnswersInstead() throws {
        let app = Application()
        app.use { _, response in
            response.onSend { $0.replaceBody("from the hook") }
            return nil
        }
        app.onAsync(.get, "/replaced") { _, response in
            try await response.stream().write("from the handler")
        }
        let response = try app.test.get("/replaced")
        #expect(response.text == "from the hook")
        #expect(response.header("transfer-encoding") == nil)
    }

    @Test func aWriterWaitsWhileTheClientIsBehind() throws {
        largestBacklog = 0
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 16 * 1024
        let total = 2 * 1024 * 1024
        app.onAsync(.get, "/large") { _, response in
            let body = response.stream()
            var sent = 0
            while sent < total {
                try await body.write(pattern(piece, from: sent))
                sent += piece
                largestBacklog = max(largestBacklog, body.worker.pointee.streamBacklog(body.slot))
            }
        }
        let client = app.testClient(configuration: config)
        client.timeoutMillis = 30_000
        let response = try client.get("/large")
        #expect(response.body.count == total)
        #expect(response.body == pattern(total, from: 0))
        // Never more than the mark, and the piece that crossed it, ahead of
        // the client.
        #expect(largestBacklog <= 64 * 1024 + piece + 64)
    }

    @Test func writersInChildTasksAllFinish() throws {
        streamEvents = []
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 2 * 1024 * 1024
        app.onAsync(.get, "/two") { _, response in
            let body = response.stream()
            // Both cross the mark: one waits for the drain, the other finds it
            // waiting and returns. Neither may be left waiting forever.
            async let first: Void = body.write(pattern(piece, from: 0))
            async let second: Void = body.write(pattern(piece, from: piece))
            try await first
            try await second
            streamEvents.append("both written")
        }
        let client = app.testClient(configuration: config)
        client.timeoutMillis = 10_000
        let response = try client.get("/two")
        #expect(response.body.count == 2 * piece)
        #expect(streamEvents == ["both written"])
    }

    @Test func aWriterWaitingForAClientThatLeavesIsCancelled() throws {
        streamEvents = []
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        app.onAsync(.get, "/forever") { _, response in
            let body = response.stream()
            do {
                while true { try await body.write(pattern(32 * 1024, from: 0)) }
            } catch let error as HandlerWaitError {
                streamEvents.append("\(error)")
            }
        }
        let client = app.testClient(configuration: config)
        try client.abandon(Array("GET /forever HTTP/1.1\r\nHost: x\r\n\r\n".utf8), turns: 20)
        for _ in 0..<20 { client.turn() }
        #expect(streamEvents == ["cancelled"])
    }
}

@Suite("Server-sent events", .serialized)
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
        app.onAsync(.get, "/events") { _, response in
            response.addHeader("cache-control", "no-store")
            try await response.eventStream().send("x")
        }
        let response = try app.test.get("/events")
        #expect(response.headers(named: "cache-control") == ["no-store"])
        #expect(response.text == "data: x\n\n")
    }
}
