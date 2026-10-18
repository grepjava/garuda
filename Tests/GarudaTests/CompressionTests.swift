import VegaWire
import Testing
import GarudaTesting
import GarudaWire
@testable import Garuda

// --compress, and requestDecompression().

private func compress(_ bytes: [UInt8], _ coding: ContentCoding) -> [UInt8] {
    guard let encoder = ResponseEncoder(coding) else { return [] }
    var out = ByteBuffer()
    defer { out.destroy() }
    let ok = bytes.withUnsafeBufferPointer { encoder.encode($0.baseAddress!, $0.count, flush: false, into: &out, chunked: false) }
        && encoder.finish(into: &out, chunked: false)
    guard ok else { return [] }
    return [UInt8](UnsafeBufferPointer(start: UnsafePointer(out.readPointer), count: out.readableBytes))
}

private func gunzip(_ bytes: [UInt8]) -> [UInt8]? {
    try? RequestDecoder.decode(bytes, contentEncoding: "gzip", limit: 1 << 24)
}

private let text: [UInt8] = {
    var s = ""
    for i in 0..<500 { s += "line \(i) of a compressible response\n" }
    return Array(s.utf8)
}()

private let largeText: [UInt8] = Array([[UInt8]](repeating: text, count: 8).joined())

private let gzipOnly = [("accept-encoding", "gzip")]

/// Whether this process has gzip: Vega builds no codec on Windows, having no
/// zlib there, so these suites are skipped.
let gzipUsable = codingUsable(.gzip)

@Suite("Response compression", .enabled(if: gzipUsable, "no gzip: Vega has no zlib on Windows"))
struct ResponseCompressionTests {
    private func client(compress: Bool = true) -> TestClient {
        let app = Application()
        app.get("/text") { _, response in
            response.addHeader("etag", "\"v1\"")
            response.send(bytes: text, contentType: "text/plain; charset=utf-8")
        }
        app.get("/small") { _, response in response.send(text: "tiny") }
        app.get("/png") { _, response in response.send(bytes: text, contentType: "image/png") }
        // Large enough to be held rather than copied (Exchange.heldBody).
        app.get("/large") { _, response in response.send(bytes: largeText, contentType: "text/plain") }
        app.get("/pieces") { () async -> StreamingBody in
            StreamingBody(contentType: "text/plain") { body in
                for i in stride(from: 0, to: text.count, by: 4000) {
                    try await body.write(Array(text[i..<min(text.count, i + 4000)]))
                }
            }
        }
        var config = ServerConfig()
        config.compress = compress
        return app.testClient(configuration: config)
    }

    @Test func aWholeBodyIsCompressedWithItsLength() throws {
        let response = try client().get("/text", headers: gzipOnly)
        #expect(response.header("content-encoding") == "gzip")
        #expect(response.header("vary") == "Accept-Encoding")
        #expect(response.header("content-length") == "\(response.body.count)")
        #expect(response.body.count < text.count)
        #expect(gunzip(response.body) == text)
        // The bytes the tag named are not the ones sent.
        #expect(response.header("etag") == "W/\"v1\"")
    }

    @Test func aLargeBodyIsCompressed() throws {
        let response = try client().get("/large", headers: gzipOnly)
        #expect(response.header("content-encoding") == "gzip")
        #expect(response.body.count < largeText.count)
        #expect(gunzip(response.body) == largeText)
    }

    @Test func whatIsNotWorthItIsLeftAlone() throws {
        let client = client()
        let small = try client.get("/small", headers: gzipOnly)
        #expect(small.header("content-encoding") == nil)
        #expect(small.text == "tiny")
        let png = try client.get("/png", headers: gzipOnly)
        #expect(png.header("content-encoding") == nil)
        #expect(png.header("vary") == nil)
        let plain = try client.get("/text")
        #expect(plain.header("content-encoding") == nil)
        #expect(plain.header("vary") == "Accept-Encoding")
        #expect(plain.header("etag") == "\"v1\"")
        let head = try client.head("/text", headers: gzipOnly)
        #expect(head.header("content-encoding") == nil)
        #expect(head.header("vary") == "Accept-Encoding")
        #expect(try self.client(compress: false).get("/text", headers: gzipOnly).header("content-encoding") == nil)
    }

    @Test func aStreamedBodyIsCompressedAsItIsWritten() throws {
        let response = try client().get("/pieces", headers: gzipOnly)
        #expect(response.header("content-encoding") == "gzip")
        #expect(response.header("transfer-encoding") == "chunked")
        #expect(response.header("content-length") == nil)
        #expect(gunzip(response.body) == text)
    }

