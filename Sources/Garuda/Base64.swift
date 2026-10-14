//===----------------------------------------------------------------------===//
// Base64 (RFC 4648), as signed and encrypted cookies and their secrets are
// written: encoded in the URL-safe alphabet without padding, which a cookie
// value can hold as it is, and decoded from either alphabet, padded or not.
//===----------------------------------------------------------------------===//

private let urlAlphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

/// `bytes` in base64url, without padding.
func base64URLEncode(_ bytes: [UInt8]) -> String {
    var out: [UInt8] = []
    out.reserveCapacity((bytes.count + 2) / 3 * 4)
    var i = 0
    while i + 3 <= bytes.count {
        let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
        out.append(urlAlphabet[Int(n >> 18 & 63)])
        out.append(urlAlphabet[Int(n >> 12 & 63)])
        out.append(urlAlphabet[Int(n >> 6 & 63)])
        out.append(urlAlphabet[Int(n & 63)])
        i += 3
    }
    let left = bytes.count - i
    if left > 0 {
        var n = UInt32(bytes[i]) << 16
        if left == 2 { n |= UInt32(bytes[i + 1]) << 8 }
        out.append(urlAlphabet[Int(n >> 18 & 63)])
        out.append(urlAlphabet[Int(n >> 12 & 63)])
        if left == 2 { out.append(urlAlphabet[Int(n >> 6 & 63)]) }
    }
    return String(decoding: out, as: UTF8.self)
}

/// The bytes of base64 or base64url text, padded or not; nil when it is
/// neither.
func base64Decode(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    out.reserveCapacity(text.utf8.count / 4 * 3 + 2)
    var accumulator: UInt32 = 0
    var bits = 0
    var padding = 0
    for c in text.utf8 {
        let value: UInt8
        switch c {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = c - UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = c - UInt8(ascii: "a") + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = c - UInt8(ascii: "0") + 52
        case UInt8(ascii: "+"), UInt8(ascii: "-"): value = 62
        case UInt8(ascii: "/"), UInt8(ascii: "_"): value = 63
        case UInt8(ascii: "="):
            padding += 1
            continue
        default: return nil
        }
        // Nothing but padding comes after padding.
        if padding > 0 { return nil }
        accumulator = accumulator << 6 | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            out.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
        }
    }
    // A last group of one character holds less than a byte.
    let characters = text.utf8.count - padding
    if characters % 4 == 1 || padding > 2 { return nil }
    return out
}
