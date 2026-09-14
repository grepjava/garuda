//===----------------------------------------------------------------------===//
// Choosing a content coding for a response.
//
// Two questions, asked at different times. What the client will accept is a
// property of the request and is settled when it is dispatched, while the
// request head is still in hand. Whether this response should be compressed
// at all is a property of the response, and is settled from its headers as
// they are written. Only a response that passes both is compressed.
//
// Everything here is parsing and deciding. The compressing is elsewhere.
//===----------------------------------------------------------------------===//

import GarudaCore

/// A content coding the server can produce, in the numbering the C layer uses.
public enum ContentCoding: UInt8, Sendable {
    case identity = 0
    case gzip = 1
    case br = 2
    case zstd = 3

    /// The `Content-Encoding` token.
    @inlinable
    public var token: StaticString {
        switch self {
        case .identity: return "identity"
        case .gzip: return "gzip"
        case .br: return "br"
        case .zstd: return "zstd"
        }
    }

    /// What a pre-compressed copy of a file is called, next to the original.
    @inlinable
    public var fileSuffix: StaticString {
        switch self {
        case .identity: return ""
        case .gzip: return ".gz"
        case .br: return ".br"
        case .zstd: return ".zst"
        }
    }

    /// The codings in the order the server prefers them when a client rates
    /// several equally -- which is what `curl --compressed` and every browser
    /// do, by rating none of them. brotli first because it compresses text
    /// best at the levels used here; zstd before gzip because it is faster
    /// than gzip at a better ratio.
    public static let preference: [ContentCoding] = [.br, .zstd, .gzip]
}

/// What an `Accept-Encoding` header allows, as a weight per coding.
///
/// Weights are q-values in thousandths, so `q=0.5` is 500. -1 means the header
/// did not name the coding, in which case `*` decides.
public struct AcceptEncoding: Sendable, Equatable {
    public var gzip = -1
    public var br = -1
    public var zstd = -1
    public var wildcard = -1

    public init() {}

    /// Reads a header value. Unknown codings are ignored; a malformed weight
    /// counts as 0, which refuses the coding rather than guessing at it.
    public init(_ p: UnsafePointer<UInt8>, _ n: Int) {
        var i = 0
        while i < n {
            while i < n && (p[i] == cSP || p[i] == 0x09 || p[i] == 0x2C) { i &+= 1 }
            let start = i
            while i < n && p[i] != 0x2C && p[i] != 0x3B && p[i] != cSP && p[i] != 0x09 {
                i &+= 1
            }
            let length = i - start
            // Parameters, of which only q means anything.
            var weight = 1000
            while i < n && p[i] != 0x2C {
                if p[i] == 0x3B {
                    i &+= 1
                    while i < n && (p[i] == cSP || p[i] == 0x09) { i &+= 1 }
                    if i + 1 < n && (p[i] | 0x20) == 0x71 && p[i + 1] == 0x3D {   // q=
                        i &+= 2
                        weight = AcceptEncoding.parseWeight(p, n, &i)
                        continue
                    }
                }
                i &+= 1
            }
            if length == 0 { continue }
            let name = p + start
            if length == 4 && equalsLowercased(name, 4, "gzip") { gzip = weight }
            else if length == 6 && equalsLowercased(name, 6, "x-gzip") {
                if gzip < 0 { gzip = weight }
            }
            else if length == 2 && equalsLowercased(name, 2, "br") { br = weight }
            else if length == 4 && equalsLowercased(name, 4, "zstd") { zstd = weight }
            else if length == 1 && name[0] == 0x2A { wildcard = weight }
        }
    }

    /// Folds in another line of the same header. A coding that line names
    /// takes the weight it gives there.
    public mutating func merge(_ other: AcceptEncoding) {
        if other.gzip >= 0 { gzip = other.gzip }
        if other.br >= 0 { br = other.br }
        if other.zstd >= 0 { zstd = other.zstd }
        if other.wildcard >= 0 { wildcard = other.wildcard }
    }

    /// `0`, `0.5`, `1`, `1.000` -> thousandths. Anything else is 0.
    @usableFromInline
    static func parseWeight(_ p: UnsafePointer<UInt8>, _ n: Int, _ i: inout Int) -> Int {
        guard i < n else { return 0 }
        let lead = p[i]
        guard lead == 0x30 || lead == 0x31 else {
            while i < n && p[i] != 0x2C && p[i] != 0x3B { i &+= 1 }
            return 0
        }
        var value = lead == 0x31 ? 1000 : 0
        i &+= 1
        if i < n && p[i] == 0x2E {
            i &+= 1
            var scale = 100
            while i < n && p[i] >= 0x30 && p[i] <= 0x39 {
                if lead == 0x30 && scale > 0 { value += Int(p[i] - 0x30) * scale }
                scale /= 10
                i &+= 1
            }
        }
        while i < n && p[i] != 0x2C && p[i] != 0x3B { i &+= 1 }
        return min(value, 1000)
    }

