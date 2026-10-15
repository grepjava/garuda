import Testing
import Synchronization
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif
import GarudaTesting
import GarudaWire
import Vega
import VegaIO
@testable import Garuda

private func pattern(_ count: Int, seed: Int = 0) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: ($0 &+ seed) &* 131 &+ 7) }
}

/// FNV-1a and the count: what a handler that reads a body a piece at a time
/// answers, to be compared with the same over what was sent.
private func checksum(_ bytes: some Sequence<UInt8>) -> String {
    var value: UInt64 = 0xcbf2_9ce4_8422_2325
    var count = 0
    for byte in bytes {
        value = (value ^ UInt64(byte)) &* 0x100_0000_01b3
        count += 1
    }
    return "\(count) \(value)"
}

/// What a handler saw of its body: how much it read, and how it ended.
private final class Seen: Sendable {
    let state = Mutex<(bytes: Int, ending: String?)>((0, nil))

    func add(_ n: Int) { state.withLock { $0.bytes += n } }
    func end(_ how: String) { state.withLock { $0.ending = how } }
    var bytes: Int { state.withLock { $0.bytes } }
    var ending: String? { state.withLock { $0.ending } }

    /// Waits, up to a few seconds, for the handler to have got this far.
    func wait(until done: (Int, String?) -> Bool) {
        for _ in 0..<500 {
            if state.withLock({ done($0.bytes, $0.ending) }) { return }
            usleep(10_000)
        }
    }
}

/// An application whose `/sum` reads its body `piece` bytes at a time and
/// answers its checksum, recording in `seen` what it read and how it ended.
private func summingApp(_ seen: Seen = Seen(), piece: Int = 8 * 1024,
                        maxBodySize: Int = .max) -> Application {
    let app = Application()
    app.onStreamingBody(.post, "/sum", maxBodySize: maxBodySize) { _, response, body in
        var buffer = IOBuffer(capacity: piece)
        var all: [UInt8] = []
        do {
            while try await body.read(into: &buffer) > 0 {
                seen.add(buffer.count)
                buffer.withUnsafeBytes { all += $0 }
                buffer.clear()
            }
            seen.end("end")
        } catch {
            seen.end("\(error)")
            throw error
        }
        #expect(body.bytesRead == all.count)
        response.send(checksum(all))
    }
    return app
}

@Suite("Request bodies read as they arrive")
struct RequestBodyTests {

    @Test func aBodyIsReadAPieceAtATimeAsItArrives() throws {
        let seen = Seen()
        let body = pattern(300 * 1024)
        let response = try summingApp(seen).test.post("/sum", body: body)
        #expect(response.status == .ok)
        #expect(response.text == checksum(body))
        #expect(seen.ending == "end")
    }

