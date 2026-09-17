import Testing
import CAvian
import AvianCore
@testable import Garuda

// `onStreamingBody`: a request body read as it arrives. And `sendInterim`.

nonisolated(unsafe) private var bodyEvents: [String] = []
nonisolated(unsafe) private var bodyReceived: [UInt8] = []
nonisolated(unsafe) private var largestBuffered = 0
nonisolated(unsafe) private var bodyGate: UnsafeContinuation<Void, Never>? = nil

private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 17) }
}

@Suite("Streaming request bodies", .serialized)
struct RequestBodyTests {

    @Test func aContentLengthBodyIsReadInPieces() throws {
        bodyEvents = []
        let app = Application()
        app.onStreamingBody(.post, "/up") { _, response, body in
            var total: [UInt8] = []
            while let bytes = try await body.read(maxBytes: 7) {
                #expect(bytes.count <= 7)
                total += bytes
            }
            bodyEvents.append("read \(body.bytesRead) of \(body.expectedLength ?? -1)")
            response.send(total)
        }
        let response = try app.test.post("/up", body: "a body read in small pieces")
        #expect(response.text == "a body read in small pieces")
        #expect(bodyEvents == ["read 27 of 27"])
    }

    @Test func aChunkedBodyIsReadWithoutItsFraming() throws {
        let app = Application()
        app.onStreamingBody(.post, "/up") { _, response, body in
            response.send(try await body.readAll(maxBytes: 1 << 20))
        }
        let raw = "POST /up HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        #expect(try app.test.send(raw: Array(raw.utf8)).text == "hello world")
    }

    @Test func aRouteWithoutABodyReadsNothing() throws {
        let app = Application()
        app.onStreamingBody(.get, "/empty") { _, response, body in
            let first = try await body.read()
            response.send(first == nil ? "nil" : "bytes")
        }
        #expect(try app.test.get("/empty").text == "nil")
    }

    @Test func otherRoutesStillGetTheirBodyWhole() throws {
        let app = Application()
        app.onStreamingBody(.post, "/stream") { _, response, _ in response.send("s") }
        app.post("/whole") { request, response in request.withBody { response.send($0) } }
        #expect(try app.test.post("/whole", body: "all of it").text == "all of it")
    }

    @Test func aLargeBodyIsHeldToTheHighWaterMarkWhileTheHandlerIsSlow() throws {
        largestBuffered = 0
        bodyReceived = []
        var config = ServerConfig()
        config.bodyHighWaterMark = 64 * 1024
        config.maxBodySize = 1024          // not what a streaming route is held to
        let app = Application()
        let total = 2 * 1024 * 1024
        app.onStreamingBody(.put, "/big") { request, response, body in
            while let bytes = try await body.read(maxBytes: 16 * 1024) {
                bodyReceived += bytes
                let c = body.worker.pointee.table[body.slot]
                largestBuffered = max(largestBuffered, c.pointee.body.readableBytes)
                if bodyReceived.count % (256 * 1024) == 0 { try await response.sleep(milliseconds: 1) }
            }
            response.send(status: .created)
        }
        let client = app.testClient(configuration: config)
        client.timeoutMillis = 30_000
        let response = try client.put("/big", body: pattern(total))
        #expect(response.status == 201)
        #expect(bodyReceived == pattern(total))
        #expect(largestBuffered <= 64 * 1024 + 64 * 1024)
    }

    @Test func aBodyPastTheRoutesLimitIs413() throws {
        let app = Application()
        app.onStreamingBody(.post, "/small", maxBodySize: 10) { _, response, body in
            _ = try await body.readAll(maxBytes: 100)
            response.send("read")
        }
        #expect(try app.test.post("/small", body: "far more than ten bytes").status == 413)
        #expect(try app.test.post("/small", body: "ten bytes!").text == "read")
    }

