//===----------------------------------------------------------------------===//
// HTTP/1.1 request-head parser.
//
// Single pass, no backtracking, no allocation. Character classes are tested
// against 64-bit bitmasks held in registers rather than a lookup table, so the
// inner loops touch no memory beyond the request bytes themselves.
//
// Security posture: this parser is strict where strictness prevents request
// smuggling and permissive nowhere that matters.
//   * whitespace between a header name and its colon is rejected (CVE-class
//     desync against downstream proxies)
//   * Content-Length together with Transfer-Encoding is rejected outright
//   * two Content-Length values that disagree is rejected
//   * a Transfer-Encoding that does not end in `chunked` is rejected
//   * obs-fold (a continuation line) is rejected rather than unfolded
//===----------------------------------------------------------------------===//

import PeregrineCore

/// RFC 9110 `tchar`. Two immediate constants, no table lookup.
@inlinable
public func isTokenChar(_ c: UInt8) -> Bool {
    if c < 64 { return (0x03FF6CFA00000000 as UInt64) >> UInt64(c) & 1 == 1 }
    if c < 128 { return (0x57FFFFFFC7FFFFFE as UInt64) >> UInt64(c &- 64) & 1 == 1 }
    return false
}

/// Legal inside a header value: VCHAR, SP, HTAB and obs-text. Everything else
/// (control characters, and in particular bare CR or LF) is a hard failure.
@inlinable
public func isFieldValueChar(_ c: UInt8) -> Bool {
    c >= 0x20 ? c != 0x7F : c == cHT
}

public enum HTTPParser {

    /// Parses a complete request head out of `base[0..<count]`.
    ///
    /// On `.complete`, `head.headEnd` is the number of bytes consumed and
    /// `headers[0..<head.headerCount]` describes the fields. All slices are
    /// relative to `base`.
    public static func parse(
        _ base: UnsafePointer<UInt8>,
        _ count: Int,
        maxHeadSize: Int,
        maxHeaders: Int,
        headers: UnsafeMutablePointer<HTTPHeaderRef>,
        head: inout HTTPRequestHead
    ) -> HTTPParseResult {

        var i = 0

        // RFC 9112 2.2: a server should ignore at least one empty line before
        // the request line, which is what a client that mis-terminated the
        // previous request will send.
        while i < count, base[i] == cCR || base[i] == cLF { i &+= 1 }
        if i == count { return .incomplete }

        // ---- request line: method SP target SP HTTP/1.x CRLF ----

        let methodStart = i
        while i < count, isTokenChar(base[i]) { i &+= 1 }
        if i == count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
        if base[i] != cSP || i == methodStart { return .failure(.badRequestLine) }
        let methodLen = i &- methodStart
        head.methodSlice = HTTPSlice(methodStart, methodLen)
        head.method = classifyMethod(base + methodStart, methodLen)
        i &+= 1

        let targetStart = i
        while i < count, base[i] > cSP, base[i] != 0x7F { i &+= 1 }
        if i == count { return count > maxHeadSize ? .failure(.uriTooLong) : .incomplete }
        if base[i] != cSP { return .failure(.badRequestLine) }
        let targetLen = i &- targetStart
        if targetLen == 0 { return .failure(.badRequestLine) }
        if targetLen > maxHeadSize { return .failure(.uriTooLong) }
        head.target = HTTPSlice(targetStart, targetLen)
        i &+= 1

        // Split target into path and query without a second scan of the whole
        // thing: the query, when present, is usually short and near the end.
        let qIndex = findByte(base + targetStart, targetLen, cQuestion)
        if qIndex >= 0 {
            head.path = HTTPSlice(targetStart, qIndex)
            head.query = HTTPSlice(targetStart &+ qIndex &+ 1, targetLen &- qIndex &- 1)
        } else {
            head.path = HTTPSlice(targetStart, targetLen)
            head.query = HTTPSlice(targetStart &+ targetLen, 0)
        }
        if hasPercent(base + Int(head.path.offset), Int(head.path.length)) {
            head.flags.insert(.escapedPath)
        }

        // "HTTP/1." DIGIT CRLF -- exactly 10 bytes.
        if count &- i < 10 { return .incomplete }
        if !equalsExact(base + i, 7, "HTTP/1.") { return .failure(.badVersion) }
        let minorByte = base[i &+ 7]
        if minorByte != 48 && minorByte != 49 { return .failure(.badVersion) }
        head.httpMinor = minorByte &- 48
        i &+= 8
        if base[i] == cCR {
            if count &- i < 2 { return .incomplete }
            if base[i &+ 1] != cLF { return .failure(.badRequestLine) }
            i &+= 2
        } else if base[i] == cLF {
            i &+= 1
        } else {
            return .failure(.badRequestLine)
        }

        // HTTP/1.1 keeps the connection alive by default; HTTP/1.0 does not.
        var keepAlive = head.httpMinor == 1
        var sawContentLength = false
        var contentLength = -1
        var chunked = false
        var n = 0

        // ---- header fields ----

        while true {
            if i >= count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
            if i > maxHeadSize { return .failure(.headTooLarge) }

            // Empty line terminates the head.
            if base[i] == cCR {
                if i &+ 1 >= count { return .incomplete }
                if base[i &+ 1] != cLF { return .failure(.badHeader) }
                i &+= 2
                break
            }
            if base[i] == cLF { i &+= 1; break }

            // A line that begins with SP/HTAB is obs-fold. Unfolding it is how
            // parsers disagree with each other, so refuse instead.
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
            // No space is permitted between the field name and the colon.
            if base[i] != cColon { return .failure(.badHeader) }
            i &+= 1

            while i < count, base[i] == cSP || base[i] == cHT { i &+= 1 }
            if i == count { return .incomplete }

            let valueStart = i
            while i < count, isFieldValueChar(base[i]) { i &+= 1 }
            if i == count { return count > maxHeadSize ? .failure(.headTooLarge) : .incomplete }
            var valueEnd = i
            // Trim trailing OWS.
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
                // A control character inside the value.
                return .failure(.badHeader)
            }

            if n == maxHeaders { return .failure(.tooManyHeaders) }
            headers[n] = HTTPHeaderRef(name: HTTPSlice(nameStart, nameLen),
                                       value: HTTPSlice(valueStart, valueEnd &- valueStart),
                                       nameHash: hash)
            n &+= 1

            // ---- framing-relevant fields ----
            let np = base + nameStart
            let vp = base + valueStart
            let vLen = valueEnd &- valueStart

            switch nameLen {
            case 4:
                if equalsLowercased(np, 4, "host") { head.flags.insert(.hasHost) }
            case 6:
                if equalsLowercased(np, 6, "expect"),
                   containsTokenLowercased(vp, vLen, "100-continue") {
                    head.flags.insert(.expectContinue)
                }
            case 7:
                if equalsLowercased(np, 7, "upgrade") { head.flags.insert(.upgrade) }
            case 10:
                if equalsLowercased(np, 10, "connection") {
                    if containsTokenLowercased(vp, vLen, "close") {
                        keepAlive = false
                    } else if containsTokenLowercased(vp, vLen, "keep-alive") {
                        keepAlive = true
                    }
                }
            case 14:
                if equalsLowercased(np, 14, "content-length") {
                    let v = parseDecimal(vp, vLen)
                    if v < 0 { return .failure(.badHeader) }
                    // Repeated Content-Length is only tolerable when every copy
                    // agrees; disagreement is a smuggling attempt.
                    if sawContentLength && contentLength != v {
                        return .failure(.conflictingFraming)
                    }
                    sawContentLength = true
                    contentLength = v
                }
            case 17:
                if equalsLowercased(np, 17, "transfer-encoding") {
                    // Only `chunked`, and only as the final coding.
                    if vLen >= 7, equalsLowercased(vp + (vLen &- 7), 7, "chunked") {
                        chunked = true
                    } else {
                        return .failure(.unsupportedTransferEncoding)
                    }
                }
            default:
                break
            }
        }

