//===----------------------------------------------------------------------===//
// --cache-size: answering repeated requests without calling the application.
//
// A GET the application marked fresh -- `Cache-Control: s-maxage` or
// `max-age` -- is copied as it is sent, and stored in a table every shard
// shares (CGarudaShared's garuda_cache.c). A later request for the same URL,
// on any shard and over either protocol, is answered from that copy until it
// expires. What may be kept is decided in GarudaWire's ResponseCachePolicy,
// conservatively: the thing this must never do is hand one user's response
// to another.
//
// The key is the scheme, the host and the whole request target, plus the
// forwarding headers when the peer is a trusted proxy, since those change
// what the application thinks it was asked. HEAD is answered from a GET's
// copy and never stores one.
//
// A request that changes its target -- any method but GET, HEAD, OPTIONS,
// TRACE and CONNECT -- invalidates it when it is answered 2xx or 3xx (RFC
// 9111 section 4.4): its copies, and the response to any GET for it
// dispatched before then that has yet to be stored. A refusal changed
// nothing, and letting one purge would let anyone without permission to make
// the change empty the cache of it.
//
// A copy holds the application's own headers and body, not the bytes that
// went on the wire, so one copy serves HTTP/1.1 and HTTP/2 alike and is
// compressed afresh for each client that accepts it. A hit is answered
// through the same path as the application's own answers -- Date, Server,
// X-Request-ID and the rest written for it as for any -- with Age and
// `Cache-Status: garuda; hit` to say where it came from.
//===----------------------------------------------------------------------===//

import CGarudaShared
import GarudaWire
import VegaCrypto
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// The largest block of headers kept with a cached response.
let responseCacheMaxHead = 16 * 1024

/// The shared table, attached in this process.
final class ResponseCache: @unchecked Sendable {
    let handle: OpaquePointer
    /// The longest a copy is kept, whatever it says, in seconds.
    let ttlLimit: Int
    let maxHead: Int
    let maxBody: Int

    /// The region a cache of `config`'s size takes, or nil for no cache.
    static func regionSize(_ config: ServerConfig) -> Int? {
        guard config.cacheSizeMiB > 0 else { return nil }
        let bytes = gc_cache_region_size(UInt64(config.cacheSizeMiB) * 1024 * 1024,
                                         UInt32(responseCacheMaxHead), UInt32(config.cacheMaxObject))
        return bytes > 0 ? Int(bytes) : nil
    }

    init?(region: UnsafeMutableRawBufferPointer, config: ServerConfig) {
        var seed: UInt64 = 0
        for b in SecureRandom.bytes(8) { seed = seed << 8 | UInt64(b) }
        guard let handle = gc_cache_attach(region.baseAddress, UInt64(config.cacheSizeMiB) * 1024 * 1024,
                                           UInt32(responseCacheMaxHead), UInt32(config.cacheMaxObject),
                                           seed) else { return nil }
        self.handle = handle
        ttlLimit = config.cacheTTLMaxSeconds
        maxHead = responseCacheMaxHead
        maxBody = config.cacheMaxObject
    }

    deinit { gc_cache_detach(handle) }
}

/// A response being copied for the cache as it is sent: armed at dispatch
/// for a GET whose response may be kept, and dropped the moment it turns out
/// it will not be.
final class ResponseCapture: @unchecked Sendable {
    let cache: ResponseCache
    /// Where a store is counted.
    let metrics: MetricsPage?
    /// The request's number in the cache's order of events, the hash its
    /// target is invalidated through, and when it was dispatched.
    let sequence: UInt64
    let mark: UInt64
    let dispatchedMs: UInt64
    /// The key, copied from the request.
    var key: [UInt8]
    var status = 0
    /// When the head settled, how old the response was then, and how long
    /// from then it may be kept.
    var settledMs: UInt64 = 0
    var ageMs = 0
    var keepMs = 0
    var head = ByteBuffer()
    var body = ByteBuffer()
    var policy = ResponseCacheability()
    /// Ruled out: by a header, a status, a body past the limit.
    private(set) var dropped = false

    init(cache: ResponseCache, key: [UInt8], mark: UInt64, metrics: MetricsPage?) {
        self.cache = cache
        self.metrics = metrics
        self.key = key
        self.mark = mark
        sequence = gc_cache_begin(cache.handle)
        dispatchedMs = monotonicMillis()
    }