    @Test func aChunkedBodyPastTheLimitStopsTheReader() throws {
        bodyEvents = []
        let app = Application()
        app.onStreamingBody(.post, "/small", maxBodySize: 8) { _, response, body in
            do {
                _ = try await body.readAll(maxBytes: 100)
                bodyEvents.append("whole")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let raw = "POST /small HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"
        #expect(try app.test.send(raw: Array(raw.utf8)).status == 413)
        #expect(bodyEvents == ["tooLarge"])
    }

    @Test func aClientThatLeavesPartWayHandsOverWhatItSent() throws {
        bodyEvents = []
        bodyReceived = []
        let app = Application()
        app.onStreamingBody(.post, "/partial") { _, response, body in
            do {
                while let bytes = try await body.read() { bodyReceived += bytes }
                bodyEvents.append("complete")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let client = app.test
        let head = "POST /partial HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n"
        try client.abandon(Array(head.utf8) + pattern(300), turns: 10)
        for _ in 0..<10 { client.turn() }
        #expect(bodyReceived == pattern(300))
        #expect(bodyEvents == ["incomplete"])
    }

    @Test func whatArrivedBeforeACloseIsReadAfterIt() throws {
        bodyEvents = []
        bodyReceived = []
        bodyGate = nil
        let app = Application()
        app.onStreamingBody(.post, "/late") { _, response, body in
            do {
                bodyReceived += try await body.read(maxBytes: 10) ?? []
                // Not reading while the connection closes: what it held is
                // handed over, and read from there.
                await withUnsafeContinuation { bodyGate = $0 }
                while let bytes = try await body.read() { bodyReceived += bytes }
                bodyEvents.append("complete")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let client = app.test
        let head = "POST /late HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n"
        try client.abandon(Array(head.utf8) + pattern(300), turns: 10)
        for _ in 0..<10 { client.turn() }
        #expect(bodyGate != nil)
        client.onWorker { bodyGate?.resume() }
        for _ in 0..<10 { client.turn() }
        #expect(bodyReceived == pattern(300))
        #expect(bodyEvents == ["incomplete"])
    }

    @Test func readAllStopsAtItsLimit() throws {
        bodyEvents = []
        let app = Application()
        app.onStreamingBody(.post, "/all") { _, response, body in
            do {
                _ = try await body.readAll(maxBytes: 4)
                bodyEvents.append("whole")
            } catch {
                bodyEvents.append("\(error)")
            }
            response.send(status: .ok)
        }
        _ = try app.test.post("/all", body: "ten bytes!")
        #expect(bodyEvents == ["tooLarge"])
    }

    @Test func aCancelledBodyEndsIncompleteEvenWhenAllOfItArrived() throws {
        bodyEvents = []
        bodyReceived = []
        let app = Application()
        app.onStreamingBody(.post, "/cancel") { _, response, body in
            body.cancel()
            do {
                while let bytes = try await body.read() { bodyReceived += bytes }
                bodyEvents.append("complete")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let client = app.test
        let head = "POST /cancel HTTP/1.1\r\nHost: x\r\nContent-Length: 20\r\n\r\n"
        try client.abandon(Array(head.utf8) + pattern(20), turns: 10)
        for _ in 0..<10 { client.turn() }
        #expect(bodyReceived == pattern(20))
        #expect(bodyEvents == ["incomplete"])
    }

    @Test func aClientThatStopsSendingEndsTheBodyIncomplete() throws {
        bodyEvents = []
        bodyReceived = []
        let app = Application()
        app.onStreamingBody(.post, "/half") { _, response, body in
            do {
                while let bytes = try await body.read() { bodyReceived += bytes }
                bodyEvents.append("complete")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let client = app.test
        let (socket, _, _) = try client.connect()
        let bytes = Array("POST /half HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n".utf8) + pattern(100)
        _ = bytes.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        // Half-closed: the client will send nothing more, but is still there.
        _ = shutdown(socket, Int32(SHUT_WR))
        for _ in 0..<20 { client.turn() }
        #expect(bodyReceived == pattern(100))
        #expect(bodyEvents == ["incomplete"])
        _ = close(socket)
    }

    @Test func twoReadsAtOnceAreRefused() throws {
        bodyEvents = []
        let app = Application()
        app.onStreamingBody(.post, "/twice") { _, response, body in
            @Sendable func attempt() async -> String? {
                do { _ = try await body.read(); return nil } catch { return "\(error)" }
            }
            async let first = attempt()
            async let second = attempt()
            bodyEvents += [await first, await second].compactMap { $0 }
            response.send(status: .ok)
        }
        let client = app.test
        let (socket, _, _) = try client.connect()
        let head = Array("POST /twice HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n".utf8)
        _ = head.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        for _ in 0..<10 { client.turn() }
        let rest = Array("body".utf8)
        _ = rest.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        for _ in 0..<10 { client.turn() }
        #expect(bodyEvents == ["concurrentRead"])
        _ = close(socket)
    }

    @Test func noInterimResponseOnceTheAnswerHasStarted() throws {
        bodyEvents = []
        let app = Application()
        app.onAsync(.get, "/started") { _, response in
            let body = response.stream(contentType: "text/plain")
            bodyEvents.append("\(response.sendInterim(status: HTTPStatus(103)))")
            try await body.write("done")
        }
        let answer = try app.test.get("/started")
        #expect(answer.text == "done")
        #expect(answer.interim.isEmpty)
        #expect(bodyEvents == ["false"])
    }

    @Test func aClientSilentMidBodyIsClosedAfterTheRequestTimeout() throws {
        bodyEvents = []
        var config = ServerConfig()
        config.requestHeadTimeoutMs = 200
        let app = Application()
        app.onStreamingBody(.post, "/stalled") { _, response, body in
            do {
                while try await body.read() != nil {}
                bodyEvents.append("complete")
            } catch {
                bodyEvents.append("\(error)")
            }
        }
        let client = app.testClient(configuration: config)
        let (socket, _, _) = try client.connect()
        let bytes = Array("POST /stalled HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\n".utf8) + pattern(10)
        _ = bytes.withUnsafeBufferPointer { write(socket, $0.baseAddress!, $0.count) }
        let deadline = av_monotonic_ms() + 3000
        while bodyEvents.isEmpty && av_monotonic_ms() < deadline { client.turn() }
        #expect(bodyEvents == ["incomplete"])
        _ = close(socket)
    }

    @Test func interimResponsesComeBeforeTheFinalOne() throws {
        bodyEvents = []
        let app = Application()
        app.onAsync(.post, "/hints") { _, response in
            let upload = response.sendInterim(status: HTTPStatus(104),
                                              headers: [("Location", "/uploads/1"), ("Upload-Limit", "max-size=10")])
            let hints = response.sendInterim(status: HTTPStatus(103), headers: [("Link", "</a.css>; rel=preload")])
            let final = response.sendInterim(status: HTTPStatus(200))
            let switching = response.sendInterim(status: HTTPStatus(101))
            let badName = response.sendInterim(status: HTTPStatus(104), headers: [("bad name", "x")])
            response.send(status: .created)
            let late = response.sendInterim(status: HTTPStatus(104))
            bodyEvents = [upload, hints, final, switching, badName, late].map { $0 ? "sent" : "refused" }
        }
        let response = try app.test.post("/hints")
        #expect(response.status == 201)
        #expect(bodyEvents == ["sent", "sent", "refused", "refused", "refused", "refused"])
        #expect(response.interim.map { $0.status.code } == [104, 103])
        #expect(response.interim.first?.headers.first { $0.name.lowercased() == "location" }?.value == "/uploads/1")
    }

    @Test func anHTTP10ClientGetsNoInterimResponse() throws {
        let app = Application()
        app.onAsync(.get, "/hints") { _, response in
            let sent = response.sendInterim(status: HTTPStatus(103))
            response.send(sent ? "sent" : "withheld")
        }
        let response = try app.test.send(raw: Array("GET /hints HTTP/1.0\r\nHost: x\r\n\r\n".utf8))
        #expect(response.text == "withheld")
        #expect(response.interim.isEmpty)
    }
}
