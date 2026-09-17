import Testing
import CAvian
import AvianCore
import AvianHTTP
@testable import Garuda

// Tests for one HTTP/1.1 exchange over a connection the worker made.
//
// Both ends are on this thread: the worker turns, and the origin is pumped on
// each turn. A fake that blocked on accept or read would stop the worker it is
// being asked to answer.

/// What the handler under test saw, read back by the test.
nonisolated(unsafe) private var outcome = ""
/// Where the handler should send its request, and what it should send.
nonisolated(unsafe) private var urlWanted = ""
nonisolated(unsafe) private var headersWanted: [(String, String)] = []
nonisolated(unsafe) private var bodyWanted: [UInt8] = []
nonisolated(unsafe) private var bodyLimitWanted = 8 * 1024 * 1024

/// An origin server the test owns, on a port the kernel chose.
///
/// Bound to port 0 and read back rather than given a fixed number: a test that
/// picks a port fails whenever something else on the machine holds it.
private final class FakeOrigin {
    let fd: Int32
    let port: UInt16
    /// Everything that arrived, in order, for a test to assert on.
    private(set) var received: [String] = []
    /// How many connections were accepted, which is how a test tells a reused
    /// connection from a second one.
    private(set) var accepted = 0
    /// Responses to send, in order, one per request.
    var script: [[UInt8]] = []
    /// Closes the connection after answering, which is how a close-delimited
    /// body ends.
    var closeAfterResponse = false
    /// Sends this many bytes of the response now and the rest on a later
    /// pump, so the client has to come back for it rather than getting the
    /// whole thing alongside the head. Splitting exactly at the head boundary
    /// is what tells a client that reads the body from what it already has
    /// apart from one that reads until the body is done.
    var splitAfter = 0
    private var open: [Int32] = []
    private var pending: [(Int32, [UInt8])] = []
    private var served = 0

    init?() {
        let opened = "127.0.0.1".withCString { av_listen_tcp($0, 0, 16, 0, 0) }
        guard opened >= 0 else { return nil }
        let got = av_local_port(opened)
        guard got != 0 else { _ = av_close(opened); return nil }
        fd = opened
        port = got
    }

    deinit {
        for peer in open { _ = av_close(peer) }
        _ = av_close(fd)
    }

    var url: String { "http://127.0.0.1:\(port)" }

    /// Accepts anything waiting and answers whatever has arrived. Called once
    /// per turn of the worker, since both ends are on this thread.
    func pump() {
        // Whatever was owed from last time goes first, so the rest of a split
        // response lands in a read after the one that carried the head.
        let owed = pending
        pending.removeAll()
        for (peer, rest) in owed {
            _ = rest.withUnsafeBytes { raw in
                av_write(peer, raw.baseAddress, raw.count)
            }
            if closeAfterResponse {
                _ = av_close(peer)
                open.removeAll { $0 == peer }
            }
        }

        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 {
            open.append(peer)
            accepted += 1
        }

        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { raw in
                av_read(peer, raw.baseAddress, raw.count)
            }
            guard got > 0 else { continue }
            received.append(String(decoding: buffer.prefix(got), as: UTF8.self))
            guard served < script.count else { continue }
            let payload = script[served]
            served += 1
            if splitAfter > 0, splitAfter < payload.count {
                let first = Array(payload.prefix(splitAfter))
                _ = first.withUnsafeBytes { raw in
                    av_write(peer, raw.baseAddress, raw.count)
                }
                pending.append((peer, Array(payload.dropFirst(splitAfter))))
            } else {
                _ = payload.withUnsafeBytes { raw in
                    av_write(peer, raw.baseAddress, raw.count)
                }
                if closeAfterResponse {
                    _ = av_close(peer)
                    open.removeAll { $0 == peer }
                }
            }
        }
    }
}

