import Testing
import CAvian
import AvianCore
import AvianHTTP
@testable import Garuda

// The HTTP client around one exchange: redirects its policy allows, and
// bodies it decodes. The exchange itself is HTTPClientTests'.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var urlWanted = ""
nonisolated(unsafe) private var methodWanted = HTTPMethod.get
nonisolated(unsafe) private var headersWanted: [(String, String)] = []
nonisolated(unsafe) private var bodyWanted: [UInt8] = []
nonisolated(unsafe) private var policyWanted = RedirectPolicy.none
nonisolated(unsafe) private var decompressWanted = true
nonisolated(unsafe) private var bodyLimitWanted = 8 * 1024 * 1024

/// An origin that answers each request with the next scripted response.
private final class Origin {
    let fd: Int32
    let port: UInt16
    private(set) var received: [String] = []
    var script: [[UInt8]] = []
    private var open: [Int32] = []
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

    func pump() {
        var address = [CChar](repeating: 0, count: 64)
        var peerPort: UInt16 = 0
        let peer = av_accept(fd, &address, 64, &peerPort)
        if peer >= 0 { open.append(peer) }
        for peer in open {
            var buffer = [UInt8](repeating: 0, count: 65536)
            let got = buffer.withUnsafeMutableBytes { av_read(peer, $0.baseAddress, $0.count) }
            guard got > 0 else { continue }
            received.append(String(decoding: buffer.prefix(got), as: UTF8.self))
            guard served < script.count else { continue }
            let payload = script[served]
            served += 1
            _ = payload.withUnsafeBytes { av_write(peer, $0.baseAddress, $0.count) }
        }
    }
}

private func app() -> Application {
    let app = Application()
    app.onAsync(.get, "/go") { request, response in
        var client = request.client
        client.redirects = policyWanted
        client.decompress = decompressWanted
        client.maxBodyBytes = bodyLimitWanted
        do {
            let answer = try await client.send(methodWanted, urlWanted, headers: headersWanted, body: bodyWanted)
            outcome = "\(answer.status)|\(answer.text)|\(answer.url)|\(answer.header("content-encoding") ?? "-")"
        } catch {
            outcome = "\(error)"
        }
        response.send(outcome)
    }
    return app
}

private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

private func gzip(_ input: [UInt8]) -> [UInt8] {
    let encoder = av_enc_new(Int32(ContentCoding.gzip.rawValue))!
    defer { av_enc_free(encoder) }
    var output: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    var offset = 0
    while true {
        var consumed = 0
        var produced = 0
        let rc = input.withUnsafeBufferPointer { i in
            chunk.withUnsafeMutableBufferPointer { o in
                av_enc_run(encoder, i.baseAddress.map { $0 + offset }, i.count - offset, AV_ENC_FINISH,
                           o.baseAddress, o.count, &consumed, &produced)
            }
        }
        offset += consumed
        output += chunk[0..<produced]
        if rc == 0 { return output }
    }
}

private func response(_ status: String, _ headers: [String] = [], body: [UInt8] = []) -> [UInt8] {
    var head = "HTTP/1.1 \(status)\r\n"
    for header in headers { head += header + "\r\n" }
    head += "Content-Length: \(body.count)\r\n\r\n"
    return bytes(head) + body
}

@Suite("HTTP client redirects and decoding", .serialized)
struct HTTPClientRedirectTests {

    private func run(_ origins: [Origin], path: String = "/start") throws -> String {
        outcome = ""
        urlWanted = origins[0].url + path
        let client = app().test
        let wire = try TestWire(client)
        wire.send("GET /go HTTP/1.1\r\nHost: test\r\n\r\n")
        _ = wire.turn(until: {
            for origin in origins { origin.pump() }
            return !outcome.isEmpty
        }, turns: 20_000)
        _ = wire.receive()
        return outcome
    }

    private func reset() {
        outcome = ""
        methodWanted = .get
        headersWanted = []
        bodyWanted = []
        policyWanted = .none
        decompressWanted = true
        bodyLimitWanted = 8 * 1024 * 1024
    }

    // MARK: Decoding

