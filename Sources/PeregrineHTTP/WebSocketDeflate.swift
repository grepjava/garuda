//===----------------------------------------------------------------------===//
// permessage-deflate negotiation (RFC 7692 section 7.1).
//
// A client lists what it would accept in Sec-WebSocket-Extensions, possibly
// several offers of the same extension with different parameters, in order of
// preference. The server takes the first offer it can honour exactly and says
// what it agreed to; an offer with a parameter it does not know, a parameter
// given twice, or a value out of range is passed over, not repaired.
//
// What this server wants from the agreement is memory it can predict. A zlib
// compressor with the default 15-bit window and memory level costs about a
// quarter of a megabyte for as long as the connection keeps its context, which
// at ten thousand connections is gigabytes. So it compresses with a 12-bit
// window and a memory level of 5 -- about 40 KiB, still most of the ratio for
// the small, similar messages this extension is for -- and asks the client to
// stay within 12 bits too whenever the client has said it may be asked.
//===----------------------------------------------------------------------===//

import PeregrineCore

public enum WSDeflate {
    /// The window this server compresses with, and asks clients for.
    public static let preferredWindowBits = 12
    public static let memoryLevel: Int32 = 5
    /// Messages shorter than this go out uncompressed: the extension allows
    /// any message to, and below this the deflate framing is most of it.
    public static let minimumMessage = 64

    /// The first acceptable permessage-deflate offer in these
    /// Sec-WebSocket-Extensions values, or nil to negotiate nothing.
    public static func negotiate(_ values: [ByteSpan]) -> WSDeflateAgreement? {
        for value in values {
            var start = 0
            while start < value.count {
                let end = scan(value, from: start, until: 0x2C)   // ','
                if let agreement = parseOffer(ByteSpan(value.base + start, end - start)) {
                    return agreement
                }
                start = end + 1
            }
        }
        return nil
    }

    /// Where the next `separator` outside a quoted string is, or the end.
    static func scan(_ s: ByteSpan, from: Int, until separator: UInt8) -> Int {
        var i = from
        var quoted = false
        while i < s.count {
            let c = s.base[i]
            if c == 0x22 {
                quoted.toggle()
            } else if c == separator && !quoted {
                return i
            }
            i += 1
        }
        return i
    }

    static func trimmed(_ s: ByteSpan) -> ByteSpan {
        var lo = 0
        var hi = s.count
        while lo < hi && (s.base[lo] == 0x20 || s.base[lo] == 0x09) { lo += 1 }
        while hi > lo && (s.base[hi - 1] == 0x20 || s.base[hi - 1] == 0x09) { hi -= 1 }
        return ByteSpan(s.base + lo, hi - lo)
    }

    /// A window size parameter's value: 8 to 15, bare or quoted.
    static func windowBits(_ raw: ByteSpan) -> Int? {
        var v = trimmed(raw)
        if v.count >= 2 && v.base[0] == 0x22 && v.base[v.count - 1] == 0x22 {
            v = ByteSpan(v.base + 1, v.count - 2)
        }
        guard v.count == 1 || v.count == 2 else { return nil }
        var n = 0
        var i = 0
        while i < v.count {
            let c = v.base[i]
            guard c >= 0x30 && c <= 0x39 else { return nil }
            n = n * 10 + Int(c - 0x30)
            i += 1
        }
        // A leading zero is not a valid value here.
        if v.count == 2 && v.base[0] == 0x30 { return nil }
        return n >= 8 && n <= 15 ? n : nil
    }

    static func parseOffer(_ offer: ByteSpan) -> WSDeflateAgreement? {
        var start = 0
        var end = scan(offer, from: 0, until: 0x3B)   // ';'
        let name = trimmed(ByteSpan(offer.base, end))
        guard name.count == 18, equalsLowercased(name.base, 18, "permessage-deflate") else {
            return nil
        }
        var agreement = WSDeflateAgreement()
        var seen: UInt8 = 0
        while end < offer.count {
            start = end + 1
            end = scan(offer, from: start, until: 0x3B)
            let param = trimmed(ByteSpan(offer.base + start, end - start))
            if param.count == 0 { return nil }
            var eq = 0
            while eq < param.count && param.base[eq] != 0x3D { eq += 1 }   // '='
            let key = trimmed(ByteSpan(param.base, eq))
            let value: ByteSpan? = eq < param.count
                ? ByteSpan(param.base + eq + 1, param.count - eq - 1) : nil

            let bit: UInt8
            switch key.count {
            case 26 where equalsLowercased(key.base, 26, "server_no_context_takeover"):
                guard value == nil else { return nil }
                agreement.serverNoContextTakeover = true
                bit = 1
            case 26 where equalsLowercased(key.base, 26, "client_no_context_takeover"):
                guard value == nil else { return nil }
                agreement.clientNoContextTakeover = true
                bit = 2
            case 22 where equalsLowercased(key.base, 22, "server_max_window_bits"):
                // zlib cannot compress with an 8-bit window, so an offer that
                // insists on one is an offer this server cannot keep.
                guard let value, let bits = windowBits(value), bits > 8 else { return nil }
                agreement.serverMaxWindowBits = bits
                bit = 4
            case 22 where equalsLowercased(key.base, 22, "client_max_window_bits"):
                agreement.clientMaxWindowBitsOffered = true
                if let value {
                    guard let bits = windowBits(value) else { return nil }
                    agreement.clientMaxWindowBitsValue = bits
                }
                bit = 8
            default:
                return nil
            }
            if seen & bit != 0 { return nil }
            seen |= bit
        }
        return agreement
    }
}

/// What was agreed with one client.
public struct WSDeflateAgreement: Sendable, Equatable {
    public var serverNoContextTakeover = false
    public var clientNoContextTakeover = false
    /// The largest window the client lets this server compress with.
    public var serverMaxWindowBits: Int? = nil
    /// Whether the client said it can be told a window, and the limit it gave.
    public var clientMaxWindowBitsOffered = false
    public var clientMaxWindowBitsValue: Int? = nil

    public init() {}

    /// The window this server compresses with.
    public var deflateWindowBits: Int32 {
        Int32(min(serverMaxWindowBits ?? WSDeflate.preferredWindowBits, WSDeflate.preferredWindowBits))
    }

    /// The window the client is told to stay within, or nil when it did not
    /// say it could be told one.
    public var clientWindowBits: Int? {
        guard clientMaxWindowBitsOffered else { return nil }
        return min(clientMaxWindowBitsValue ?? WSDeflate.preferredWindowBits,
                   WSDeflate.preferredWindowBits)
    }

    /// The window to inflate with. At least 9: a zlib client asked for 8 bits
    /// uses 9, and a larger window reads a smaller one's stream perfectly well.
    public var inflateWindowBits: Int32 { Int32(max(clientWindowBits ?? 15, 9)) }

    /// The Sec-WebSocket-Extensions value that accepts it.
    public func writeResponse(into out: inout ByteBuffer) {
        out.write("permessage-deflate")
        if serverNoContextTakeover { out.write("; server_no_context_takeover") }
        if clientNoContextTakeover { out.write("; client_no_context_takeover") }
        if let bits = serverMaxWindowBits {
            out.write("; server_max_window_bits=")
            out.writeDecimal(bits)
        }
        if let bits = clientWindowBits {
            out.write("; client_max_window_bits=")
            out.writeDecimal(bits)
        }
    }
}
