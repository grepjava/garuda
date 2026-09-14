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
    /// The response's Age in seconds, or -1 when it has none worth reading.
    public var ageSeconds = -1
    private var ageSeen = false
    /// The response's Date, in seconds since the epoch, or -1.
    public var dateSeconds = -1

    public init() {}

    public mutating func observe(_ name: ByteSpan, _ value: ByteSpan) {
        switch name.count {
        case 3 where equalsLowercased(name.base, 3, "age"):
            // A repeated Age is a list, and only its first member counts
            // (RFC 9111 section 5.1).
            if !ageSeen {
                ageSeen = true
                ageSeconds = HTTPAge.parse(value.base, value.count)
            }
        case 4 where equalsLowercased(name.base, 4, "date"):
            if dateSeconds < 0 { dateSeconds = HTTPDate.parse(value.base, value.count) ?? -1 }
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

    /// How old the response already is and how much longer it may be kept,
    /// both in milliseconds, or nil when it may not be kept at all.
    ///
    /// Its age is worked out as RFC 9111 section 4.2.3 says: the larger of how
    /// long ago its Date was by this machine's clock, and its Age plus
    /// `responseDelayMs`, how long the application took to answer. That much
    /// of its lifetime is gone before it is stored, and a response with none
    /// left is not stored. `limitSeconds` caps what remains.
    public func storage(status: Int, limitSeconds: Int, responseDelayMs: Int,
                        nowSeconds: Int) -> (ageMs: Int, keepMs: Int)? {
        guard !excluded, !control.isPrivate, !control.noStore, !control.noCache,
              ResponseCacheability.cacheableStatus(status) else { return nil }
        let lifetime = control.sharedMaxAge >= 0 ? control.sharedMaxAge : control.maxAge
        guard lifetime > 0, limitSeconds > 0 else { return nil }
        let apparentMs = dateSeconds >= 0 ? max(0, nowSeconds - dateSeconds) * 1000 : 0
        let correctedMs = max(0, ageSeconds) * 1000 + max(0, responseDelayMs)
        let ageMs = max(apparentMs, correctedMs)
        let remainingMs = lifetime * 1000 - ageMs
        guard remainingMs > 0 else { return nil }
        return (ageMs, min(remainingMs, limitSeconds * 1000))
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

/// The Age field (RFC 9111 section 5.1).
public enum HTTPAge {
    /// Its delta-seconds: the first member of the list, or -1 when that is not
    /// a non-negative integer. Past 2^31 it is 2^31, as the specification says.
    public static func parse(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        var i = 0
        while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
        var value = 0
        var digits = 0
        while i < n && p[i] >= 0x30 && p[i] <= 0x39 {
            if value < 2_147_483_648 { value = min(2_147_483_648, value * 10 + Int(p[i] - 0x30)) }
            digits += 1
            i += 1
        }
        while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
        guard digits > 0, i == n || p[i] == 0x2C else { return -1 }
        return value
    }
}

/// HTTP-date (RFC 9110 section 5.6.7), in the three forms a recipient has to
/// accept: IMF-fixdate, and the obsolete RFC 850 and asctime forms.
public enum HTTPDate {
    /// Seconds since the epoch, or nil when the value is not an HTTP-date. The
    /// day of the week is not checked; nothing depends on it.
    public static func parse(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int? {
        var start = 0
        var end = n
        while start < end && (p[start] == 0x20 || p[start] == 0x09) { start += 1 }
        while end > start && (p[end - 1] == 0x20 || p[end - 1] == 0x09) { end -= 1 }
        let s = p + start
        let length = end - start
        var year = 0
        var month = 0
        var day = 0
        var clock = 0
        if length == 29 && s[3] == 0x2C {
            // Sun, 06 Nov 1994 08:49:37 GMT
            guard s[4] == 0x20, s[7] == 0x20, s[11] == 0x20, s[16] == 0x20, s[25] == 0x20,
                  isGMT(s + 26),
                  let d = number(s + 5, 2), let m = monthNumber(s + 8),
                  let y = number(s + 12, 4), let t = timeOfDay(s + 17) else { return nil }
            (year, month, day, clock) = (y, m, d, t)
        } else if length == 24 && s[3] == 0x20 {
            // Sun Nov  6 08:49:37 1994
            guard s[7] == 0x20, s[10] == 0x20, s[19] == 0x20,
                  let m = monthNumber(s + 4),
                  let d = s[8] == 0x20 ? number(s + 9, 1) : number(s + 8, 2),
                  let t = timeOfDay(s + 11), let y = number(s + 20, 4) else { return nil }
            (year, month, day, clock) = (y, m, d, t)
        } else {
            // Sunday, 06-Nov-94 08:49:37 GMT
            var comma = 0
            while comma < length && comma < 10 && s[comma] != 0x2C { comma += 1 }
            guard comma >= 6, comma < length, length == comma + 24 else { return nil }
            let r = s + comma + 1
            guard r[0] == 0x20, r[3] == 0x2D, r[7] == 0x2D, r[10] == 0x20, r[19] == 0x20,
                  isGMT(r + 20),
                  let d = number(r + 1, 2), let m = monthNumber(r + 4),
                  let yy = number(r + 8, 2), let t = timeOfDay(r + 11) else { return nil }
            // A two-digit year is placed in the nearest century, which for a
            // date a server is sent means this one or the last.
            (year, month, day, clock) = (yy < 70 ? 2000 + yy : 1900 + yy, m, d, t)
        }
        guard day >= 1 && day <= 31 else { return nil }
        return daysSinceEpoch(year: year, month: month, day: day) * 86_400 + clock
    }

    private static func number(_ p: UnsafePointer<UInt8>, _ digits: Int) -> Int? {
        var value = 0
        var i = 0
        while i < digits {
            let ch = p[i]
            guard ch >= 0x30 && ch <= 0x39 else { return nil }
            value = value * 10 + Int(ch - 0x30)
            i += 1
        }
        return value
    }

    /// HH:MM:SS as seconds into the day; a leap second is allowed.
    private static func timeOfDay(_ p: UnsafePointer<UInt8>) -> Int? {
        guard p[2] == 0x3A, p[5] == 0x3A,
              let h = number(p, 2), let m = number(p + 3, 2), let sec = number(p + 6, 2),
              h < 24, m < 60, sec <= 60 else { return nil }
        return h * 3600 + m * 60 + sec
    }

    private static func isGMT(_ p: UnsafePointer<UInt8>) -> Bool {
        p[0] == 0x47 && p[1] == 0x4D && p[2] == 0x54
    }

    /// Month names are case-sensitive in an HTTP-date.
    private static func monthNumber(_ p: UnsafePointer<UInt8>) -> Int? {
        switch (p[0], p[1], p[2]) {
        case (0x4A, 0x61, 0x6E): return 1   // Jan
        case (0x46, 0x65, 0x62): return 2   // Feb
        case (0x4D, 0x61, 0x72): return 3   // Mar
        case (0x41, 0x70, 0x72): return 4   // Apr
        case (0x4D, 0x61, 0x79): return 5   // May
        case (0x4A, 0x75, 0x6E): return 6   // Jun
        case (0x4A, 0x75, 0x6C): return 7   // Jul
        case (0x41, 0x75, 0x67): return 8   // Aug
        case (0x53, 0x65, 0x70): return 9   // Sep
        case (0x4F, 0x63, 0x74): return 10  // Oct
        case (0x4E, 0x6F, 0x76): return 11  // Nov
        case (0x44, 0x65, 0x63): return 12  // Dec
        default: return nil
        }
    }

    /// Days from 1970-01-01 to a date in the proleptic Gregorian calendar.
    private static func daysSinceEpoch(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = (month + 9) % 12
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
