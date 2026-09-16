import Testing
@testable import GarudaCore
@testable import GarudaHTTP

// Tests for the request writer. Most of these are about what it refuses: a
// request line or a field that could carry a CR or an LF onto the wire is a
// second request the caller never wrote, and on a pooled connection that is
// somebody else's answer arriving in the middle of this exchange.

/// Runs `body` against a fresh buffer and returns what ended up in it,
/// together with whatever `body` returned.
private func written<T>(_ body: (inout ByteBuffer) -> T) -> (T, String) {
    var buf = ByteBuffer(capacity: 256)
    defer { buf.destroy() }
    let outcome = body(&buf)
    let text = String(decoding: UnsafeBufferPointer(start: buf.readPointer,
                                                    count: buf.readableBytes), as: UTF8.self)
    return (outcome, text)
}

/// Calls `body` with `text` as a span.
private func span<T>(_ text: String, _ body: (ByteSpan) -> T) -> T {
    let bytes = Array(text.utf8)
    return bytes.withUnsafeBufferPointer { body(ByteSpan($0.baseAddress!, $0.count)) }
}

/// Calls `body` with two spans, which is what a header takes.
private func spans<T>(_ a: String, _ b: String, _ body: (ByteSpan, ByteSpan) -> T) -> T {
    let ab = Array(a.utf8)
    let bb = Array(b.utf8)
    return ab.withUnsafeBufferPointer { ap in
        bb.withUnsafeBufferPointer { bp in
            body(ByteSpan(ap.baseAddress!, ap.count), ByteSpan(bp.baseAddress!, bp.count))
        }
    }
}

private func requestLine(_ method: String, _ target: String) -> (Bool, String) {
    written { buf in
        spans(method, target) { m, t in
            HTTPRequestWriter.writeRequestLine(&buf, method: m, target: t)
        }
    }
}

private func host(_ authority: String) -> (Bool, String) {
    written { buf in span(authority) { HTTPRequestWriter.writeHost(&buf, $0) } }
}

private func userHeader(_ name: String, _ value: String) -> (Bool, String) {
    written { buf in
        spans(name, value) { n, v in
            HTTPRequestWriter.writeUserHeader(&buf, name: n, value: v)
        }
    }
}

private func classify(_ name: String) -> RequestHeaderKind {
    span(name) { HTTPRequestWriter.classify($0) }
}

@Suite("HTTP/1.1 request writing")
struct HTTPRequestWriterTests {

    // MARK: The request line

    @Test func anOrdinaryRequestLineIsWritten() {
        let (ok, text) = requestLine("GET", "/index.html")
        #expect(ok)
        #expect(text == "GET /index.html HTTP/1.1\r\n")
    }

    @Test func aTargetKeepsItsQueryAndItsEscapes() {
        let (ok, text) = requestLine("GET", "/search?q=a%20b&n=1")
        #expect(ok)
        #expect(text == "GET /search?q=a%20b&n=1 HTTP/1.1\r\n")
    }

    @Test func everyKnownMethodHasATokenAndWritesItself() {
        let expected: [(HTTPMethod, String)] = [
            (.get, "GET"), (.head, "HEAD"), (.post, "POST"), (.put, "PUT"),
            (.delete, "DELETE"), (.patch, "PATCH"), (.options, "OPTIONS"),
            (.connect, "CONNECT"), (.trace, "TRACE"),
        ]
        for (method, token) in expected {
            let (ok, text) = written { buf in
                span("/") { HTTPRequestWriter.writeRequestLine(&buf, method: method, target: $0) }
            }
            #expect(ok)
            #expect(text == "\(token) / HTTP/1.1\r\n")
        }
    }

    @Test func theMethodWithoutANameIsRefusedRatherThanGuessedAt() {
        let (ok, text) = written { buf in
            span("/") { HTTPRequestWriter.writeRequestLine(&buf, method: .other, target: $0) }
        }
        #expect(!ok)
        #expect(text.isEmpty)
    }

    // MARK: Request-line injection -- guard W1, the method

