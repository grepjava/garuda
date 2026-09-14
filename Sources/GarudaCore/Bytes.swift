//===----------------------------------------------------------------------===//
// Byte-level primitives.
//
// Every helper here is `@inlinable` and operates on raw pointers. Nothing in
// this file allocates, and nothing produces a Swift `String` -- the parser and
// the response writer work on byte ranges from beginning to end, so no ARC
// traffic and no UTF-8 validation ever happen on the request path.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
@_exported import Glibc
#elseif canImport(Darwin)
@_exported import Darwin
#endif

public let cCR: UInt8 = 13
public let cLF: UInt8 = 10
public let cSP: UInt8 = 32
public let cHT: UInt8 = 9
public let cColon: UInt8 = 58
public let cQuestion: UInt8 = 63
public let cSlash: UInt8 = 47
public let cPercent: UInt8 = 37
public let cSemicolon: UInt8 = 59
public let cComma: UInt8 = 44
public let cDash: UInt8 = 45
public let cUnderscore: UInt8 = 95
public let cZero: UInt8 = 48
public let cNine: UInt8 = 57

/// A borrowed view of bytes we do not own. Trivial, so it never touches ARC and
/// is passed in registers.
public struct ByteSpan {
    public var base: UnsafePointer<UInt8>
    public var count: Int

    @inlinable
    public init(_ base: UnsafePointer<UInt8>, _ count: Int) {
        self.base = base
        self.count = count
    }

    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable
    public subscript(i: Int) -> UInt8 { base[i] }

    @inlinable
    public func dropFirst(_ n: Int) -> ByteSpan { ByteSpan(base + n, count - n) }

    @inlinable
    public func prefix(_ n: Int) -> ByteSpan { ByteSpan(base, n < count ? n : count) }
}

/// ASCII lowercase without a branch: only letters have bit 0x20 free in a way
/// that maps A-Z onto a-z, and the mask is computed from an unsigned compare.
@inlinable
public func asciiLower(_ c: UInt8) -> UInt8 {
    let isUpper = (c &- 65) < 26
    return isUpper ? (c | 0x20) : c
}

@inlinable
public func asciiUpper(_ c: UInt8) -> UInt8 {
    let isLower = (c &- 97) < 26
    return isLower ? (c & 0xDF) : c
}

/// Case-insensitive comparison of a byte range against an all-lowercase
/// literal. `literal` must already be lowercase; we only fold the input.
@inlinable
public func equalsLowercased(_ p: UnsafePointer<UInt8>, _ n: Int, _ literal: StaticString) -> Bool {
    guard n == literal.utf8CodeUnitCount else { return false }
    let l = literal.utf8Start
    var i = 0
    while i < n {
        if asciiLower(p[i]) != l[i] { return false }
        i &+= 1
    }
    return true
}

@inlinable
public func equalsExact(_ p: UnsafePointer<UInt8>, _ n: Int, _ literal: StaticString) -> Bool {
    guard n == literal.utf8CodeUnitCount else { return false }
    return memcmp(p, literal.utf8Start, n) == 0
}

/// Case-insensitive substring search used for comma-separated header values
/// such as `Connection: keep-alive, Upgrade`.
@inlinable
public func containsTokenLowercased(_ p: UnsafePointer<UInt8>, _ n: Int, _ needle: StaticString) -> Bool {
    let m = needle.utf8CodeUnitCount
    if m == 0 || n < m { return false }
    let nd = needle.utf8Start
    var i = 0
    while i <= n - m {
        if asciiLower(p[i]) == nd[0] {
            var j = 1
            while j < m, asciiLower(p[i &+ j]) == nd[j] { j &+= 1 }
            if j == m {
                // Must be a whole token, not a substring of a longer one.
                let leftOK = i == 0 || p[i &- 1] == cComma || p[i &- 1] == cSP || p[i &- 1] == cHT
                let e = i &+ m
                let rightOK = e == n || p[e] == cComma || p[e] == cSP || p[e] == cHT || p[e] == cSemicolon
                if leftOK && rightOK { return true }
            }
        }
        i &+= 1
    }
    return false
}

@inlinable
public func findByte(_ p: UnsafePointer<UInt8>, _ n: Int, _ needle: UInt8) -> Int {
    // memchr is vectorised in every libc worth using; hand-rolling a loop here
    // measurably loses on long header values.
    guard let hit = memchr(p, Int32(needle), n) else { return -1 }
    return UnsafeRawPointer(hit) - UnsafeRawPointer(p)
}

/// Parses a non-negative decimal integer. Returns -1 on overflow or on any
/// non-digit byte: HTTP framing fields must be exact.
@inlinable
public func parseDecimal(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
    if n == 0 || n > 19 { return -1 }
    var v = 0
    var i = 0
    while i < n {
        let d = p[i]
        if d < cZero || d > cNine { return -1 }
        v = v &* 10 &+ Int(d &- cZero)
        if v < 0 { return -1 }
        i &+= 1
    }
    return v
}

/// Parses a hex integer (chunk sizes). Returns -1 if empty or malformed.
@inlinable
public func parseHex(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
    if n == 0 || n > 15 { return -1 }
    var v = 0
    var i = 0
    while i < n {
        let c = p[i]
        let d: Int
        switch c {
        case 48...57: d = Int(c &- 48)
        case 97...102: d = Int(c &- 87)
        case 65...70: d = Int(c &- 55)
        default: return -1
        }
        v = (v << 4) | d
        i &+= 1
    }
    return v
}

/// Writes `value` as decimal digits at `p`, returning the length. Caller
/// guarantees 20 bytes of room.
@inlinable
@discardableResult
public func writeDecimal(_ value: Int, _ p: UnsafeMutablePointer<UInt8>) -> Int {
    if value == 0 { p[0] = cZero; return 1 }
    var tmp = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
               UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
    var n = 0
    var v = value < 0 ? 0 : value
    withUnsafeMutableBytes(of: &tmp) { raw in
        let t = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
        while v > 0 {
            t[n] = cZero &+ UInt8(v % 10)
            v /= 10
            n &+= 1
        }
        var i = 0
        while i < n {
            p[i] = t[n &- 1 &- i]
            i &+= 1
        }
    }
    return n
}

/// RFC 3986 percent-decoding, in place-safe form (dst may equal src).
/// Returns the decoded length. Invalid escapes are copied through verbatim,
/// matching what every other server does in practice.
@inlinable
public func percentDecode(_ src: UnsafePointer<UInt8>, _ n: Int,
                          into dst: UnsafeMutablePointer<UInt8>) -> Int {
    var i = 0
    var o = 0
    while i < n {
        let c = src[i]
        if c == cPercent, i &+ 2 < n {
            let hi = hexValue(src[i &+ 1])
            let lo = hexValue(src[i &+ 2])
            if hi >= 0 && lo >= 0 {
                dst[o] = UInt8((hi << 4) | lo)
                o &+= 1
                i &+= 3
                continue
            }
        }
        dst[o] = c
        o &+= 1
        i &+= 1
    }
    return o
}

@inlinable
public func hexValue(_ c: UInt8) -> Int {
    switch c {
    case 48...57: return Int(c &- 48)
    case 97...102: return Int(c &- 87)
    case 65...70: return Int(c &- 55)
    default: return -1
    }
}

@inlinable
public func hasPercent(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
    findByte(p, n, cPercent) >= 0
}
