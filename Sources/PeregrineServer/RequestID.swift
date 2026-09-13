//===----------------------------------------------------------------------===//
// --request-id: one ID per request, in the application, the response and the
// access log.
//
// An ID is only useful if all three places agree. The application logs it,
// the access log records it, and the client can quote it back from the
// response headers. That is what makes "request 7c9e... was slow" something
// that can be looked up.
//
// Where it comes from:
//
//  * A trusted proxy (--forwarded-allow-ips) that already sent X-Request-ID
//    has its ID kept, when it looks like an ID. The proxy saw the request
//    first and may already have logged it.
//  * Anything else gets a new one, a version 4 UUID. That includes an ID a
//    client sent directly: a header a client can set is not an identifier
//    anybody else can rely on, and one chosen to collide with another
//    request's is worse than none. The client's header is replaced in what
//    the application sees, not left beside the new one.
//
// A UUID here needs to be unique, not unpredictable. Each worker keeps a
// random key and a counter and mixes the two through splitmix64, a bijection,
// so within a worker two counts cannot produce the same half, and between
// workers the keys differ. That costs no system call per request.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore
import PeregrineHTTP
import PeregrinePython

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

extension Worker {

    /// Settles this request's ID. Reads the parsed header array, so it runs
    /// during dispatch.
    mutating func assignRequestID(_ slot: Int) {
        let c = table[slot]
        c.pointee.requestID.clear()
        c.pointee.requestIDKept = false

        if !config.trust.isEmpty && peerIsTrusted(slot) {
            let base = c.pointee.headBase()
            var i = 0
            while i < c.pointee.head.headerCount {
                let h = headers[i]
                i += 1
                guard h.name.length == 12,
                      equalsLowercased(base + Int(h.name.offset), 12, "x-request-id") else { continue }
                let value = h.value.span(in: base)
                guard value.count > 0 && value.count <= RequestID.maxLength else { break }
                var k = 0
                while k < value.count && RequestID.allowed(value.base[k]) { k += 1 }
                guard k == value.count else { break }
                c.pointee.requestID.write(value)
                c.pointee.requestIDKept = true
                return
            }
        }

        if requestIDKey == (0, 0) {
            withUnsafeMutableBytes(of: &requestIDKey) { raw in
                _ = pg_random_bytes(raw.baseAddress!, raw.count)
            }
            // A failed read of the random source leaves a key of zero, which
            // is still unique within this worker; only across workers would it
            // repeat, and pg_random_bytes does not fail where getrandom exists.
            if requestIDKey == (0, 0) { requestIDKey = (UInt64(pg_getpid()), pg_realtime_us()) }
        }
        requestIDCount &+= 1
        var high = RequestID.mix(requestIDKey.0 &+ requestIDCount)
        var low = RequestID.mix(requestIDKey.1 &+ requestIDCount)
        high = (high & ~0xF000) | 0x4000                                   // version 4
        low = (low & 0x3FFF_FFFF_FFFF_FFFF) | 0x8000_0000_0000_0000        // RFC 9562 variant

        let digits: StaticString = "0123456789abcdef"
        let hex = digits.utf8Start
        c.pointee.requestID.reserve(36)
        func put(_ value: UInt64, from: Int, count: Int) {
            var shift = UInt64(from)
            var n = count
            while n > 0 {
                shift -= 4
                c.pointee.requestID.writeByte(hex[Int((value >> shift) & 0xF)])
                n -= 1
            }
        }
        put(high, from: 64, count: 8)
        c.pointee.requestID.writeByte(0x2D)
        put(high, from: 32, count: 4)
        c.pointee.requestID.writeByte(0x2D)
        put(high, from: 16, count: 4)
        c.pointee.requestID.writeByte(0x2D)
        put(low, from: 64, count: 4)
        c.pointee.requestID.writeByte(0x2D)
        put(low, from: 48, count: 12)
    }