    @Test func aMethodWithASpaceIsRefused() {
        let (ok, text) = requestLine("GE T", "/")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aMethodCarryingAWholeSecondRequestIsRefused() {
        let (ok, text) = requestLine("GET / HTTP/1.1\r\nHost: evil\r\n\r\nGET", "/")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func anEmptyMethodIsRefused() {
        let (ok, _) = requestLine("", "/")
        #expect(!ok)
    }

    // MARK: Request-line injection -- guard W2, the target

    @Test func aTargetWithASpaceIsRefused() {
        // The commonest form of this: a path built from unescaped user input
        // acquires a space long before it acquires a newline, and a space ends
        // the target as surely as a CR does -- everything after it is read as
        // the version.
        let (ok, text) = requestLine("GET", "/files/my report.pdf")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aTargetCarryingASecondRequestIsRefused() {
        let (ok, text) = requestLine("GET", "/x HTTP/1.1\r\nHost: evil\r\n\r\nGET /y")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aTargetWithABareCarriageReturnIsRefused() {
        let (ok, _) = requestLine("GET", "/x\rHost: evil")
        #expect(!ok)
    }

    @Test func aTargetWithABareLineFeedIsRefused() {
        let (ok, _) = requestLine("GET", "/x\nHost: evil")
        #expect(!ok)
    }

    @Test func aTargetWithANulIsRefused() {
        let (ok, _) = requestLine("GET", "/x\u{0}y")
        #expect(!ok)
    }

    @Test func aTargetWithATabIsRefused() {
        let (ok, _) = requestLine("GET", "/x\ty")
        #expect(!ok)
    }

    @Test func aTargetWithHighBytesIsRefused() {
        // Non-ASCII must be percent-encoded before it gets here. Passing it
        // through would leave whoever is ahead to guess an encoding.
        let (ok, _) = requestLine("GET", "/caf\u{e9}")
        #expect(!ok)
    }

    @Test func anEmptyTargetIsRefused() {
        let (ok, _) = requestLine("GET", "")
        #expect(!ok)
    }

    // MARK: Host -- guard W5

    @Test func aHostIsWritten() {
        let (ok, text) = host("example.com")
        #expect(ok)
        #expect(text == "Host: example.com\r\n")
    }

    @Test func aHostKeepsANonDefaultPort() {
        let (ok, text) = host("example.com:8443")
        #expect(ok)
        #expect(text == "Host: example.com:8443\r\n")
    }

    @Test func aHostCarryingASecondFieldIsRefused() {
        let (ok, text) = host("example.com\r\nX-Admin: 1")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aHostWithASpaceIsRefused() {
        let (ok, _) = host("example.com evil.com")
        #expect(!ok)
    }

    @Test func anEmptyHostIsRefused() {
        let (ok, _) = host("")
        #expect(!ok)
    }

    // MARK: Fields this writer owns -- guard W4

    @Test func aCallerSuppliedHostIsRefused() {
        // Two Host fields is the host-desync attack, which the parser next
        // door refuses on the way in even when the two agree.
        let (ok, text) = userHeader("Host", "evil.com")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aCallerSuppliedContentLengthIsRefused() {
        let (ok, text) = userHeader("Content-Length", "0")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aCallerSuppliedTransferEncodingIsRefused() {
        let (ok, _) = userHeader("Transfer-Encoding", "chunked")
        #expect(!ok)
    }

    @Test func aCallerSuppliedConnectionIsRefused() {
        let (ok, _) = userHeader("Connection", "close")
        #expect(!ok)
    }

    @Test func aManagedFieldIsRefusedWhateverItsCase() {
        // Field names are case-insensitive, so a check that only caught the
        // lowercase spelling would be no check at all.
        for name in ["host", "HOST", "HoSt", "content-length", "CONTENT-LENGTH",
                     "transfer-encoding", "Transfer-Encoding", "CONNECTION"] {
            let (ok, text) = userHeader(name, "x")
            #expect(!ok, "\(name) should be refused")
            #expect(text.isEmpty)
        }
    }

    // MARK: Fields a caller may set

    @Test func anOrdinaryFieldIsWritten() {
        let (ok, text) = userHeader("Accept", "application/json")
        #expect(ok)
        #expect(text == "Accept: application/json\r\n")
    }

    @Test func aCallerMaySetItsOwnUserAgent() {
        // Recognised so the client knows not to add a default, not refused:
        // it decides nothing about framing.
        let (ok, text) = userHeader("User-Agent", "mine/1.0")
        #expect(ok)
        #expect(text == "User-Agent: mine/1.0\r\n")
    }

    @Test func aFieldValueCarryingASecondFieldIsRefused() {
        let (ok, text) = userHeader("X-Token", "abc\r\nX-Admin: 1")
        #expect(!ok)
        #expect(text.isEmpty)
    }

    @Test func aFieldNameThatIsNotATokenIsRefused() {
        let (ok, _) = userHeader("X Token", "abc")
        #expect(!ok)
    }

    // MARK: Classification

    @Test func theManagedFieldsAreTheOnesThisWriterEmits() {
        #expect(classify("Host") == .host)
        #expect(classify("Content-Length") == .contentLength)
        #expect(classify("Transfer-Encoding") == .transferEncoding)
        #expect(classify("Connection") == .connection)
        for kind in [RequestHeaderKind.host, .contentLength, .transferEncoding, .connection] {
            #expect(RequestHeaderKind.managed.contains(kind))
        }
    }

    @Test func theFieldsTheClientOnlyNeedsToKnowAboutAreNotManaged() {
        #expect(classify("User-Agent") == .userAgent)
        #expect(classify("Accept-Encoding") == .acceptEncoding)
        #expect(classify("Expect") == .expect)
        for kind in [RequestHeaderKind.userAgent, .acceptEncoding, .expect] {
            #expect(!RequestHeaderKind.managed.contains(kind))
        }
    }

    @Test func anUnrecognisedFieldClassifiesAsNothing() {
        #expect(classify("Accept") == [])
        #expect(classify("X-Request-ID") == [])
        // Same length as a managed name, different name: a check on length
        // alone would call this Content-Length.
        #expect(classify("Content-Digest") == [])
        #expect(classify("Xost") == [])
    }

    // MARK: A whole head

    @Test func aCompleteRequestHeadGoesOutInOrder() {
        var buf = ByteBuffer(capacity: 512)
        defer { buf.destroy() }
        _ = spans("POST", "/submit") { m, target in
            HTTPRequestWriter.writeRequestLine(&buf, method: m, target: target)
        }
        _ = span("example.com") { HTTPRequestWriter.writeHost(&buf, $0) }
        _ = spans("Content-Type", "application/json") { n, v in
            HTTPRequestWriter.writeUserHeader(&buf, name: n, value: v)
        }
        HTTPRequestWriter.writeContentLength(&buf, 2)
        HTTPRequestWriter.writeConnection(&buf, keepAlive: true)
        HTTPRequestWriter.endHead(&buf)
        buf.write("{}")
        let text = String(decoding: UnsafeBufferPointer(start: buf.readPointer,
                                                        count: buf.readableBytes), as: UTF8.self)
        #expect(text == "POST /submit HTTP/1.1\r\n"
            + "Host: example.com\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: 2\r\n"
            + "Connection: keep-alive\r\n"
            + "\r\n{}")
    }

    @Test func aChunkedBodyIsFramed() {
        var buf = ByteBuffer(capacity: 256)
        defer { buf.destroy() }
        HTTPRequestWriter.writeChunkedEncoding(&buf)
        HTTPRequestWriter.endHead(&buf)
        let body = Array("hello".utf8)
        body.withUnsafeBufferPointer {
            HTTPRequestWriter.writeChunk(&buf, $0.baseAddress!, $0.count)
        }
        HTTPRequestWriter.writeLastChunk(&buf)
        let text = String(decoding: UnsafeBufferPointer(start: buf.readPointer,
                                                        count: buf.readableBytes), as: UTF8.self)
        #expect(text == "Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
    }

    @Test func connectionCloseIsSaidOutLoud() {
        var buf = ByteBuffer(capacity: 64)
        defer { buf.destroy() }
        HTTPRequestWriter.writeConnection(&buf, keepAlive: false)
        let text = String(decoding: UnsafeBufferPointer(start: buf.readPointer,
                                                        count: buf.readableBytes), as: UTF8.self)
        #expect(text == "Connection: close\r\n")
    }

    // MARK: What a refusal leaves behind

    @Test func aRefusedRequestLineLeavesNothingHalfWritten() {
        // A writer that emitted the method and then refused the target would
        // leave a buffer holding the start of a request the caller believes
        // was never written -- and the next thing written would continue it.
        var buf = ByteBuffer(capacity: 256)
        defer { buf.destroy() }
        let ok = spans("POST", "/x y") { m, t in
            HTTPRequestWriter.writeRequestLine(&buf, method: m, target: t)
        }
        #expect(!ok)
        #expect(buf.readableBytes == 0)
    }

    @Test func aRefusalDoesNotDisturbWhatWasAlreadyThere() {
        var buf = ByteBuffer(capacity: 256)
        defer { buf.destroy() }
        _ = spans("GET", "/") { m, t in
            HTTPRequestWriter.writeRequestLine(&buf, method: m, target: t)
        }
        let before = buf.readableBytes
        _ = spans("X-Token", "a\r\nX-Admin: 1") { n, v in
            HTTPRequestWriter.writeUserHeader(&buf, name: n, value: v)
        }
        #expect(buf.readableBytes == before)
    }
}
