//===----------------------------------------------------------------------===//
// --cache-size: answering repeated requests without calling the application.
//
// A GET the application marked fresh -- `Cache-Control: s-maxage` or
// `max-age` -- is copied as it is sent, and stored in a table every worker
// shares (garuda_cache.c). A later request for the same URL, on any worker
// and over any protocol, is answered from that copy until it expires. What may
// be kept is decided in GarudaHTTP's ResponseCachePolicy, conservatively:
// the thing this must never do is hand one user's response to another.
//
// The key is the scheme, the host and the whole request target, plus the
// forwarding headers when the peer is a trusted proxy, since those change
// what the application thinks it was asked. HEAD is answered from a GET's
// copy and never stores one.
//
// A request that changes its target -- any method but GET, HEAD, OPTIONS,
// TRACE and CONNECT -- is marked at dispatch. When its response has a 2xx or
// 3xx status, the target is invalidated in the table (RFC 9111 section 4.4):
// its copies, and the response to any GET for it dispatched before then that
// has yet to be stored.
//
// A copy is kept for what is left of the response's freshness lifetime once
// its age -- Age, Date, and the time the application took -- is taken off.
//
// A copy holds the application's own headers and body, not the bytes that
// went on the wire, so one copy serves HTTP/1.1, HTTP/2 and HTTP/3 alike and
// is compressed afresh for each client that accepts it. Date, Age,
// X-Request-ID, HSTS and the rest of what the server adds are written for
// every response as it is sent, with `Cache-Status: garuda; hit` to say
// where it came from.
//
// The copy is taken in one place per application interface: for ASGI as the
// messages arrive, for WSGI in the response builder shared by the inline and
// pooled paths. Either way it is stored only when the response ended the way
// its head said it would.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaHTTP

/// The largest block of headers kept with a cached response.
let responseCacheMaxHead = 16 * 1024

/// A response being copied for the cache as it is sent.
///
/// Armed at dispatch for a request whose response may be kept, and disarmed
/// the moment it turns out it will not be: a status or header that rules it
/// out, a body past the limit, a response that ended short.
public struct ResponseCapture {
    public private(set) var active = false
    var ttlLimit = 0
    var status = 0
    /// The request's number in the cache's order of events, the hash its
    /// target is invalidated through, and when it was dispatched.
    var sequence: UInt64 = 0
    var mark: UInt64 = 0
    var dispatchedMs: UInt64 = 0
    /// When the head settled, how old the response was then, and how long
    /// from then it may be kept.
    var settledMs: UInt64 = 0
    var ageMs = 0
    var keepMs = 0
    var head = ByteBuffer()
    var body = ByteBuffer()
    var policy = ResponseCacheability()

    public init() {}

    /// Starts copying the response to a request dispatched now, whose target
    /// hashes to `mark`. The number is taken before the application runs, so
    /// a change to the target made while it is still answering keeps this
    /// response out of the cache.
    mutating func arm(ttlLimit: Int, mark: UInt64) {
        abandon()
        active = true
        self.ttlLimit = ttlLimit
        self.mark = mark
        sequence = pg_cache_begin()
        dispatchedMs = pg_monotonic_ms()
    }

    /// Carries an armed capture over to the WSGI pool job that fills it.
    mutating func arm(continuing other: ResponseCapture) {
        abandon()
        active = other.active
        ttlLimit = other.ttlLimit
        mark = other.mark
        sequence = other.sequence
        dispatchedMs = other.dispatchedMs
    }

    /// One response header, as the application gave it.
    public mutating func observe(_ name: ByteSpan, _ value: ByteSpan) {
        policy.observe(name, value)
        if CachedHead.keeps(name) && !CachedHead.append(name: name, value: value, into: &head) {
            policy.excluded = true
        }
    }

    /// Every header has been seen: the response is kept or it is not, and how
    /// old it already is decides for how long.
    public mutating func settle(status: Int) {
        let now = pg_monotonic_ms()
        let delay = now > dispatchedMs ? Int(now - dispatchedMs) : 0
        guard head.readableBytes <= Int(pg_cache_max_head()),
              let kept = policy.storage(status: status, limitSeconds: ttlLimit,
                                        responseDelayMs: delay,
                                        nowSeconds: Int(pg_unix_seconds())) else {
            abandon()
            return
        }
        self.status = status
        settledMs = now
        ageMs = kept.ageMs
        keepMs = kept.keepMs
    }

