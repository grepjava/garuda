//===----------------------------------------------------------------------===//
// HTTP/1.1 response-head parser, for connections this process makes.
//
// The mirror of HTTPParser next door, which reads a request head. The two are
// deliberately the same shape -- slices into the caller's buffer, no
// allocation, the same HTTPParseResult -- because the difference between them
// is only the first line and which fields decide framing. Where this one can
// borrow that one's reasoning it does, and where the roles genuinely differ it
// says so.
//
// The framing rules are not symmetric, and getting that wrong is how a client
// desynchronises. A request's body is whatever Content-Length or chunked says;
// a response's body is decided first by *what was asked* and by the status
// code, and only then by the fields:
//
//   * A response to HEAD has no body however much Content-Length it declares.
//   * 1xx, 204 and 304 have no body, and a Content-Length on one is a claim to
//     be ignored rather than obeyed.
//   * Everything else with neither Content-Length nor chunked runs to the
//     close of the connection, which is a body the parser cannot bound.
//
// A client that reads a body where there is none consumes the head of the next
// response, and every answer after that belongs to the wrong request. That is
// response smuggling, and it is the same family of bug as the request kind the
// parser next door refuses obs-fold to avoid.
//===----------------------------------------------------------------------===//

import GarudaCore

/// How a response's body is delimited, decided by the status, the request
/// method, and the fields -- in that order.
public enum HTTPBodyFraming: Equatable, Sendable {
    /// No body at all, whatever the fields claim.
    case none
    /// Exactly this many bytes.
    case length(Int)
    /// Chunked transfer coding.
    case chunked
    /// Until the connection closes, which also means it cannot be reused.
    case untilClose
}

public struct HTTPResponseHead {
    public var status: Int = 0
    /// The reason phrase, which may legitimately be empty.
    public var reason = HTTPSlice()
    public var httpMajor: UInt8 = 1
    public var httpMinor: UInt8 = 1
    public var headerCount: Int = 0
    /// -1 when absent.
    public var contentLength: Int = -1
    public var isChunked = false
    /// Whether the server is willing to keep the connection.
    public var keepAlive = true
    /// Byte length of the whole head including the terminating CRLF.
    public var headEnd: Int = 0

    @inlinable public init() {}

    /// How to read the body that follows, given what was asked for.
    ///
    /// The method matters because a response to HEAD is framed exactly as the
    /// GET would have been -- Content-Length and all -- and carries none of it.
    /// A client that believed the field would read the next response's head as
    /// this one's body.
    public func framing(method: HTTPMethod) -> HTTPBodyFraming {
        if method == .head { return .none }
        if status >= 100 && status < 200 { return .none }
        if status == 204 || status == 304 { return .none }
        if isChunked { return .chunked }
        if contentLength >= 0 { return .length(contentLength) }
        return .untilClose
    }
}

public enum HTTPResponseParser {

