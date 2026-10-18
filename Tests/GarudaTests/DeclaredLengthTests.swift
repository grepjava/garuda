import Testing
@testable import Garuda
@_spi(Testing) import GarudaTesting
import GarudaWire

// A handler's own Content-Length, on every protocol: a 304 keeps it, a body
// longer than it is cut to it, and one shorter than it is never ended as if
// it were whole -- the HTTP/1.1 connection closed, the stream reset -- as
// Garuda 1 did (scripts/handler-test.py checks the same from outside).

/// `n` bytes of the alphabet, over and over.
private func letters(_ n: Int) -> [UInt8] {
    (0..<n).map { UInt8(97 + $0 % 26) }
}

private func lengthApp() -> Application {
    let app = Application()
    app.get("/") { _, response in response.send(status: .ok) }
    let length: Handler = { request, response in
        response.addHeader("content-length", request.parameter(0))
        response.send(letters(Int(request.parameter(1)) ?? 0))
    }
    app.get("/length/:declared/:actual", length)
    app.head("/length/:declared/:actual", length)
    app.get("/status/:code") { request, response in
        response.addHeader("etag", "\"v1\"")
        response.addHeader("content-length", "5")
        response.send(status: HTTPStatus(Int(request.parameter(0)) ?? 200))
    }
    app.get("/streamed/304") { _, response in
        response.addHeader("content-length", "5")
        _ = response.stream(status: .notModified)
    }
    return app
}

private func get(_ path: String) -> String {
    "GET \(path) HTTP/1.1\r\nHost: test\r\n\r\n"
}

@Suite("A declared Content-Length, HTTP/1.1")
struct DeclaredLengthHTTP1Tests {
    @Test func a304KeepsTheLengthTheHandlerGave() throws {
        let client = lengthApp().testClient()
        let responses = try client.sendPipelined(raw: Array((get("/status/304") + get("/")).utf8))
        #expect(responses.count == 2)
        #expect(responses.first?.status == .notModified)
        #expect(responses.first?.headers(named: "content-length") == ["5"])
        #expect(responses.first?.body.isEmpty == true)
        // Stating it frames nothing: the connection carries on.
        #expect(responses.last?.status == .ok)
    }

    @Test func a204StatesNoLengthEvenWhenTheHandlerGaveOne() throws {
        let response = try lengthApp().testClient().get("/status/204")
        #expect(response.status == .noContent)
        #expect(response.header("content-length") == nil)
    }

    @Test func aStreamed304KeepsTheLengthToo() throws {
        let response = try lengthApp().testClient().get("/streamed/304")
        #expect(response.status == .notModified)
        #expect(response.header("content-length") == "5")
        #expect(response.body.isEmpty)
    }

    @Test func aMatchingLengthIsStatedOnceAndKeepsTheConnection() throws {
        let client = lengthApp().testClient()
        let responses = try client.sendPipelined(raw: Array((get("/length/13/13") + get("/")).utf8))
        #expect(responses.count == 2)
        #expect(responses.first?.headers(named: "content-length") == ["13"])
        #expect(responses.first?.body == letters(13))
        #expect(responses.first?.header("connection") == nil)
    }

    @Test func aLongerBodyIsCutAndTheConnectionCloses() throws {
        let client = lengthApp().testClient()
        let responses = try client.sendPipelined(raw: Array((get("/length/2/4") + get("/")).utf8))
        // The bytes past the length would have been read as the next
        // response: nothing pipelined behind it is answered.
        #expect(responses.count == 1)
        #expect(responses.first?.headers(named: "content-length") == ["2"])
        #expect(responses.first?.body == letters(2))
        #expect(responses.first?.header("connection") == "close")
    }

    @Test func aShorterBodyIsSentAndTheConnectionCloses() throws {
        let client = lengthApp().testClient()
        // The response is cut short by the close, which is what tells the
        // client it is not whole; the request behind it is never answered.
        #expect(throws: TestClientError.self) {
            try client.sendPipelined(raw: Array((get("/length/10/3") + get("/")).utf8))
        }
    }

    @Test func aHeadStatesTheDeclaredLengthAndKeepsTheConnection() throws {
        let response = try lengthApp().testClient().head("/length/10/3")
        #expect(response.status == .ok)
        #expect(response.headers(named: "content-length") == ["10"])
        #expect(response.body.isEmpty)
        #expect(response.header("connection") == nil)
    }
}

