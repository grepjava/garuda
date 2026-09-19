import Testing
import CAvian
import AvianCore
import AvianHTTP
@testable import Garuda

// A response read as it arrives: `HTTPClient.stream`.
//
// The origin here sends a response a piece per turn, so the client has to come
// back for each one rather than finding the body whole behind the head -- the
// difference between a client that streams and one that buffers and then
// hands the buffer out in pieces.

nonisolated(unsafe) private var streamOutcome = ""
nonisolated(unsafe) private var streamURL = ""

/// An origin that answers each request with `pieces`, one per pump.
private final class DripOrigin {
    let fd: Int32
    let port: UInt16
    /// The response, in the pieces it goes out as.
    var pieces: [[UInt8]] = []
    /// Reads requests but never answers them.
    var silent = false
    /// How long to leave between one piece and the next.
    var gapMilliseconds: UInt64 = 0
    private var lastSent: [Int32: UInt64] = [:]
    private(set) var accepted = 0
    private(set) var requests = 0
    private var open: [Int32] = []
    /// Per connection, the pieces still to send.
    private var owed: [Int32: [[UInt8]]] = [:]

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        fd = opened
        port = av_local_port(opened)
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        _ = av_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 {
            open.append(peer)
            accepted += 1
        }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            if got > 0, String(decoding: buffer.prefix(got), as: UTF8.self).contains("\r\n\r\n") {
                requests += 1
                if !silent { owed[peer, default: []] += pieces }
            }
            if var rest = owed[peer], !rest.isEmpty {
                let now = av_monotonic_ms()
                if let last = lastSent[peer], now - last < gapMilliseconds { continue }
                lastSent[peer] = now
                let piece = rest.removeFirst()
                owed[peer] = rest
                _ = piece.withUnsafeBytes { av_write(peer, $0.baseAddress, $0.count) }
            }
        }
    }
}

private func streamApp(_ body: @escaping @Sendable (HTTPClient) async throws -> String) -> Application {
    let app = Application()
    app.onAsync(.get, "/run") { request, response in
        let client = request.client
        do {
            streamOutcome = try await body(client)
        } catch {
            streamOutcome = "\(error)"
        }
        response.send(streamOutcome)
    }
    return app
}

