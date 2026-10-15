//===----------------------------------------------------------------------===//
// --request-id: one ID per request, in the application, the response and the
// access log. And --trace-context: the W3C trace a request belongs to.
//
// An ID is only useful if all three places agree. The application logs it
// (`request.log`), the access log records it, and the client can quote it
// back from the response's X-Request-ID. That is what makes "request 7c9e...
// was slow" something that can be looked up.
//
// Where it comes from:
//
//  * A trusted proxy (--forwarded-allow-ips) that already sent X-Request-ID
//    has its ID kept, when it looks like an ID. The proxy saw the request
//    first and may already have logged it.
//  * Anything else gets a new one, a version 4 UUID. That includes an ID a
//    client sent directly: a header a client can set is not an identifier
//    anybody else can rely on, and one chosen to collide with another
//    request's is worse than none. The client's header is taken out of what
//    the application sees, not left beside the new one.
//
// A UUID here needs to be unique, not unpredictable. Each exchange -- one per
// connection, reused by the next -- keeps a random key and a counter and
// mixes the two through splitmix64, a bijection, so within an exchange two
// counts cannot produce the same half, and between exchanges the keys
// differ. That costs one read of the random source per exchange, and nothing
// per request.
//
// A traceparent is never made up and never changed. With --trace-context
// one that is valid is noted where it lies in the request, and its trace and
// parent IDs go to the logs and the response observers; one that is not is
// ignored, as the specification asks.
//===----------------------------------------------------------------------===//

import GarudaWire

enum RequestID {
    /// The longest ID accepted from a proxy. Enough for any UUID, ULID or
    /// trace-style ID with a prefix; anything longer is more likely a mistake.
    static let maxLength = 128

    @inline(__always)
    static func mix(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Characters an ID may have: letters, digits and `-_.:+/=@~`. Nothing a
    /// header, a log line or a JSON string would need to escape.
    @inline(__always)
    static func allowed(_ c: UInt8) -> Bool {
        let lower = c | 0x20
        if (c >= 0x30 && c <= 0x39) || (lower >= 0x61 && lower <= 0x7A) { return true }
        switch c {
        case 0x2D, 0x5F, 0x2E, 0x3A, 0x2B, 0x2F, 0x3D, 0x40, 0x7E: return true
        default: return false
        }
    }
}

extension Exchange {
    /// Settles this request's ID: the one a trusted proxy sent, or a new one.
    mutating func assignRequestID(trusting trust: ForwardedTrust?) {
        requestID.clear()
        let at = headerIndex("x-request-id")
        if let at {
            let value = slice(headers[at].value)
            if let trust, value.count > 0, value.count <= RequestID.maxLength, peerIsTrusted(trust) {
                var k = 0
                while k < value.count && RequestID.allowed(value.base[k]) { k &+= 1 }
                if k == value.count {
                    requestID.write(value)
                    return
                }
            }
            removeHeader(at)
        }

        if requestIDKey == (0, 0) {
            var random = SystemRandomNumberGenerator()
            requestIDKey = (random.next(), random.next())
            // Zero is the mark of no key yet; a random key of zero is still
            // unique within this exchange.
            if requestIDKey == (0, 0) { requestIDKey = (1, 0) }
        }
        requestIDCount &+= 1
        var high = RequestID.mix(requestIDKey.0 &+ requestIDCount)
        var low = RequestID.mix(requestIDKey.1 &+ requestIDCount)
        high = (high & ~0xF000) | 0x4000                                   // version 4
        low = (low & 0x3FFF_FFFF_FFFF_FFFF) | 0x8000_0000_0000_0000        // RFC 9562 variant

        let digits: StaticString = "0123456789abcdef"
        let hex = digits.utf8Start
        requestID.reserve(36)
        func put(_ value: UInt64, from: Int, count: Int) {
            var shift = UInt64(from)
            var n = count
            while n > 0 {
                shift -= 4
                requestID.writeByte(hex[Int((value >> shift) & 0xF)])
                n -= 1
            }
        }
        put(high, from: 64, count: 8)
        requestID.writeByte(0x2D)
        put(high, from: 32, count: 4)
        requestID.writeByte(0x2D)
        put(high, from: 16, count: 4)
        requestID.writeByte(0x2D)
        put(low, from: 64, count: 4)
        requestID.writeByte(0x2D)
        put(low, from: 48, count: 12)
    }

