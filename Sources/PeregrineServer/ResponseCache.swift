//===----------------------------------------------------------------------===//
// --cache-size: answering repeated requests without calling the application.
//
// A GET the application marked fresh -- `Cache-Control: s-maxage` or
// `max-age` -- is copied as it is sent, and stored in a table every worker
// shares (peregrine_cache.c). A later request for the same URL, on any worker
// and over any protocol, is answered from that copy until it expires. What may
// be kept is decided in PeregrineHTTP's ResponseCachePolicy, conservatively:
// the thing this must never do is hand one user's response to another.
//
// The key is the scheme, the host and the whole request target, plus the
// forwarding headers when the peer is a trusted proxy, since those change
// what the application thinks it was asked. HEAD is answered from a GET's
// copy and never stores one.
//
// A copy holds the application's own headers and body, not the bytes that
// went on the wire, so one copy serves HTTP/1.1, HTTP/2 and HTTP/3 alike and
// is compressed afresh for each client that accepts it. Date, Age,
// X-Request-ID, HSTS and the rest of what the server adds are written for
// every response as it is sent, with `Cache-Status: peregrine; hit` to say
// where it came from.
//
// The copy is taken in one place per application interface: for ASGI as the
// messages arrive, for WSGI in the response builder shared by the inline and
// pooled paths. Either way it is stored only when the response ended the way
// its head said it would.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

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
    var ttlSeconds = 0
    var head = ByteBuffer()
    var body = ByteBuffer()
    var policy = ResponseCacheability()

    public init() {}

    mutating func arm(ttlLimit: Int) {
        abandon()
        active = true
        self.ttlLimit = ttlLimit
    }

    /// One response header, as the application gave it.
    public mutating func observe(_ name: ByteSpan, _ value: ByteSpan) {
        policy.observe(name, value)
        if CachedHead.keeps(name) && !CachedHead.append(name: name, value: value, into: &head) {
            policy.excluded = true
        }
    }

    /// Every header has been seen: the response is kept or it is not.
    public mutating func settle(status: Int) {
        let fresh = policy.freshSeconds(status: status, limit: ttlLimit)
        guard fresh > 0, head.readableBytes <= Int(pg_cache_max_head()) else {
            abandon()
            return
        }
        self.status = status
        ttlSeconds = fresh
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
        let keyPointer = UnsafePointer(key.readPointer)
        let headLength = head.readableBytes
        let bodyLength = body.readableBytes
        // An empty buffer may never have been given storage; any valid pointer
        // does for a length of zero.
        let stored = pg_cache_put(keyPointer, keyLength, pg_monotonic_ms(),
                                  UInt64(ttlSeconds) * 1000, UInt16(status),
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
        ttlSeconds = 0
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

    // MARK: - Lookup

    /// At dispatch: answers the request from the cache and returns true, or
    /// arms the capture of the application's response and returns false.
    mutating func cacheDispatch(_ slot: Int) -> Bool {
        let c = table[slot]
        c.pointee.capture.abandon()
        let method = c.pointee.head.method
        guard method == .get || method == .head,
              !c.pointee.head.flags.contains(.upgrade), !c.pointee.head.hasBody else { return false }

        let base = c.pointee.headBase()
        var host = ByteSpan(base, 0)
        var forwardedProto = ByteSpan(base, 0)
        var forwardedHost = ByteSpan(base, 0)
        var forwarded = ByteSpan(base, 0)
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
            case 16 where equalsLowercased(name.base, 16, "x-forwarded-host"): forwardedHost = value
            case 17 where equalsLowercased(name.base, 17, "x-forwarded-proto"): forwardedProto = value
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
            let entry = CachedEntry(status: Int(status),
                                    head: ByteSpan(p, Int(headLength)),
                                    body: ByteSpan(p + Int(headLength), Int(bodyLength)),
                                    ageSeconds: Int(ageMs / 1000),
                                    ttlSeconds: Int((ttlMs + 999) / 1000))
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
        if method == .get { c.pointee.capture.arm(ttlLimit: config.cacheTTLMaxSeconds) }
        return false
    }

    // MARK: - Serving a copy

    struct CachedEntry {
        var status: Int
        var head: ByteSpan
        var body: ByteSpan
        var ageSeconds: Int
        var ttlSeconds: Int
    }

    /// The body as this client gets it: compressed when the copy may be and
    /// the client accepts a coding, in which case `scratch` holds the result.
    private func cachedPayload(_ slot: Int, _ entry: CachedEntry,
                               eligibility: CompressionEligibility,
                               into scratch: inout ByteBuffer) -> (ByteSpan, ContentCoding) {
        let c = table[slot]
        guard config.compress else { return (entry.body, .identity) }
        let coding = eligibility.choose(offered: c.pointee.acceptedCoding, status: entry.status,
                                        bodyAllowed: !HTTPResponseWriter.statusForbidsBody(entry.status),
                                        declaredLength: entry.body.count,
                                        minimumLength: config.compressMinimumLength)
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

    /// `peregrine; hit; ttl=N`, the value of Cache-Status (RFC 9211).
    private func writeCacheStatus(_ entry: CachedEntry, into out: inout ByteBuffer) {
        out.write("peregrine; hit; ttl=")
        out.writeDecimal(entry.ttlSeconds)
    }

    private mutating func serveCachedH1(_ slot: Int, _ entry: CachedEntry) {
        let c = table[slot]
        dates.refresh()
        var seen: ResponseHeaderKind = []
        var eligibility = CompressionEligibility()
        let compress = config.compress
        c.pointee.write.reserve(entry.head.count + 512)
        HTTPResponseWriter.writeStatusLine(&c.pointee.write, status: entry.status)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            seen.formUnion(HTTPResponseWriter.classify(name))
            if compress { eligibility.observe(name, value) }
            _ = HTTPResponseWriter.writeHeader(&c.pointee.write, name: name, value: value)
        }

        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            c.pointee.write.write("Vary: Accept-Encoding\r\n")
        }
        if coding != .identity {
            c.pointee.write.write("Content-Encoding: ")
            c.pointee.write.write(coding.token)
            c.pointee.write.writeCRLF()
        }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.status)
        if !forbids { HTTPResponseWriter.writeContentLength(&c.pointee.write, payload.count) }
        if !seen.contains(.date) { HTTPResponseWriter.writeDate(&c.pointee.write, dates) }
        if !seen.contains(.server) { c.pointee.write.write("Server: peregrine\r\n") }
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
        logAccess(slot, status: entry.status)
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
        var block = ByteBuffer()
        defer { block.destroy() }
        var seen: ResponseHeaderKind = []
        var eligibility = CompressionEligibility()
        let compress = config.compress
        h2.encoder.encodeStatus(entry.status, into: &block)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            seen.formUnion(HTTPResponseWriter.classify(name))
            if compress { eligibility.observe(name, value) }
            // Stored lowercase, and checked when the application first sent it.
            h2.encoder.encode(name: name.base, nameLength: name.count,
                              value: value.count > 0 ? value.base : emptyH2Byte,
                              valueLength: value.count, into: &block)
        }

        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            encodeStatic(h2, "vary", "accept-encoding", into: &block)
        }
        if coding != .identity { encodeStatic(h2, "content-encoding", coding.token, into: &block) }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.status)
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
        if !seen.contains(.server) { encodeStatic(h2, "server", "peregrine", into: &block) }
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
        logAccess(slot, status: entry.status)
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
        var block = ByteBuffer()
        defer { block.destroy() }
        var seen: ResponseHeaderKind = []
        var eligibility = CompressionEligibility()
        let compress = config.compress
        h3.encoder.begin(into: &block)
        h3.encoder.encodeStatus(entry.status, into: &block)
        CachedHead.forEach(entry.head.base, entry.head.count) { name, value in
            seen.formUnion(HTTPResponseWriter.classify(name))
            if compress { eligibility.observe(name, value) }
            h3.encoder.encode(name: name.base, nameLength: name.count,
                              value: value.count > 0 ? value.base : emptyH3Byte,
                              valueLength: value.count, into: &block)
        }

        var scratch = ByteBuffer()
        defer { scratch.destroy() }
        let (payload, coding) = cachedPayload(slot, entry, eligibility: eligibility, into: &scratch)
        if compress && eligibility.mayVary(status: entry.status) && !eligibility.varyCovered {
            encodeStaticH3(h3, "vary", "accept-encoding", into: &block)
        }
        if coding != .identity { encodeStaticH3(h3, "content-encoding", coding.token, into: &block) }
        let forbids = HTTPResponseWriter.statusForbidsBody(entry.status)
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
        if !seen.contains(.server) { encodeStaticH3(h3, "server", "peregrine", into: &block) }
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
        logAccess(slot, status: entry.status)
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

    // MARK: - Capturing an ASGI response

    /// `http.response.start` for a request whose response may be kept: decides
    /// from the status and headers whether it will be, and copies the headers.
    mutating func cacheCaptureStart(_ slot: Int, message: PyObj) {
        let c = table[slot]
        guard let statusObj = pg_dict_get(message, Interned[.status]) else {
            c.pointee.capture.abandon()
            return
        }
        let status = Int(pg_int_as_long(statusObj))
        if status == -1 {
            // Not an integer; the response itself will say so.
            pg_err_clear()
            c.pointee.capture.abandon()
            return
        }
        if let headerList = pg_dict_get(message, Interned[.headers]),
           pg_is(headerList, Interned.none) == 0 {
            // Only a list or a tuple. Anything else has to be iterated to be
            // read, and a generator read here would be empty by the time the
            // response is written.
            guard pg_is_list(headerList) != 0 || pg_is_tuple(headerList) != 0 else {
                c.pointee.capture.abandon()
                return
            }
            let count = PySeq.count(headerList)
            var i = 0
            while i < count {
                guard let item = PySeq.item(headerList, i),
                      let (nameObj, valueObj) = PySeq.pair(item),
                      let nameView = PyBytesView.of(nameObj) else {
                    pg_err_clear()
                    c.pointee.capture.abandon()
                    return
                }
                guard let valueView = PyBytesView.of(valueObj) else {
                    nameView.release()
                    pg_err_clear()
                    c.pointee.capture.abandon()
                    return
                }
                i += 1
                c.pointee.capture.observe(nameView.span, valueView.span)
                valueView.release()
                nameView.release()
            }
        }
        c.pointee.capture.settle(status: status)
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