private func run(_ origin: DripOrigin, turns: Int = 40_000,
                 _ body: @escaping @Sendable (HTTPClient) async throws -> String) throws -> String {
    streamOutcome = ""
    streamURL = origin.url + "/x"
    let client = streamApp(body).test
    let wire = try TestWire(client)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    _ = wire.turn(until: {
        origin.pump()
        return !streamOutcome.isEmpty
    }, turns: turns)
    return streamOutcome
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

/// Every piece of a stream, as text, joined with `|` to show the seams.
private func pieces(of stream: ClientResponseStream) async throws -> String {
    var seen: [String] = []
    while let piece = try await stream.next() { seen.append(String(decoding: piece, as: UTF8.self)) }
    return seen.joined(separator: "|")
}

@Suite("HTTP client, streamed responses", .serialized)
struct HTTPClientStreamTests {

    @Test func aChunkedBodyIsHandedOverAsItArrives() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [
            bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"),
            bytes("5\r\nworld\r\n"),
            bytes("0\r\n\r\n"),
        ]
        let result = try run(origin) { client in
            let stream = try await client.stream(.get, streamURL)
            let first = "\(stream.status) " + (try await pieces(of: stream))
            // The body was read to its end, so the connection is kept for
            // the next request.
            let again = try await client.stream(.get, streamURL)
            return first + " / " + (try await pieces(of: again))
        }
        #expect(result == "200 hello|world / hello|world")
        #expect(origin.accepted == 1, "the connection is reused once the body has ended")
    }

    @Test func aLengthBodyEndsWhereItSaysAndKeepsTheConnection() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabcd"), bytes("efghij")]
        let result = try run(origin) { client in
            let stream = try await client.stream(.get, streamURL)
            let first = try await pieces(of: stream)
            let second = try await client.get(streamURL)
            return first + " / " + second.text
        }
        #expect(result == "abcd|efghij / abcdefghij")
        #expect(origin.accepted == 1)
    }

    @Test func aStreamGivenUpOnClosesItsConnection() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabcd"), bytes("efghij")]
        let result = try run(origin) { client in
            let stream = try await client.stream(.get, streamURL)
            let first = try await stream.next().map { String(decoding: $0, as: UTF8.self) } ?? "none"
            stream.cancel()
            let after = try await stream.next()
            let again = try await client.get(streamURL)
            return "\(first) \(after == nil) \(again.text)"
        }
        #expect(result == "abcd true abcdefghij")
        #expect(origin.accepted == 2, "the rest of a body nobody read is not handed to the next request")
    }

    @Test func aStreamIsNotHeldToTheBodyLimitButCollectIs() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 30\r\n\r\n0123456789"),
                         bytes("0123456789"), bytes("0123456789")]
        let result = try run(origin) { client in
            var client = client
            client.maxBodyBytes = 12
            let whole = try await client.stream(.get, streamURL)
            var count = 0
            while let piece = try await whole.next() { count += piece.count }
            let limited = try await client.stream(.get, streamURL)
            do {
                _ = try await limited.collect()
                return "\(count) collected"
            } catch {
                return "\(count) \(error)"
            }
        }
        #expect(result == "30 bodyTooLarge")
    }

    @Test func eventsAreReadAcrossPiecesWhereverTheySplit() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        let events = "id: 1\r\ndata: first\r\n\r\n: a comment\r\nevent: delta\r\ndata: sec"
            + "ond\r\ndata: line\r\n\r\ndata: third\r"
        // Cut mid-field and between a CR and its LF.
        let a = Array(events.utf8.prefix(20))
        let b = Array(events.utf8.dropFirst(20).prefix(40))
        let c = Array(events.utf8.dropFirst(60))
        func chunk(_ part: [UInt8]) -> [UInt8] { bytes(String(part.count, radix: 16) + "\r\n") + part + bytes("\r\n") }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                               + "Transfer-Encoding: chunked\r\n\r\n") + chunk(a),
                         chunk(b), chunk(c) + chunk(bytes("\n\ndata: cut off")), bytes("0\r\n\r\n")]
        let result = try run(origin) { client in
            let stream = try await client.stream(.get, streamURL)
            var seen: [String] = []
            while let event = try await stream.nextEvent() {
                seen.append("\(event.event):\(event.data):\(event.id ?? "-")")
            }
            return seen.joined(separator: " / ")
        }
        #expect(result == "message:first:1 / delta:second\nline:1 / message:third:1")
    }

    /// The README's relay: an upstream's events read as they arrive and
    /// written on as a streamed response of this server's own.
    @Test func anUpstreamsEventsAreRelayedAsTheyArrive() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [
            bytes("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"),
            bytes("e\r\ndata: token1\n\n\r\n"),
            bytes("e\r\ndata: token2\n\n\r\n"),
            bytes("0\r\n\r\n"),
        ]
        streamURL = origin.url + "/x"
        let app = Application()
        app.onAsync(.get, "/relay") { request, response in
            let client = request.client
            let upstream = try await client.stream(.get, streamURL)
            let body = response.stream(contentType: "text/event-stream")
            while let event = try await upstream.nextEvent() {
                try await body.write("data: \(event.data)\n\n")
            }
        }
        let client = app.test
        let wire = try TestWire(client)
        wire.send("GET /relay HTTP/1.1\r\nHost: test\r\n\r\n")
        var received = ""
        _ = wire.turn(until: {
            origin.pump()
            received = wire.arrived()
            return received.contains("0\r\n\r\n")
        }, turns: 40_000)
        #expect(received.contains("text/event-stream"))
        #expect(received.contains("data: token1\n\n"))
        #expect(received.contains("data: token2\n\n"))
    }

    @Test func noCompressionIsAskedForAStream() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")]
        let result = try run(origin) { client in
            let stream = try await client.stream(.get, streamURL, headers: [("Accept-Encoding", "gzip")])
            return try await pieces(of: stream)
        }
        #expect(result == "ok", "a caller's own Accept-Encoding is its to send")
    }

    @Test func theWholeBudgetEndsAnExchangeThatEveryWaitWouldAllow() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.silent = true
        let started = av_monotonic_ms()
        let result = try run(origin) { client in
            var client = client
            client.timeoutMilliseconds = 5_000
            client.totalTimeoutMilliseconds = 150
            _ = try await client.get(streamURL)
            return "answered"
        }
        let took = av_monotonic_ms() - started
        #expect(result == "timedOut")
        #expect(took < 2_000, "ended by the budget, not the per-wait timeout: \(took) ms")
    }

    /// A stream may rightly run for longer than the budget that got it
    /// going: the body comes after the budget has run out, and still comes.
    /// The same response read whole is over budget.
    @Test func theBudgetCoversAStreamOnlyUntilItsHead() throws {
        guard let origin = DripOrigin() else { Issue.record("no socket"); return }
        origin.pieces = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n"), bytes("done")]
        origin.gapMilliseconds = 400
        let result = try run(origin) { client in
            var client = client
            client.totalTimeoutMilliseconds = 200
            let stream = try await client.stream(.get, streamURL)
            let streamed = try await pieces(of: stream)
            do {
                _ = try await client.get(streamURL)
                return streamed + " / whole"
            } catch {
                return streamed + " / \(error)"
            }
        }
        #expect(result == "done / timedOut")
    }
}

