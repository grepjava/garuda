//===----------------------------------------------------------------------===//
// What a shared cache may keep, and for how long (RFC 9111), for --cache-size.
//
// These are the conservative end of what the specification allows, because
// the failure being guarded against is one user's response served to another.
// A response is kept only when it says so itself -- `s-maxage`, or `max-age`
// -- and never when it is private, sets a cookie, varies on anything but
// Accept-Encoding, or is already encoded. A request that carries credentials
// or a cookie is neither answered from the cache nor stored in it: plenty of
// applications personalise a page by cookie without saying `Vary: Cookie`,
// and nothing in the response gives that away.
//===----------------------------------------------------------------------===//

import PeregrineCore

/// The directives of one or more Cache-Control fields.
public struct CacheControl: Sendable {
    public var maxAge = -1
    public var sharedMaxAge = -1
    public var isPrivate = false
    public var noStore = false
    public var noCache = false

    public init() {}

    /// Adds the directives in one field value. A field may arrive more than
    /// once, and every copy counts; a repeated age keeps the smaller.
    public mutating func parse(_ p: UnsafePointer<UInt8>, _ n: Int) {
        var i = 0
        while i < n {
            while i < n && (p[i] == 0x2C || p[i] == 0x20 || p[i] == 0x09) { i += 1 }
            let nameStart = i
            while i < n && p[i] != 0x3D && p[i] != 0x2C && p[i] != 0x20 && p[i] != 0x09 { i += 1 }
            let nameLength = i - nameStart
            while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }

            var hasArgument = false
            var argument = -1
            if i < n && p[i] == 0x3D {
                hasArgument = true
                i += 1
                while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
                let quoted = i < n && p[i] == 0x22
                if quoted { i += 1 }
                var value = 0
                var digits = 0
                var numeric = true
                while i < n {
                    let ch = p[i]
                    if quoted ? ch == 0x22 : (ch == 0x2C || ch == 0x20 || ch == 0x09) { break }
                    if numeric && ch >= 0x30 && ch <= 0x39 {
                        // Past a hundred million seconds, three years, the
                        // exact number stops mattering.
                        if value < 100_000_000 { value = value * 10 + Int(ch - 0x30) }
                        digits += 1
                    } else {
                        numeric = false
                    }
                    i += 1
                }
                if quoted && i < n { i += 1 }
                if numeric && digits > 0 { argument = value }
            }
            if nameLength == 0 { continue }

            let name = p + nameStart
            switch nameLength {
            case 7 where equalsLowercased(name, 7, "max-age"):
                maxAge = CacheControl.combine(maxAge, argument, hasArgument, &noCache)
            case 8 where equalsLowercased(name, 8, "s-maxage"):
                sharedMaxAge = CacheControl.combine(sharedMaxAge, argument, hasArgument, &noCache)
            case 7 where equalsLowercased(name, 7, "private"):
                isPrivate = true
            case 8 where equalsLowercased(name, 8, "no-store"):
                noStore = true
            case 8 where equalsLowercased(name, 8, "no-cache"):
                noCache = true
            default:
                break
            }
        }
    }

    /// An age directive. One whose argument is not a number makes the
    /// response unusable, which is what the specification says a malformed
    /// freshness lifetime means.
    private static func combine(_ current: Int, _ argument: Int, _ hasArgument: Bool,
                                _ noCache: inout Bool) -> Int {
        guard hasArgument else { return current }
        guard argument >= 0 else {
            noCache = true
            return current
        }
        return current < 0 ? argument : min(current, argument)
    }
}

/// What a response's own headers say about keeping it, gathered as they pass.
public struct ResponseCacheability: Sendable {
    public var control = CacheControl()
    /// Something about the response rules it out, however fresh it says it is.
    public var excluded = false

    public init() {}

    public mutating func observe(_ name: ByteSpan, _ value: ByteSpan) {
        switch name.count {
        case 4 where equalsLowercased(name.base, 4, "vary"):
            if !ResponseCacheability.variesOnlyOnEncoding(value.base, value.count) {
                excluded = true
            }
        case 10 where equalsLowercased(name.base, 10, "set-cookie"):
            excluded = true
        case 13 where equalsLowercased(name.base, 13, "cache-control"):
            control.parse(value.base, value.count)
        case 16 where equalsLowercased(name.base, 16, "content-encoding"):
            // The server encodes a cached body for each client itself; one
            // the application encoded would need a copy per coding.
            excluded = true
        default:
            break
        }
    }

    /// Seconds the response may be served from the cache, at most `limit`, or
    /// 0 when it may not be kept at all.
    public func freshSeconds(status: Int, limit: Int) -> Int {
        guard !excluded, !control.isPrivate, !control.noStore, !control.noCache,
              ResponseCacheability.cacheableStatus(status) else { return 0 }
        let age = control.sharedMaxAge >= 0 ? control.sharedMaxAge : control.maxAge
        return age > 0 ? min(age, max(0, limit)) : 0
    }

