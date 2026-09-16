import Testing
@testable import GarudaCore
@testable import GarudaHTTP

/// Parses `text` and hands back the outcome with the head and the fields.
private func parse(_ text: String, maxHeadSize: Int = 8192,
                   maxHeaders: Int = 64) -> (HTTPParseResult, HTTPResponseHead, [(String, String)]) {
    var head = HTTPResponseHead()
    var fields: [(String, String)] = []
    let bytes = Array(text.utf8)
    let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: max(1, maxHeaders))
    defer { headers.deallocate() }
    let result = bytes.withUnsafeBufferPointer { buffer -> HTTPParseResult in
        guard let base = buffer.baseAddress else { return .incomplete }
        let outcome = HTTPResponseParser.parse(base, buffer.count,
                                               maxHeadSize: maxHeadSize,
                                               maxHeaders: maxHeaders,
                                               headers: headers, head: &head)
        if case .complete = outcome {
            for i in 0..<head.headerCount {
                let name = String(decoding: UnsafeBufferPointer(
                    start: base + Int(headers[i].name.offset),
                    count: headers[i].name.count), as: UTF8.self)
                let value = String(decoding: UnsafeBufferPointer(
                    start: base + Int(headers[i].value.offset),
                    count: headers[i].value.count), as: UTF8.self)
                fields.append((name, value))
            }
        }
        return outcome
    }
    return (result, head, fields)
}

private func failure(_ text: String) -> HTTPParseError? {
    if case .failure(let error) = parse(text).0 { return error }
    return nil
}

private func isComplete(_ text: String) -> Bool {
    if case .complete = parse(text).0 { return true }
    return false
}

private func isIncomplete(_ text: String) -> Bool {
    if case .incomplete = parse(text).0 { return true }
    return false
}

@Suite("HTTP/1.1 response parsing")
struct HTTPResponseParserTests {

    // MARK: The status line

    @Test func anOrdinaryResponseIsRead() {
        let (result, head, fields) = parse(
            "HTTP/1.1 200 OK\r\ncontent-length: 5\r\nserver: nginx\r\n\r\n")
        #expect(result == .complete)
        #expect(head.status == 200)
        #expect(head.contentLength == 5)
        #expect(head.keepAlive)
        #expect(fields.count == 2)
        #expect(fields[0].0 == "content-length")
        #expect(fields[1] == ("server", "nginx"))
    }

    @Test func theReasonPhraseIsOptional() {
        let (result, head, _) = parse("HTTP/1.1 204\r\n\r\n")
        #expect(result == .complete)
        #expect(head.status == 204)
        #expect(head.reason.isEmpty)
    }

    @Test func aReasonPhraseMayHoldSpaces() {
        let (result, head, _) = parse("HTTP/1.1 404 Not Found Here\r\n\r\n")
        #expect(result == .complete)
        #expect(head.status == 404)
        #expect(head.reason.count == 14)
    }

    /// HTTP/1.0 does not keep a connection alive unless it says so, which is
    /// the opposite default from 1.1 and an easy thing to get backwards.
    @Test func versionOneZeroClosesByDefault() {
        let (result, head, _) = parse("HTTP/1.0 200 OK\r\n\r\n")
        #expect(result == .complete)
        #expect(head.httpMinor == 0)
        #expect(!head.keepAlive)
    }

    @Test func versionOneZeroKeepsAliveWhenAsked() {
        let (_, head, _) = parse("HTTP/1.0 200 OK\r\nconnection: keep-alive\r\n\r\n")
        #expect(head.keepAlive)
    }

    /// Exactly three digits. A four-digit code read as three leaves a stray
    /// digit at the front of the reason phrase and a status nobody sent.
    @Test func aFourDigitStatusIsRefused() {
        #expect(failure("HTTP/1.1 2000 OK\r\n\r\n") == .badStatusLine)
    }

    @Test func aNonNumericStatusIsRefused() {
        #expect(failure("HTTP/1.1 2x0 OK\r\n\r\n") == .badStatusLine)
    }

    @Test func aVersionThisIsNotIsRefused() {
        #expect(failure("HTTP/2.0 200 OK\r\n\r\n") == .badVersion)
        #expect(failure("ICY 200 OK\r\n\r\n") == .badVersion)
        #expect(failure("HTTP/1.1x 200 OK\r\n\r\n") == .badVersion)
    }

    @Test func aControlCharacterInTheReasonIsRefused() {
        #expect(failure("HTTP/1.1 200 O\u{0}K\r\n\r\n") == .badStatusLine)
    }

    // MARK: Arriving in pieces

    @Test func everyPrefixIsIncompleteRatherThanWrong() {
        let whole = "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\n"
        // A response arrives in as many reads as the network feels like, and a
        // parser that guessed at a prefix would frame the next one wrongly.
        for cut in 1..<whole.count {
            let prefix = String(whole.prefix(cut))
            #expect(isIncomplete(prefix), "prefix of \(cut) should be incomplete")
        }
        #expect(isComplete(whole))
    }

    // MARK: Framing, which is where a client desynchronises

