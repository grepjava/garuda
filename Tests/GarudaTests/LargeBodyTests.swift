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

    // An array this large is held rather than copied, and sent from where
    // it is; everything else that reads the body reads it as it would any.

    @Test func aHookSeesALargeBody() throws {
        let app = largeApp()
        app.use { _, response, next in
            response.onSend { outgoing in
                outgoing.addHeader("x-count", String(outgoing.bodyCount))
                outgoing.addHeader("x-last", String(outgoing.withBody { $0[$0.count - 1] }))
            }
            try await next()
        }
        let response = try app.test.get("/large")
        #expect(response.header("x-count") == "\(megabyte.count)")
        #expect(response.header("x-last") == "\(megabyte[megabyte.count - 1])")
        #expect(response.body == megabyte)
    }

    @Test func aHookCanReplaceALargeBody() throws {
        let app = largeApp()
        app.use { _, response, next in
            response.onSend { outgoing in outgoing.replaceBody("replaced") }
            try await next()
        }
        let response = try app.test.get("/large")
        #expect(response.header("content-length") == "8")
        #expect(response.text == "replaced")
    }

    @Test func aDeclaredShorterLengthCutsALargeBody() throws {
        let app = Application()
        app.get("/large") { _, response in
            response.addHeader("content-length", "1000")
            response.send(bytes: megabyte, contentType: "application/octet-stream")
        }
        let response = try app.test.get("/large")
        #expect(response.header("content-length") == "1000")
        #expect(response.body == Array(megabyte[..<1000]))
    }

    @Test func aLargeBodyArrivesWholeOverHTTP2() throws {
        let h2 = try largeApp().test.http2()
        let response = try h2.get("/large")
        #expect(response.status == .ok)
        #expect(response.header("content-length") == "\(megabyte.count)")
        #expect(response.body == megabyte)
    }
}