    /// The statuses RFC 9110 calls heuristically cacheable, which are the
    /// ones whose meaning does not depend on anything but the request.
    public static func cacheableStatus(_ status: Int) -> Bool {
        switch status {
        case 200, 203, 204, 300, 301, 308, 404, 405, 410, 414, 501: return true
        default: return false
        }
    }

    /// Whether a Vary value names nothing but Accept-Encoding. `*` and every
    /// other field name are a no: the key would have to include them.
    public static func variesOnlyOnEncoding(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var i = 0
        while i < n {
            while i < n && (p[i] == 0x2C || p[i] == 0x20 || p[i] == 0x09) { i += 1 }
            let start = i
            while i < n && p[i] != 0x2C && p[i] != 0x20 && p[i] != 0x09 { i += 1 }
            let length = i - start
            if length == 0 { continue }
            if !(length == 15 && equalsLowercased(p + start, 15, "accept-encoding")) { return false }
        }
        return true
    }
}

public enum RequestCacheability {
    /// Whether a request header keeps the request away from the cache, both
    /// from being answered out of it and from its response being stored.
    public static func excludes(_ name: ByteSpan, _ value: ByteSpan) -> Bool {
        switch name.count {
        case 5:
            return equalsLowercased(name.base, 5, "range")
        case 6:
            if equalsLowercased(name.base, 6, "cookie") { return true }
            if equalsLowercased(name.base, 6, "pragma") {
                return containsTokenLowercased(value.base, value.count, "no-cache")
            }
            return false
        case 13:
            if equalsLowercased(name.base, 13, "authorization") { return true }
            if equalsLowercased(name.base, 13, "cache-control") {
                // A browser's reload sends max-age=0, which asks for a copy
                // no older than now: the application's.
                var control = CacheControl()
                control.parse(value.base, value.count)
                return control.noCache || control.noStore || control.maxAge == 0
            }
            return false
        default:
            return false
        }
    }
}

/// A cached response's headers: for each, a two-byte name length, a two-byte
/// value length, the name in lowercase and the value as the application sent
/// it.
public enum CachedHead {
    /// Whether a response header is kept with a cached copy. Framing and
    /// connection headers belong to each response as it is sent; Date, Age
    /// and X-Request-ID are written fresh for every copy.
    public static func keeps(_ name: ByteSpan) -> Bool {
        switch name.count {
        case 2: return !equalsLowercased(name.base, 2, "te")
        case 3: return !equalsLowercased(name.base, 3, "age")
        case 4: return !equalsLowercased(name.base, 4, "date")
        case 7:
            return !(equalsLowercased(name.base, 7, "trailer")
                     || equalsLowercased(name.base, 7, "upgrade"))
        case 10:
            return !(equalsLowercased(name.base, 10, "connection")
                     || equalsLowercased(name.base, 10, "keep-alive"))
        case 12: return !equalsLowercased(name.base, 12, "x-request-id")
        case 14: return !equalsLowercased(name.base, 14, "content-length")
        case 16: return !equalsLowercased(name.base, 16, "proxy-connection")
        case 17: return !equalsLowercased(name.base, 17, "transfer-encoding")
        default: return true
        }
    }

    /// Appends one header. False when it cannot be kept: an empty name, or a
    /// name or value longer than two bytes of length can say.
    public static func append(name: ByteSpan, value: ByteSpan, into out: inout ByteBuffer) -> Bool {
        guard name.count > 0, name.count <= 0xFFFF, value.count <= 0xFFFF else { return false }
        out.reserve(4 + name.count + value.count)
        out.writeByte(UInt8(truncatingIfNeeded: name.count >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: name.count))
        out.writeByte(UInt8(truncatingIfNeeded: value.count >> 8))
        out.writeByte(UInt8(truncatingIfNeeded: value.count))
        var i = 0
        while i < name.count {
            out.writeByte(asciiLower(name.base[i]))
            i += 1
        }
        if value.count > 0 { out.write(value.base, value.count) }
        return true
    }

    /// Calls `body` with each header of a block `append` built. A block cut
    /// short ends the walk where it is cut.
    public static func forEach(_ p: UnsafePointer<UInt8>, _ n: Int,
                               _ body: (ByteSpan, ByteSpan) -> Void) {
        var i = 0
        while i + 4 <= n {
            let nameLength = Int(p[i]) << 8 | Int(p[i + 1])
            let valueLength = Int(p[i + 2]) << 8 | Int(p[i + 3])
            i += 4
            guard nameLength > 0, i + nameLength + valueLength <= n else { return }
            body(ByteSpan(p + i, nameLength), ByteSpan(p + i + nameLength, valueLength))
            i += nameLength + valueLength
        }
    }
}