    /// HTTP_X_REQUEST_ID in a WSGI environ, replacing whatever the client sent.
    func stampRequestID(_ slot: Int, environ: PyObj) {
        let c = table[slot]
        guard config.requestID, !c.pointee.requestIDKept,
              c.pointee.requestID.readableBytes > 0 else { return }
        let key: StaticString = "HTTP_X_REQUEST_ID"
        guard let keyObj = key.utf8Start.withMemoryRebound(
                to: CChar.self, capacity: key.utf8CodeUnitCount,
                { pg_str_latin1($0, pg_ssize_t(key.utf8CodeUnitCount)) }),
              let value = UnsafePointer(c.pointee.requestID.readPointer).withMemoryRebound(
                to: CChar.self, capacity: c.pointee.requestID.readableBytes,
                { pg_str_latin1($0, pg_ssize_t(c.pointee.requestID.readableBytes)) }) else {
            pg_err_clear()
            return
        }
        defer {
            pg_decref(keyObj)
            pg_decref(value)
        }
        if pg_dict_set(environ, keyObj, value) != 0 { pg_err_clear() }
    }

    /// `(b"x-request-id", id)` in an ASGI scope's headers. Appended when the
    /// request had none; when the client sent its own, the list is rebuilt
    /// without it, so the application is never handed two.
    func stampRequestID(_ slot: Int, scope: PyObj) {
        let c = table[slot]
        guard config.requestID, !c.pointee.requestIDKept,
              c.pointee.requestID.readableBytes > 0,
              let list = pg_dict_get(scope, Interned[.headers]) else { return }
        let name: StaticString = "x-request-id"
        guard let nameObj = name.utf8Start.withMemoryRebound(
                to: CChar.self, capacity: name.utf8CodeUnitCount,
                { pg_bytes($0, pg_ssize_t(name.utf8CodeUnitCount)) }),
              let valueObj = UnsafePointer(c.pointee.requestID.readPointer).withMemoryRebound(
                to: CChar.self, capacity: c.pointee.requestID.readableBytes,
                { pg_bytes($0, pg_ssize_t(c.pointee.requestID.readableBytes)) }) else {
            pg_err_clear()
            return
        }
        defer {
            pg_decref(nameObj)
            pg_decref(valueObj)
        }
        guard let pair = pg_tuple2(nameObj, valueObj) else {
            pg_err_clear()
            return
        }
        defer { pg_decref(pair) }

        func isRequestID(_ item: PyObj) -> Bool {
            guard let n = pg_tuple_get(item, 0), pg_bytes_len(n) == 12,
                  let p = pg_bytes_data(n) else { return false }
            return UnsafeRawPointer(p).withMemoryRebound(to: UInt8.self, capacity: 12) {
                equalsLowercased($0, 12, "x-request-id")
            }
        }

        let count = pg_list_size(list)
        var clientSentOne = false
        var i: pg_ssize_t = 0
        while i < count {
            if let item = pg_list_get(list, i), isRequestID(item) {
                clientSentOne = true
                break
            }
            i += 1
        }
        if !clientSentOne {
            if pg_list_append(list, pair) != 0 { pg_err_clear() }
            return
        }
        guard let rebuilt = pg_list_empty_new() else {
            pg_err_clear()
            return
        }
        defer { pg_decref(rebuilt) }
        i = 0
        while i < count {
            if let item = pg_list_get(list, i), !isRequestID(item) {
                if pg_list_append(rebuilt, item) != 0 { pg_err_clear(); return }
            }
            i += 1
        }
        if pg_list_append(rebuilt, pair) != 0 { pg_err_clear(); return }
        if pg_dict_set(scope, Interned[.headers], rebuilt) != 0 { pg_err_clear() }
    }

    /// `X-Request-ID` in an HTTP/1.1 head.
    @inline(__always)
    func writeRequestIDHeader(_ slot: Int, _ buf: inout ByteBuffer) {
        guard config.requestID else { return }
        let c = table[slot]
        let n = c.pointee.requestID.readableBytes
        guard n > 0 else { return }
        buf.write("X-Request-ID: ")
        buf.write(UnsafePointer(c.pointee.requestID.readPointer), n)
        buf.writeCRLF()
    }

    /// The headers the server adds to every HTTP/1.1 response it builds
    /// itself, a static file for one: HSTS and the request ID.
    @inline(__always)
    func writeServerHeaders(_ slot: Int, _ buf: inout ByteBuffer) {
        writeHSTS(&buf)
        writeRequestIDHeader(slot, &buf)
    }
}