    /// Body bytes as the application produced them, before any compression.
    public mutating func append(_ p: UnsafePointer<UInt8>, _ n: Int) {
        if body.readableBytes + n > Int(pg_cache_max_body()) {
            abandon()
            return
        }
        body.write(p, n)
    }

    /// Stores the copy under `key` and lets it go. True when it was stored.
    mutating func store(key: borrowing ByteBuffer) -> Bool {
        defer { abandon() }
        let keyLength = key.readableBytes
        guard active, status > 0, keyLength > 0 else { return false }
        // Sending the body took time, and that time is part of the copy's age
        // as it would be for a copy a client kept.
        let now = pg_monotonic_ms()
        let sent = now > settledMs ? Int(now - settledMs) : 0
        guard sent < keepMs else { return false }
        let keyPointer = UnsafePointer(key.readPointer)
        let headLength = head.readableBytes
        let bodyLength = body.readableBytes
        // An empty buffer may never have been given storage; any valid pointer
        // does for a length of zero.
        let stored = pg_cache_put(keyPointer, keyLength, mark, sequence, now,
                                  UInt64(ageMs + sent), UInt64(keepMs - sent), UInt16(status),
                                  headLength > 0 ? UnsafePointer(head.readPointer) : keyPointer,
                                  headLength,
                                  bodyLength > 0 ? UnsafePointer(body.readPointer) : keyPointer,
                                  bodyLength)
        return stored == 1
    }

    /// Stops copying and gives the memory back: a copy can be as large as the
    /// largest body the cache keeps, and most connections never need one.
    public mutating func abandon() {
        active = false
        status = 0
        sequence = 0
        mark = 0
        dispatchedMs = 0
        settledMs = 0
        ageMs = 0
        keepMs = 0
        policy = ResponseCacheability()
        head.destroy()
        body.destroy()
    }
}

extension Worker {

    /// The connection's capture, for the WSGI builder, which writes through a
    /// pointer because it is shared with pool threads that own no connection.
    /// The table's slots do not move, so neither does this.
    func capturePointer(_ slot: Int) -> UnsafeMutablePointer<ResponseCapture> {
        let offset = MemoryLayout<Connection>.offset(of: \Connection.capture)!
        return (UnsafeMutableRawPointer(table[slot]) + offset)
            .assumingMemoryBound(to: ResponseCapture.self)
    }

    // MARK: - Invalidation

    /// A request that changes its target has been answered with `status`. A
    /// success means the application changed what the target is, so every
    /// copy of it, and the response to any GET for it still being produced,
    /// describes what it was (RFC 9111 section 4.4). A refusal changed
    /// nothing, and letting one purge would let anyone without permission to
    /// make the change empty the cache of it.
    mutating func cacheResponded(_ slot: Int, status: Int) {
        let c = table[slot]
        c.pointee.flags.remove(.invalidatesCache)
        if status >= 200 && status < 400 { pg_cache_invalidate(c.pointee.cacheMark) }
    }

    // MARK: - Lookup

    /// At dispatch: answers the request from the cache and returns true, or
    /// arms the capture of the application's response and returns false. A
    /// request that changes its target is marked to invalidate it instead.
    mutating func cacheDispatch(_ slot: Int) -> Bool {
        let c = table[slot]
        c.pointee.capture.abandon()
        let method = c.pointee.head.method
        let base = c.pointee.headBase()
        guard method == .get || method == .head else {
            // The safe methods change nothing, and CONNECT opens a tunnel or
            // a session rather than changing what its path names.
            if method != .options && method != .trace && method != .connect {
                let target = c.pointee.head.target.span(in: base)
                c.pointee.cacheMark = pg_cache_target_hash(target.base, target.count)
                c.pointee.flags.insert(.invalidatesCache)
            }
            return false
        }
        guard !c.pointee.head.flags.contains(.upgrade), !c.pointee.head.hasBody else { return false }

        var host = ByteSpan(base, 0)
        var forwardedProto = ByteSpan(base, 0)
        var forwardedHost = ByteSpan(base, 0)
        var forwarded = ByteSpan(base, 0)
        var ifNoneMatch: ByteSpan? = nil
        var ifModifiedSince: ByteSpan? = nil
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            let name = ByteSpan(base + Int(h.name.offset), Int(h.name.length))
            let value = h.value.span(in: base)
            if RequestCacheability.excludes(name, value) { return false }
            switch name.count {
            case 4 where equalsLowercased(name.base, 4, "host"): host = value
            case 9 where equalsLowercased(name.base, 9, "forwarded"): forwarded = value
            case 13 where equalsLowercased(name.base, 13, "if-none-match"):
                if ifNoneMatch == nil { ifNoneMatch = value }
            case 16 where equalsLowercased(name.base, 16, "x-forwarded-host"): forwardedHost = value
            case 17 where equalsLowercased(name.base, 17, "x-forwarded-proto"): forwardedProto = value
            case 17 where equalsLowercased(name.base, 17, "if-modified-since"):
                if ifModifiedSince == nil { ifModifiedSince = value }
            default: break
            }
        }

