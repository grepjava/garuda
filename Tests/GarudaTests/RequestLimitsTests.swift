import Testing
import Garuda
import GarudaTesting

// maxBodySize, as the server configuration sets it for every route.

private func bodyClient() -> TestClient {
    let app = Application()
    app.post("/count") { request, response in response.send("\(request.body.count)") }
    var config = ServerConfig()
    config.maxBodySize = 16
    return app.testClient(configuration: config)
}

@Suite("Request limits")
struct RequestLimitsTests {
    @Test func aBodyPastMaxBodySizeIs413() throws {
        let client = bodyClient()
        #expect(try client.post("/count", body: String(repeating: "x", count: 40)).status == 413)
        #expect(try client.post("/count", body: "0123456789").text == "10")
        #expect(try client.post("/count", body: String(repeating: "x", count: 16)).text == "16")
        #expect(try client.post("/count", body: String(repeating: "x", count: 17)).status == 413)
    }

    @Test func aChunkedBodyIsRefusedWhenItGrowsPastTheLimit() throws {
        let client = bodyClient()
        let chunked = "POST /count HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
        let within = try client.send(raw: Array((chunked + "4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n").utf8))
        #expect(within.text == "8")
        let past = try client.send(raw: Array((chunked + "9\r\nhello wor\r\n9\r\nld, again\r\n0\r\n\r\n").utf8))
        #expect(past.status == 413)
    }
}
