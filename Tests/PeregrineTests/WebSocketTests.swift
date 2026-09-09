//===----------------------------------------------------------------------===//
// Frame codec, UTF-8 validation and forwarded-header parsing.
//
// These are the pieces where a wrong answer is a security or interoperability
// failure rather than a visible crash: a frame the peer can desynchronise, a
// text message that is not valid UTF-8, or a client address a caller can forge.
//===----------------------------------------------------------------------===//

import Testing

@testable import PeregrineCore
@testable import PeregrineHTTP

private func withBytes<R>(_ bytes: [UInt8], _ body: (UnsafePointer<UInt8>, Int) -> R) -> R {
    bytes.withUnsafeBufferPointer { body($0.baseAddress!, $0.count) }
}

@Suite("WebSocket framing")
struct WebSocketFramingTests {

    @Test("a short masked text frame parses")
    func shortFrame() {
        // FIN + text, masked, 5 bytes, key 01020304.
        let bytes: [UInt8] = [0x81, 0x85, 1, 2, 3, 4, 0, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .header(let h) = WebSocketCodec.parseHeader(p, n, maxPayload: 1 << 20) else {
                Issue.record("expected a header")
                return
            }
            #expect(h.fin)
            #expect(h.opcode == .text)
            #expect(h.masked)
            #expect(h.payloadLength == 5)
            #expect(h.headerLength == 6)
            #expect(h.totalLength == 11)
        }
    }