    @Test func aChunkedBodyIsDecodedAsItIsRead() throws {
        let body = pattern(70_000)
        var raw = Array("POST /sum HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        var at = 0
        for size in [1, 10_000, 59_999] {
            raw += Array("\(String(size, radix: 16))\r\n".utf8) + body[at..<(at + size)] + Array("\r\n".utf8)
            at += size
        }
        raw += Array("0\r\n\r\n".utf8)
        let response = try summingApp().test.send(raw: raw)
        #expect(response.text == checksum(body))
    }

    @Test func theDeclaredLengthIsThere() throws {
        let app = Application()
        app.onStreamingBody(.post, "/length") { _, response, body in
            response.send("\(body.expectedLength.map(String.init) ?? "none")")
        }
        #expect(try app.test.post("/length", body: pattern(12)).text == "12")
        let chunked = "POST /length HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n\r\n"
        #expect(try app.test.send(raw: Array(chunked.utf8)).text == "none")
    }

    @Test func aDeclaredLengthPastTheRoutesLimitIsRefusedBeforeTheHandlerRuns() throws {
        let seen = Seen()
        let response = try summingApp(seen, maxBodySize: 100).test.post("/sum", body: pattern(101))
        #expect(response.status == .contentTooLarge)
        #expect(seen.ending == nil, "the handler never ran")
    }

    @Test func aChunkedBodyThatGrowsPastTheLimitIsTooLarge() throws {
        let seen = Seen()
        let raw = "POST /sum HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "40\r\n\(String(repeating: "a", count: 64))\r\n"
            + "40\r\n\(String(repeating: "b", count: 64))\r\n0\r\n\r\n"
        let response = try summingApp(seen, maxBodySize: 100).test.send(raw: Array(raw.utf8))
        #expect(response.status == .contentTooLarge)
        #expect(seen.ending == "tooLarge")
        #expect(seen.bytes <= 100, "nothing past the limit was handed over")
    }

    @Test func aRoutesOwnLimitTakesThePlaceOfMaxBody() throws {
        var config = ServerConfig()
        config.maxBodySize = 1024
        let body = pattern(64 * 1024)
        let response = try summingApp().testClient(configuration: config).post("/sum", body: body)
        #expect(response.status == .ok)
        #expect(response.text == checksum(body))
    }

    @Test func aBodyCutShortIsHandedOverAndThenIncomplete() throws {
        let seen = Seen()
        let head = "POST /sum HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n"
        // The client's side ends after 400 of the 1000 bytes.
        _ = try? summingApp(seen).test.send(raw: Array(head.utf8) + pattern(400))
        seen.wait { $1 != nil }
        #expect(seen.bytes == 400, "everything that arrived was read")
        #expect(seen.ending == "incomplete")
    }

    @Test func aBodyLeftUnreadDoesNotCostTheConnectionWhenItHasArrived() throws {
        let app = Application()
        app.onStreamingBody(.post, "/ignore") { _, response, _ in
            response.send("ignored")
        }
        app.get("/next") { _, response in response.send("next") }
        let raw = "POST /ignore HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello"
            + "GET /next HTTP/1.1\r\nHost: x\r\n\r\n"
        let responses = try app.test.sendPipelined(raw: Array(raw.utf8))
        #expect(responses.map(\.text) == ["ignored", "next"])
    }

    @Test func aClientWaitingToBeToldToSendIsToldOnTheFirstRead() throws {
        let body = pattern(5000)
        // A connection left open, so the client can wait as it would.
        let connection = try summingApp().test.http2(handshake: false)
        let head = "POST /sum HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 5000\r\n\r\n"
        try connection.send(raw: Array(head.utf8))
        usleep(100_000)
        try connection.send(raw: body)
        connection.close()
        let answer = String(decoding: try connection.readUntilClose(), as: UTF8.self)
        #expect(answer.hasPrefix("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200"))
        #expect(answer.hasSuffix(checksum(body)))
    }

    @Test func noContinueIsOwedOnceTheBodyHasArrived() throws {
        // The client did not wait: telling it to send what it sent is noise.
        let body = pattern(5000)
        let response = try summingApp().test.post("/sum", body: body, headers: [("Expect", "100-continue")])
        #expect(response.interim.isEmpty)
        #expect(response.text == checksum(body))
    }

    @Test func readAllHasALimitOfItsOwn() throws {
        let app = Application()
        app.onStreamingBody(.post, "/all") { _, response, body in
            let bytes = try await body.readAll(maxBytes: 100)
            response.send("\(bytes.count)")
        }
        #expect(try app.test.post("/all", body: pattern(100)).text == "100")
        #expect(try app.test.post("/all", body: pattern(101)).status == .contentTooLarge)
    }

    @Test func aRequestWithoutABodyReadsAsEmpty() throws {
        let app = Application()
        app.onStreamingBody(.get, "/empty") { _, response, body in
            response.send("\(try await body.read(maxBytes: 10)?.count ?? -1)")
        }
        #expect(try app.test.get("/empty").text == "-1")
    }

    // MARK: HTTP/2

    @Test func overHTTP2ABodyLargerThanTheWindowIsReadAsItArrives() throws {
        let seen = Seen()
        let body = pattern(400 * 1024, seed: 3)
        let response = try summingApp(seen).test.http2().post("/sum", body: body)
        #expect(response.status == .ok)
        #expect(response.text == checksum(body))
        #expect(seen.ending == "end")
    }

    @Test func overHTTP2TheRoutesLimitApplies() throws {
        let seen = Seen()
        let h2 = try summingApp(seen, maxBodySize: 100).test.http2()
        #expect(try h2.post("/sum", body: pattern(101)).status == .contentTooLarge)
        #expect(seen.ending == nil, "a declared length is refused before the handler runs")
        // Undeclared, it is found out as it arrives.
        let id = try h2.request("POST", "/sum", body: pattern(300))
        #expect(try h2.response(id).status == .contentTooLarge)
        #expect(seen.ending == "tooLarge")
    }

    @Test func overHTTP2AResetStreamHandsOverWhatArrived() throws {
        let seen = Seen()
        let h2 = try summingApp(seen).test.http2()
        let id = try h2.request("POST", "/sum", headers: [("content-length", "1000")], body: pattern(400),
                                endStream: false)
        seen.wait { bytes, _ in bytes == 400 }
        try h2.reset(id)
        seen.wait { $1 != nil }
        #expect(seen.bytes == 400)
        #expect(seen.ending == "incomplete")
    }

    @Test func overHTTP2AHandlerThatStopsReadingHoldsTheClientToTheWindow() throws {
        let release = Mutex(false)
        let app = Application()
        app.onStreamingBody(.post, "/later") { _, response, body in
            while !release.withLock({ $0 }) { try await Runtime.sleep(for: .milliseconds(5)) }
            response.send("\(try await body.readAll(maxBytes: 4 << 20).count)")
        }
        let h2 = try app.test.http2()
        // As much as the stream's window allows goes, and then the client
        // waits: the connection's window is given back as the bytes arrive.
        let window = Int(h2.serverSettings[0x4] ?? 65535)
        let body = pattern(window + 100 * 1024)
        let id = try h2.request("POST", "/later", headers: [("content-length", "\(body.count)")], endStream: false)
        try h2.sendData(stream: id, Array(body[..<window]), endStream: false)
        h2.timeout = .milliseconds(300)
        #expect(throws: TestClientError.timedOut) { try h2.sendData(stream: id, [0], endStream: false) }
        h2.timeout = .seconds(5)
        release.withLock { $0 = true }
        try h2.sendData(stream: id, Array(body[window...]))
        #expect(try h2.response(id).text == "\(body.count)")
    }
}