    @Test func contentLengthFramesTheBody() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\ncontent-length: 42\r\n\r\n")
        #expect(head.framing(method: .get) == .length(42))
    }

    @Test func chunkedFramesTheBody() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        #expect(head.isChunked)
        #expect(head.framing(method: .get) == .chunked)
    }

    @Test func neitherMeansUntilTheConnectionCloses() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\nserver: nginx\r\n\r\n")
        #expect(head.framing(method: .get) == .untilClose)
    }

    /// A response to HEAD is framed exactly as the GET would have been and
    /// carries none of it. Believing the field here reads the next response's
    /// head as this one's body, and every answer after that belongs to the
    /// wrong request.
    @Test func aResponseToHEADHasNoBodyWhateverItDeclares() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\ncontent-length: 1024\r\n\r\n")
        #expect(head.framing(method: .head) == .none)
        #expect(head.framing(method: .get) == .length(1024))
    }

    @Test func theBodylessStatusesHaveNoBody() {
        for status in [100, 101, 199, 204, 304] {
            let (_, head, _) = parse(
                "HTTP/1.1 \(status) X\r\ncontent-length: 99\r\n\r\n")
            #expect(head.framing(method: .get) == .none,
                    "status \(status) must carry no body")
        }
    }

    @Test func twoHundredAndFiveIsNotBodyless() {
        // 205 looks like it belongs with 204 and does not: it may carry a body.
        let (_, head, _) = parse("HTTP/1.1 205 Reset\r\ncontent-length: 7\r\n\r\n")
        #expect(head.framing(method: .get) == .length(7))
    }

    // MARK: What a hostile or broken server can send

    /// Two Content-Lengths that disagree: whichever this believes, something
    /// upstream believed the other, and the gap between them is the attack.
    @Test func disagreeingContentLengthsAreRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\ncontent-length: 5\r\ncontent-length: 6\r\n\r\n")
                == .conflictingFraming)
    }

    @Test func agreeingContentLengthsAreAllowed() {
        let (result, head, _) = parse(
            "HTTP/1.1 200 OK\r\ncontent-length: 5\r\ncontent-length: 5\r\n\r\n")
        #expect(result == .complete)
        #expect(head.contentLength == 5)
    }

    /// Both framings at once. RFC 9112 says prefer chunked, but a response
    /// carrying both has passed through something that disagreed about which,
    /// and that disagreement is the whole of a desync.
    @Test func chunkedAndContentLengthTogetherAreRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\ncontent-length: 5\r\n\r\n")
                == .conflictingFraming)
    }

    @Test func aTransferEncodingThisCannotFrameIsRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\ntransfer-encoding: gzip\r\n\r\n")
                == .unsupportedTransferEncoding)
    }

    @Test func chunkedMustBeTheLastCoding() {
        // gzip then chunked is legal and framable; chunked then gzip is not,
        // because the chunking is no longer the outermost layer.
        let (result, head, _) = parse(
            "HTTP/1.1 200 OK\r\ntransfer-encoding: gzip, chunked\r\n\r\n")
        #expect(result == .complete)
        #expect(head.isChunked)
        #expect(failure("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked, gzip\r\n\r\n")
                == .unsupportedTransferEncoding)
    }

    @Test func aNonNumericContentLengthIsRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\ncontent-length: 5x\r\n\r\n") == .badHeader)
        #expect(failure("HTTP/1.1 200 OK\r\ncontent-length: -1\r\n\r\n") == .badHeader)
        #expect(failure("HTTP/1.1 200 OK\r\ncontent-length: \r\n\r\n") == .badHeader)
    }

    /// Unfolding a continuation line is where parsers disagree with each
    /// other, so it is refused rather than interpreted -- the same choice the
    /// request parser makes, for the same reason.
    @Test func obsFoldIsRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\nx-a: one\r\n two\r\n\r\n") == .badHeader)
    }

    @Test func aSpaceBeforeTheColonIsRefused() {
        #expect(failure("HTTP/1.1 200 OK\r\ncontent-length : 5\r\n\r\n") == .badHeader)
    }

    @Test func tooManyHeadersAreRefused() {
        var text = "HTTP/1.1 200 OK\r\n"
        for i in 0..<20 { text += "x-\(i): v\r\n" }
        text += "\r\n"
        var head = HTTPResponseHead()
        let bytes = Array(text.utf8)
        let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: 8)
        defer { headers.deallocate() }
        let result = bytes.withUnsafeBufferPointer {
            HTTPResponseParser.parse($0.baseAddress!, $0.count, maxHeadSize: 8192,
                                     maxHeaders: 8, headers: headers, head: &head)
        }
        #expect(result == .failure(.tooManyHeaders))
    }

    @Test func aHeadLargerThanAllowedIsRefused() {
        var text = "HTTP/1.1 200 OK\r\n"
        text += "x-big: " + String(repeating: "a", count: 4096) + "\r\n\r\n"
        // Only meaningful against a limit the head actually exceeds: the
        // helper above allows 8192, which this fits inside, so asking it
        // would be asserting that a legal response is illegal.
        var head = HTTPResponseHead()
        let bytes = Array(text.utf8)
        let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: 16)
        defer { headers.deallocate() }
        let result = bytes.withUnsafeBufferPointer {
            HTTPResponseParser.parse($0.baseAddress!, $0.count, maxHeadSize: 256,
                                     maxHeaders: 16, headers: headers, head: &head)
        }
        #expect(result == .failure(.headTooLarge))
    }

    @Test func connectionCloseIsHonoured() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n")
        #expect(!head.keepAlive)
    }

    @Test func connectionCloseAmongOtherTokensIsFound() {
        let (_, head, _) = parse("HTTP/1.1 200 OK\r\nconnection: keep-alive, close\r\n\r\n")
        #expect(!head.keepAlive)
    }

    @Test func aLeadingBlankLineIsSkipped() {
        // A server that mis-terminated the previous response leaves one.
        #expect(isComplete("\r\nHTTP/1.1 200 OK\r\n\r\n"))
    }

    @Test func theHeadEndIsWhereTheBodyBegins() {
        let text = "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nabc"
        let (result, head, _) = parse(text)
        #expect(result == .complete)
        #expect(head.headEnd == text.utf8.count - 3)
    }
}

// HTTPParseResult is made Equatable by HTTPParserTests in this same target,
// which got there first. Declaring it again here is a redeclaration, not a
// second conformance.
