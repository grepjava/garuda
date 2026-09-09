//===----------------------------------------------------------------------===//
// Trusted proxies and forwarded request metadata.
//
// Peregrine is meant to run behind a reverse proxy that terminates TLS, so the
// application's idea of who the client is and whether the request arrived over
// HTTPS comes from headers the proxy sets. Those headers are also trivially
// forgeable by anyone who can reach the server directly, which is why nothing
// here is enabled by default: a forwarded header is read only when the
// immediate peer is on the configured trust list.
//
// This file is startup configuration and per-request header scanning, not the
// byte-pushing path, so it uses ordinary Swift arrays and lets ARC manage them.
//===----------------------------------------------------------------------===//

import CPeregrine
import PeregrineCore


/// One trusted address or network, held in binary form so matching is a masked
/// comparison rather than string work.
public struct TrustedNet: Sendable {
    /// 4 or 6.
    public var family: Int32
    /// IPv4 occupies the first four bytes.
    public var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
    public var prefix: Int32
}

/// Which peers are believed when they claim to be forwarding.
public struct ForwardedTrust {
    /// `*`: trust every peer. Correct only when nothing but the proxy can open
    /// a connection to this server (a private network, or a unix socket).
    public var trustAll = false
    /// Trust connections arriving over a unix socket, which have no address.
    public var trustUnix = false
    public var nets: [TrustedNet] = []

    public init() {}

    public var isEmpty: Bool { !trustAll && !trustUnix && nets.isEmpty }

    /// Parses a comma-separated list: `*`, `unix`, literal addresses, or CIDR
    /// blocks. Returns false on the first entry that does not parse.
    public mutating func parse(_ spec: UnsafePointer<CChar>) -> Bool {
        var i = 0
        var length = 0
        while spec[length] != 0 { length += 1 }

        while i < length {
            while i < length, spec[i] == 32 || spec[i] == 9 || spec[i] == 44 { i += 1 }
            if i >= length { break }
            var end = i
            while end < length, spec[end] != 44 { end += 1 }
            var stop = end
            while stop > i, spec[stop - 1] == 32 || spec[stop - 1] == 9 { stop -= 1 }
            let token = ByteSpan(UnsafeRawPointer(spec + i).assumingMemoryBound(to: UInt8.self),
                                 stop - i)
            i = end + 1
            if token.count == 0 { continue }
            if token.count == 1 && token[0] == 42 {          // '*'
                trustAll = true
                continue
            }
            if equalsLowercased(token.base, token.count, "unix") {
                trustUnix = true
                continue
            }
            guard let net = ForwardedTrust.parseNet(token) else { return false }
            nets.append(net)
        }
        return true
    }

    /// `address` or `address/prefix`.
    static func parseNet(_ token: ByteSpan) -> TrustedNet? {
        var addrLen = token.count
        var prefix = -1
        let slash = findByte(token.base, token.count, cSlash)
        if slash >= 0 {
            addrLen = slash
            prefix = parseDecimal(token.base + slash + 1, token.count - slash - 1)
            if prefix < 0 { return nil }
        }
        // inet_pton needs a NUL-terminated string, and an address is short.
        var buf = [CChar](repeating: 0, count: addrLen + 1)
        var out = [UInt8](repeating: 0, count: 16)
        var family: Int32 = 0
        let ok: Bool = buf.withUnsafeMutableBufferPointer { b -> Bool in
            memcpy(b.baseAddress!, token.base, addrLen)
            b[addrLen] = 0
            return out.withUnsafeMutableBufferPointer { o in
                pg_parse_ip(b.baseAddress!, o.baseAddress!, &family) == 0
            }
        }
        if !ok { return nil }
        let width: Int32 = family == 4 ? 32 : 128
        if prefix < 0 { prefix = Int(width) }
        if prefix > Int(width) { return nil }
        var net = TrustedNet(family: family,
                             bytes: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
                             prefix: Int32(prefix))
        _ = withUnsafeMutableBytes(of: &net.bytes) { raw in
            out.withUnsafeBufferPointer { memcpy(raw.baseAddress!, $0.baseAddress!, 16) }
        }
        return net
    }