    @Test func aGzipBodyIsDecodedAndItsCodingHeadersRemoved() throws {
        reset()
        guard let origin = Origin() else { Issue.record("no socket"); return }
        let text = String(repeating: "decoded ", count: 200)
        origin.script = [response("200 OK", ["Content-Encoding: gzip"], body: gzip(bytes(text)))]
        #expect(try run([origin]) == "200|\(text)|\(origin.url)/start|-")
        #expect(origin.received.joined().contains("Accept-Encoding: \(ContentDecoder.acceptEncoding)\r\n"))
    }

    @Test func aCorruptBodyOrOneThatInflatesTooFarIsRefused() throws {
        reset()
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("200 OK", ["Content-Encoding: gzip"], body: bytes("not gzip at all"))]
        #expect(try run([origin]) == "undecodableBody")

        reset()
        bodyLimitWanted = 4096
        guard let bombing = Origin() else { Issue.record("no socket"); return }
        bombing.script = [response("200 OK", ["Content-Encoding: gzip"],
                                   body: gzip([UInt8](repeating: 0, count: 1 << 20)))]
        #expect(try run([bombing]) == "bodyTooLarge")
    }

    @Test func aCodingThatCannotBeDecodedIsLeftAsItCame() throws {
        reset()
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("200 OK", ["Content-Encoding: compress"], body: bytes("raw"))]
        #expect(try run([origin]) == "200|raw|\(origin.url)/start|compress")
    }

    @Test func withDecompressOffTheCallerAsksAndReadsForItself() throws {
        reset()
        decompressWanted = false
        headersWanted = [("Accept-Encoding", "gzip")]
        guard let origin = Origin() else { Issue.record("no socket"); return }
        let packed = gzip(bytes("hello"))
        origin.script = [response("200 OK", ["Content-Encoding: gzip"], body: packed)]
        let result = try run([origin])
        #expect(result.hasPrefix("200|"))
        #expect(result.hasSuffix("|gzip"))
        let sent = origin.received.joined()
        #expect(sent.contains("Accept-Encoding: gzip\r\n"))
        #expect(!sent.contains(ContentDecoder.acceptEncoding + "\r\n") || ContentDecoder.acceptEncoding == "gzip")
    }

    @Test func aCallersAcceptEncodingIsRefusedWhileTheClientDecodes() throws {
        reset()
        headersWanted = [("Accept-Encoding", "gzip")]
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("200 OK")]
        #expect(try run([origin]) == "refusedHeader")
    }

    // MARK: Redirects

    @Test func aRedirectIsTheResponseUnlessThePolicyFollowsIt() throws {
        reset()
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("302 Found", ["Location: /next"])]
        #expect(try run([origin]) == "302||\(origin.url)/start|-")
        #expect(origin.received.count == 1)
    }

    @Test func aSameOriginRedirectIsFollowedToWhereItLeads() throws {
        reset()
        policyWanted = .sameOrigin()
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("301 Moved Permanently", ["Location: ../b/c?x=1#frag"]),
                         response("308 Permanent Redirect", ["Location: \(origin.url)/final"]),
                         response("200 OK", body: bytes("arrived"))]
        #expect(try run([origin], path: "/a/start") == "200|arrived|\(origin.url)/final|-")
        #expect(origin.received.count == 3)
        #expect(origin.received[1].hasPrefix("GET /b/c?x=1 HTTP/1.1\r\n"))
        #expect(origin.received[2].hasPrefix("GET /final HTTP/1.1\r\n"))
    }

    @Test func a303TurnsAPostIntoAGetWithoutItsBody() throws {
        reset()
        policyWanted = .sameOrigin()
        methodWanted = .post
        bodyWanted = bytes("payload")
        headersWanted = [("Content-Type", "text/plain")]
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("303 See Other", ["Location: /result"]),
                         response("200 OK", body: bytes("done"))]
        #expect(try run([origin]) == "200|done|\(origin.url)/result|-")
        #expect(origin.received[0].hasPrefix("POST /start HTTP/1.1\r\n"))
        let second = origin.received[1]
        #expect(second.hasPrefix("GET /result HTTP/1.1\r\n"))
        #expect(!second.contains("payload"))
        #expect(!second.contains("Content-Type"))
    }

    @Test func a307RepeatsThePostAsItWas() throws {
        reset()
        policyWanted = .sameOrigin()
        methodWanted = .post
        bodyWanted = bytes("payload")
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = [response("307 Temporary Redirect", ["Location: /again"]),
                         response("201 Created")]
        #expect(try run([origin]).hasPrefix("201|"))
        #expect(origin.received.contains { $0.hasPrefix("POST /again HTTP/1.1\r\n") })
        #expect(origin.received.joined().hasSuffix("payload"))
    }

    @Test func tooManyRedirectsIsAnError() throws {
        reset()
        policyWanted = .sameOrigin(limit: 2)
        guard let origin = Origin() else { Issue.record("no socket"); return }
        origin.script = Array(repeating: response("302 Found", ["Location: /loop"]), count: 5)
        #expect(try run([origin]) == "tooManyRedirects")
        #expect(origin.received.count == 3)
    }

    @Test func leavingTheOriginNeedsAPolicyThatAllowsItAndDropsCredentials() throws {
        reset()
        policyWanted = .sameOrigin()
        headersWanted = [("Authorization", "Bearer secret"), ("X-Keep", "yes")]
        guard let first = Origin(), let second = Origin() else { Issue.record("no socket"); return }
        first.script = [response("302 Found", ["Location: \(second.url)/elsewhere"])]
        #expect(try run([first, second]).hasPrefix("302|"))
        #expect(second.received.isEmpty)

        reset()
        policyWanted = .any()
        headersWanted = [("Authorization", "Bearer secret"), ("X-Keep", "yes")]
        guard let third = Origin(), let fourth = Origin() else { Issue.record("no socket"); return }
        third.script = [response("302 Found", ["Location: \(fourth.url)/elsewhere"])]
        fourth.script = [response("200 OK", body: bytes("over there"))]
        #expect(try run([third, fourth]) == "200|over there|\(fourth.url)/elsewhere|-")
        #expect(third.received[0].contains("Authorization: Bearer secret"))
        #expect(!fourth.received.joined().contains("Authorization"))
        #expect(fourth.received.joined().contains("X-Keep: yes"))

        reset()
        policyWanted = .matching { $0.hasSuffix("/allowed") }
        guard let fifth = Origin(), let sixth = Origin() else { Issue.record("no socket"); return }
        fifth.script = [response("302 Found", ["Location: \(sixth.url)/refused"])]
        #expect(try run([fifth, sixth]).hasPrefix("302|"))
    }

    // MARK: References

    @Test func locationsResolveAgainstTheURLAsked() {
        let base = "http://example.com:8080/a/b/c?q=1"
        #expect(resolveReference("/x", against: base) == "http://example.com:8080/x")
        #expect(resolveReference("d", against: base) == "http://example.com:8080/a/b/d")
        #expect(resolveReference("../d?e=f", against: base) == "http://example.com:8080/a/d?e=f")
        #expect(resolveReference("./", against: base) == "http://example.com:8080/a/b/")
        #expect(resolveReference("../../../../x", against: base) == "http://example.com:8080/x")
        #expect(resolveReference("?z=2", against: base) == "http://example.com:8080/a/b/c?z=2")
        #expect(resolveReference("//other.example/p", against: base) == "http://other.example/p")
        #expect(resolveReference("HTTPS://secure.example/p#frag", against: base) == "https://secure.example/p")
        #expect(resolveReference(" /spaced ", against: base) == "http://example.com:8080/spaced")
        #expect(resolveReference("ftp://files.example/", against: base) == nil)
        #expect(resolveReference("javascript:alert(1)", against: base) == nil)
        #expect(resolveReference("/x", against: "http://example.com") == "http://example.com/x")
        #expect(resolveReference("y", against: "http://example.com") == "http://example.com/y")
    }

    @Test func httpsIsNeverLeftForHTTP() {
        var client = HTTPClient(worker: UnsafeMutablePointer<Worker>(bitPattern: 1)!)
        client.redirects = .any()
        let redirect = ClientResponse(status: 302, reason: "", headers: [ClientHeader(name: "Location", value: "http://example.com/")],
                                      body: [], reusedConnection: false)
        #expect(client.redirect(redirect, from: "https://example.com/start") == nil)
        #expect(client.redirect(redirect, from: "http://example.org/start") == "http://example.com/")
    }
}