    @Test("a 16-bit extended length parses")
    func extendedLength16() {
        var bytes: [UInt8] = [0x82, 0xFE, 0x01, 0x00, 9, 9, 9, 9]
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 256))
        withBytes(bytes) { p, n in
            guard case .header(let h) = WebSocketCodec.parseHeader(p, n, maxPayload: 1 << 20) else {
                Issue.record("expected a header")
                return
            }
            #expect(h.payloadLength == 256)
            #expect(h.headerLength == 8)
        }
    }

    @Test("a 64-bit extended length parses")
    func extendedLength64() {
        let bytes: [UInt8] = [0x82, 0xFF, 0, 0, 0, 0, 0, 1, 0, 0, 1, 2, 3, 4]
        withBytes(bytes) { p, n in
            guard case .header(let h) = WebSocketCodec.parseHeader(p, n, maxPayload: 1 << 24) else {
                Issue.record("expected a header")
                return
            }
            #expect(h.payloadLength == 65536)
            #expect(h.headerLength == 14)
        }
    }

    @Test("a truncated header asks for more rather than guessing")
    func truncated() {
        for prefix in 0..<6 {
            let bytes = [UInt8](repeating: 0x81, count: prefix)
            withBytes(bytes) { p, n in
                if case .needMore = WebSocketCodec.parseHeader(p, n, maxPayload: 1024) {
                    return
                }
                if n == 0 { return }
                Issue.record("expected needMore for a \(n)-byte header")
            }
        }
    }

    @Test("a reserved bit is a protocol error")
    func reservedBits() {
        let bytes: [UInt8] = [0xC1, 0x80, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.protocolError) = WebSocketCodec.parseHeader(
                p, n, maxPayload: 1024) else {
                Issue.record("a set RSV bit must be refused")
                return
            }
        }
    }

    @Test("an unknown opcode is a protocol error")
    func unknownOpcode() {
        let bytes: [UInt8] = [0x83, 0x80, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.protocolError) = WebSocketCodec.parseHeader(
                p, n, maxPayload: 1024) else {
                Issue.record("opcode 3 is not defined and must be refused")
                return
            }
        }
    }

    @Test("a fragmented control frame is refused")
    func fragmentedControl() {
        // Close, FIN clear.
        let bytes: [UInt8] = [0x08, 0x80, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.protocolError) = WebSocketCodec.parseHeader(
                p, n, maxPayload: 1024) else {
                Issue.record("a control frame may not be fragmented")
                return
            }
        }
    }

    @Test("an oversized control frame is refused")
    func oversizedControl() {
        // Ping with a 126-byte payload: control frames cap at 125.
        let bytes: [UInt8] = [0x89, 0xFE, 0x00, 0x7E, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.protocolError) = WebSocketCodec.parseHeader(
                p, n, maxPayload: 1 << 20) else {
                Issue.record("a control frame is limited to 125 bytes")
                return
            }
        }
    }

    @Test("a payload past the message limit is refused before it is buffered")
    func tooLarge() {
        let bytes: [UInt8] = [0x82, 0xFE, 0xFF, 0xFF, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.messageTooBig) = WebSocketCodec.parseHeader(
                p, n, maxPayload: 1024) else {
                Issue.record("the limit must be applied to the declared length")
                return
            }
        }
    }

    @Test("a 64-bit length with the high bit set is refused")
    func negativeLength() {
        let bytes: [UInt8] = [0x82, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        withBytes(bytes) { p, n in
            guard case .failure(.protocolError) = WebSocketCodec.parseHeader(
                p, n, maxPayload: Int.max) else {
                Issue.record("the most significant length bit must be zero")
                return
            }
        }
    }

    @Test("unmasking is its own inverse")
    func unmaskRoundTrip() {
        let plain: [UInt8] = Array("the quick brown fox".utf8)
        let mask: (UInt8, UInt8, UInt8, UInt8) = (0x37, 0xFA, 0x21, 0x3D)
        var masked = [UInt8](repeating: 0, count: plain.count)
        var back = [UInt8](repeating: 0, count: plain.count)
        plain.withUnsafeBufferPointer { src in
            masked.withUnsafeMutableBufferPointer { dst in
                WebSocketCodec.unmask(dst.baseAddress!, src.baseAddress!, src.count, mask)
            }
        }
        #expect(masked != plain)
        masked.withUnsafeBufferPointer { src in
            back.withUnsafeMutableBufferPointer { dst in
                WebSocketCodec.unmask(dst.baseAddress!, src.baseAddress!, src.count, mask)
            }
        }
        #expect(back == plain)
    }

    @Test("a written frame parses back to what went in")
    func writeThenParse() {
        var buf = ByteBuffer()
        defer { buf.destroy() }
        let payload: [UInt8] = Array(repeating: 0x41, count: 300)
        payload.withUnsafeBufferPointer {
            WebSocketCodec.writeFrame(&buf, opcode: .binary, fin: true,
                                      payload: $0.baseAddress!, length: $0.count)
        }
        let span = buf.readableSpan
        guard case .header(let h) = WebSocketCodec.parseHeader(
            span.base, span.count, maxPayload: 1 << 20) else {
            Issue.record("expected a header")
            return
        }
        #expect(h.fin)
        #expect(h.opcode == .binary)
        // A server frame must never be masked.
        #expect(!h.masked)
        #expect(h.payloadLength == 300)
        #expect(h.totalLength == span.count)
    }

    @Test("a close frame carries its code and reason")
    func closeFrame() {
        var buf = ByteBuffer()
        defer { buf.destroy() }
        let reason: [UInt8] = Array("bye".utf8)
        reason.withUnsafeBufferPointer {
            WebSocketCodec.writeClose(&buf, code: 1001,
                                      reason: $0.baseAddress!, reasonLength: $0.count)
        }
        let span = buf.readableSpan
        guard case .header(let h) = WebSocketCodec.parseHeader(
            span.base, span.count, maxPayload: 1024) else {
            Issue.record("expected a header")
            return
        }
        #expect(h.opcode == .close)
        #expect(h.payloadLength == 5)
        let body = span.base + h.headerLength
        #expect(Int(body[0]) << 8 | Int(body[1]) == 1001)
        #expect(body[2] == UInt8(ascii: "b"))
    }

    @Test("codes reserved for local reporting are never sent")
    func closeCodeFilter() {
        #expect(WebSocketCodec.isSendableCloseCode(1000))
        #expect(WebSocketCodec.isSendableCloseCode(1009))
        #expect(WebSocketCodec.isSendableCloseCode(4000))
        #expect(!WebSocketCodec.isSendableCloseCode(1005))
        #expect(!WebSocketCodec.isSendableCloseCode(1006))
        #expect(!WebSocketCodec.isSendableCloseCode(999))
        #expect(!WebSocketCodec.isSendableCloseCode(2000))
        #expect(!WebSocketCodec.isSendableCloseCode(5000))
    }
}

@Suite("UTF-8 validation")
struct UTF8ValidatorTests {

    private func accepts(_ bytes: [UInt8]) -> Bool {
        var v = UTF8Validator()
        let ok = withBytes(bytes) { v.feed($0, $1) }
        return ok && v.isComplete
    }