    /// Whether a peer whose printable address is `addr` may be believed.
    public func trusts(_ addr: UnsafePointer<UInt8>, _ count: Int) -> Bool {
        if trustAll { return true }
        if count == 4 && equalsExact(addr, 4, "unix") { return trustUnix }
        if nets.isEmpty { return false }
        var raw = [UInt8](repeating: 0, count: 16)
        var family: Int32 = 0
        var buf = [CChar](repeating: 0, count: count + 1)
        let parsed: Bool = buf.withUnsafeMutableBufferPointer { b -> Bool in
            memcpy(b.baseAddress!, addr, count)
            b[count] = 0
            return raw.withUnsafeMutableBufferPointer { o in
                pg_parse_ip(b.baseAddress!, o.baseAddress!, &family) == 0
            }
        }
        if !parsed { return false }
        for net in nets where net.family == family {
            if ForwardedTrust.matches(net, raw) { return true }
        }
        return false
    }

    static func matches(_ net: TrustedNet, _ raw: [UInt8]) -> Bool {
        var net = net
        return withUnsafeBytes(of: &net.bytes) { nb -> Bool in
            let n = nb.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var bits = Int(net.prefix)
            var i = 0
            return raw.withUnsafeBufferPointer { r -> Bool in
                while bits >= 8 {
                    if n[i] != r[i] { return false }
                    bits -= 8
                    i += 1
                }
                if bits > 0 {
                    let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
                    if (n[i] & mask) != (r[i] & mask) { return false }
                }
                return true
            }
        }
    }
}

// MARK: - Reading the forwarded headers

/// What a trusted proxy said about the original request. All slices point into
/// the request head, so nothing is copied until the value reaches Python.
public struct ForwardedInfo {
    public var client: ByteSpan? = nil
    public var clientPort: Int = 0
    /// nil when the proxy said nothing about the scheme.
    public var https: Bool? = nil
    public init() {}

    public var isEmpty: Bool { client == nil && https == nil }
}

public enum Forwarded {

    /// Extracts client and scheme from the forwarded headers of one request.
    ///
    /// `X-Forwarded-For` is read right to left, skipping entries that are
    /// themselves trusted proxies, which is what makes a chain of proxies
    /// resolve to the real client rather than to the innermost hop. RFC 7239
    /// `Forwarded` is consulted only when the X- headers are absent, since
    /// proxies that emit both emit the same thing twice.
    public static func read(base: UnsafePointer<UInt8>,
                            head: borrowing HTTPRequestHead,
                            headers: UnsafePointer<HTTPHeaderRef>,
                            trust: ForwardedTrust) -> ForwardedInfo {
        var info = ForwardedInfo()
        // With nothing on the trust list there is no proxy to believe, so
        // there is nothing to read. The caller checks the peer as well; this
        // second gate is here so that a future caller which forgets cannot
        // turn a forgeable header into a client identity.
        if trust.isEmpty { return info }
        var forwardedFor: ByteSpan? = nil
        var forwardedProto: ByteSpan? = nil
        var rfc7239: ByteSpan? = nil

        var i = 0
        while i < head.headerCount {
            let h = headers[i]
            i += 1
            let np = base + Int(h.name.offset)
            let value = ByteSpan(base + Int(h.value.offset), Int(h.value.length))
            switch h.name.length {
            case 9:
                if equalsLowercased(np, 9, "forwarded") { rfc7239 = value }
            case 15:
                if equalsLowercased(np, 15, "x-forwarded-for") { forwardedFor = value }
            case 17:
                if equalsLowercased(np, 17, "x-forwarded-proto") { forwardedProto = value }
            default:
                break
            }
        }

        if let list = forwardedFor {
            info.client = rightmostUntrusted(list, trust: trust)
        }
        if let proto = forwardedProto {
            let last = lastElement(proto)
            if equalsLowercased(last.base, last.count, "https") { info.https = true }
            else if equalsLowercased(last.base, last.count, "http") { info.https = false }
        }
        if info.isEmpty, let fwd = rfc7239 {
            readRFC7239(fwd, into: &info)
        }
        return info
    }