@Suite("Server-sent events, read")
struct ServerSentEventParserTests {
    private func parse(_ parts: [String], limit: Int = 1 << 20) -> [ServerSentEvent]? {
        var parser = ServerSentEventParser()
        var out: [ServerSentEvent] = []
        for part in parts {
            guard parser.feed(Array(part.utf8), limit: limit) else { return nil }
            while let event = parser.take() { out.append(event) }
        }
        return out
    }

    @Test func linesEndWithCRLFOrLFOrCR() {
        #expect(parse(["data: a\r\n\r\ndata: b\n\ndata: c\r\r"]) ==
                [ServerSentEvent(data: "a"), ServerSentEvent(data: "b"), ServerSentEvent(data: "c")])
    }

    @Test func aCRAndItsLFSplitAcrossReadsEndOneLine() {
        #expect(parse(["data: a\r", "\ndata: b\r", "\n\r", "\n"]) == [ServerSentEvent(data: "a\nb")])
    }

    @Test func fieldsAreReadAsTheFormatSays() {
        let events = parse(["\u{FEFF}event: tick\ndata:no space\ndata:  two spaces\nid: 7\nretry: 1500\n\n",
                            "data: later\n\n", "id\ndata: cleared\n\n"])
        #expect(events == [
            ServerSentEvent(event: "tick", data: "no space\n two spaces", id: "7", retry: 1500),
            ServerSentEvent(data: "later", id: "7"),
            ServerSentEvent(data: "cleared", id: ""),
        ])
    }

    @Test func commentsAndEventsWithoutDataAreNotEvents() {
        #expect(parse([": keep-alive\n\nevent: nothing\n\nretry: x\ndata: yes\n\n"]) ==
                [ServerSentEvent(data: "yes")])
    }

    @Test func anEventCutOffByTheEndIsNotReturned() {
        #expect(parse(["data: whole\n\ndata: cut"]) == [ServerSentEvent(data: "whole")])
    }

    @Test func aLineWithNoEndIsHeldToTheLimit() {
        #expect(parse([String(repeating: "x", count: 100)], limit: 50) == nil)
        #expect(parse(["data: " + String(repeating: "x", count: 40) + "\n"], limit: 50) != nil)
    }
}