@Suite("A declared Content-Length, HTTP/2")
struct DeclaredLengthHTTP2Tests {
    @Test func a304KeepsTheLengthTheHandlerGave() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.get("/status/304")
        #expect(response.status == .notModified)
        #expect(response.headers(named: "content-length") == ["5"])
        #expect(response.body.isEmpty)
        #expect(response.ended)
        let noContent = try h2.get("/status/204")
        #expect(noContent.header("content-length") == nil)
    }

    @Test func aStreamed304KeepsTheLengthToo() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.get("/streamed/304")
        #expect(response.status == .notModified)
        #expect(response.header("content-length") == "5")
        #expect(response.ended)
    }

    @Test func aMatchingLengthIsStatedOnce() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.get("/length/13/13")
        #expect(response.headers(named: "content-length") == ["13"])
        #expect(response.body == letters(13))
        #expect(response.ended)
    }

    @Test func aLongerBodyIsCutAndTheStreamEnds() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.get("/length/2/4")
        #expect(response.headers(named: "content-length") == ["2"])
        #expect(response.body == letters(2))
        #expect(response.ended)
        #expect(response.reset == nil)
    }

    @Test func aShorterBodyIsSentAndTheStreamReset() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.get("/length/10/3")
        #expect(response.headers(named: "content-length") == ["10"])
        #expect(response.body == letters(3))
        #expect(!response.ended)
        #expect(response.reset == HTTP2ErrorCode.internalError.rawValue)
        // Nothing to send at all is reset just the same.
        let empty = try h2.get("/length/10/0")
        #expect(!empty.ended)
        #expect(empty.reset == HTTP2ErrorCode.internalError.rawValue)
        // The connection survives the reset streams.
        #expect(try h2.get("/").status == .ok)
    }

    @Test func aHeadStatesTheDeclaredLengthAndEnds() throws {
        let h2 = try lengthApp().test.http2()
        let response = try h2.head("/length/10/3")
        #expect(response.headers(named: "content-length") == ["10"])
        #expect(response.body.isEmpty)
        #expect(response.ended)
        #expect(response.reset == nil)
    }
}

@Suite("A declared Content-Length, HTTP/3")
struct DeclaredLengthHTTP3Tests {
    private func get(_ client: H3Client, _ id: UInt64, _ path: String, method: String = "GET") async throws
        -> H3Answer {
        try await client.request(id, [(":method", method), (":scheme", "https"), (":authority", "localhost"),
                                      (":path", path)])
        return try await client.answer(id)
    }

    @Test func a304KeepsTheLengthTheHandlerGave() throws {
        try withServer(lengthApp()) { client, _ in
            try await client.connect()
            let answer = try await get(client, 0, "/status/304")
            #expect(answer.status == 304)
            #expect(answer.headers.filter { $0.name == "content-length" }.map(\.value) == ["5"])
            #expect(answer.body.isEmpty)
            #expect(answer.reset == nil)
            let noContent = try await get(client, 4, "/status/204")
            #expect(noContent.header("content-length") == nil)
            let streamed = try await get(client, 8, "/streamed/304")
            #expect(streamed.header("content-length") == "5")
        }
    }

    @Test func aMatchingLengthIsStatedOnce() throws {
        try withServer(lengthApp()) { client, _ in
            try await client.connect()
            let answer = try await get(client, 0, "/length/13/13")
            #expect(answer.headers.filter { $0.name == "content-length" }.map(\.value) == ["13"])
            #expect(answer.body == letters(13))
            #expect(answer.reset == nil)
        }
    }

    @Test func aLongerBodyIsCutAndTheStreamEnds() throws {
        try withServer(lengthApp()) { client, _ in
            try await client.connect()
            let answer = try await get(client, 0, "/length/2/4")
            #expect(answer.header("content-length") == "2")
            #expect(answer.body == letters(2))
            #expect(answer.reset == nil)
        }
    }

    @Test func aShorterBodyIsResetAndTheConnectionGoesOn() throws {
        try withServer(lengthApp()) { client, _ in
            try await client.connect()
            let answer = try await get(client, 0, "/length/10/3")
            #expect(answer.reset == HTTP3ErrorCode.internalError.rawValue)
            let empty = try await get(client, 4, "/length/10/0")
            #expect(empty.reset == HTTP3ErrorCode.internalError.rawValue)
            #expect(try await get(client, 8, "/").status == 200)
        }
    }

    @Test func aHeadStatesTheDeclaredLengthAndEnds() throws {
        try withServer(lengthApp()) { client, _ in
            try await client.connect()
            let answer = try await get(client, 0, "/length/10/3", method: "HEAD")
            #expect(answer.header("content-length") == "10")
            #expect(answer.body.isEmpty)
            #expect(answer.reset == nil)
        }
    }
}
