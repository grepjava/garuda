//===----------------------------------------------------------------------===//
// The Date header.
//
// Every response carries one, and formatting it per response would cost a
// date conversion on every request. A connection keeps its own cache, so
// nothing is shared between threads: it reformats at most once a second, and
// asking whether the second has changed is one read of the coarse clock.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif os(Windows)
import ucrt
#endif

/// `Sun, 06 Nov 1994 08:49:37 GMT`: RFC 9110's IMF-fixdate, 29 bytes.
public struct DateCache: ~Copyable {
    public let bytes: UnsafeMutablePointer<UInt8>
    @usableFromInline var lastSecond: Int64 = -1

    public init() {
        bytes = .allocate(capacity: 29)
        refresh()
    }

    deinit { bytes.deallocate() }

    @inlinable public var count: Int { 29 }

    /// Reformats when the second has changed since the last call.
    @inlinable
    public mutating func refresh() {
        let now = DateCache.unixSeconds()
        if now != lastSecond {
            lastSecond = now
            DateCache.format(now, into: bytes)
        }
    }

    /// Seconds since the epoch, from the cheapest clock that has them.
    @inlinable
    public static func unixSeconds() -> Int64 {
        #if os(Linux)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME_COARSE, &ts)
        return Int64(ts.tv_sec)
        #elseif canImport(Darwin)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return Int64(ts.tv_sec)
        #else
        return Int64(time(nil))
        #endif
    }

    /// Writes the 29 bytes for `seconds` since the epoch at `out`.
    public static func format(_ seconds: Int64, into out: UnsafeMutablePointer<UInt8>) {
        let days = seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400
        let time = seconds - days * 86_400
        let (year, month, day) = CivilTime.date(days: days)
        // 1970-01-01 was a Thursday.
        let weekday = Int(((days % 7) + 11) % 7)
        let names: StaticString = "SunMonTueWedThuFriSat"
        let months: StaticString = "JanFebMarAprMayJunJulAugSepOctNovDec"
        func put(_ i: Int, _ b: UInt8) { out[i] = b }
        func two(_ i: Int, _ v: Int64) {
            out[i] = UInt8(48 + v / 10)
            out[i + 1] = UInt8(48 + v % 10)
        }
        for k in 0..<3 { put(k, names.utf8Start[weekday * 3 + k]) }
        put(3, 44); put(4, 32)                                  // ", "
        two(5, day)
        put(7, 32)
        for k in 0..<3 { put(8 + k, months.utf8Start[Int(month - 1) * 3 + k]) }
        put(11, 32)
        let y = max(0, min(9999, year))
        two(12, y / 100)
        two(14, y % 100)
        put(16, 32)
        two(17, time / 3600)
        put(19, 58)
        two(20, time / 60 % 60)
        put(22, 58)
        two(23, time % 60)
        put(25, 32); put(26, 71); put(27, 77); put(28, 84)      // " GMT"
    }
}
