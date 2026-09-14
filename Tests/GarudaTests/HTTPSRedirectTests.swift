//===----------------------------------------------------------------------===//
// --redirect-http: the Location a plain request is sent to, and what is refused.
//===----------------------------------------------------------------------===//

import Testing
@testable import GarudaCore
@testable import GarudaHTTP

/// The Location for `host` and `target`, or nil when the request is refused.
private func location(_ host: String?, _ target: String, port: UInt16 = 8443) -> String? {
    var out = ByteBuffer()
    defer { out.destroy() }
    // A terminator keeps the pointers valid for empty strings.
    var t = Array(target.utf8)
    t.append(0)
    var h = Array((host ?? "").utf8)
    h.append(0)
    let ok = t.withUnsafeBufferPointer { tp in
        h.withUnsafeBufferPointer { hp in
            HTTPSRedirect.location(host: host == nil ? nil : ByteSpan(hp.baseAddress!, hp.count - 1),
                                   target: ByteSpan(tp.baseAddress!, tp.count - 1),
                                   httpsPort: port, into: &out)
        }
    }
    guard ok else { return nil }
    return String(decoding: UnsafeBufferPointer(start: out.readPointer, count: out.readableBytes),
                  as: UTF8.self)
}

@Test("the path and query survive, and the port becomes the TLS one")
func redirectKeepsPathAndQuery() {
    #expect(location("example.com", "/a/b?x=1&y=%20") == "https://example.com:8443/a/b?x=1&y=%20")
    #expect(location("example.com:80", "/") == "https://example.com:8443/")
    #expect(location("example.com:", "/") == "https://example.com:8443/")
    #expect(location("Example.COM", "/") == "https://Example.COM:8443/")
    #expect(location("10.0.0.1:8080", "/x") == "https://10.0.0.1:8443/x")
}

@Test("port 443 is left out of the Location")
func redirectOmitsDefaultPort() {
    #expect(location("example.com", "/", port: 443) == "https://example.com/")
}

@Test("an IPv6 literal keeps its brackets")
func redirectIPv6() {
    #expect(location("[2001:db8::1]:80", "/") == "https://[2001:db8::1]:8443/")
    #expect(location("[::ffff:10.0.0.1]", "/p") == "https://[::ffff:10.0.0.1]:8443/p")
    #expect(location("[::1", "/") == nil)
    #expect(location("[]", "/") == nil)
    #expect(location("[::1]x", "/") == nil)
    #expect(location("[fe80::1%eth0]", "/") == nil)
}

@Test("an absolute-form target supplies the host, over Host")
func redirectAbsoluteForm() {
    #expect(location("ignored.example", "http://example.org/p?q") == "https://example.org:8443/p?q")
    #expect(location(nil, "HTTP://example.org") == "https://example.org:8443/")
    #expect(location(nil, "https://example.org?q") == "https://example.org:8443/?q")
    #expect(location(nil, "http:///p") == nil)
}

@Test("anything that is not a host is refused")
func redirectRefusesBadHosts() {
    #expect(location(nil, "/") == nil)
    #expect(location("", "/") == nil)
    #expect(location("evil.com/x", "/") == nil)
    #expect(location("user@example.com", "/") == nil)
    #expect(location("example.com:8x", "/") == nil)
    #expect(location("exa mple.com", "/") == nil)
    #expect(location("example.com\r\nSet-Cookie: a=b", "/") == nil)
    #expect(location(String(repeating: "a", count: 256), "/") == nil)
}

@Test("a target that is not a path or absolute is refused")
func redirectRefusesBadTargets() {
    #expect(location("example.com", "*") == nil)
    #expect(location("example.com", "example.com:443") == nil)
    #expect(location("example.com", "") == nil)
    #expect(location("example.com", "/a b") == nil)
    #expect(location("example.com", "/a\u{7F}") == nil)
    #expect(location("example.com", "/caf\u{E9}") == nil)
}

@Test("GET and HEAD are 301; every other method is 308")
func redirectStatus() {
    #expect(HTTPSRedirect.status(for: .get) == 301)
    #expect(HTTPSRedirect.status(for: .head) == 301)
    #expect(HTTPSRedirect.status(for: .post) == 308)
    #expect(HTTPSRedirect.status(for: .put) == 308)
    #expect(HTTPSRedirect.status(for: .other) == 308)
}
