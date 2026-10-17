import Testing
import Synchronization
import GarudaTesting
import GarudaWire
@testable import Garuda

// `Response.stream` and `StreamingBody`: a body written as it is produced.

private final class Events: Sendable {
    private let list = Mutex<[String]>([])
    private let largest = Mutex(0)

    func append(_ event: String) { list.withLock { $0.append(event) } }
    var all: [String] { list.withLock { $0 } }

    func noteBacklog(_ n: Int) { largest.withLock { $0 = max($0, n) } }
    var largestBacklog: Int { largest.withLock { $0 } }
}

private func pattern(_ count: Int, from start: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 + start) &* 31 &+ 7) }
}

private func closedEarly(_ error: TestClientError?) -> Bool {
    if case .closed = error { return true }
    return false
}

@Suite("Streaming responses")
struct StreamingResponseTests {

    @Test func writesArriveInOrderAsAChunkedBody() throws {
        let app = Application()
        app.get("/lines") { _, response in
            let body = response.stream(contentType: "text/plain")
            for i in 1...3 { try await body.write("line \(i)\n") }
        }
        let response = try app.test.get("/lines")
        #expect(response.status == .ok)
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
        #expect(response.status == .accepted)
        #expect(response.text == "ab")
        #expect(response.header("content-type") == "text/plain")
    }

    @Test func aStreamingBodyStartsAfterTheMiddlewareOnItsWayOut() throws {
        let app = Application()
        app.use { _, response, next in
            try await next()
            response.addHeader("x-after", "yes")
        }
        app.get("/typed") { () -> StreamingBody in
            StreamingBody { body in try await body.write("body") }
        }
        let response = try app.test.get("/typed")
        #expect(response.text == "body")
        #expect(response.header("x-after") == "yes")
    }

    @Test func aLayerThatThrowsAfterAStreamingBodyAnswersTheError() throws {
        let app = Application()
        app.use { _, _, next in
            try await next()
            throw HTTPError.forbidden
        }
        app.get("/typed") { () -> StreamingBody in
            StreamingBody { body in try await body.write("never") }
        }
        #expect(try app.test.get("/typed").status == .forbidden)
    }

