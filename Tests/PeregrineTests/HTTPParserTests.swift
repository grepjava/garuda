import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

/// Parses `text` and hands the result to `body`, with the header table and the
/// raw bytes kept alive for the duration.
@discardableResult
private func parse(_ text: String,
                   maxHeadSize: Int = 32 * 1024,
                   maxHeaders: Int = 100,
                   _ body: (HTTPParseResult, HTTPRequestHead, UnsafePointer<UInt8>,
                            UnsafeMutablePointer<HTTPHeaderRef>) -> Void = { _, _, _, _ in }
) -> HTTPParseResult {
    var bytes = Array(text.utf8)
    let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: maxHeaders)
    defer { headers.deallocate() }
    var head = HTTPRequestHead()
    return bytes.withUnsafeMutableBufferPointer { buf -> HTTPParseResult in
        let base = UnsafePointer(buf.baseAddress!)
        let result = HTTPParser.parse(base, buf.count,
                                      maxHeadSize: maxHeadSize,
                                      maxHeaders: maxHeaders,
                                      headers: headers,
                                      head: &head)
        body(result, head, base, headers)
        return result
    }
}

private func string(_ slice: HTTPSlice, _ base: UnsafePointer<UInt8>) -> String {
    String(decoding: UnsafeBufferPointer(start: base + Int(slice.offset), count: slice.count),
           as: UTF8.self)
}

private func isFailure(_ r: HTTPParseResult, _ expected: HTTPParseError) -> Bool {
    if case .failure(let e) = r { return e == expected }
    return false
}

@Suite("HTTP request parsing")
struct HTTPParserTests {

    @Test("a minimal GET is parsed into method, path and version")
    func minimalGet() {
        parse("GET /hello HTTP/1.1\r\nHost: example.com\r\n\r\n") { result, head, base, _ in
            #expect(result == .complete)
            #expect(head.method == .get)
            #expect(string(head.path, base) == "/hello")
            #expect(head.query.isEmpty)
            #expect(head.httpMinor == 1)
            #expect(head.headerCount == 1)
            #expect(head.isKeepAlive)
            #expect(head.contentLength == 0)
            // 19 + 2 + 17 + 2 + 2
            #expect(head.headEnd == 42)
        }
    }

    @Test("the query string is split from the path without decoding either")
    func querySplit() {
        parse("GET /search?q=a%20b&n=2 HTTP/1.1\r\nHost: x\r\n\r\n") { _, head, base, _ in
            #expect(string(head.path, base) == "/search")
            #expect(string(head.query, base) == "q=a%20b&n=2")
            #expect(string(head.target, base) == "/search?q=a%20b&n=2")
            #expect(head.flags.contains(.escapedPath) == false)
        }
    }

    @Test("a percent escape in the path is flagged so decoding runs only when needed")
    func escapedPathFlag() {
        parse("GET /a%2Fb HTTP/1.1\r\nHost: x\r\n\r\n") { _, head, _, _ in
            #expect(head.flags.contains(.escapedPath))
        }
    }

    @Test("headers keep their order, name and trimmed value")
    func headerCapture() {
        parse("GET / HTTP/1.1\r\nHost: x\r\nA:   1   \r\nB:2\r\n\r\n") { _, head, base, headers in
            #expect(head.headerCount == 3)
            #expect(string(headers[1].name, base) == "A")
            #expect(string(headers[1].value, base) == "1")
            #expect(string(headers[2].name, base) == "B")
            #expect(string(headers[2].value, base) == "2")
        }
    }

