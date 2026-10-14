//===----------------------------------------------------------------------===//
// Base64 (RFC 4648): the standard alphabet, for Basic credentials and stored
// password hashes, and base64url, for JSON Web Tokens and keys.
//
// Decoding reads bytes where they lie, into a buffer the caller gives or a
// new array, and takes either alphabet: what a token or a JWK carries is
// base64url, but an issuer that writes `+` and `/` is not worth refusing for
// it. Padding is let through and never needed.
//
// Internal, and named apart from the general Base64 helpers another part of
// Garuda carries, so the two can be joined later without a clash.
//===----------------------------------------------------------------------===//

/// Base64 with the standard alphabet and padding.
enum StandardBase64 {
    /// `bytes` in base64, with padding.
    static func encode(_ bytes: [UInt8]) -> String {
        encode(bytes, alphabet: standardAlphabet, padded: true)
    }

    /// The bytes `text` holds, or nil for anything that is not base64 of the
    /// standard alphabet. Padding may be left off.
    static func decode(_ text: String) -> [UInt8]? {
        var text = text
        return text.withUTF8 { bytes -> [UInt8]? in
            // The standard alphabet only: base64url's - and _ are refused.
            for byte in bytes where byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") { return nil }
            return tokenBase64URLDecode(bytes)
        }
    }

    static let standardAlphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    static let urlAlphabet: StaticString = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    static func encode(_ bytes: [UInt8], alphabet: StaticString, padded: Bool) -> String {
        let table = alphabet.utf8Start
        let full = bytes.count / 3
        let rest = bytes.count - full * 3
        let length = full * 4 + (rest == 0 ? 0 : (padded ? 4 : rest + 1))
        return String(unsafeUninitializedCapacity: length) { out in
            var o = 0
            var i = 0
            while i + 3 <= bytes.count {
                let n = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
                out[o] = table[Int(n >> 18)]
                out[o + 1] = table[Int(n >> 12 & 63)]
                out[o + 2] = table[Int(n >> 6 & 63)]
                out[o + 3] = table[Int(n & 63)]
                o += 4
                i += 3
            }
            if rest > 0 {
                let n = UInt32(bytes[i]) << 16 | (rest == 2 ? UInt32(bytes[i + 1]) << 8 : 0)
                out[o] = table[Int(n >> 18)]
                out[o + 1] = table[Int(n >> 12 & 63)]
                o += 2
                if rest == 2 {
                    out[o] = table[Int(n >> 6 & 63)]
                    o += 1
                } else if padded {
                    out[o] = UInt8(ascii: "=")
                    o += 1
                }
                if padded {
                    out[o] = UInt8(ascii: "=")
                    o += 1
                }
            }
            return o
        }
    }
}

/// base64url without padding, as JWS writes it.
func tokenBase64URLEncode(_ bytes: [UInt8]) -> String {
    StandardBase64.encode(bytes, alphabet: StandardBase64.urlAlphabet, padded: false)
}

/// base64 of either alphabet, padded or not, decoded: for a JWK's members.
func tokenBase64Decode(_ text: String) -> [UInt8]? {
    var text = text
    return text.withUTF8 { tokenBase64URLDecode($0) }
}

/// base64url as JWS writes it -- no padding, though padding is let through --
/// decoded from bytes. The standard alphabet's + and / are taken too.
func tokenBase64URLDecode(_ input: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
    var failed = false
    let out = [UInt8](unsafeUninitializedCapacity: input.count) { buffer, written in
        if let length = tokenBase64URLDecode(input, into: buffer) {
            written = length
        } else {
            failed = true
        }
    }
    return failed ? nil : out
}

/// The same, into `out`, which has room for at least `input.count` bytes.
/// Returns how many were written, or nil.
func tokenBase64URLDecode(_ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) -> Int? {
    var count = input.count
    while count > 0 && input[count - 1] == UInt8(ascii: "=") { count -= 1 }
    if count % 4 == 1 { return nil }
    var written = 0
    var accumulated: UInt32 = 0
    var bits = 0
    var i = 0
    while i < count {
        let byte = input[i]
        let value: UInt8
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): value = byte &- UInt8(ascii: "A")
        case UInt8(ascii: "a")...UInt8(ascii: "z"): value = byte &- UInt8(ascii: "a") &+ 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): value = byte &- UInt8(ascii: "0") &+ 52
        case UInt8(ascii: "-"), UInt8(ascii: "+"): value = 62
        case UInt8(ascii: "_"), UInt8(ascii: "/"): value = 63
        default: return nil
        }
        accumulated = (accumulated << 6) | UInt32(value)
        bits += 6
        if bits >= 8 {
            bits -= 8
            out[written] = UInt8(truncatingIfNeeded: accumulated >> UInt32(bits))
            written += 1
        }
        i += 1
    }
    return written
}