    /// Parses a complete response head out of `base[0..<count]`.
    ///
    /// On `.complete`, `head.headEnd` is the number of bytes consumed and
    /// `headers[0..<head.headerCount]` describes the fields, as slices relative
    /// to `base`.
    public static func parse(
        _ base: UnsafePointer<UInt8>,
        _ count: Int,
        maxHeadSize: Int,
        maxHeaders: Int,
        headers: UnsafeMutablePointer<HTTPHeaderRef>,
        head: inout HTTPResponseHead
    ) -> HTTPParseResult {

        var i = 0

        // A server that mis-terminated the previous response leaves a blank
        // line in front of this one. The request parser tolerates the same
        // thing for the same reason.
        while i < count, base[i] == cCR || base[i] == cLF { i &+= 1 }
        if i == count { return .incomplete }

        // ---- status line: HTTP/1.1 200 OK ----

        let versionStart = i
        while i < count, base[i] != cSP { i &+= 1 }
        if i == count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
        let versionLength = i &- versionStart
        guard versionLength == 8 else { return .failure(.badVersion) }
        let v = base + versionStart
        guard v[0] == UInt8(ascii: "H"), v[1] == UInt8(ascii: "T"), v[2] == UInt8(ascii: "T"),
              v[3] == UInt8(ascii: "P"), v[4] == UInt8(ascii: "/"), v[6] == UInt8(ascii: "."),
              v[5] >= cZero, v[5] <= cNine, v[7] >= cZero, v[7] <= cNine else {
            return .failure(.badVersion)
        }
        head.httpMajor = v[5] &- cZero
        head.httpMinor = v[7] &- cZero
        // 0.9 had no status line at all, and 2 and 3 are not this syntax.
        guard head.httpMajor == 1 else { return .failure(.badVersion) }
        // HTTP/1.0 does not keep a connection alive unless it says so.
        head.keepAlive = head.httpMinor >= 1
        i &+= 1

        // Exactly three digits. Not "at least three": a four-digit code would
        // otherwise parse as a three-digit one with rubbish after it.
        if i &+ 2 >= count { return .incomplete }
        guard base[i] >= cZero, base[i] <= cNine,
              base[i &+ 1] >= cZero, base[i &+ 1] <= cNine,
              base[i &+ 2] >= cZero, base[i &+ 2] <= cNine else {
            return .failure(.badStatusLine)
        }
        head.status = Int(base[i] &- cZero) * 100
            + Int(base[i &+ 1] &- cZero) * 10
            + Int(base[i &+ 2] &- cZero)
        i &+= 3
        if i < count, base[i] >= cZero, base[i] <= cNine { return .failure(.badStatusLine) }

        // The reason phrase is optional, and so is the space before it.
        if i < count, base[i] == cSP { i &+= 1 }
        let reasonStart = i
        while i < count, base[i] != cCR, base[i] != cLF {
            // Anything a field value may not hold has no business here either.
            if !isFieldValueChar(base[i]) && base[i] != cSP && base[i] != cHT {
                return .failure(.badStatusLine)
            }
            i &+= 1
        }
        if i == count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
        head.reason = HTTPSlice(reasonStart, i &- reasonStart)
        if base[i] == cCR {
            if i &+ 1 >= count { return .incomplete }
            if base[i &+ 1] != cLF { return .failure(.badStatusLine) }
            i &+= 2
        } else {
            i &+= 1
        }

        // ---- header fields ----

        var n = 0
        var sawContentLength = false

        while true {
            if i >= count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
            if i > maxHeadSize { return .failure(.headTooLarge) }

            if base[i] == cCR {
                if i &+ 1 >= count { return .incomplete }
                if base[i &+ 1] != cLF { return .failure(.badHeader) }
                i &+= 2
                break
            }
            if base[i] == cLF { i &+= 1; break }

            // obs-fold, refused here for the same reason as in a request:
            // unfolding is where parsers disagree with each other, and a
            // disagreement between a proxy and an origin is a desync.
            if base[i] == cSP || base[i] == cHT { return .failure(.badHeader) }

            let nameStart = i
            var hash: UInt32 = 2166136261
            while i < count, isTokenChar(base[i]) {
                hash = (hash ^ UInt32(asciiLower(base[i]))) &* 16777619
                i &+= 1
            }
            if i == count { return .incomplete }
            let nameLen = i &- nameStart
            if nameLen == 0 { return .failure(.badHeader) }
            if base[i] != cColon { return .failure(.badHeader) }
            i &+= 1

            while i < count, base[i] == cSP || base[i] == cHT { i &+= 1 }
            if i == count { return .incomplete }

            let valueStart = i
            while i < count, isFieldValueChar(base[i]) { i &+= 1 }
            if i == count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
            var valueEnd = i
            while valueEnd > valueStart,
                  base[valueEnd &- 1] == cSP || base[valueEnd &- 1] == cHT {
                valueEnd &-= 1
            }
            if base[i] == cCR {
                if i &+ 1 >= count { return .incomplete }
                if base[i &+ 1] != cLF { return .failure(.badHeader) }
                i &+= 2
            } else if base[i] == cLF {
                i &+= 1
            } else {
                return .failure(.badHeader)
            }

            if n == maxHeaders { return .failure(.tooManyHeaders) }
            headers[n] = HTTPHeaderRef(name: HTTPSlice(nameStart, nameLen),
                                       value: HTTPSlice(valueStart, valueEnd &- valueStart),
                                       nameHash: hash)
            n &+= 1

            // ---- fields that decide framing ----
            let np = base + nameStart
            let vp = base + valueStart
            let vLen = valueEnd &- valueStart

            switch nameLen {
            case 10:
                if equalsLowercased(np, 10, "connection") {
                    if containsToken(vp, vLen, "close") {
                        head.keepAlive = false
                    } else if containsToken(vp, vLen, "keep-alive") {
                        head.keepAlive = true
                    }
                }
            case 14:
                if equalsLowercased(np, 14, "content-length") {
                    guard let value = parseDecimal(vp, vLen) else {
                        return .failure(.badHeader)
                    }
                    // Two that disagree is the response-side of the smuggling
                    // family: whichever a client believes, something upstream
                    // believed the other.
                    if sawContentLength, head.contentLength != value {
                        return .failure(.conflictingFraming)
                    }
                    head.contentLength = value
                    sawContentLength = true
                }
            case 17:
                if equalsLowercased(np, 17, "transfer-encoding") {
                    // Only chunked, and only as the last coding. Anything else
                    // is a body this client cannot frame, and guessing is what
                    // a desync is made of.
                    guard endsWithChunked(vp, vLen) else {
                        return .failure(.unsupportedTransferEncoding)
                    }
                    if head.isChunked { return .failure(.conflictingFraming) }
                    head.isChunked = true
                }
            default:
                break
            }
        }

        // Both framings at once: RFC 9112 says ignore Content-Length, but a
        // response carrying both has been through something that disagreed
        // about which, and that disagreement is the attack.
        if head.isChunked && sawContentLength { return .failure(.conflictingFraming) }

        head.headerCount = n
        head.headEnd = i
        return .complete
    }

