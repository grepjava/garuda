//===----------------------------------------------------------------------===//
// The few structured fields (RFC 9651) resumable uploads use: a Boolean for
// Upload-Complete, a non-negative Integer for Upload-Offset and
// Upload-Length, and a Dictionary of Integers for Upload-Limit.
//
// Parsed strictly. A field that is not exactly one of these is treated as
// malformed and answered 400, rather than guessed at: an offset read
// generously is data written in the wrong place.
//
// Read from the bytes the request lends, so a field is never copied out of
// it to be looked at.
//===----------------------------------------------------------------------===//

enum StructuredField {
    /// `?1` or `?0`, with the optional surrounding spaces a field may carry.
    static func boolean(_ field: Span<UInt8>) -> Bool? {
        let (start, end) = trimmed(field)
        guard end &- start == 2, field[start] == UInt8(ascii: "?") else { return nil }
        switch field[start &+ 1] {
        case UInt8(ascii: "1"): return true
        case UInt8(ascii: "0"): return false
        default: return nil
        }
    }

    /// A non-negative sf-integer: at most 15 digits, no sign, no fraction.
    static func integer(_ field: Span<UInt8>) -> Int? {
        let (start, end) = trimmed(field)
        guard end > start, end &- start <= 15 else { return nil }
        var value = 0
        var i = start
        while i < end {
            let digit = field[i]
            guard digit >= 0x30 && digit <= 0x39 else { return nil }
            value = value &* 10 &+ Int(digit &- 0x30)
            i &+= 1
        }
        return value
    }

    static func boolean(_ text: String) -> Bool? {
        var text = text
        return text.withUTF8 { boolean($0.span) }
    }

    static func integer(_ text: String) -> Int? {
        var text = text
        return text.withUTF8 { integer($0.span) }
    }

    /// `key=value, key=value`, in the order given.
    static func dictionary(_ members: [(String, Int)]) -> String {
        members.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    /// Where the field's value begins and ends, without the spaces and tabs
    /// around it.
    private static func trimmed(_ field: Span<UInt8>) -> (Int, Int) {
        var start = 0
        var end = field.count
        while start < end && (field[start] == 0x20 || field[start] == 0x09) { start &+= 1 }
        while end > start && (field[end &- 1] == 0x20 || field[end &- 1] == 0x09) { end &-= 1 }
        return (start, end)
    }
}