    @Test("Content-Length is recorded and framing is set")
    func contentLength() {
        parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 42\r\n\r\n") { _, head, _, _ in
            #expect(head.contentLength == 42)
            #expect(head.hasBody)
            #expect(head.isChunked == false)
        }
    }

    @Test("chunked transfer encoding is recognised")
    func chunkedFraming() {
        parse("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n") { _, head, _, _ in
            #expect(head.isChunked)
            #expect(head.contentLength == -1)
            #expect(head.hasBody)
        }
    }

    @Test("HTTP/1.1 keeps alive by default, HTTP/1.0 does not")
    func keepAliveDefaults() {
        parse("GET / HTTP/1.1\r\nHost: x\r\n\r\n") { _, h, _, _ in #expect(h.isKeepAlive) }
        parse("GET / HTTP/1.0\r\n\r\n") { _, h, _, _ in #expect(!h.isKeepAlive) }
        parse("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n") { _, h, _, _ in
            #expect(h.isKeepAlive)
        }
        parse("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n") { _, h, _, _ in
            #expect(!h.isKeepAlive)
        }
    }

    @Test("Connection is matched as a whole token, not a substring")
    func connectionTokenMatching() {
        // "close" must not be found inside "closely-related".
        parse("GET / HTTP/1.1\r\nHost: x\r\nConnection: closely-related\r\n\r\n") { _, h, _, _ in
            #expect(h.isKeepAlive)
        }
        parse("GET / HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, close\r\n\r\n") { _, h, _, _ in
            #expect(!h.isKeepAlive)
        }
    }

    @Test("Expect: 100-continue is detected")
    func expectContinue() {
        parse("POST / HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 1\r\n\r\n") {
            _, head, _, _ in
            #expect(head.flags.contains(.expectContinue))
        }
    }

    @Test("an incomplete head asks for more bytes rather than failing")
    func incomplete() {
        #expect(parse("GET / HTTP/1.1\r\nHost: exa") == .incomplete)
        #expect(parse("GET / HTTP/1.1\r\nHost: x\r\n") == .incomplete)
        #expect(parse("GE") == .incomplete)
    }

    // MARK: - Hardening

    @Test("whitespace before the colon is rejected (proxy desync vector)")
    func spaceBeforeColon() {
        #expect(isFailure(parse("GET / HTTP/1.1\r\nHost: x\r\nFoo : bar\r\n\r\n"), .badHeader))
    }

    @Test("Content-Length together with Transfer-Encoding is rejected")
    func smugglingCLAndTE() {
        let r = parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n")
        #expect(isFailure(r, .conflictingFraming))
    }

    @Test("two disagreeing Content-Length values are rejected")
    func smugglingDoubleCL() {
        let r = parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n")
        #expect(isFailure(r, .conflictingFraming))
    }

    @Test("repeated but identical Content-Length is accepted")
    func repeatedIdenticalCL() {
        parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\n") {
            r, head, _, _ in
            #expect(r == .complete)
            #expect(head.contentLength == 5)
        }
    }

    @Test("an unknown transfer coding is refused rather than guessed at")
    func unknownTransferEncoding() {
        let r = parse("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n")
        #expect(isFailure(r, .unsupportedTransferEncoding))
    }

    @Test("obs-fold continuation lines are rejected, not unfolded")
    func obsFold() {
        #expect(isFailure(parse("GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\n  continued\r\n\r\n"),
                          .badHeader))
    }

    @Test("HTTP/1.1 without a Host header is a bad request")
    func missingHost() {
        #expect(isFailure(parse("GET / HTTP/1.1\r\n\r\n"), .badRequestLine))
    }

    @Test("a non-numeric Content-Length is rejected")
    func badContentLength() {
        #expect(isFailure(parse("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1a\r\n\r\n"),
                          .badHeader))
    }

    @Test("an unsupported version is refused")
    func badVersion() {
        #expect(isFailure(parse("GET / HTTP/2.0\r\nHost: x\r\n\r\n"), .badVersion))
        #expect(isFailure(parse("GET / HTTP/1.9\r\nHost: x\r\n\r\n"), .badVersion))
    }

    @Test("more headers than the limit is refused")
    func tooManyHeaders() {
        var text = "GET / HTTP/1.1\r\nHost: x\r\n"
        for i in 0..<20 { text += "X-\(i): v\r\n" }
        text += "\r\n"
        #expect(isFailure(parse(text, maxHeaders: 8), .tooManyHeaders))
    }

    @Test("a control character in a header value is refused")
    func controlCharacterInValue() {
        #expect(isFailure(parse("GET / HTTP/1.1\r\nHost: x\r\nA: b\u{0}c\r\n\r\n"), .badHeader))
    }

    @Test("leading empty lines before the request line are tolerated")
    func leadingCRLF() {
        parse("\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\n") { r, head, base, _ in
            #expect(r == .complete)
            #expect(string(head.path, base) == "/")
        }
    }

    @Test("headEnd points exactly past the terminating CRLF so pipelining works")
    func headEndBoundary() {
        let text = "GET /a HTTP/1.1\r\nHost: x\r\n\r\nGET /b HTTP/1.1\r\nHost: x\r\n\r\n"
        parse(text) { r, head, _, _ in
            #expect(r == .complete)
            #expect(head.headEnd == 28)
        }
    }

    @Test("all standard methods are classified")
    func methods() {
        let expected: [(String, HTTPMethod)] = [
            ("GET", .get), ("HEAD", .head), ("POST", .post), ("PUT", .put),
            ("DELETE", .delete), ("PATCH", .patch), ("OPTIONS", .options),
            ("CONNECT", .connect), ("TRACE", .trace), ("PROPFIND", .other),
        ]
        for (name, want) in expected {
            parse("\(name) / HTTP/1.1\r\nHost: x\r\n\r\n") { _, head, _, _ in
                #expect(head.method == want, "\(name)")
            }
        }
    }
}

extension HTTPParseResult: Equatable {
    public static func == (a: HTTPParseResult, b: HTTPParseResult) -> Bool {
        switch (a, b) {
        case (.incomplete, .incomplete), (.complete, .complete): return true
        case (.failure(let x), .failure(let y)): return x == y
        default: return false
        }
    }
}
