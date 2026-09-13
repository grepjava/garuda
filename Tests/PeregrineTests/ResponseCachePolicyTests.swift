//===----------------------------------------------------------------------===//
// --cache-size: what a shared cache may keep, and what keeps a request out.
//===----------------------------------------------------------------------===//

import Testing
@testable import PeregrineCore
@testable import PeregrineHTTP

private func withSpan<T>(_ s: String, _ body: (ByteSpan) -> T) -> T {
    var bytes = Array(s.utf8)
    // A terminator keeps the pointer valid for an empty string.
    bytes.append(0)
    return bytes.withUnsafeBufferPointer { body(ByteSpan($0.baseAddress!, $0.count - 1)) }
}

private func control(_ value: String) -> CacheControl {
    var c = CacheControl()
    withSpan(value) { c.parse($0.base, $0.count) }
    return c
}

private func fresh(_ headers: [(String, String)], status: Int = 200, limit: Int = 300) -> Int {
    var policy = ResponseCacheability()
    for (name, value) in headers {
        withSpan(name) { n in withSpan(value) { v in policy.observe(n, v) } }
    }
    return policy.freshSeconds(status: status, limit: limit)
}

private func excludes(_ name: String, _ value: String) -> Bool {
    withSpan(name) { n in withSpan(value) { v in RequestCacheability.excludes(n, v) } }
}

@Test("Cache-Control directives are read, quoted or not, in any case")
func cacheControlParsing() {
    let c = control("public, Max-Age=60, s-maxage=\"30\"")
    #expect(c.maxAge == 60)
    #expect(c.sharedMaxAge == 30)
    #expect(!c.isPrivate && !c.noStore && !c.noCache)
    #expect(control("private=\"set-cookie\"").isPrivate)
    #expect(control("no-store").noStore)
    #expect(control("no-cache=\"x-y\"").noCache)
    #expect(control("max-age").maxAge == -1)
    #expect(control("max-age=soon").noCache)
    #expect(control("max-age=60, max-age=10").maxAge == 10)
    #expect(control(",,  ,").maxAge == -1)
}

@Test("a response is kept only for as long as it says, and never past the limit")
func responseFreshness() {
    #expect(fresh([("Cache-Control", "public, max-age=60")]) == 60)
    #expect(fresh([("cache-control", "max-age=60, s-maxage=5")]) == 5)
    #expect(fresh([("Cache-Control", "s-maxage=0, max-age=60")]) == 0)
    #expect(fresh([("Cache-Control", "max-age=86400")], limit: 300) == 300)
    #expect(fresh([]) == 0)
    #expect(fresh([("Cache-Control", "max-age=60")], status: 500) == 0)
    #expect(fresh([("Cache-Control", "max-age=60")], status: 404) == 60)
}

@Test("private, no-store, no-cache, cookies, other Vary fields and encodings are not kept")
func responseExclusions() {
    let cc = ("Cache-Control", "max-age=60")
    #expect(fresh([("Cache-Control", "max-age=60, private")]) == 0)
    #expect(fresh([("Cache-Control", "max-age=60, no-store")]) == 0)
    #expect(fresh([("Cache-Control", "max-age=60, no-cache")]) == 0)
    #expect(fresh([cc, ("Set-Cookie", "id=1")]) == 0)
    #expect(fresh([cc, ("Vary", "Cookie")]) == 0)
    #expect(fresh([cc, ("Vary", "*")]) == 0)
    #expect(fresh([cc, ("Vary", "accept-encoding, User-Agent")]) == 0)
    #expect(fresh([cc, ("Content-Encoding", "gzip")]) == 0)
    #expect(fresh([cc, ("Vary", "Accept-Encoding")]) == 60)
    #expect(fresh([cc, ("Vary", "")]) == 60)
}

@Test("credentials, cookies, ranges and a reload keep a request out of the cache")
func requestExclusions() {
    #expect(excludes("Authorization", "Bearer x"))
    #expect(excludes("cookie", "a=b"))
    #expect(excludes("Range", "bytes=0-1"))
    #expect(excludes("Cache-Control", "no-cache"))
    #expect(excludes("Cache-Control", "max-age=0"))
    #expect(excludes("Pragma", "no-cache"))
    #expect(!excludes("Cache-Control", "max-age=60"))
    #expect(!excludes("Accept", "text/html"))
    #expect(!excludes("User-Agent", "curl"))
}

@Test("stored headers round trip, lowercased, without framing or per-copy fields")
func cachedHeadRoundTrip() {
    var block = ByteBuffer()
    defer { block.destroy() }
    let headers = [("Content-Type", "text/html"), ("X-Empty", ""), ("ETag", "\"v1\"")]
    for (name, value) in headers {
        withSpan(name) { n in withSpan(value) { v in
            #expect(CachedHead.append(name: n, value: v, into: &block))
        } }
    }
    var seen: [(String, String)] = []
    CachedHead.forEach(UnsafePointer(block.readPointer), block.readableBytes) { n, v in
        seen.append((String(decoding: UnsafeBufferPointer(start: n.base, count: n.count), as: UTF8.self),
                     String(decoding: UnsafeBufferPointer(start: v.base, count: v.count), as: UTF8.self)))
    }
    #expect(seen.map { $0.0 } == ["content-type", "x-empty", "etag"])
    #expect(seen.map { $0.1 } == ["text/html", "", "\"v1\""])
    for name in ["Content-Length", "transfer-encoding", "Connection", "Date", "Age", "X-Request-ID"] {
        #expect(!withSpan(name) { CachedHead.keeps($0) })
    }
    #expect(withSpan("Cache-Control") { CachedHead.keeps($0) })
}