        c.pointee.cacheKey.clear()
        if c.pointee.isStream {
            c.pointee.cacheKey.write(c.pointee.h2Scheme ? "https" : "http")
        } else if c.pointee.tls != nil {
            c.pointee.cacheKey.write("https")
        } else {
            let scheme = config.scheme
            let length = strlen(scheme)
            scheme.withMemoryRebound(to: UInt8.self, capacity: length) {
                c.pointee.cacheKey.write($0, length)
            }
        }
        c.pointee.cacheKey.writeByte(0)
        c.pointee.cacheKey.reserve(host.count)
        var k = 0
        while k < host.count {
            c.pointee.cacheKey.writeByte(asciiLower(host.base[k]))
            k += 1
        }
        c.pointee.cacheKey.writeByte(0)
        c.pointee.cacheKey.write(c.pointee.head.target.span(in: base))
        if !config.trust.isEmpty && peerIsTrusted(slot) {
            c.pointee.cacheKey.writeByte(0)
            if forwardedProto.count > 0 { c.pointee.cacheKey.write(forwardedProto) }
            c.pointee.cacheKey.writeByte(0)
            if forwardedHost.count > 0 { c.pointee.cacheKey.write(forwardedHost) }
            c.pointee.cacheKey.writeByte(0)
            if forwarded.count > 0 { c.pointee.cacheKey.write(forwarded) }
        }
        let keyLength = c.pointee.cacheKey.readableBytes
        guard keyLength <= Int(PG_CACHE_MAX_KEY) else { return false }