    /// Notes where a valid traceparent lies in the request, if it has one and
    /// only one.
    mutating func readTraceParent() {
        let name: StaticString = "traceparent"
        guard let first = headerIndex(name) else { return }
        // Two say two different things, and neither can be believed over
        // the other (W3C Trace Context, 3.2): the request has none.
        var i = first &+ 1
        while i < head.headerCount {
            let h = headers[i]
            if h.name.count == 11, equalsIgnoringCase(base + Int(h.name.offset), name.utf8Start, 11) { return }
            i &+= 1
        }
        let value = slice(headers[first].value)
        guard TraceContext.valid(value.base, value.count) else { return }
        traceParent = value.base
    }

    /// The trace ID and parent span ID of the request's traceparent, as
    /// --trace-context noted it, or nil.
    var traceIDs: (trace: ByteSpan, parent: ByteSpan)? {
        guard let p = traceParent else { return nil }
        return (ByteSpan(p + TraceContext.traceIDOffset, TraceContext.traceIDLength),
                ByteSpan(p + TraceContext.parentIDOffset, TraceContext.parentIDLength))
    }

    /// The request's ID, or nil without one.
    var requestIDBytes: ByteSpan? {
        requestID.readableBytes > 0 ? requestID.readableSpan : nil
    }

    /// Where the first header named `name` -- a lowercase literal -- is.
    private func headerIndex(_ name: StaticString) -> Int? {
        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            if h.name.count == name.utf8CodeUnitCount,
               equalsIgnoringCase(base + Int(h.name.offset), name.utf8Start, name.utf8CodeUnitCount) {
                return i
            }
            i &+= 1
        }
        return nil
    }

    /// Takes header `index` out of what the application sees, and any more of
    /// the same name after it.
    private mutating func removeHeader(_ index: Int) {
        let name = slice(headers[index].name)
        var kept = index
        var i = index
        while i < head.headerCount {
            let h = headers[i]
            let other = slice(h.name)
            if !(other.count == name.count && equalsIgnoringCase(other.base, name.base, name.count)) {
                headers[kept] = h
                kept &+= 1
            }
            i &+= 1
        }
        head.headerCount = kept
    }

    /// Whether the peer is one `trust` believes.
    private mutating func peerIsTrusted(_ trust: ForwardedTrust) -> Bool {
        var address = remote.address
        return address.withUTF8 { a in
            guard let base = a.baseAddress, a.count > 0 else { return false }
            return trust.trusts(base, a.count)
        }
    }
}

extension Request {
    /// The ID --request-id assigned or kept, or nil without one.
    public var requestID: String? { exchange.pointee.requestIDBytes?.string }

    /// The ID --request-id assigned or kept, lent. Nil, and `body` is not
    /// called, without one.
    @discardableResult
    public borrowing func withRequestID<R, E: Error>(_ body: (Span<UInt8>) throws(E) -> R) throws(E) -> R? {
        guard let id = exchange.pointee.requestIDBytes else { return nil }
        return try lend(id, body)
    }

    /// With --trace-context, the trace ID and parent span ID of the W3C
    /// traceparent the request carries, as lowercase hex; nil when it carries
    /// none that is valid, or without the flag.
    public var traceContext: (traceID: String, parentID: String)? {
        guard let ids = exchange.pointee.traceIDs else { return nil }
        return (ids.trace.string, ids.parent.string)
    }
}
