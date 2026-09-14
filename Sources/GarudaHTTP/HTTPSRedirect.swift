//===----------------------------------------------------------------------===//
// Where a plain HTTP request should have gone, for --redirect-http.
//
// The only input is the request line and Host, both supplied by the client,
// and the output goes into a Location header. So both are validated rather
// than copied: a host is letters, digits, dots and hyphens or a bracketed IPv6
// literal, and a target is visible ASCII. What comes back to the client is its
// own host with the scheme and port changed, which is what nginx's
// `return 301 https://$host$request_uri` does too.
//===----------------------------------------------------------------------===//

import GarudaCore

public enum HTTPSRedirect {

    /// 301 for GET and HEAD, which every client follows. 308 for anything
    /// else: a 301 allows a client to turn a POST into a GET and drop its body.
    @inlinable
    public static func status(for method: HTTPMethod) -> Int {
        method == .get || method == .head ? 301 : 308
    }

    /// Writes `https://HOST[:PORT]TARGET` into `out`.
    ///
    /// The host comes from an absolute-form target when there is one -- RFC
    /// 9112 section 3.2.2 has it take precedence over Host -- and otherwise
    /// from Host. Whatever port it carried is dropped, since that was the
    /// plain port; `httpsPort` is written instead unless it is 443. False when
    /// there is no host, when the host or target is not what it should be, or
    /// when the target is neither a path nor absolute (`*`, authority-form).
    public static func location(host: ByteSpan?, target: ByteSpan, httpsPort: UInt16,
                                into out: inout ByteBuffer) -> Bool {
        var authority = host
        var path = target
        if let scheme = schemeLength(target) {
            var end = scheme
            while end < target.count && target.base[end] != 0x2F && target.base[end] != 0x3F {
                end += 1
            }
            authority = ByteSpan(target.base + scheme, end - scheme)
            path = ByteSpan(target.base + end, target.count - end)
        } else if target.count == 0 || target.base[0] != 0x2F {
            return false
        }
        guard let authority, let hostLength = hostLength(authority) else { return false }
        var i = 0
        while i < path.count {
            let c = path.base[i]
            if c <= 0x20 || c >= 0x7F { return false }
            i += 1
        }

        out.write("https://")
        out.write(authority.base, hostLength)
        if httpsPort != 443 {
            out.writeByte(0x3A)
            out.writeDecimal(Int(httpsPort))
        }
        // An absolute target may have no path at all ("http://host?q").
        if path.count == 0 || path.base[0] != 0x2F { out.writeByte(0x2F) }
        if path.count > 0 { out.write(path.base, path.count) }
        return true
    }

    /// The length of `http://` or `https://` at the front, in any case.
    static func schemeLength(_ t: ByteSpan) -> Int? {
        guard t.count >= 7 else { return nil }
        let p = t.base
        guard p[0] | 0x20 == 0x68, p[1] | 0x20 == 0x74, p[2] | 0x20 == 0x74,
              p[3] | 0x20 == 0x70 else { return nil }
        if p[4] == 0x3A && p[5] == 0x2F && p[6] == 0x2F { return 7 }
        if t.count >= 8 && p[4] | 0x20 == 0x73 && p[5] == 0x3A && p[6] == 0x2F && p[7] == 0x2F {
            return 8
        }
        return nil
    }

    /// How much of `authority` is the host, once its port is set aside, or
    /// nil if it is not a host followed by at most a port. User information
    /// is refused along with everything else that is not a host.
    static func hostLength(_ a: ByteSpan) -> Int? {
        let n = a.count
        if n == 0 || n > 255 { return nil }
        let p = a.base
        var end = 0
        if p[0] == 0x5B {   // [
            end = 1
            while end < n && p[end] != 0x5D {
                let c = p[end]
                let lower = c | 0x20
                let hex = (c >= 0x30 && c <= 0x39) || (lower >= 0x61 && lower <= 0x66)
                if !(hex || c == 0x3A || c == 0x2E) { return nil }
                end += 1
            }
            if end == n || end == 1 { return nil }
            end += 1   // the closing bracket belongs to the host
        } else {
            while end < n && p[end] != 0x3A {
                let c = p[end]
                let lower = c | 0x20
                let ok = (c >= 0x30 && c <= 0x39) || (lower >= 0x61 && lower <= 0x7A)
                    || c == 0x2E || c == 0x2D
                if !ok { return nil }
                end += 1
            }
            if end == 0 { return nil }
        }
        if end < n {
            if p[end] != 0x3A { return nil }
            var i = end + 1
            while i < n {
                if p[i] < 0x30 || p[i] > 0x39 { return nil }
                i += 1
            }
        }
        return end
    }
}
