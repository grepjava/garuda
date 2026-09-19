import Testing
import CAvian
@testable import Garuda

// A large body answered from an array is written from that array, after the
// head, rather than copied in behind it (Connection.heldBody). What the
// client gets must not change: every byte, in order, and the connection
// fit for the next request.

private let megabyte: [UInt8] = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }

private func largeApp() -> Application {
    let app = Application()
    app.get("/large") { _, response in
        response.send(bytes: megabyte, contentType: "application/octet-stream")
    }
    app.get("/edge") { _, response in
        // Just at the size that is held, and one short of it.
        response.send(Array(megabyte[0..<Worker.heldBodyMinimum]))
    }
    app.get("/under") { _, response in
        response.send(Array(megabyte[0..<(Worker.heldBodyMinimum - 1)]))
    }
    app.get("/small") { _, response in response.send("small") }
    return app
}

/// Reads whatever has arrived on `wire`, however much, into `bytes`.
private func take(_ wire: TestWire, into bytes: inout [UInt8]) {
    var chunk = [UInt8](repeating: 0, count: 256 * 1024)
    while true {
        let n = chunk.withUnsafeMutableBufferPointer { av_read(wire.fd, $0.baseAddress!, $0.count) }
        if n <= 0 { return }
        bytes.append(contentsOf: chunk[0..<n])
    }
}

private func endsWith(_ bytes: [UInt8], _ text: String) -> Bool {
    let tail = Array(text.utf8)
    return bytes.count >= tail.count && Array(bytes.suffix(tail.count)) == tail
}

/// Where the first response's body starts: after its head's blank line.
private func bodyStart(_ bytes: [UInt8]) -> Int? {
    let blank: [UInt8] = [13, 10, 13, 10]
    guard bytes.count >= 4 else { return nil }
    for i in 0...(bytes.count - 4) where bytes[i] == 13 {
        if Array(bytes[i..<(i + 4)]) == blank { return i + 4 }
    }
    return nil
}

@Suite("Large bodies")
struct LargeBodyTests {
    @Test func aLargeBodyArrivesWholeAndInOrder() throws {
        let response = try largeApp().test.get("/large")
        #expect(response.status == 200)
        #expect(response.header("content-length") == "\(megabyte.count)")
        #expect(response.body == megabyte)
    }

    @Test func bodiesEitherSideOfTheHeldSizeArriveWhole() throws {
        let client = largeApp().test
        #expect(try client.get("/edge").body == Array(megabyte[0..<Worker.heldBodyMinimum]))
        #expect(try client.get("/under").body == Array(megabyte[0..<(Worker.heldBodyMinimum - 1)]))
    }

    @Test func theConnectionServesTheNextRequestAfterIt() throws {
        let client = largeApp().test
        let wire = try TestWire(client)
        // Pipelined: the second request is already there while the first
        // body is still going out.
        wire.send("GET /large HTTP/1.1\r\nHost: t\r\n\r\nGET /small HTTP/1.1\r\nHost: t\r\n\r\n")
        var received: [UInt8] = []
        for _ in 0..<200_000 {
            client.turn()
            take(wire, into: &received)
            if endsWith(received, "\r\n\r\nsmall") { break }
        }
        #expect(endsWith(received, "\r\n\r\nsmall"))
        // The first body sits whole between its head and the second response.
        let start = try #require(bodyStart(received))
        #expect(received.count >= start + megabyte.count)
        #expect(Array(received[start..<(start + megabyte.count)]) == megabyte)
        let rest = String(decoding: received[(start + megabyte.count)...], as: UTF8.self)
        #expect(rest.hasPrefix("HTTP/1.1 200"))
    }

    @Test func aHeadRequestGetsTheLengthAndNoBody() throws {
        let response = try largeApp().test.head("/large")
        #expect(response.status == 200)
        #expect(response.header("content-length") == "\(megabyte.count)")
        #expect(response.body.isEmpty)
    }

    @Test func aCompressedLargeBodyIsTheCompressedOne() throws {
        let app = Application()
        let text = [UInt8](repeating: UInt8(ascii: "a"), count: 1 << 20)
        app.get("/text") { _, response in response.send(bytes: text, contentType: "text/plain") }
        var config = ServerConfig()
        config.compress = true
        let response = try app.testClient(configuration: config)
            .get("/text", headers: [("Accept-Encoding", "gzip")])
        #expect(response.status == 200)
        #expect(response.header("content-encoding") == "gzip")
        // Compressed, so neither the array nor its length went out.
        #expect(response.body.count < 64 * 1024)
        #expect(response.header("content-length") == "\(response.body.count)")
    }

    @Test func manyConnectionsAtOnceEachGetTheirOwn() throws {
        let client = largeApp().test
        var wires: [TestWire] = []
        for _ in 0..<8 {
            let wire = try TestWire(client)
            wire.send("GET /large HTTP/1.1\r\nHost: t\r\n\r\n")
            wires.append(wire)
        }
        var received = [[UInt8]](repeating: [], count: wires.count)
        // Turned together, so the worker is writing to all of them at once.
        for _ in 0..<200_000 {
            client.turn()
            for (i, wire) in wires.enumerated() { take(wire, into: &received[i]) }
            let done = received.allSatisfy { bytes in
                bodyStart(bytes).map { bytes.count >= $0 + megabyte.count } ?? false
            }
            if done { break }
        }
        for bytes in received {
            let start = try #require(bodyStart(bytes))
            #expect(bytes.count == start + megabyte.count)
            #expect(Array(bytes[start...]) == megabyte)
        }
    }
}
