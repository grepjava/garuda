//===----------------------------------------------------------------------===//
// Base64 (RFC 4648): the standard alphabet, for Basic credentials and stored
// password hashes, and base64url without padding, for JSON Web Tokens and
// keys and for signed and encrypted cookies, which can hold it as it is.
//
// Decoding reads bytes where they lie, into a buffer the caller gives or a
// new array, and takes either alphabet: what a token, a JWK or a cookie
// carries is base64url, but an issuer that writes `+` and `/` is not worth
// refusing for it. Up to two `=` of padding are let through and never needed;
// anything after them is not base64.
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
            return base64Decode(bytes)
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

/// `bytes` in base64url, without padding.
func base64URLEncode(_ bytes: [UInt8]) -> String {
    StandardBase64.encode(bytes, alphabet: StandardBase64.urlAlphabet, padded: false)
}

/// The bytes of base64 or base64url text, padded or not; nil when it is
/// neither.
func base64Decode(_ text: String) -> [UInt8]? {
    var text = text
    return text.withUTF8 { base64Decode($0) }
}

/// The same, from bytes.
func base64Decode(_ input: UnsafeBufferPointer<UInt8>) -> [UInt8]? {
    var failed = false
    let out = [UInt8](unsafeUninitializedCapacity: input.count) { buffer, written in
        if let length = base64Decode(input, into: buffer) {
            written = length
        } else {
            failed = true
        }
    }
    return failed ? nil : out
}

/// The same, into `out`, which has room for at least `input.count` bytes.
/// Returns how many were written, or nil.
func base64Decode(_ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutableBufferPointer<UInt8>) -> Int? {
    var count = input.count
    var padding = 0
    while count > 0 && input[count - 1] == UInt8(ascii: "=") && padding < 2 {
        count -= 1
        padding += 1
    }
    // A last group of one character holds less than a byte.
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
        // Padding anywhere but the end, or a third `=`, is not base64.
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
