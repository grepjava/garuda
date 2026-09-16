import Testing
@testable import GarudaCore
@testable import GarudaHTTP

// Tests for URL splitting. The three things a URL decides -- who this process
// connects to, which site the peer is asked to serve, and what goes on the
// request line -- are each a place where a wrong answer is a security failure,
// so most of these are about what is refused.

/// The parts of a parsed URL, lifted out to Strings so a test can read them.
private struct Parsed {
    var scheme: HTTPURLScheme
    var host: String
    var hostForField: String
    var port: UInt16
    var hasExplicitPort: Bool
    var target: String
    var needsLeadingSlash: Bool
    /// What a client would actually put on the request line.
    var requestTarget: String { needsLeadingSlash ? "/" + target : target }
}

private func parse(_ text: String) -> Result<Parsed, HTTPURLError> {
    let bytes = Array(text.utf8)
    // An empty array has no base address, and this has to be able to parse the
    // empty string rather than crash on it.
    let storage = bytes.isEmpty ? [UInt8(0)] : bytes
    let count = bytes.count
    return storage.withUnsafeBufferPointer { buffer -> Result<Parsed, HTTPURLError> in
        let base = buffer.baseAddress!
        func text(_ slice: HTTPSlice) -> String {
            String(decoding: UnsafeBufferPointer(start: base + Int(slice.offset),
                                                 count: slice.count), as: UTF8.self)
        }
        do {
            let url = try HTTPURL.parse(base, count)
            return .success(Parsed(scheme: url.scheme,
                                   host: text(url.host),
                                   hostForField: text(url.hostForField),
                                   port: url.port,
                                   hasExplicitPort: url.hasExplicitPort,
                                   target: text(url.target),
                                   needsLeadingSlash: url.needsLeadingSlash))
        } catch {
            // withUnsafeBufferPointer erases the typed throw, so what arrives
            // here is `any Error` and has to be put back before it is useful.
            return .failure((error as? HTTPURLError) ?? .illegalByte)
        }
    }
}

private func parsed(_ text: String) -> Parsed? {
    if case .success(let url) = parse(text) { return url }
    return nil
}

private func refusal(_ text: String) -> HTTPURLError? {
    if case .failure(let error) = parse(text) { return error }
    return nil
}

@Suite("URL splitting")
struct HTTPURLTests {

    // MARK: Ordinary URLs

    @Test func anOrdinaryURLComesApart() {
        let url = parsed("http://example.com/a/b")
        #expect(url?.scheme == .http)
        #expect(url?.host == "example.com")
        #expect(url?.port == 80)
        #expect(url?.hasExplicitPort == false)
        #expect(url?.requestTarget == "/a/b")
    }

    @Test func httpsBringsItsOwnPort() {
        let url = parsed("https://example.com/")
        #expect(url?.scheme == .https)
        #expect(url?.port == 443)
        #expect(url?.requestTarget == "/")
    }

    @Test func theSchemeIsReadWithoutRegardToCase() {
        #expect(parsed("HTTPS://example.com/")?.scheme == .https)
        #expect(parsed("HtTp://example.com/")?.scheme == .http)
    }

    @Test func aQueryStaysWithTheTarget() {
        // The target is what goes on the request line, and the server needs
        // the query on it -- splitting them here would only mean joining them
        // again at the only place that uses them.
        let url = parsed("http://example.com/search?q=swift&n=2")
        #expect(url?.requestTarget == "/search?q=swift&n=2")
    }

    @Test func anEscapeInThePathIsLeftExactlyAsItCame() {
        // Decoding and re-encoding is how two parsers come to disagree about
        // what was asked for.
        let url = parsed("http://example.com/a%2Fb%20c?x=%26")
        #expect(url?.requestTarget == "/a%2Fb%20c?x=%26")
    }

    @Test func anExplicitPortIsKept() {
        let url = parsed("http://example.com:8080/x")
        #expect(url?.port == 8080)
        #expect(url?.hasExplicitPort == true)
        #expect(url?.host == "example.com")
    }

    @Test func theHighestPortIsAllowed() {
        #expect(parsed("http://h:65535/")?.port == 65535)
    }

    @Test func portZeroIsAllowedBecauseItIsANumber() {
        // Nothing listens there, so connecting fails -- but that is the
        // connect's answer to give, not the parser's.
        #expect(parsed("http://h:0/")?.port == 0)
    }

    // MARK: The Host field