    @Test("well-formed text is accepted")
    func valid() {
        #expect(accepts(Array("hello".utf8)))
        #expect(accepts(Array("héllo ☃ 𝄞".utf8)))
        #expect(accepts([]))
    }

    @Test("a truncated sequence is incomplete rather than valid")
    func truncated() {
        var v = UTF8Validator()
        let bytes: [UInt8] = [0xE2, 0x98]      // two thirds of a snowman
        #expect(withBytes(bytes) { v.feed($0, $1) })
        #expect(!v.isComplete)
    }

    @Test("a split sequence validates across feeds")
    func split() {
        var v = UTF8Validator()
        let all: [UInt8] = Array("☃".utf8)
        #expect(withBytes([all[0]]) { v.feed($0, $1) })
        #expect(withBytes([all[1], all[2]]) { v.feed($0, $1) })
        #expect(v.isComplete)
    }

    @Test("overlong encodings are refused")
    func overlong() {
        #expect(!accepts([0xC0, 0x80]))           // overlong NUL
        #expect(!accepts([0xC1, 0xBF]))
        #expect(!accepts([0xE0, 0x80, 0x80]))
        #expect(!accepts([0xF0, 0x80, 0x80, 0x80]))
    }

    @Test("surrogates and out-of-range code points are refused")
    func surrogates() {
        #expect(!accepts([0xED, 0xA0, 0x80]))     // U+D800
        #expect(!accepts([0xF4, 0x90, 0x80, 0x80]))   // beyond U+10FFFF
        #expect(!accepts([0xF5, 0x80, 0x80, 0x80]))
    }

    @Test("stray continuation bytes are refused")
    func strayContinuation() {
        #expect(!accepts([0x80]))
        #expect(!accepts([0xE2, 0x28, 0xA1]))
    }
}

@Suite("Trusted proxies")
struct ForwardedTrustTests {

    private func trust(_ spec: StaticString) -> ForwardedTrust {
        var t = ForwardedTrust()
        let ok = spec.utf8Start.withMemoryRebound(
            to: CChar.self, capacity: spec.utf8CodeUnitCount + 1) { t.parse($0) }
        #expect(ok, "\(spec) should parse")
        return t
    }

    private func trusts(_ t: ForwardedTrust, _ address: String) -> Bool {
        Array(address.utf8).withUnsafeBufferPointer { t.trusts($0.baseAddress!, $0.count) }
    }

    @Test("nothing is trusted by default")
    func defaultDenies() {
        let t = ForwardedTrust()
        #expect(t.isEmpty)
        #expect(!trusts(t, "127.0.0.1"))
    }

    @Test("a literal address matches only itself")
    func literal() {
        let t = trust("127.0.0.1")
        #expect(trusts(t, "127.0.0.1"))
        #expect(!trusts(t, "127.0.0.2"))
        #expect(!trusts(t, "10.0.0.1"))
    }

    @Test("a CIDR block matches its range and nothing outside it")
    func cidr() {
        let t = trust("10.0.0.0/8, 192.168.1.0/24")
        #expect(trusts(t, "10.0.0.1"))
        #expect(trusts(t, "10.255.255.254"))
        #expect(trusts(t, "192.168.1.7"))
        #expect(!trusts(t, "192.168.2.7"))
        #expect(!trusts(t, "11.0.0.1"))
    }

    @Test("IPv6 literals and prefixes match")
    func ipv6() {
        let t = trust("::1, fd00::/8")
        #expect(trusts(t, "::1"))
        #expect(trusts(t, "fd12:3456::9"))
        #expect(!trusts(t, "2001:db8::1"))
        // Families do not cross.
        #expect(!trusts(t, "127.0.0.1"))
    }

    @Test("a wildcard trusts everything and unix trusts only unix peers")
    func wildcards() {
        let all = trust("*")
        #expect(trusts(all, "203.0.113.1"))
        #expect(trusts(all, "unix"))

        let unixOnly = trust("unix")
        #expect(trusts(unixOnly, "unix"))
        #expect(!trusts(unixOnly, "127.0.0.1"))
    }

    @Test("a malformed entry is rejected rather than ignored")
    func malformed() {
        var t = ForwardedTrust()
        let spec: StaticString = "not-an-address"
        let ok = spec.utf8Start.withMemoryRebound(
            to: CChar.self, capacity: spec.utf8CodeUnitCount + 1) { t.parse($0) }
        #expect(!ok)
    }
}

