//===----------------------------------------------------------------------===//
// Forwarded-header parsing and trusted proxies.
//
// A wrong answer here is a client address a caller can forge. These tests
// sat with the WebSocket framing tests, which moved to Vega's VegaWireTests.
//===----------------------------------------------------------------------===//

import Testing

@testable import GarudaWire

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