    /// The last comma-separated element of a header value, trimmed.
    static func lastElement(_ v: ByteSpan) -> ByteSpan {
        var start = v.count
        while start > 0, v[start - 1] != cComma { start -= 1 }
        return trim(ByteSpan(v.base + start, v.count - start))
    }

    static func trim(_ v: ByteSpan) -> ByteSpan {
        var lo = 0
        var hi = v.count
        while lo < hi, v[lo] == cSP || v[lo] == cHT { lo += 1 }
        while hi > lo, v[hi - 1] == cSP || v[hi - 1] == cHT { hi -= 1 }
        return ByteSpan(v.base + lo, hi - lo)
    }

    /// Walks the list from the right, returning the first entry that is not
    /// itself a trusted proxy. When every hop is trusted the leftmost entry is
    /// the original client.
    static func rightmostUntrusted(_ list: ByteSpan, trust: ForwardedTrust) -> ByteSpan? {
        var end = list.count
        var leftmost: ByteSpan? = nil
        while end > 0 {
            var start = end
            while start > 0, list[start - 1] != cComma { start -= 1 }
            let element = normalize(trim(ByteSpan(list.base + start, end - start)))
            if element.count > 0 {
                leftmost = element
                if !trust.trusts(element.base, element.count) { return element }
            }
            if start == 0 { break }
            end = start - 1
        }
        return leftmost
    }

    /// Strips the decorations proxies add: quotes, a bracketed IPv6 literal,
    /// and a trailing `:port`. An IPv6 address without brackets keeps its
    /// colons, which is why the port is only removed when there is exactly one.
    static func normalize(_ v: ByteSpan) -> ByteSpan {
        var s = v
        if s.count >= 2, s[0] == 34, s[s.count - 1] == 34 {          // "..."
            s = ByteSpan(s.base + 1, s.count - 2)
        }
        if s.count >= 2, s[0] == 91 {                                 // [::1]:443
            var j = 1
            while j < s.count, s[j] != 93 { j += 1 }
            return ByteSpan(s.base + 1, j - 1)
        }
        var colons = 0
        var last = -1
        var i = 0
        while i < s.count {
            if s[i] == cColon { colons += 1; last = i }
            i += 1
        }
        if colons == 1 && last > 0 { return ByteSpan(s.base, last) }
        return s
    }

    /// `Forwarded: for=192.0.2.1;proto=https, for=198.51.100.7`
    static func readRFC7239(_ value: ByteSpan, into info: inout ForwardedInfo) {
        var i = 0
        while i < value.count {
            // One parameter: name '=' value, ended by ';' or ','.
            let nameStart = i
            while i < value.count, value[i] != 61, value[i] != cSemicolon, value[i] != cComma {
                i += 1
            }
            let name = trim(ByteSpan(value.base + nameStart, i - nameStart))
            if i >= value.count || value[i] != 61 {
                if i < value.count { i += 1 }
                continue
            }
            i += 1
            let valueStart = i
            if i < value.count, value[i] == 34 {           // quoted
                i += 1
                while i < value.count, value[i] != 34 { i += 1 }
                if i < value.count { i += 1 }
            } else {
                while i < value.count, value[i] != cSemicolon, value[i] != cComma { i += 1 }
            }
            let raw = trim(ByteSpan(value.base + valueStart, i - valueStart))
            if i < value.count { i += 1 }

            if equalsLowercased(name.base, name.count, "for") {
                // Last `for=` wins, matching the right-to-left reading above.
                let element = normalize(raw)
                if element.count > 0 { info.client = element }
            } else if equalsLowercased(name.base, name.count, "proto") {
                let p = normalize(raw)
                if equalsLowercased(p.base, p.count, "https") { info.https = true }
                else if equalsLowercased(p.base, p.count, "http") { info.https = false }
            }
        }
    }
}