    deinit {
        head.destroy()
        body.destroy()
    }

    /// The response's head, as the application gave it: kept or not, and,
    /// when kept, for how long, now that its age is known.
    func settle(_ x: UnsafeMutablePointer<Exchange>) {
        x.pointee.forEachResponseHeader { name, value in
            policy.observe(name, value)
            if CachedHead.keeps(name) && !CachedHead.append(name: name, value: value, into: &head) {
                policy.excluded = true
            }
        }
        let now = monotonicMillis()
        let delay = now > dispatchedMs ? Int(now - dispatchedMs) : 0
        guard head.readableBytes <= cache.maxHead,
              let kept = policy.storage(status: x.pointee.status, limitSeconds: cache.ttlLimit,
                                        responseDelayMs: delay, nowSeconds: Int(time(nil))) else {
            dropped = true
            return
        }
        status = x.pointee.status
        settledMs = now
        ageMs = kept.ageMs
        keepMs = kept.keepMs
    }

    /// Body bytes as the application produced them, before any compression.
    func append(_ p: UnsafePointer<UInt8>, _ n: Int) {
        guard !dropped else { return }
        if body.readableBytes + n > cache.maxBody {
            dropped = true
            return
        }
        body.write(p, n)
    }

    /// Stores the copy. True when it was stored.
    func store() -> Bool {
        guard !dropped, status > 0, !key.isEmpty else { return false }
        // Sending the body took time, and that time is part of the copy's
        // age as it would be for a copy a client kept.
        let now = monotonicMillis()
        let sent = now > settledMs ? Int(now - settledMs) : 0
        guard sent < keepMs else { return false }
        let headLength = head.readableBytes
        let bodyLength = body.readableBytes
        let stored = key.withUnsafeBufferPointer { k in
            // An empty buffer may never have been given storage; any valid
            // pointer does for a length of zero.
            gc_cache_put(cache.handle, k.baseAddress, k.count, mark, sequence, now,
                         UInt64(ageMs + sent), UInt64(keepMs - sent), UInt16(status),
                         headLength > 0 ? UnsafePointer(head.readPointer) : k.baseAddress, headLength,
                         bodyLength > 0 ? UnsafePointer(body.readPointer) : k.baseAddress, bodyLength) == 1
        }
        if stored { metrics?.add(.cacheStores) }
        return stored
    }
}

func monotonicMillis() -> UInt64 { monotonicNanos() / 1_000_000 }

// MARK: - At dispatch