@Suite("Forwarded header parsing")
struct ForwardedHeaderTests {

    /// Runs the reader over a synthetic request head.
    private func read(_ raw: String, trust: ForwardedTrust) -> (client: String?, https: Bool?) {
        var bytes = Array(raw.utf8)
        var head = HTTPRequestHead()
        let headers = UnsafeMutablePointer<HTTPHeaderRef>.allocate(capacity: 32)
        defer { headers.deallocate() }
        var result: (String?, Bool?) = (nil, nil)
        bytes.withUnsafeMutableBufferPointer { buf in
            let base = UnsafePointer(buf.baseAddress!)
            guard case .complete = HTTPParser.parse(base, buf.count, maxHeadSize: 8192,
                                                    maxHeaders: 32, headers: headers,
                                                    head: &head) else {
                Issue.record("the test request did not parse")
                return
            }
            let info = Forwarded.read(base: base, head: head, headers: headers, trust: trust)
            var client: String? = nil
            if let c = info.client {
                client = String(decoding: UnsafeBufferPointer(start: c.base, count: c.count),
                                as: UTF8.self)
            }
            result = (client, info.https)
        }
        return result
    }

    private var trustAll: ForwardedTrust {
        var t = ForwardedTrust()
        let spec: StaticString = "*"
        _ = spec.utf8Start.withMemoryRebound(to: CChar.self, capacity: 2) { t.parse($0) }
        return t
    }

    private var trustLocal: ForwardedTrust {
        var t = ForwardedTrust()
        let spec: StaticString = "127.0.0.1"
        _ = spec.utf8Start.withMemoryRebound(to: CChar.self, capacity: 10) { t.parse($0) }
        return t
    }

    @Test("a single hop gives the client and the scheme")
    func singleHop() {
        let r = read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.9\r\n"
                     + "X-Forwarded-Proto: https\r\n\r\n", trust: trustAll)
        #expect(r.client == "203.0.113.9")
        #expect(r.https == true)
    }

    @Test("the walk stops at the first hop that is not a trusted proxy")
    func stopsAtUntrusted() {
        // Only 127.0.0.1 is a known proxy, so 198.51.100.7 is the caller and
        // the address to its left is whatever that caller chose to claim.
        let r = read("GET / HTTP/1.1\r\nHost: x\r\n"
                     + "X-Forwarded-For: 1.2.3.4, 198.51.100.7, 127.0.0.1\r\n\r\n",
                     trust: trustLocal)
        #expect(r.client == "198.51.100.7")
    }

    @Test("a chain of trusted hops resolves to the leftmost entry")
    func allTrusted() {
        let r = read("GET / HTTP/1.1\r\nHost: x\r\n"
                     + "X-Forwarded-For: 203.0.113.9, 127.0.0.1, 127.0.0.1\r\n\r\n",
                     trust: trustLocal)
        #expect(r.client == "203.0.113.9")
    }

    @Test("ports and bracketed IPv6 literals are stripped")
    func decorations() {
        #expect(read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.9:51234\r\n\r\n",
                     trust: trustAll).client == "203.0.113.9")
        #expect(read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: [2001:db8::1]:443\r\n\r\n",
                     trust: trustAll).client == "2001:db8::1")
        // A bare IPv6 address has colons of its own and must survive intact.
        #expect(read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 2001:db8::1\r\n\r\n",
                     trust: trustAll).client == "2001:db8::1")
    }

    @Test("RFC 7239 Forwarded is understood when the X- headers are absent")
    func rfc7239() {
        let r = read("GET / HTTP/1.1\r\nHost: x\r\n"
                     + "Forwarded: for=\"198.51.100.4\";proto=https;by=10.0.0.1\r\n\r\n",
                     trust: trustAll)
        #expect(r.client == "198.51.100.4")
        #expect(r.https == true)
    }

    @Test("an untrusted peer is told nothing")
    func untrusted() {
        let r = read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-For: 203.0.113.9\r\n"
                     + "X-Forwarded-Proto: https\r\n\r\n",
                     trust: ForwardedTrust())
        #expect(r.client == nil)
        #expect(r.https == nil)
    }

    @Test("http is honoured as well as https")
    func plainScheme() {
        let r = read("GET / HTTP/1.1\r\nHost: x\r\nX-Forwarded-Proto: http\r\n\r\n",
                     trust: trustAll)
        #expect(r.https == false)
    }
}