    /// A non-negative decimal with no sign, no padding and no overflow.
    static func parseDecimal(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int? {
        if n == 0 || n > 18 { return nil }
        var value = 0
        var i = 0
        while i < n {
            guard p[i] >= cZero, p[i] <= cNine else { return nil }
            value = value * 10 + Int(p[i] &- cZero)
            i &+= 1
        }
        return value
    }

    /// Whether a comma-separated list holds `token`, compared without case.
    static func containsToken(_ p: UnsafePointer<UInt8>, _ n: Int,
                              _ token: StaticString) -> Bool {
        let tLen = token.utf8CodeUnitCount
        var i = 0
        while i < n {
            while i < n, p[i] == cSP || p[i] == cHT || p[i] == cComma { i &+= 1 }
            let start = i
            while i < n, p[i] != cComma { i &+= 1 }
            var end = i
            while end > start, p[end &- 1] == cSP || p[end &- 1] == cHT { end &-= 1 }
            if end &- start == tLen, equalsLowercased(p + start, tLen, token) { return true }
        }
        return false
    }

    /// Whether the last coding in the list is `chunked`, which is the only
    /// arrangement RFC 9112 allows and the only one this can frame.
    static func endsWithChunked(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var end = n
        while end > 0, p[end &- 1] == cSP || p[end &- 1] == cHT { end &-= 1 }
        var start = end
        while start > 0, p[start &- 1] != cComma { start &-= 1 }
        while start < end, p[start] == cSP || p[start] == cHT { start &+= 1 }
        return end &- start == 7 && equalsLowercased(p + start, 7, "chunked")
    }
}