    /// The weight the client gave `coding`.
    @inlinable
    public func weight(_ coding: ContentCoding) -> Int {
        let named: Int
        switch coding {
        case .identity: return 1000
        case .gzip: named = gzip
        case .br: named = br
        case .zstd: named = zstd
        }
        if named >= 0 { return named }
        return wildcard >= 0 ? wildcard : 0
    }

    /// The best coding the client accepts among those `usable` allows, or
    /// identity. Highest weight wins; a tie goes to the server's preference.
    public func choose(_ usable: (ContentCoding) -> Bool) -> ContentCoding {
        var best = ContentCoding.identity
        var bestWeight = 0
        for coding in ContentCoding.preference where usable(coding) {
            let w = weight(coding)
            if w > bestWeight {
                best = coding
                bestWeight = w
            }
        }
        return best
    }

    /// Every coding the client accepts among those `usable` allows, best
    /// first. For pre-compressed files, where the best coding may not have a
    /// copy on disk and the next one should be tried.
    public func ranked(_ usable: (ContentCoding) -> Bool) -> [ContentCoding] {
        var out: [ContentCoding] = []
        for coding in ContentCoding.preference where usable(coding) && weight(coding) > 0 {
            var at = out.count
            while at > 0 && weight(out[at - 1]) < weight(coding) { at -= 1 }
            out.insert(coding, at: at)
        }
        return out
    }
}

/// Entity-tags on a response the server compresses.
///
/// A strong entity-tag stands for one exact sequence of bytes, and a body the
/// server compressed is not the sequence the application tagged: two
/// representations in different content codings must not share one (RFC 9110
/// section 8.8.3.3). A strong tag on a compressed response is sent weak
/// instead, `W/"v1"` for `"v1"`, as nginx and Django's GZipMiddleware do.
/// If-None-Match compares weakly, so revalidation still works; If-Match and
/// If-Range compare strongly, and no longer accept a tag that never named the
/// bytes the client holds.
public enum EntityTag {
    @inlinable
    public static func isName(_ name: ByteSpan) -> Bool {
        name.count == 4 && equalsLowercased(name.base, 4, "etag")
    }

    /// A quoted entity-tag with no `W/`. A value that is not an entity-tag at
    /// all is not strong, and goes out as the application wrote it.
    @inlinable
    public static func isStrong(_ value: ByteSpan) -> Bool {
        value.count >= 2 && value.base[0] == 0x22 && value.base[value.count - 1] == 0x22
    }

    /// `value` as a response in `coding` sends it. A weakened copy is written
    /// into `scratch`, which is left alone otherwise.
    public static func sent(_ value: ByteSpan, coding: ContentCoding,
                            scratch: inout ByteBuffer) -> ByteSpan {
        guard coding != .identity, isStrong(value) else { return value }
        scratch.clear()
        scratch.reserve(value.count &+ 2)
        scratch.write("W/")
        scratch.write(value)
        return ByteSpan(UnsafePointer(scratch.readPointer), scratch.readableBytes)
    }
}

/// ETag values held back from a response head until its coding is chosen,
/// which is only once every header has been seen. Each is copied, because the
/// application's bytes are lent only for the header being read.
public struct HeldETags {
    // Each entry is a four-byte length, `W/`, then the value, so that the weak
    // form is the same bytes starting two earlier.
    private var buffer = ByteBuffer()

    public init() {}

    /// Holds one value, or refuses one no header may carry.
    public mutating func hold(_ value: ByteSpan) -> Bool {
        var i = 0
        while i < value.count {
            if !isFieldValueChar(value.base[i]) { return false }
            i &+= 1
        }
        let n = value.count
        buffer.reserve(n &+ 6)
        buffer.writeByte(UInt8(truncatingIfNeeded: n >> 24))
        buffer.writeByte(UInt8(truncatingIfNeeded: n >> 16))
        buffer.writeByte(UInt8(truncatingIfNeeded: n >> 8))
        buffer.writeByte(UInt8(truncatingIfNeeded: n))
        buffer.write("W/")
        buffer.write(value)
        return true
    }

    /// Every held value, as a response in `coding` sends it.
    public func forEach(coding: ContentCoding, _ body: (ByteSpan) -> Void) {
        guard buffer.readableBytes > 0 else { return }
        var p = UnsafePointer(buffer.readPointer)
        var left = buffer.readableBytes
        while left >= 6 {
            let n = Int(p[0]) << 24 | Int(p[1]) << 16 | Int(p[2]) << 8 | Int(p[3])
            let value = ByteSpan(p + 6, n)
            body(coding != .identity && EntityTag.isStrong(value) ? ByteSpan(p + 4, n + 2) : value)
            p += 6 + n
            left -= 6 + n
        }
    }

