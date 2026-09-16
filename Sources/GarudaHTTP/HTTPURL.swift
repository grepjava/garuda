//===----------------------------------------------------------------------===//
// Splitting an absolute URL into the parts a request is made of.
//
// A client is handed `https://example.com:8443/a/b?c=d` and has to turn it
// into three separate decisions: where to open a connection, what to put in
// the Host field, and what to write as the request-target. Nothing in this
// process did that before -- the server reads an authority that arrived, and
// ACME hands its URLs to C without ever looking inside one.
//
// This is where the untrusted bytes are. A URL is the part of an outbound
// request most likely to have been built out of user input, and the three
// decisions it feeds are each a place where a wrong answer is a security
// failure rather than a mistake:
//
//   * the host decides who this process talks to, and who its certificate is
//     checked against;
//   * the Host field decides which site the peer serves;
//   * the target goes onto the request line, where a stray byte starts a
//     second request.
//
// So this refuses rather than repairs. A URL that cannot be read exactly is
// not worth guessing at, because every guess here is a guess about who the
// caller meant to talk to, and the classic attacks on URL parsing are all
// built from two parsers guessing differently about the same string.
//
// Slices into the caller's bytes, like everything else here: no String, no
// allocation, and the caller keeps the memory.
//===----------------------------------------------------------------------===//

import GarudaCore

public enum HTTPURLScheme: UInt8, Sendable {
    case http
    case https

    @inlinable
    public var defaultPort: UInt16 { self == .https ? 443 : 80 }

    @inlinable
    public var isSecure: Bool { self == .https }
}

public enum HTTPURLError: UInt8, Error, Sendable {
    /// No scheme, or one this client does not speak. Only http and https:
    /// anything else is a URL meant for something that is not this.
    case scheme
    /// Missing `//`, or nothing between it and the path.
    case authority
    /// A port that is not a number, is empty, or does not fit.
    case port
    /// An IPv6 literal whose brackets do not close.
    case brackets
    /// Userinfo before the host. Refused rather than skipped -- see `parse`.
    case userinfo
    /// A byte that cannot be in a URL: control, space, or high.
    case illegalByte
}

/// An absolute http or https URL, as slices into the bytes it was parsed from.
public struct HTTPURL {
    public var scheme: HTTPURLScheme = .http
    /// The host alone: no port, and for an IPv6 literal no brackets either,
    /// because that is the form a connect and a certificate check want.
    public var host = HTTPSlice()
    /// The host as it belongs in a Host field: an IPv6 literal keeps its
    /// brackets there, since that is what makes the colons unambiguous.
    public var hostForField = HTTPSlice()
    public var port: UInt16 = 80
    /// Whether the URL said the port out loud.
    public var hasExplicitPort = false
    /// Path and query together, ready to be the request-target. Never empty:
    /// a URL with no path has a target of `/`.
    public var target = HTTPSlice()
    /// Whether a `/` has to be written before `target`.
    ///
    /// True when the URL gave no path at all, whether or not it gave a query:
    /// `http://h` and `http://h?q=1` both ask for the root, and their targets
    /// are `/` and `/?q=1`. The slash is not in the caller's bytes to point
    /// at, so it is a flag rather than part of the slice.
    public var needsLeadingSlash = false

    @inlinable public init() {}

    /// Whether the port is the scheme's own, and so belongs off the Host field.
    @inlinable
    public var isDefaultPort: Bool { port == scheme.defaultPort }
}

extension HTTPURL {