    @Test func overHTTP2() throws {
        let h2 = try client().http2()
        let whole = try h2.get("/text", headers: gzipOnly)
        #expect(whole.header("content-encoding") == "gzip")
        #expect(whole.header("content-length") == "\(whole.body.count)")
        #expect(gunzip(whole.body) == text)
        let pieces = try h2.get("/pieces", headers: gzipOnly)
        #expect(pieces.ended)
        #expect(pieces.header("content-encoding") == "gzip")
        #expect(pieces.header("content-length") == nil)
        #expect(gunzip(pieces.body) == text)
    }
}

private struct Event: Codable {
    var name: String
    var count: Int
}

@Suite("Request decompression", .enabled(if: gzipUsable, "no gzip: Vega has no zlib on Windows"))
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
        }
        app.post("/plain") { request, response in response.send("\(request.body.count)") }
        return app
    }

    @Test(arguments: [ContentCoding.gzip, .br, .zstd])
    func aCompressedBodyReachesTheHandlerDecoded(coding: ContentCoding) throws {
        guard codingUsable(coding), RequestDecoder.codec("\(coding.token)") != nil else { return }
        let plain = Array(String(repeating: "garuda ", count: 500).utf8)
        let body = compress(plain, coding)
        #expect(!body.isEmpty && body.count < plain.count)
        let client = app().test
        let echoed = try client.post("/in/echo", body: body, headers: [("content-encoding", "\(coding.token)")])
        #expect(echoed.status == .ok)
        #expect(echoed.body == plain)

        let events = compress(Array(#"[{"name":"a","count":2},{"name":"b","count":40}]"#.utf8), coding)
        #expect(try client.post("/in/events", body: events,
                                headers: [("content-encoding", "\(coding.token)"),
                                          ("content-type", "application/json")]).text == "42")
        // Over HTTP/2 too.
        let h2 = try client.http2()
        #expect(try h2.post("/in/echo", body: body, headers: [("content-encoding", "\(coding.token)")]).body == plain)
    }

    @Test func codingsStackAndIdentityIsNone() throws {
        let plain = Array("stacked twice".utf8)
        let twice = compress(compress(plain, .gzip), .gzip)
        let client = app().test
        #expect(try client.post("/in/echo", body: twice, headers: [("content-encoding", "gzip, gzip")]).body == plain)
        #expect(try client.post("/in/echo", body: plain, headers: [("content-encoding", "identity")]).body == plain)
        #expect(try client.post("/in/echo", body: plain).body == plain)
        // Deflate, as the zlib format RFC 9110 means by it.
        #expect(try client.post("/in/echo", body: [0x78, 0x9C, 0x4B, 0x4C, 0x4A, 0x06, 0x00, 0x02, 0x4D, 0x01, 0x27],
                                headers: [("content-encoding", "deflate")]).text == "abc")
    }

    @Test func whatCannotBeDecodedIsRefused() throws {
        let client = app().test
        let unknown = try client.post("/in/echo", body: Array("x".utf8), headers: [("content-encoding", "compress")])
        #expect(unknown.status == .unsupportedMediaType)
        #expect(unknown.header("accept-encoding")?.contains("gzip") == true)
        let broken = try client.post("/in/echo", body: Array("not gzip at all".utf8),
                                     headers: [("content-encoding", "gzip")])
        #expect(broken.status == .badRequest)
        var truncated = compress(Array(String(repeating: "cut ", count: 100).utf8), .gzip)
        truncated.removeLast(12)
        #expect(try client.post("/in/echo", body: truncated, headers: [("content-encoding", "gzip")]).status == .badRequest)
    }

    @Test func theDecodedBodyIsHeldToTheRouteLimit() throws {
        let bomb = compress([UInt8](repeating: 0, count: 50_000), .gzip)
        #expect(bomb.count < 2000)
        let client = app().test
        #expect(try client.post("/in/small", body: bomb, headers: [("content-encoding", "gzip")]).status
                == .contentTooLarge)
        let fits = compress([UInt8](repeating: 0, count: 1500), .gzip)
        #expect(try client.post("/in/small", body: fits, headers: [("content-encoding", "gzip")]).text == "1500")

        var config = ServerConfig()
        config.maxBodySize = 10_000
        #expect(try app().testClient(configuration: config)
            .post("/in/echo", body: bomb, headers: [("content-encoding", "gzip")]).status == .contentTooLarge)
    }

    @Test func outsideTheScopeTheBodyIsLeftAsItCame() throws {
        let body = compress(Array("left alone".utf8), .gzip)
        #expect(try app().test.post("/plain", body: body, headers: [("content-encoding", "gzip")]).text
                == "\(body.count)")
    }
}