/// Answers the request from the cache and returns true, or arms the capture
/// of the application's response and returns false. A request that changes
/// its target is marked to invalidate it instead.
func cacheDispatch(_ x: UnsafeMutablePointer<Exchange>, _ app: CompiledApplication) -> Bool {
    guard let cache = app.cache else { return false }
    let method = x.pointee.head.method
    let target = x.pointee.slice(x.pointee.head.target)
    guard method == .get || method == .head else {
        // The safe methods change nothing, and CONNECT opens a tunnel rather
        // than changing what its path names.
        if method != .options && method != .trace && method != .connect {
            x.pointee.cacheInvalidates = gc_cache_target_hash(cache.handle, target.base, target.count)
            x.pointee.touchedStream = true
        }
        return false
    }
    guard !x.pointee.head.flags.contains(.upgrade), !x.pointee.head.hasBody else { return false }

    var host = ByteSpan(target.base, 0)
    var forwardedProto = ByteSpan(target.base, 0)
    var forwardedHost = ByteSpan(target.base, 0)
    var forwarded = ByteSpan(target.base, 0)
    var ifNoneMatch = false
    var ifModifiedSince: ByteSpan? = nil
    var i = 0
    while i < x.pointee.head.headerCount {
        let h = x.pointee.headers[i]
        i += 1
        let name = x.pointee.slice(h.name)
        let value = x.pointee.slice(h.value)
        if RequestCacheability.excludes(name, value) { return false }
        switch name.count {
        case 4 where equalsLowercased(name.base, 4, "host"): host = value
        case 9 where equalsLowercased(name.base, 9, "forwarded"): forwarded = value
        case 13 where equalsLowercased(name.base, 13, "if-none-match"): ifNoneMatch = true
        case 16 where equalsLowercased(name.base, 16, "x-forwarded-host"): forwardedHost = value
        case 17 where equalsLowercased(name.base, 17, "x-forwarded-proto"): forwardedProto = value
        case 17 where equalsLowercased(name.base, 17, "if-modified-since"):
            if ifModifiedSince == nil { ifModifiedSince = value }
        default: break
        }
    }

    var key: [UInt8] = []
    key.reserveCapacity(16 + host.count + target.count)
    key.append(contentsOf: x.pointee.secure ? Array("https".utf8) : Array("http".utf8))
    key.append(0)
    for k in 0..<host.count { key.append(asciiLower(host.base[k])) }
    key.append(0)
    key.append(contentsOf: UnsafeBufferPointer(start: target.base, count: target.count))
    if x.pointee.trust != nil, case .said = x.pointee.forwarded() {
        // Behind a trusted proxy, what it said changes what was asked.
        for part in [forwardedProto, forwardedHost, forwarded] {
            key.append(0)
            key.append(contentsOf: UnsafeBufferPointer(start: part.base, count: part.count))
        }
    }
    guard key.count <= Int(GC_CACHE_MAX_KEY) else { return false }

    // Looked up into the exchange's own buffer, which the answer then is.
    x.pointee.cacheScratch.clear()
    x.pointee.cacheScratch.reserve(cache.maxHead + cache.maxBody)
    var headLength: UInt32 = 0
    var bodyLength: UInt32 = 0
    var status: UInt16 = 0
    var ageMs: UInt64 = 0
    var ttlMs: UInt64 = 0
    let hit = key.withUnsafeBufferPointer { k in
        gc_cache_get(cache.handle, k.baseAddress, k.count, monotonicMillis(),
                     x.pointee.cacheScratch.writePointer, x.pointee.cacheScratch.writableBytes,
                     &headLength, &bodyLength, &status, &ageMs, &ttlMs)
    }
    guard hit == 1 else {
        app.metrics?.add(.cacheMisses)
        // Only a GET has a body worth keeping.
        if method == .get {
            x.pointee.capture = ResponseCapture(cache: cache, key: key,
                                                mark: gc_cache_target_hash(cache.handle, target.base, target.count),
                                                metrics: app.metrics)
            x.pointee.touchedStream = true
        }
        return false
    }
    app.metrics?.add(.cacheHits)
    x.pointee.cacheScratch.advanceWriter(Int(headLength) + Int(bodyLength))
    let p = UnsafePointer(x.pointee.cacheScratch.readPointer)
    let head = ByteSpan(p, Int(headLength))
    let body = ByteSpan(p + Int(headLength), Int(bodyLength))
    // A conditional request the stored 200 satisfies is answered 304, with
    // no body (RFC 9110 section 15.4.5).
    var notModified = false
    if (ifNoneMatch || ifModifiedSince != nil) && status == 200 {
        notModified = cachedNotModified(x, head, ifNoneMatch: ifNoneMatch, ifModifiedSince: ifModifiedSince)
    }
    answerFromCache(x, status: Int(status), head: head, body: body, notModified: notModified,
                    ageSeconds: Int(ageMs / 1000), ttlSeconds: Int((ttlMs + 999) / 1000))
    return true
}

/// Whether a conditional request is satisfied by the stored response. Every
/// line of If-None-Match counts, a list split over several lines being one
/// list, and it decides alone when it is there.
private func cachedNotModified(_ x: UnsafeMutablePointer<Exchange>, _ head: ByteSpan, ifNoneMatch: Bool,
                               ifModifiedSince: ByteSpan?) -> Bool {
    guard ifNoneMatch else {
        return CacheValidation.notModified(ifNoneMatch: nil, ifModifiedSince: ifModifiedSince,
                                           storedHead: head.base, head.count)
    }
    var i = 0
    while i < x.pointee.head.headerCount {
        let h = x.pointee.headers[i]
        i += 1
        let name = x.pointee.slice(h.name)
        guard name.count == 13, equalsLowercased(name.base, 13, "if-none-match") else { continue }
        if CacheValidation.notModified(ifNoneMatch: x.pointee.slice(h.value), ifModifiedSince: nil,
                                       storedHead: head.base, head.count) {
            return true
        }
    }
    return false
}

