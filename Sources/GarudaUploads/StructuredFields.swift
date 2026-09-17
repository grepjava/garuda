//===----------------------------------------------------------------------===//
// The few structured fields (RFC 9651) resumable uploads use: a Boolean for
// Upload-Complete, a non-negative Integer for Upload-Offset and
// Upload-Length, and a Dictionary of Integers for Upload-Limit.
//
// Parsed strictly. A field that is not exactly one of these is treated as
// malformed and answered 400, rather than guessed at: an offset read
// generously is data written in the wrong place.
//===----------------------------------------------------------------------===//

enum StructuredField {
    /// `?1` or `?0`, with the optional surrounding spaces a field may carry.
    static func boolean(_ text: String) -> Bool? {
        switch trimmed(text) {
        case "?1": return true
        case "?0": return false
        default: return nil
        }
    }

    /// A non-negative sf-integer: at most 15 digits, no sign, no fraction.
    static func integer(_ text: String) -> Int? {
        let digits = trimmed(text)
        guard !digits.isEmpty, digits.count <= 15,
              digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        return Int(digits)
    }

    /// `key=value, key=value`, in the order given.
    static func dictionary(_ members: [(String, Int)]) -> String {
        members.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
    }

    private static func trimmed(_ text: String) -> Substring {
        var s = Substring(text)
        while s.first == " " || s.first == "\t" { s.removeFirst() }
        while s.last == " " || s.last == "\t" { s.removeLast() }
        return s
    }
}