    @Test func aDefaultPortIsLeftOffTheHostField() {
        // A server matching virtual hosts on the literal field will not match
        // "example.com:443" against "example.com".
        #expect(parsed("https://example.com:443/")?.hostForField == "example.com")
        #expect(parsed("http://example.com:80/")?.hostForField == "example.com")
    }

    @Test func aNonDefaultPortStaysOnTheHostField() {
        #expect(parsed("http://example.com:8080/")?.hostForField == "example.com:8080")
        #expect(parsed("https://example.com:8443/")?.hostForField == "example.com:8443")
    }

    @Test func anImplicitPortIsNeverOnTheHostField() {
        #expect(parsed("http://example.com/")?.hostForField == "example.com")
    }

    // MARK: IPv6 literals

    @Test func anIPv6LiteralLosesItsBracketsForConnectingAndKeepsThemForTheField() {
        // Two different jobs: connect(2) and a certificate check want the
        // address, and the Host field wants the brackets, because without them
        // its colons are ambiguous with a port.
        let url = parsed("http://[::1]/x")
        #expect(url?.host == "::1")
        #expect(url?.hostForField == "[::1]")
        #expect(url?.port == 80)
        #expect(url?.requestTarget == "/x")
    }

    @Test func anIPv6LiteralTakesAPortAfterItsBrackets() {
        let url = parsed("http://[2001:db8::1]:8080/x")
        #expect(url?.host == "2001:db8::1")
        #expect(url?.hostForField == "[2001:db8::1]:8080")
        #expect(url?.port == 8080)
    }

    @Test func anIPv6LiteralOnADefaultPortKeepsOnlyItsBrackets() {
        #expect(parsed("https://[::1]:443/")?.hostForField == "[::1]")
    }

    @Test func anUnclosedBracketIsRefused() {
        #expect(refusal("http://[::1/x") == .brackets)
    }

    @Test func anEmptyBracketPairIsRefused() {
        #expect(refusal("http://[]/x") == .authority)
    }

    @Test func rubbishBetweenTheBracketAndThePortIsRefused() {
        // "[::1]x:80" has no reading at all, and guessing one would mean
        // connecting somewhere nobody asked for.
        #expect(refusal("http://[::1]x:80/") == .port)
    }

    // MARK: Userinfo -- refused, not honoured

    @Test func userinfoIsRefused() {
        // "https://a@b/" names host b but reads as a. A filter that checks the
        // front of the authority and a client that connects to the back of it
        // disagree about where the request is going, which is the whole of
        // that attack.
        #expect(refusal("https://evil.example@good.example/") == .userinfo)
    }

    @Test func userinfoWithAPasswordIsRefused() {
        #expect(refusal("https://user:pass@example.com/") == .userinfo)
    }

    @Test func anAtSignAfterTheAuthorityIsNotUserinfo() {
        // A path may hold an @, and refusing this one would refuse ordinary
        // URLs for no reason.
        #expect(parsed("http://example.com/users/@alice")?.requestTarget == "/users/@alice")
    }

    // MARK: Bytes that have no business in a URL

    @Test func aURLWithASpaceIsRefused() {
        #expect(refusal("http://example.com/a b") == .illegalByte)
    }

    @Test func aURLWithACarriageReturnIsRefused() {
        #expect(refusal("http://example.com/a\rb") == .illegalByte)
    }

    @Test func aURLWithALineFeedIsRefused() {
        #expect(refusal("http://example.com/a\nb") == .illegalByte)
    }

    @Test func aURLWithANulIsRefused() {
        #expect(refusal("http://example.com/a\u{0}b") == .illegalByte)
    }

    @Test func aURLWithHighBytesIsRefused() {
        #expect(refusal("http://example.com/caf\u{e9}") == .illegalByte)
    }

    @Test func anIllegalByteIsCaughtEvenInsideTheAuthority() {
        // The check runs before anything is located, which is the point: a
        // parser that found the host first would have decided where it ended
        // using a byte it was about to reject.
        #expect(refusal("http://exa\rmple.com/") == .illegalByte)
        #expect(refusal("http://exa mple.com/") == .illegalByte)
    }

    // MARK: Schemes

    @Test func anUnknownSchemeIsRefused() {
        #expect(refusal("ftp://example.com/") == .scheme)
        #expect(refusal("file:///etc/passwd") == .scheme)
        #expect(refusal("gopher://example.com/") == .scheme)
    }