/// Makes the stored response the answer, as the application would have:
/// its headers, its body, and what says it came from the cache.
private func answerFromCache(_ x: UnsafeMutablePointer<Exchange>, status: Int, head: ByteSpan, body: ByteSpan,
                             notModified: Bool, ageSeconds: Int, ttlSeconds: Int) {
    var eligibility = CompressionEligibility()
    var tags: [[UInt8]] = []
    CachedHead.forEach(head.base, head.count) { name, value in
        if x.pointee.compress { eligibility.observe(name, value) }
        // A 304 repeats only some of what its 200 had.
        if notModified && !CacheValidation.keptInNotModified(name) { return }
        if notModified && EntityTag.isName(name) {
            tags.append(Array(UnsafeBufferPointer(start: value.base, count: value.count)))
            return
        }
        _ = x.pointee.addHeader(name, value)
    }
    if notModified {
        // The Vary and the ETag a 304 repeats are the ones its 200 would
        // have had, and both turn on how the 200 would be encoded for this
        // client.
        var coding = ContentCoding.identity
        if x.pointee.compress {
            if eligibility.mayVary(status: status) && !eligibility.varyCovered {
                Response(x).addHeader("vary", "Accept-Encoding")
            }
            coding = eligibility.choose(offered: x.pointee.acceptedCoding, status: status, bodyAllowed: true,
                                        declaredLength: body.count, minimumLength: x.pointee.compressMinimum)
        }
        for tag in tags {
            let sent = coding != .identity && tag.count >= 2 && tag.first == 0x22 && tag.last == 0x22
                ? Array("W/".utf8) + tag : tag
            sent.withUnsafeBufferPointer { Response(x).addHeader("etag", $0.span) }
        }
        x.pointee.noCompress = true
    }
    Response(x).addHeader("age", String(ageSeconds))
    Response(x).addHeader("cache-status", "garuda; hit; ttl=\(ttlSeconds)")
    // The copy is the answer as it stands: its bytes are the exchange's
    // own, read into its scratch buffer.
    x.pointee.answer(notModified ? 304 : status, notModified ? nil : body.base, notModified ? 0 : body.count)
}

// MARK: - As the answer goes

/// The answer to `x` is about to be written whole: a change to its target is
/// recorded, and a copy being made is stored.
func cacheAnswer(_ x: UnsafeMutablePointer<Exchange>) {
    if x.pointee.cacheInvalidates != 0 { invalidateIfChanged(x) }
    guard let capture = x.pointee.capture else { return }
    x.pointee.capture = nil
    capture.settle(x)
    x.pointee.settleHeldBody()
    let count = x.pointee.responseBody.readableBytes
    // A body that disagrees with the length its head declares is sent as it
    // is, and kept by nobody.
    let declared = x.pointee.headerKinds.contains(.contentLength) ? declaredLength(x) : -1
    guard declared < 0 || declared == count else { return }
    if count > 0 { capture.append(UnsafePointer(x.pointee.responseBody.readPointer), count) }
    _ = capture.store()
}

/// The answer to `x` is a streamed body: the copy, if one is being made,
/// goes with the body, and is stored when it ends whole.
func cacheStreamStart(_ x: UnsafeMutablePointer<Exchange>) -> ResponseCapture? {
    if x.pointee.cacheInvalidates != 0 { invalidateIfChanged(x) }
    guard let capture = x.pointee.capture else { return nil }
    x.pointee.capture = nil
    capture.settle(x)
    return capture.dropped ? nil : capture
}

/// A request that changes its target was answered: a success means the
/// application changed what the target is.
private func invalidateIfChanged(_ x: UnsafeMutablePointer<Exchange>) {
    let mark = x.pointee.cacheInvalidates
    x.pointee.cacheInvalidates = 0
    let status = x.pointee.status
    guard status >= 200 && status < 400, let app = x.pointee.application else { return }
    app._withUnsafeGuaranteedRef { app in
        if let cache = app.cache { gc_cache_invalidate(cache.handle, mark) }
    }
}