    /// Splits `base[0..<count]`.
    ///
    /// Userinfo is refused rather than honoured or skipped, which is the one
    /// place this is deliberately stricter than the RFC. `https://a@b/` names
    /// host `b`, but it reads to a human as `a`, and that gap is a standing
    /// phishing technique and a standing SSRF technique: a filter that checks
    /// the front of the authority and a client that connects to the back of it
    /// disagree about where the request is going. Since nothing here needs
    /// userinfo -- HTTP auth goes in a field, not a URL -- the safe reading is
    /// no reading at all.
    public static func parse(_ base: UnsafePointer<UInt8>, _ count: Int)
        throws(HTTPURLError) -> HTTPURL {

        // Before anything is located, before any of it is believed: no byte in
        // a URL may be a control character, a space, or high. A URL is split
        // on punctuation, so a parser that located the pieces first and
        // checked them afterwards would have already decided where the host
        // ended using a byte it was about to reject.
        var i = 0
        while i < count {
            if base[i] <= 0x20 || base[i] >= 0x7f { throw .illegalByte }
            i &+= 1
        }

        var url = HTTPURL()

        // ---- scheme ----

        var at = 0
        while at < count, base[at] != cColon { at &+= 1 }
        guard at < count else { throw .scheme }
        switch at {
        case 4:
            guard equalsLowercased(base, 4, "http") else { throw .scheme }
            url.scheme = .http
        case 5:
            guard equalsLowercased(base, 5, "https") else { throw .scheme }
            url.scheme = .https
        default:
            throw .scheme
        }
        url.port = url.scheme.defaultPort
        at &+= 1

        guard at &+ 1 < count, base[at] == cSlash, base[at &+ 1] == cSlash else {
            throw .authority
        }
        at &+= 2

        // ---- authority ----

        let authorityStart = at
        while at < count, base[at] != cSlash, base[at] != cQuestion, base[at] != cHash {
            at &+= 1
        }
        let authorityEnd = at
        if authorityEnd == authorityStart { throw .authority }

        var cursor = authorityStart
        while cursor < authorityEnd {
            if base[cursor] == cAt { throw .userinfo }
            cursor &+= 1
        }

        // The host, and the port if one is there. An IPv6 literal is found by
        // its brackets first, because everything inside them is colons and a
        // search for the port separator would land in the middle of the
        // address.
        var hostStart = authorityStart
        var hostEnd = authorityEnd
        var portStart = -1

        if base[authorityStart] == cLeftBracket {
            var close = authorityStart &+ 1
            while close < authorityEnd, base[close] != cRightBracket { close &+= 1 }
            guard close < authorityEnd else { throw .brackets }
            url.hostForField = HTTPSlice(authorityStart, close &+ 1 &- authorityStart)
            hostStart = authorityStart &+ 1
            hostEnd = close
            if hostEnd == hostStart { throw .authority }
            if close &+ 1 < authorityEnd {
                guard base[close &+ 1] == cColon else { throw .port }
                portStart = close &+ 2
            }
        } else {
            var colon = authorityStart
            while colon < authorityEnd, base[colon] != cColon { colon &+= 1 }
            hostEnd = colon
            if hostEnd == hostStart { throw .authority }
            url.hostForField = HTTPSlice(hostStart, hostEnd &- hostStart)
            if colon < authorityEnd { portStart = colon &+ 1 }
        }
        url.host = HTTPSlice(hostStart, hostEnd &- hostStart)

        if portStart >= 0 {
            if portStart == authorityEnd { throw .port }
            var value = 0
            var p = portStart
            while p < authorityEnd {
                guard base[p] >= cZero, base[p] <= cNine else { throw .port }
                value = value * 10 + Int(base[p] &- cZero)
                // Checked inside the loop, not after: a long enough run of
                // digits would otherwise overflow before anything looked.
                if value > 65535 { throw .port }
                p &+= 1
            }
            url.port = UInt16(value)
            url.hasExplicitPort = true
            // The field carries the authority as given, minus a default port,
            // which a virtual-host match would not recognise.
            if value != Int(url.scheme.defaultPort) {
                url.hostForField = HTTPSlice(authorityStart, authorityEnd &- authorityStart)
            }
        }

        // ---- target ----
        //
        // The fragment is not sent. It never was addressed to the server: it
        // is for whoever holds the document afterwards, and putting it on the
        // wire leaks where in a page somebody was.
        var targetEnd = count
        var f = authorityEnd
        while f < count {
            if base[f] == cHash { targetEnd = f; break }
            f &+= 1
        }

        if authorityEnd == targetEnd {
            url.needsLeadingSlash = true
            url.target = HTTPSlice(0, 0)
        } else if base[authorityEnd] == cQuestion {
            // A URL with a query but no path still asks for the root.
            url.needsLeadingSlash = true
            url.target = HTTPSlice(authorityEnd, targetEnd &- authorityEnd)
        } else {
            url.target = HTTPSlice(authorityEnd, targetEnd &- authorityEnd)
        }

        return url
    }

    /// Splits `text`, which must stay alive while the result is used -- the
    /// slices point into it.
    @inlinable
    public static func parse(_ text: ByteSpan) throws(HTTPURLError) -> HTTPURL {
        try parse(text.base, text.count)
    }
}
