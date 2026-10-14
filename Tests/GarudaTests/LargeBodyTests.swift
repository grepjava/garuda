import Testing
import Garuda
import GarudaTesting

// A large body: every byte, in order, and the connection fit for the next
// request.

private let megabyte: [UInt8] = (0..<(1 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }

private func largeApp() -> Application {
    let app = Application()
    app.get("/large") { _, response in
        response.send(bytes: megabyte, contentType: "application/octet-stream")
    }
    app.get("/small") { _, response in response.send("small") }
    return app
}

@Suite("Large bodies")
struct LargeBodyTests {
    @Test func aLargeBodyArrivesWholeAndInOrder() throws {
        let response = try largeApp().test.get("/large")
        #expect(response.status == 200)
        #expect(response.header("content-length") == "\(megabyte.count)")
        #expect(response.body == megabyte)
    }

    @Test func theConnectionServesTheNextRequestAfterIt() throws {
        // Pipelined: the second request is already there while the first
        // body is still going out.
        let raw = Array("GET /large HTTP/1.1\r\nHost: t\r\n\r\nGET /small HTTP/1.1\r\nHost: t\r\n\r\n".utf8)
        let responses = try largeApp().test.sendPipelined(raw: raw)
        #expect(responses.count == 2)
        #expect(responses.first?.body == megabyte)
        #expect(responses.last?.status == 200)
        #expect(responses.last?.text == "small")
    }

    @Test func aHeadRequestGetsTheLengthAndNoBody() throws {
        let response = try largeApp().test.head("/large")
        #expect(response.status == 200)
        #expect(response.header("content-length") == "\(megabyte.count)")
        #expect(response.body.isEmpty)
    }
}
