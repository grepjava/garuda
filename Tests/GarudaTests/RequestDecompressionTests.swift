import Testing
import CAvian
import AvianCore
@testable import Garuda
import AvianHTTP

// Compressed request bodies decoded before the handler reads them.

private func compress(_ bytes: [UInt8], _ coding: ContentCoding) -> [UInt8] {
    var encoder = ResponseEncoder()
    guard encoder.start(coding) else { return [] }
    var out = ByteBuffer()
    defer { out.destroy() }
    let ok = bytes.withUnsafeBufferPointer { encoder.encode($0.baseAddress!, $0.count, flush: false, into: &out, chunked: false) }
        && encoder.finish(into: &out, chunked: false)
    guard ok else { return [] }
    return [UInt8](UnsafeBufferPointer(start: UnsafePointer(out.readPointer), count: out.readableBytes))
}

private struct Event: Codable {
    var name: String
    var count: Int
}

@Suite("Request decompression")
struct RequestDecompressionTests {
    private func app() -> Application {
        let app = Application()
        app.group("/in") {
            app.requestDecompression()
            app.post("/echo") { request, response in response.send(request.body) }
            app.post("/events") { (events: Body<[Event]>) in "\(events.value.map(\.count).reduce(0, +))" }
            app.maxBodySize(2000) {
                app.post("/small") { request, response in response.send("\(request.body.count)") }
            }
            app.onStreamingBody(.post, "/stream") { _, response, body in
                var total: [UInt8] = []
                while let bytes = try await body.read(maxBytes: 4096) { total += bytes }
                response.send(total)
            }
        }
        app.post("/plain") { request, response in response.send("\(request.body.count)") }
        return app
    }

    @Test(arguments: [ContentCoding.gzip, .br, .zstd])
    func aCompressedBodyReachesTheHandlerDecoded(coding: ContentCoding) throws {
        guard av_dec_available(Int32(coding.rawValue)) == 1 else { return }
        let text = Array(String(repeating: "garuda ", count: 500).utf8)
        let body = compress(text, coding)
        #expect(!body.isEmpty && body.count < text.count)
        let client = app().test
        let echoed = try client.post("/in/echo", body: body, headers: [("content-encoding", "\(coding.token)")])
        #expect(echoed.status == 200)
        #expect(echoed.body == text)

        let events = compress(Array(#"[{"name":"a","count":2},{"name":"b","count":40}]"#.utf8), coding)
        #expect(try client.post("/in/events", body: events,
                                headers: [("content-encoding", "\(coding.token)"),
                                          ("content-type", "application/json")]).text == "42")
    }

    @Test func codingsStackAndIdentityIsNone() throws {
        let text = Array("stacked twice".utf8)
        let twice = compress(compress(text, .gzip), .gzip)
        let client = app().test
        #expect(try client.post("/in/echo", body: twice, headers: [("content-encoding", "gzip, gzip")]).body == text)
        #expect(try client.post("/in/echo", body: text, headers: [("content-encoding", "identity")]).body == text)
        #expect(try client.post("/in/echo", body: text).body == text)
        // Deflate, as the zlib format RFC 9110 means by it.
        #expect(try client.post("/in/echo", body: [0x78, 0x9C, 0x4B, 0x4C, 0x4A, 0x06, 0x00, 0x02, 0x4D, 0x01, 0x27],
                                headers: [("content-encoding", "deflate")]).text == "abc")
    }

    @Test func whatCannotBeDecodedIsRefused() throws {
        let client = app().test
        let unknown = try client.post("/in/echo", body: Array("x".utf8), headers: [("content-encoding", "compress")])
        #expect(unknown.status == 415)
        #expect(unknown.header("accept-encoding")?.contains("gzip") == true)
        let broken = try client.post("/in/echo", body: Array("not gzip at all".utf8), headers: [("content-encoding", "gzip")])
        #expect(broken.status == 400)
        var truncated = compress(Array(String(repeating: "cut ", count: 100).utf8), .gzip)
        truncated.removeLast(12)
        #expect(try client.post("/in/echo", body: truncated, headers: [("content-encoding", "gzip")]).status == 400)
    }

    @Test func theDecodedBodyIsHeldToTheRouteLimit() throws {
        let bomb = compress([UInt8](repeating: 0, count: 50_000), .gzip)
        #expect(bomb.count < 2000)
        let client = app().test
        #expect(try client.post("/in/small", body: bomb, headers: [("content-encoding", "gzip")]).status == 413)
        let fits = compress([UInt8](repeating: 0, count: 1500), .gzip)
        #expect(try client.post("/in/small", body: fits, headers: [("content-encoding", "gzip")]).text == "1500")

        var config = ServerConfig()
        config.maxConnections = 16
        config.maxBodySize = 10_000
        #expect(try app().testClient(configuration: config)
            .post("/in/echo", body: bomb, headers: [("content-encoding", "gzip")]).status == 413)
    }

    @Test func outsideTheScopeAndWhenStreamingTheBodyIsLeftAsItCame() throws {
        let body = compress(Array("left alone".utf8), .gzip)
        let client = app().test
        #expect(try client.post("/plain", body: body, headers: [("content-encoding", "gzip")]).text == "\(body.count)")
        #expect(try client.post("/in/stream", body: body, headers: [("content-encoding", "gzip")]).body == body)
    }
}