private func clientApp() -> Application {
    let app = Application()
    app.onAsync(.get, "/fetch") { request, response in
        // Taken before the first await: a Request is a view of a slot, and the
        // worker pointer is what outlives the wait.
        var client = request.client
        client.maxBodyBytes = bodyLimitWanted
        do {
            let answer = try await client.get(urlWanted, headers: headersWanted)
            outcome = "\(answer.status)|\(answer.text)|\(answer.reusedConnection)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/head") { request, response in
        let client = request.client
        do {
            let answer = try await client.head(urlWanted)
            outcome = "\(answer.status)|\(answer.body.count)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    app.onAsync(.get, "/post") { request, response in
        let client = request.client
        do {
            let answer = try await client.post(urlWanted, body: bodyWanted,
                                               contentType: "text/plain")
            outcome = "\(answer.status)|\(answer.text)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // Two exchanges in one handler, so a test can ask whether the first
    // connection was kept and handed to the second.
    app.onAsync(.get, "/twice") { request, response in
        let client = request.client
        do {
            let first = try await client.get(urlWanted)
            let second = try await client.get(urlWanted)
            outcome = "\(first.status),\(second.status)"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    // Reports the header a response carried, to prove they are read out.
    app.onAsync(.get, "/header") { request, response in
        let client = request.client
        do {
            let answer = try await client.get(urlWanted)
            outcome = answer.header("X-Thing") ?? "absent"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    return app
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

@Suite("HTTP client", .serialized)
struct HTTPClientTests {

    /// Runs one request while being the origin on the other end.
    private func run(_ route: String, _ origin: FakeOrigin,
                     path: String = "/x", turns: Int = 20_000) throws -> String {
        outcome = ""
        urlWanted = origin.url + path
        let client = clientApp().test
        let wire = try TestWire(client)
        wire.send("GET \(route) HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            origin.pump()
            return !outcome.isEmpty
        }, turns: turns)
        _ = wire.receive()
        return outcome
    }

    /// The same, keeping the test client so the worker can be inspected after.
    private func runKeeping(_ route: String, _ origin: FakeOrigin,
                            path: String = "/x") throws -> (String, TestClient) {
        outcome = ""
        urlWanted = origin.url + path
        let client = clientApp().test
        let wire = try TestWire(client)
        wire.send("GET \(route) HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            origin.pump()
            return !outcome.isEmpty
        }, turns: 20_000)
        _ = wire.receive()
        return (outcome, client)
    }

    private func reset() {
        outcome = ""
        headersWanted = []
        bodyWanted = []
        bodyLimitWanted = 8 * 1024 * 1024
    }

    // MARK: An ordinary exchange

    @Test func anOrdinaryResponseComesBack() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")]
        #expect(try run("/fetch", origin) == "200|hello|true")
    }

    @Test func theRequestSaysWhereItIsGoingAndWhoItIsFrom() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        _ = try run("/fetch", origin, path: "/a/b?c=d")
        let sent = origin.received.joined()
        #expect(sent.hasPrefix("GET /a/b?c=d HTTP/1.1\r\n"))
        #expect(sent.contains("Host: 127.0.0.1:\(origin.port)\r\n"))
        #expect(sent.contains("User-Agent: garuda\r\n"))
        #expect(sent.contains("Connection: keep-alive\r\n"))
    }

    @Test func aURLWithNoPathAsksForTheRoot() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        _ = try run("/fetch", origin, path: "")
        #expect(origin.received.joined().hasPrefix("GET / HTTP/1.1\r\n"))
    }

    @Test func aResponseHeaderIsReadOut() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nX-Thing: here\r\nContent-Length: 0\r\n\r\n")]
        #expect(try run("/header", origin) == "here")
    }

    @Test func aPostSendsItsBodyAndItsLength() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        bodyWanted = bytes("name=value")
        origin.script = [bytes("HTTP/1.1 201 Created\r\nContent-Length: 2\r\n\r\nok")]
        #expect(try run("/post", origin) == "201|ok")
        let sent = origin.received.joined()
        #expect(sent.hasPrefix("POST /x HTTP/1.1\r\n"))
        #expect(sent.contains("Content-Length: 10\r\n"))
        #expect(sent.contains("Content-Type: text/plain\r\n"))
        #expect(sent.hasSuffix("name=value"))
    }

    // MARK: Framing

    @Test func aChunkedBodyIsDecoded() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")]
        #expect(try run("/fetch", origin) == "200|hello world|true")
    }

    @Test func aResponseToHEADCarriesNoBodyHoweverMuchItDeclares() throws {
        // The response-smuggling guard, end to end. A client that believed the
        // Content-Length here would read the next response's head as this
        // one's body, and every answer after that would belong to the wrong
        // request.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 1024\r\n\r\n")]
        #expect(try run("/head", origin) == "200|0")
    }

    @Test func aBodylessStatusCarriesNoBody() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 204 No Content\r\nContent-Length: 7\r\n\r\n")]
        #expect(try run("/fetch", origin) == "204||true")
    }

    @Test func aCloseDelimitedBodyIsReadToTheEndAndItsConnectionNotKept() throws {
        // The body ends when the connection does, so reading it to the end is
        // the same act as making the connection unusable. A client that pooled
        // this would hand the next caller a socket that is already gone.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.closeAfterResponse = true
        origin.script = [bytes("HTTP/1.1 200 OK\r\n\r\nstreamed")]
        #expect(try run("/fetch", origin) == "200|streamed|false")
    }

    @Test func aCloseDelimitedBodyThatArrivesAfterItsHeadIsStillRead() throws {
        // The same response, split exactly at the head boundary so the body
        // arrives in a later read. The test above passes even for a client
        // that only ever reads what came alongside the head; this one fails
        // unless it goes back for more. Both arrangements are real, and a
        // client that handles one and not the other is a client whose bugs
        // depend on how the peer happened to flush.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.closeAfterResponse = true
        origin.splitAfter = 19          // "HTTP/1.1 200 OK\r\n\r\n"
        origin.script = [bytes("HTTP/1.1 200 OK\r\n\r\nstreamed")]
        #expect(try run("/fetch", origin) == "200|streamed|false")
    }

    @Test func anInformationalResponseIsNotMistakenForTheAnswer() throws {
        // 100 Continue arrives, and the real response follows on the same
        // connection. Reading the first as final would leave the second in the
        // buffer to be read as a body.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 100 Continue\r\n\r\n"
            + "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndone")]
        #expect(try run("/fetch", origin) == "200|done|true")
    }

    // MARK: Pooling

    @Test func aKeptConnectionIsUsedAgainForTheNextRequest() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [
            bytes("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\none"),
            bytes("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ntwo"),
        ]
        #expect(try run("/twice", origin) == "200,200")
        // Two requests, one connection: the second was served on the first.
        #expect(origin.received.count == 2)
        #expect(origin.accepted == 1)
    }

    @Test func aConnectionThatWasKeptIsLeftIdleRatherThanClosed() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi")]
        let (text, client) = try runKeeping("/fetch", origin)
        #expect(text == "200|hi|true")
        // Still held, not closed: that is what makes it available next time.
        #expect(client.worker.pointee.outbound?.liveCount == 1)
    }

    @Test func aConnectionWithBytesStillOnItIsNotPooled() throws {
        // The server sent a second response nobody asked for. Whatever it is —
        // an over-sending origin, a pipelined answer, a smuggled one — those
        // bytes belong to no exchange this client made, and handing the
        // connection on is exactly what makes the next caller read somebody
        // else's answer.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
            + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno")]
        let (text, client) = try runKeeping("/fetch", origin)
        #expect(text == "200|hello|false")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    @Test func aFailedExchangeClosesItsConnectionRatherThanPoolingIt() throws {
        // Nothing about a failed exchange says the connection is clean. The
        // parser stopped somewhere it could not make sense of, so what is
        // still on the wire is anybody's guess — and a guess is not something
        // to hand the next caller.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 2000 OK\r\n\r\n")]
        let (text, client) = try runKeeping("/fetch", origin)
        #expect(text.hasPrefix("malformedResponse"))
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    @Test func aConnectionThatCouldNotBeKeptIsClosed() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi")]
        let (text, client) = try runKeeping("/fetch", origin)
        #expect(text == "200|hi|false")
        #expect(client.worker.pointee.outbound?.liveCount == 0)
    }

    // MARK: What the client refuses

    @Test func aCallerSuppliedHostIsRefused() throws {
        // The writer owns Host. Two of them is the host-desync the parser
        // refuses on the way in, and sending what this process refuses to
        // receive would be a strange thing to allow.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        headersWanted = [("Host", "evil.example")]
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        #expect(try run("/fetch", origin) == "refusedHeader")
        // Refused before anything was opened.
        #expect(origin.accepted == 0)
    }

    @Test func aHeaderValueThatCouldSplitTheRequestIsRefused() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        headersWanted = [("X-Token", "abc\r\nX-Admin: 1")]
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        #expect(try run("/fetch", origin) == "refusedHeader")
        #expect(origin.accepted == 0)
    }

    @Test func anOrdinaryCallerHeaderGoesOut() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        headersWanted = [("X-Token", "abc")]
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        _ = try run("/fetch", origin)
        #expect(origin.received.joined().contains("X-Token: abc\r\n"))
    }

    @Test func aCallerMaySetItsOwnUserAgent() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        headersWanted = [("User-Agent", "mine/1.0")]
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")]
        _ = try run("/fetch", origin)
        let sent = origin.received.joined()
        #expect(sent.contains("User-Agent: mine/1.0\r\n"))
        #expect(!sent.contains("User-Agent: garuda\r\n"))
    }

    @Test func aBadURLIsRefusedBeforeAnythingIsOpened() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        outcome = ""
        urlWanted = "ftp://example.com/x"
        let client = clientApp().test
        let wire = try TestWire(client)
        wire.send("GET /fetch HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: { origin.pump(); return !outcome.isEmpty }, turns: 20_000)
        _ = wire.receive()
        #expect(outcome == "url(AvianHTTP.HTTPURLError.scheme)")
        #expect(origin.accepted == 0)
    }

    @Test func aMalformedResponseIsRefused() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 2000 OK\r\n\r\n")]
        #expect(try run("/fetch", origin).hasPrefix("malformedResponse"))
    }

    @Test func twoDisagreeingContentLengthsAreRefused() throws {
        // The response side of the smuggling family: whichever a client
        // believes, something upstream believed the other.
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello")]
        #expect(try run("/fetch", origin).hasPrefix("malformedResponse"))
    }

    @Test func aBodyLargerThanTheLimitIsRefused() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        bodyLimitWanted = 8
        origin.script = [bytes("HTTP/1.1 200 OK\r\nContent-Length: 64\r\n\r\n"
            + String(repeating: "x", count: 64))]
        #expect(try run("/fetch", origin) == "bodyTooLarge")
    }

    @Test func aChunkedBodyLargerThanTheLimitIsRefused() throws {
        reset()
        guard let origin = FakeOrigin() else { Issue.record("no socket"); return }
        bodyLimitWanted = 8
        origin.script = [bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "20\r\n" + String(repeating: "x", count: 32) + "\r\n0\r\n\r\n")]
        #expect(try run("/fetch", origin) == "bodyTooLarge")
    }
}