    public mutating func destroy() { buffer.destroy() }
}

/// What a response's own headers say about compressing it, gathered as they
/// are written.
public struct CompressionEligibility: Sendable {
    /// The media type is one that compresses: text, and the structured formats
    /// that are text in all but name.
    public var compressibleType = false
    /// The application already chose an encoding. Compressing twice is never
    /// right, and `Content-Encoding: identity` is a choice too.
    public var alreadyEncoded = false
    /// `Cache-Control: no-transform` forbids exactly this.
    public var noTransform = false
    /// A partial response describes a byte range of the unencoded body.
    public var partial = false
    /// The application's own `Vary` already covers `Accept-Encoding`, so a
    /// second one would only repeat it.
    public var varyCovered = false

    public init() {}

    /// Looks at one response header. Cheap for the headers that do not matter,
    /// which is nearly all of them: one switch on the name's length.
    @inlinable
    public mutating func observe(_ name: ByteSpan, _ value: ByteSpan) {
        switch name.count {
        case 4:
            if equalsLowercased(name.base, 4, "vary") {
                if containsTokenLowercased(value.base, value.count, "accept-encoding")
                    || (value.count == 1 && value.base[0] == 0x2A) {
                    varyCovered = true
                }
            }
        case 12:
            if equalsLowercased(name.base, 12, "content-type") {
                compressibleType = CompressionEligibility.isCompressible(value.base, value.count)
            }
        case 13:
            if equalsLowercased(name.base, 13, "cache-control") {
                if containsTokenLowercased(value.base, value.count, "no-transform") {
                    noTransform = true
                }
            } else if equalsLowercased(name.base, 13, "content-range") {
                partial = true
            }
        case 16:
            if equalsLowercased(name.base, 16, "content-encoding") { alreadyEncoded = true }
        default:
            break
        }
    }

    /// Whether a response like this one could be compressed for some client,
    /// which is when it has to say `Vary: Accept-Encoding` -- including to a
    /// client that did not ask, or a cache would hand that client's plain copy
    /// to everyone after it, or the compressed copy to a client that cannot
    /// read it.
    @inlinable
    public func mayVary(status: Int) -> Bool {
        compressibleType && !alreadyEncoded && !noTransform && !partial && status != 206
    }

    /// The coding to use, or identity.
    ///
    /// `declaredLength` is the unencoded length when the application gave one,
    /// else -1; a body known to be small is not worth a compressor's framing.
    @inlinable
    public func choose(offered: ContentCoding, status: Int, bodyAllowed: Bool,
                       declaredLength: Int, minimumLength: Int) -> ContentCoding {
        guard offered != .identity, bodyAllowed, mayVary(status: status) else { return .identity }
        if declaredLength >= 0 && declaredLength < minimumLength { return .identity }
        return offered
    }

    /// The media types worth compressing.
    ///
    /// A list of what compresses rather than of what does not, because the
    /// failure modes are not symmetric: a type missing from here is sent as it
    /// was, while compressing a JPEG spends CPU to make it bigger.
    /// `text/event-stream` is left out on purpose -- an event stream is a
    /// connection that stays open for small writes, and a compressor sitting
    /// on each one is a delay the client can see.
    public static func isCompressible(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        // The media type ends at a parameter or whitespace.
        var end = 0
        while end < n && p[end] != 0x3B && p[end] != cSP && p[end] != 0x09 { end &+= 1 }
        if end == 0 { return false }

        func starts(_ s: StaticString) -> Bool {
            let k = s.utf8CodeUnitCount
            return end >= k && equalsLowercased(p, k, s)
        }
        func exactly(_ s: StaticString) -> Bool {
            end == s.utf8CodeUnitCount && equalsLowercased(p, end, s)
        }
        func ends(_ s: StaticString) -> Bool {
            let k = s.utf8CodeUnitCount
            return end >= k && equalsLowercased(p + end - k, k, s)
        }

        if starts("text/") { return !exactly("text/event-stream") }
        if ends("+json") || ends("+xml") { return true }
        return exactly("application/json")
            || exactly("application/javascript")
            || exactly("application/x-javascript")
            || exactly("application/ecmascript")
            || exactly("application/xml")
            || exactly("application/wasm")
            || exactly("application/x-ndjson")
            || exactly("application/graphql-response+json")
            || exactly("application/vnd.ms-fontobject")
            || exactly("font/ttf")
            || exactly("font/otf")
            || exactly("image/svg+xml")
            || exactly("image/x-icon")
            || exactly("image/bmp")
    }
}