        let capacity = Int(pg_cache_max_head()) + Int(pg_cache_max_body())
        cacheScratch.reserve(capacity)
        var headLength: UInt32 = 0
        var bodyLength: UInt32 = 0
        var status: UInt16 = 0
        var ageMs: UInt64 = 0
        var ttlMs: UInt64 = 0
        let hit = pg_cache_get(UnsafePointer(c.pointee.cacheKey.readPointer), keyLength,
                               pg_monotonic_ms(), cacheScratch.writePointer,
                               cacheScratch.writableBytes, &headLength, &bodyLength,
                               &status, &ageMs, &ttlMs)
        if hit == 1 {
            if Metrics.enabled { Metrics.add(PG_M_CACHE_HITS) }
            let p = UnsafePointer(cacheScratch.writePointer)
            var entry = CachedEntry(status: Int(status),
                                    head: ByteSpan(p, Int(headLength)),
                                    body: ByteSpan(p + Int(headLength), Int(bodyLength)),
                                    ageSeconds: Int(ageMs / 1000),
                                    ttlSeconds: Int((ttlMs + 999) / 1000),
                                    notModified: false)
            // A conditional request the stored 200 satisfies is answered 304,
            // with no body (RFC 9110 section 15.4.5). The entry keeps the whole
            // 200 all the same: the Vary and the ETag a 304 repeats are the
            // ones the 200 would have had, and both turn on how the 200 would
            // be encoded for this client.
            if (ifNoneMatch != nil || ifModifiedSince != nil) && entry.status == 200
                && cachedNotModified(slot, entry, ifNoneMatch: ifNoneMatch != nil,
                                     ifModifiedSince: ifModifiedSince) {
                entry.notModified = true
            }
            if c.pointee.isH3Stream {
                serveCachedH3(slot, entry)
            } else if c.pointee.isStream {
                serveCachedH2(slot, entry)
            } else {
                serveCachedH1(slot, entry)
            }
            return true
        }
        if Metrics.enabled { Metrics.add(PG_M_CACHE_MISSES) }
        // Only a GET has a body worth keeping.
        if method == .get {
            let target = c.pointee.head.target.span(in: base)
            c.pointee.capture.arm(ttlLimit: config.cacheTTLMaxSeconds,
                                  mark: pg_cache_target_hash(target.base, target.count))
        }
        return false
    }

    // MARK: - Serving a copy

    struct CachedEntry {
        var status: Int
        var head: ByteSpan
        var body: ByteSpan
        var ageSeconds: Int
        var ttlSeconds: Int
        /// Answered 304 in place of the stored 200.
        var notModified: Bool

        /// The status the response goes out with.
        var sentStatus: Int { notModified ? 304 : status }

        /// Whether a stored header goes out with the response: all of them,
        /// or for a 304 the ones it repeats.
        func sends(_ name: ByteSpan) -> Bool {
            !notModified || CacheValidation.keptInNotModified(name)
        }
    }

    /// Whether a conditional request is satisfied by the stored response.
    /// If-None-Match, when there is one, decides alone, and every line of it
    /// counts: a list split over several lines is still one list (RFC 9110
    /// section 5.3), and it matches when any member does.
    private func cachedNotModified(_ slot: Int, _ entry: CachedEntry, ifNoneMatch: Bool,
                                   ifModifiedSince: ByteSpan?) -> Bool {
        guard ifNoneMatch else {
            return CacheValidation.notModified(ifNoneMatch: nil, ifModifiedSince: ifModifiedSince,
                                               storedHead: entry.head.base, entry.head.count)
        }
        let c = table[slot]
        let base = c.pointee.headBase()
        var i = 0
        while i < c.pointee.head.headerCount {
            let h = headers[i]
            i += 1
            guard h.name.length == 13,
                  equalsLowercased(base + Int(h.name.offset), 13, "if-none-match") else { continue }
            if CacheValidation.notModified(ifNoneMatch: h.value.span(in: base), ifModifiedSince: nil,
                                           storedHead: entry.head.base, entry.head.count) {
                return true
            }
        }
        return false
    }

    /// Compression's view of the stored response, a 304's included.
    private func cachedEligibility(_ entry: CachedEntry) -> CompressionEligibility {
        var eligibility = CompressionEligibility()
        if config.compress {
            CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
                eligibility.observe(name, value)
            }
        }
        return eligibility
    }

    /// The body as this client gets it: compressed when the copy may be and
    /// the client accepts a coding, in which case `scratch` holds the result.
    /// A 304 gets no body, and the coding the 200 would have had, which is
    /// what decides the ETag it repeats.
    private func cachedPayload(_ slot: Int, _ entry: CachedEntry,
                               eligibility: CompressionEligibility,
                               into scratch: inout ByteBuffer) -> (ByteSpan, ContentCoding) {
        let c = table[slot]
        let nothing = ByteSpan(entry.body.base, 0)
        guard config.compress else { return (entry.notModified ? nothing : entry.body, .identity) }
        let coding = eligibility.choose(offered: c.pointee.acceptedCoding, status: entry.status,
                                        bodyAllowed: !HTTPResponseWriter.statusForbidsBody(entry.status),
                                        declaredLength: entry.body.count,
                                        minimumLength: config.compressMinimumLength)
        if entry.notModified { return (nothing, coding) }
        guard coding != .identity else { return (entry.body, .identity) }
        var encoder = ResponseEncoder()
        defer { encoder.destroy() }
        guard encoder.start(coding),
              encoder.encode(entry.body.base, entry.body.count, flush: false,
                             into: &scratch, chunked: false),
              encoder.finish(into: &scratch, chunked: false) else {
            scratch.clear()
            return (entry.body, .identity)
        }
        return (ByteSpan(UnsafePointer(scratch.readPointer), scratch.readableBytes), coding)
    }

    /// `garuda; hit; ttl=N`, the value of Cache-Status (RFC 9211).
    private func writeCacheStatus(_ entry: CachedEntry, into out: inout ByteBuffer) {
        out.write("garuda; hit; ttl=")
        out.writeDecimal(entry.ttlSeconds)
    }

    private mutating func serveCachedH1(_ slot: Int, _ entry: CachedEntry) {
        let c = table[slot]
        dates.refresh()
        let compress = config.compress
        let eligibility = cachedEligibility(entry)
        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)

        var seen: ResponseHeaderKind = []
        var weak = ByteBuffer()
        defer { weak.destroy() }
        c.pointee.write.reserve(entry.head.count + 512)
        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: entry.sentStatus)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            guard entry.sends(name) else { return }
            seen.formUnion(HTTPResponseWriter.classify(name))
            let sent = EntityTag.isName(name)
                ? EntityTag.sent(value, coding: coding, scratch: &weak) : value
            _ = HTTPResponseWriter.writeHeader(&c.pointee.write, name: name, value: sent)
        }
        // A 304 says Vary exactly when its 200 would.
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            c.pointee.write.write("Vary: Accept-Encoding\r\n")
        }
        if coding != .identity && !entry.notModified {
            c.pointee.write.write("Content-Encoding: ")
            c.pointee.write.write(coding.token)
            c.pointee.write.writeCRLF()
        }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.sentStatus)
        if !forbids { HTTPResponseWriter.writeContentLength(&c.pointee.write, payload.count) }
        if !seen.contains(.date) { HTTPResponseWriter.writeDate(&c.pointee.write, dates) }
        if !seen.contains(.server) { c.pointee.write.write("Server: garuda\r\n") }
        if let altSvc = config.altSvc, !seen.contains(.altSvc) {
            c.pointee.write.write("Alt-Svc: ")
            c.pointee.write.write(altSvc, config.altSvcLength)
            c.pointee.write.writeCRLF()
        }
        if !seen.contains(.hsts) { writeHSTS(&c.pointee.write) }
        writeRequestIDHeader(slot, &c.pointee.write)
        c.pointee.write.write("Age: ")
        c.pointee.write.writeDecimal(entry.ageSeconds)
        c.pointee.write.write("\r\nCache-Status: ")
        writeCacheStatus(entry, into: &c.pointee.write)
        c.pointee.write.writeCRLF()
        HTTPResponseWriter.writeConnection(&c.pointee.write,
                                           keepAlive: c.pointee.flags.contains(.keepAlive))
        HTTPResponseWriter.endHead(&c.pointee.write)
        if !forbids && !c.pointee.flags.contains(.suppressBody) && payload.count > 0 {
            c.pointee.write.write(payload.base, payload.count)
        }
        logAccess(slot, status: entry.sentStatus)
        c.pointee.state = .writing
        // As for a health probe: `flush` finishes the response once the
        // buffer drains, and a keep-alive connection reads its next head.
        _ = flush(slot)
    }

    private mutating func serveCachedH2(_ slot: Int, _ entry: CachedEntry) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h2 = table[parent].pointee.h2 else {
            closeConnection(slot)
            return
        }
        dates.refresh()
        let compress = config.compress
        let eligibility = cachedEligibility(entry)
        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)

        var block = ByteBuffer()
        defer { block.destroy() }
        var seen: ResponseHeaderKind = []
        var weak = ByteBuffer()
        defer { weak.destroy() }
        h2.encoder.encodeStatus(entry.sentStatus, into: &block)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            guard entry.sends(name) else { return }
            seen.formUnion(HTTPResponseWriter.classify(name))
            let sent = EntityTag.isName(name)
                ? EntityTag.sent(value, coding: coding, scratch: &weak) : value
            // Stored lowercase, and checked when the application first sent it.
            h2.encoder.encode(name: name.base, nameLength: name.count,
                              value: sent.count > 0 ? sent.base : emptyH2Byte,
                              valueLength: sent.count, into: &block)
        }
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            encodeStatic(h2, "vary", "accept-encoding", into: &block)
        }
        if coding != .identity && !entry.notModified {
            encodeStatic(h2, "content-encoding", coding.token, into: &block)
        }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.sentStatus)
        var digits = ByteBuffer()
        defer { digits.destroy() }
        if !forbids {
            digits.writeDecimal(payload.count)
            encodeStatic(h2, "content-length", UnsafePointer(digits.readPointer),
                         digits.readableBytes, into: &block)
        }
        if !seen.contains(.date) {
            encodeStatic(h2, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !seen.contains(.server) { encodeStatic(h2, "server", "garuda", into: &block) }
        if let altSvc = config.altSvc, !seen.contains(.altSvc) {
            encodeStatic(h2, "alt-svc", altSvc, config.altSvcLength, into: &block)
        }
        if let hsts = config.hsts, !seen.contains(.hsts) {
            encodeStatic(h2, "strict-transport-security", hsts, config.hstsLength, into: &block)
        }
        if config.requestID && c.pointee.requestID.readableBytes > 0 {
            encodeStatic(h2, "x-request-id", UnsafePointer(c.pointee.requestID.readPointer),
                         c.pointee.requestID.readableBytes, into: &block)
        }
        digits.clear()
        digits.writeDecimal(entry.ageSeconds)
        encodeStatic(h2, "age", UnsafePointer(digits.readPointer), digits.readableBytes, into: &block)
        digits.clear()
        writeCacheStatus(entry, into: &digits)
        encodeStatic(h2, "cache-status", UnsafePointer(digits.readPointer), digits.readableBytes,
                     into: &block)

        let sendBody = !forbids && !c.pointee.flags.contains(.suppressBody) && payload.count > 0
        writeHeaderBlock(slot, h2, block: &block, endStream: !sendBody)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: entry.sentStatus)
        if !sendBody {
            c.pointee.flags.insert(.responseComplete)
            _ = flush(parent)
            closeStream(slot, resetWith: nil)
            return
        }
        c.pointee.write.write(payload.base, payload.count)
        c.pointee.responseRemaining = -1
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    private mutating func serveCachedH3(_ slot: Int, _ entry: CachedEntry) {
        let c = table[slot]
        let parent = Int(c.pointee.parentSlot)
        guard parent >= 0, let h3 = table[parent].pointee.h3 else {
            closeConnection(slot)
            return
        }
        dates.refresh()
        let compress = config.compress
        let eligibility = cachedEligibility(entry)
        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)

        var block = ByteBuffer()
        defer { block.destroy() }
        var seen: ResponseHeaderKind = []
        var weak = ByteBuffer()
        defer { weak.destroy() }
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(entry.sentStatus, into: &block)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            guard entry.sends(name) else { return }
            seen.formUnion(HTTPResponseWriter.classify(name))
            let sent = EntityTag.isName(name)
                ? EntityTag.sent(value, coding: coding, scratch: &weak) : value
            h3.encoder.encode(name: name.base, nameLength: name.count,
                              value: sent.count > 0 ? sent.base : emptyH3Byte,
                              valueLength: sent.count, into: &block)
        }
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            encodeStaticH3(h3, "vary", "accept-encoding", into: &block)
        }
        if coding != .identity && !entry.notModified {
            encodeStaticH3(h3, "content-encoding", coding.token, into: &block)
        }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.sentStatus)
        var digits = ByteBuffer()
        defer { digits.destroy() }
        if !forbids {
            digits.writeDecimal(payload.count)
            encodeStaticH3(h3, "content-length", UnsafePointer(digits.readPointer),
                           digits.readableBytes, into: &block)
        }
        if !seen.contains(.date) {
            encodeStaticH3(h3, "date", UnsafePointer(dates.bytes), dates.count, into: &block)
        }
        if !seen.contains(.server) { encodeStaticH3(h3, "server", "garuda", into: &block) }
        if let hsts = config.hsts, !seen.contains(.hsts) {
            encodeStaticH3(h3, "strict-transport-security", hsts, config.hstsLength, into: &block)
        }
        if config.requestID && c.pointee.requestID.readableBytes > 0 {
            encodeStaticH3(h3, "x-request-id", UnsafePointer(c.pointee.requestID.readPointer),
                           c.pointee.requestID.readableBytes, into: &block)
        }
        digits.clear()
        digits.writeDecimal(entry.ageSeconds)
        encodeStaticH3(h3, "age", UnsafePointer(digits.readPointer), digits.readableBytes, into: &block)
        digits.clear()
        writeCacheStatus(entry, into: &digits)
        encodeStaticH3(h3, "cache-status", UnsafePointer(digits.readPointer), digits.readableBytes,
                       into: &block)

        writeH3HeaderBlock(slot, h3, block: &block)
        c.pointee.flags.insert(.responseStarted)
        logAccess(slot, status: entry.sentStatus)
        let sendBody = !forbids && !c.pointee.flags.contains(.suppressBody) && payload.count > 0
        if !sendBody {
            // Finished and retired here, inside dispatch: see endEmptyH3Response.
            c.pointee.flags.insert(.responseComplete)
            c.pointee.flags.insert(.endStreamSent)
            h3.quic.send(c.pointee.qstreamID, emptyH3Byte, 0, fin: true)
            flushQUIC(parent)
            closeH3Stream(slot)
            return
        }
        c.pointee.write.write(payload.base, payload.count)
        c.pointee.responseRemaining = -1
        c.pointee.flags.insert(.responseComplete)
        c.pointee.state = .writing
        _ = flush(slot)
    }

    /// The response ended. A complete one is stored, anything else dropped.
    mutating func cacheCaptureFinish(_ slot: Int, complete: Bool) {
        let c = table[slot]
        guard complete else {
            c.pointee.capture.abandon()
            return
        }
        if c.pointee.capture.store(key: c.pointee.cacheKey) && Metrics.enabled {
            Metrics.add(PG_M_CACHE_STORES)
        }
    }
}