    @Test func aSchemeThatIsAPrefixOfAKnownOneIsRefused() {
        #expect(refusal("htt://example.com/") == .scheme)
        #expect(refusal("httpz://example.com/") == .scheme)
    }

    @Test func aRelativeURLIsRefused() {
        // This takes absolute URLs only. A path alone does not say who to
        // talk to, and inventing a host for it is exactly the kind of repair
        // that ends in a request going somewhere nobody chose.
        #expect(refusal("/just/a/path") == .scheme)
        #expect(refusal("example.com/x") == .scheme)
    }

    @Test func anEmptyStringIsRefused() {
        #expect(refusal("") == .scheme)
    }

    @Test func aSchemeWithoutItsSlashesIsRefused() {
        #expect(refusal("http:example.com/") == .authority)
        #expect(refusal("http:/example.com/") == .authority)
    }

    // MARK: Authority

    @Test func anEmptyAuthorityIsRefused() {
        #expect(refusal("http:///just/a/path") == .authority)
        #expect(refusal("http://") == .authority)
    }

    @Test func anEmptyHostBeforeAPortIsRefused() {
        #expect(refusal("http://:8080/x") == .authority)
    }

    // MARK: Ports

    @Test func aPortThatIsNotANumberIsRefused() {
        #expect(refusal("http://example.com:80x/") == .port)
        #expect(refusal("http://example.com:http/") == .port)
    }

    @Test func anEmptyPortIsRefused() {
        #expect(refusal("http://example.com:/x") == .port)
    }

    @Test func aPortTooLargeForAPortIsRefused() {
        #expect(refusal("http://example.com:65536/") == .port)
        #expect(refusal("http://example.com:99999/") == .port)
    }

    @Test func aPortLongEnoughToOverflowIsRefused() {
        // Checked as it accumulates rather than at the end: a long enough run
        // of digits would otherwise wrap into a plausible port.
        #expect(refusal("http://example.com:99999999999999999999999/") == .port)
    }

    // MARK: The target

    @Test func aURLWithNoPathAsksForTheRoot() {
        let url = parsed("http://example.com")
        #expect(url?.needsLeadingSlash == true)
        #expect(url?.target == "")
        #expect(url?.requestTarget == "/")
    }

    @Test func aURLWithAQueryButNoPathAsksForTheRoot() {
        let url = parsed("http://example.com?q=1")
        #expect(url?.needsLeadingSlash == true)
        #expect(url?.requestTarget == "/?q=1")
    }

    @Test func aPathThatIsJustASlashNeedsNothingAdded() {
        let url = parsed("http://example.com/")
        #expect(url?.needsLeadingSlash == false)
        #expect(url?.requestTarget == "/")
    }

    @Test func aFragmentIsNotSent() {
        // It was never addressed to the server: it says where in a document
        // somebody was, and putting it on the wire leaks that.
        #expect(parsed("http://example.com/page#section")?.requestTarget == "/page")
        #expect(parsed("http://example.com/p?q=1#frag")?.requestTarget == "/p?q=1")
    }

    @Test func aFragmentOnAPathlessURLStillAsksForTheRoot() {
        let url = parsed("http://example.com#frag")
        #expect(url?.requestTarget == "/")
    }

    @Test func aFragmentHoldingWhatLooksLikeAQueryIsStillNotSent() {
        #expect(parsed("http://example.com/p#?q=1")?.requestTarget == "/p")
    }

    // MARK: What comes out is safe to write

    @Test func everyTargetThisAcceptsIsOneTheRequestWriterWillWrite() {
        // The two have to agree: a URL this accepts whose target the writer
        // then refuses would be a request that can be parsed and never sent.
        // Both hold the same VCHAR line, and this is what says so.
        for text in ["http://h/a/b", "http://h/a%20b", "http://h/?q=1&r=2",
                     "http://h/users/@alice", "http://h/a~b!c$d'e(f)g*h+i,j;k=l"] {
            guard let url = parsed(text) else {
                Issue.record("\(text) should parse")
                continue
            }
            let target = Array(url.requestTarget.utf8)
            var buf = ByteBuffer(capacity: 256)
            defer { buf.destroy() }
            let ok = target.withUnsafeBufferPointer { t in
                HTTPRequestWriter.writeRequestLine(
                    &buf, method: .get, target: ByteSpan(t.baseAddress!, t.count))
            }
            #expect(ok, "\(text) parsed to a target the writer refuses")
        }
    }
}