        // Transfer-Encoding beats Content-Length in the spec, but a request
        // carrying both is exactly the shape of a smuggling attack, so reject.
        if chunked && sawContentLength { return .failure(.conflictingFraming) }

        // HTTP/1.1 requires Host. Its absence is a 400 per RFC 9112 3.2.
        if head.httpMinor == 1 && !head.flags.contains(.hasHost) {
            return .failure(.badRequestLine)
        }

        if chunked { head.flags.insert(.chunked) }
        if sawContentLength {
            head.flags.insert(.hasContentLength)
            head.contentLength = contentLength
        } else {
            head.contentLength = chunked ? -1 : 0
        }
        if keepAlive { head.flags.insert(.keepAlive) }
        head.headerCount = n
        head.headEnd = i
        return .complete
    }

    /// Method classification by length and first byte: one comparison chain,
    /// no hashing, and the common verbs land first.
    @inlinable
    static func classifyMethod(_ p: UnsafePointer<UInt8>, _ n: Int) -> HTTPMethod {
        switch n {
        case 3:
            if equalsExact(p, 3, "GET") { return .get }
            if equalsExact(p, 3, "PUT") { return .put }
        case 4:
            if equalsExact(p, 4, "POST") { return .post }
            if equalsExact(p, 4, "HEAD") { return .head }
        case 5:
            if equalsExact(p, 5, "PATCH") { return .patch }
            if equalsExact(p, 5, "TRACE") { return .trace }
        case 6:
            if equalsExact(p, 6, "DELETE") { return .delete }
        case 7:
            if equalsExact(p, 7, "OPTIONS") { return .options }
            if equalsExact(p, 7, "CONNECT") { return .connect }
        default:
            break
        }
        return .other
    }
}