    @Test func aDeclaredLengthIsSentUnframed() throws {
        let app = Application()
        app.get("/fixed") { _, response in
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
        let events = Events()
        let app = Application()
        app.get("/over") { _, response in
            response.addHeader("content-length", "3")
            let body = response.stream()
            do {
                try await body.write("abcdef")
                events.append("accepted")
            } catch {
                events.append("refused")
            }
        }
        let response = try app.test.get("/over")
        #expect(response.text == "abc")
        #expect(events.all == ["refused"])
    }

    @Test func aBodyShortOfItsLengthClosesTheConnection() throws {
        let app = Application()
        app.get("/short") { _, response in
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
        app.get("/broke") { _, response in
            try await response.stream().write("partial")
            throw Broke()
        }
        // Chunked, and the last chunk never comes: the client sees a close in
        // the middle of the body rather than a complete response.
        #expect(throws: TestClientError.self) { try app.test.get("/broke") }
    }

    @Test func finishEndsTheBodyBeforeTheHandlerReturns() throws {
        let events = Events()
        let app = Application()
        app.get("/early") { _, response in
            let body = response.stream()
            try await body.write("done")
            body.finish()
            events.append(body.isOpen ? "open" : "closed")
            do {
                try await body.write("late")
            } catch {
                events.append("late write refused")
            }
        }
        let response = try app.test.get("/early")
        #expect(response.text == "done")
        #expect(events.all == ["closed", "late write refused"])
    }

    @Test func headSendsTheHeadAndDropsTheWrites() throws {
        let events = Events()
        let app = Application()
        app.get("/both") { _, response in
            let body = response.stream(contentType: "text/plain")
            try await body.write("not for HEAD")
            events.append("returned")
        }
        let response = try app.test.head("/both")
        #expect(response.status == .ok)
        #expect(response.body.isEmpty)
        #expect(response.header("content-type") == "text/plain")
        // No chunks will follow a HEAD, so it is not framed as if they would.
        #expect(response.header("transfer-encoding") == nil)
        #expect(events.all == ["returned"])
    }

    @Test func anHTTP10BodyEndsWithTheConnection() throws {
        let app = Application()
        app.get("/old") { _, response in
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

    @Test func pipelinedAnswersGoBeforeAndAfterAStreamedOne() throws {
        let app = Application()
        app.get("/plain") { _, response in response.send("plain") }
        app.get("/streamed") { _, response in
            let body = response.stream()
            try await body.write("str")
            try await body.write("eamed")
        }
        let request = "GET /plain HTTP/1.1\r\nHost: x\r\n\r\n"
            + "GET /streamed HTTP/1.1\r\nHost: x\r\n\r\n"
            + "GET /plain HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
        let responses = try app.test.sendPipelined(raw: Array(request.utf8))
        #expect(responses.map(\.text) == ["plain", "streamed", "plain"])
    }

    @Test func middlewareHeadersAndHooksReachAStreamedHead() throws {
        let app = Application()
        app.use { _, response, next in
            response.addHeader("x-middleware", "yes")
            response.onSend { outgoing in
                outgoing.addHeader("x-streaming", outgoing.isStreaming ? "true" : "false")
            }
            try await next()
        }
        app.get("/hooked") { _, response in
            try await response.stream().write("body")
        }
        let response = try app.test.get("/hooked")
        #expect(response.text == "body")
        #expect(response.header("x-middleware") == "yes")
        #expect(response.header("x-streaming") == "true")
    }

    @Test func aHookThatReplacesTheBodyAnswersInstead() throws {
        let app = Application()
        app.use { _, response, next in
            response.onSend { $0.replaceBody("from the hook") }
            try await next()
        }
        app.get("/replaced") { _, response in
            try await response.stream().write("from the handler")
        }
        let response = try app.test.get("/replaced")
        #expect(response.text == "from the hook")
        #expect(response.header("transfer-encoding") == nil)
    }

    @Test func aWriterWaitsWhileTheClientIsBehind() throws {
        let events = Events()
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 16 * 1024
        let total = 2 * 1024 * 1024
        app.get("/large") { _, response in
            let body = response.stream()
            var sent = 0
            while sent < total {
                try await body.write(pattern(piece, from: sent))
                sent += piece
                events.noteBacklog(body.queuedBytes)
            }
        }
        let client = app.testClient(configuration: config)
        client.timeout = .seconds(30)
        let response = try client.get("/large")
        #expect(response.body.count == total)
        #expect(response.body == pattern(total, from: 0))
        // Never more than the mark, and the piece that crossed it, ahead of
        // the client.
        #expect(events.largestBacklog <= 64 * 1024 + piece + 64)
    }

    @Test func writersInChildTasksAllFinish() throws {
        let events = Events()
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 2 * 1024 * 1024
        app.get("/two") { _, response in
            let body = response.stream()
            // Both cross the mark, so both wait for the drain. Neither may be
            // left waiting forever.
            async let first: Void = body.write(pattern(piece, from: 0))
            async let second: Void = body.write(pattern(piece, from: piece))
            try await first
            try await second
            events.append("both written")
        }
        let client = app.testClient(configuration: config)
        client.timeout = .seconds(10)
        let response = try client.get("/two")
        #expect(response.body.count == 2 * piece)
        #expect(events.all == ["both written"])
    }

    @Test func everyConcurrentWriterIsHeldToTheMark() throws {
        let events = Events()
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 16 * 1024
        let each = 512 * 1024
        app.get("/both") { _, response in
            let body = response.stream()
            @Sendable func produce(_ from: Int) async throws {
                var sent = 0
                while sent < each {
                    try await body.write(pattern(piece, from: from))
                    sent += piece
                    events.noteBacklog(body.queuedBytes)
                }
            }
            async let first: Void = produce(0)
            async let second: Void = produce(1)
            try await first
            try await second
        }
        let client = app.testClient(configuration: config)
        client.timeout = .seconds(30)
        let response = try client.get("/both")
        #expect(response.body.count == 2 * each)
        #expect(events.largestBacklog <= 64 * 1024 + 2 * (piece + 32), "\(events.largestBacklog)")
    }

    @Test func streamCalledTwiceIsTheSameBody() throws {
        let app = Application()
        app.get("/twice") { _, response in
            try await response.stream().write("a")
            try await response.stream().write("b")
            let streaming = response.isStreaming
            #expect(streaming)
        }
        #expect(try app.test.get("/twice").text == "ab")
    }

    @Test func aStreamAfterAnAnswerRefusesItsWrites() throws {
        let events = Events()
        let app = Application()
        app.get("/answered") { _, response in
            response.send("answer")
            do {
                try await response.stream().write("late")
            } catch {
                events.append("refused")
            }
        }
        #expect(try app.test.get("/answered").text == "answer")
        #expect(events.all == ["refused"])
    }

    // MARK: HTTP/2

    @Test func overHTTP2TheBodyIsDATAFrames() throws {
        let app = Application()
        app.get("/lines") { _, response in
            let body = response.stream(contentType: "text/plain")
            for i in 1...3 { try await body.write("line \(i)\n") }
        }
        let h2 = try app.test.http2()
        let response = try h2.get("/lines")
        #expect(response.status == .ok)
        #expect(response.ended)
        #expect(response.text == "line 1\nline 2\nline 3\n")
        #expect(response.header("content-length") == nil)
        #expect(response.header("content-type") == "text/plain")
    }

    @Test func overHTTP2ADeclaredLengthIsSaid() throws {
        let app = Application()
        app.get("/fixed") { _, response in
            response.addHeader("content-length", "5")
            let body = response.stream()
            try await body.write("hel")
            try await body.write("lo")
        }
        let response = try app.test.http2().get("/fixed")
        #expect(response.text == "hello")
        #expect(response.header("content-length") == "5")
        #expect(response.ended)
    }

    @Test func overHTTP2ABodyEndedWithNoBytesStillEnds() throws {
        let app = Application()
        app.get("/empty") { _, response in
            _ = response.stream()
        }
        let response = try app.test.http2().get("/empty")
        #expect(response.status == .ok)
        #expect(response.ended)
        #expect(response.body.isEmpty)
    }

    @Test func overHTTP2ThrowingPartWayResetsTheStream() throws {
        struct Broke: Error {}
        let app = Application()
        app.get("/broke") { _, response in
            try await response.stream().write("partial")
            throw Broke()
        }
        let response = try app.test.http2().get("/broke")
        #expect(response.reset == H2Error.internalError.rawValue)
        #expect(!response.ended)
    }

    @Test func overHTTP2ATypedStreamingBody() throws {
        let app = Application()
        app.get("/typed") { () async -> StreamingBody in
            StreamingBody(status: .accepted) { body in
                for i in 0..<4 { try await body.write("\(i)") }
            }
        }
        let response = try app.test.http2().get("/typed")
        #expect(response.status == .accepted)
        #expect(response.text == "0123")
        #expect(response.ended)
    }

    @Test func overHTTP2ALargeBodyWaitsForTheWindow() throws {
        let events = Events()
        var config = ServerConfig()
        config.writeHighWaterMark = 64 * 1024
        config.writeLowWaterMark = 16 * 1024
        let app = Application()
        let piece = 16 * 1024
        let total = 1024 * 1024
        app.get("/large") { _, response in
            let body = response.stream()
            var sent = 0
            while sent < total {
                try await body.write(pattern(piece, from: sent))
                sent += piece
                events.noteBacklog(body.queuedBytes)
            }
        }
        let client = app.testClient(configuration: config)
        client.timeout = .seconds(30)
        let response = try client.http2().get("/large")
        #expect(response.ended)
        #expect(response.body.count == total)
        #expect(response.body == pattern(total, from: 0))
        #expect(events.largestBacklog <= 64 * 1024 + piece)
    }

    @Test func overHTTP2EveryRunOfAStreamingRouteWorks() throws {
        // The first runs of a route go to a task; later ones of a route that
        // never waited run on the reader, which a streamed body must not.
        let app = Application()
        app.get("/s") { _, response in
            try await response.stream().write("x")
        }
        let h2 = try app.test.http2()
        for _ in 0..<40 {
            let response = try h2.get("/s")
            #expect(response.text == "x")
            #expect(response.ended)
        }
    }
}
