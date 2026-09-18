//===----------------------------------------------------------------------===//
// PostgreSQL's text form of an array: `{1,2,3}`, `{a,"b,c",NULL}`.
//
// One dimension of elements, each either text or NULL. An array's elements are
// the server's own text for whatever type they are, so the same element
// readers that turn a text cell into a Swift value turn an element into one:
// there is no separate reader per array type.
//
// Arrays come as text rather than in binary, like json: the binary form
// repeats the element format inside a header per dimension, so text is one
// format to get right instead of two.
//===----------------------------------------------------------------------===//

public enum PostgresArrayText {

    /// The elements of a one-dimensional array literal, nil for NULL, or nil
    /// for text that is not one.
    ///
    /// Refuses a literal with a dimension inside it -- `{{1,2},{3,4}}` --
    /// rather than flattening it into elements that were never a list.
    public static func parse(_ text: String) -> [String?]? {
        var bytes = Array(text.utf8)[...]
        // `[0:2]=` names the bounds, and appears when the lower one is not 1.
        if bytes.first == UInt8(ascii: "[") {
            guard let equals = bytes.firstIndex(of: UInt8(ascii: "=")) else { return nil }
            bytes = bytes[(equals + 1)...]
        }
        while let first = bytes.first, isSpace(first) { bytes = bytes.dropFirst() }
        while let last = bytes.last, isSpace(last) { bytes = bytes.dropLast() }
        guard bytes.count >= 2, bytes.first == UInt8(ascii: "{"),
              bytes.last == UInt8(ascii: "}") else { return nil }

        let end = bytes.endIndex - 1
        var i = bytes.startIndex + 1
        // `{}`, and `{ }` as the server would never write it.
        if !bytes[i..<end].contains(where: { !isSpace($0) }) { return [] }

        var out: [String?] = []
        while true {
            var value: [UInt8] = []
            // Whitespace outside quotes belongs to no element until a
            // character follows it: `{ a b , c}` is "a b" and "c".
            var pending: [UInt8] = []
            var quoted = false
            // Whether any of this element was quoted or escaped, which is what
            // tells a NULL from the four letters spelling it.
            var written = false
            element: while i < end {
                let c = bytes[i]
                if quoted {
                    switch c {
                    case UInt8(ascii: "\\"):
                        i += 1
                        guard i < end else { return nil }
                        value.append(bytes[i])
                    case UInt8(ascii: "\""):
                        quoted = false
                    default:
                        value.append(c)
                    }
                    i += 1
                    continue
                }
                switch c {
                case UInt8(ascii: "\""):
                    quoted = true
                    written = true
                    pending.removeAll()
                case UInt8(ascii: ","):
                    break element
                case UInt8(ascii: "\\"):
                    i += 1
                    guard i < end else { return nil }
                    flush(&value, &pending, written)
                    value.append(bytes[i])
                    written = true
                case UInt8(ascii: "{"), UInt8(ascii: "}"):
                    return nil
                default:
                    if isSpace(c) {
                        pending.append(c)
                    } else {
                        flush(&value, &pending, written)
                        value.append(c)
                    }
                }
                i += 1
            }
            guard !quoted else { return nil }
            if written {
                out.append(String(decoding: value, as: UTF8.self))
            } else if value.isEmpty {
                // The server writes no empty unquoted element, and refuses
                // one on the way in.
                return nil
            } else if isNULL(value) {
                out.append(nil)
            } else {
                out.append(String(decoding: value, as: UTF8.self))
            }
            guard i < end else { break }
            // The comma the element ended at.
            i += 1
        }
        return out
    }

    /// An array literal PostgreSQL parses into whatever array type the
    /// placeholder has.
    ///
    /// Every element is quoted, which no type minds and which keeps a value
    /// spelling NULL, holding a comma, or holding nothing from becoming
    /// something else. NULL itself is the unquoted word, as it must be.
    public static func format(_ elements: [String?]) -> String {
        var out: [UInt8] = [UInt8(ascii: "{")]
        for (i, element) in elements.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            guard let element else {
                out.append(contentsOf: Array("NULL".utf8))
                continue
            }
            out.append(UInt8(ascii: "\""))
            for byte in element.utf8 {
                if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") {
                    out.append(UInt8(ascii: "\\"))
                }
                out.append(byte)
            }
            out.append(UInt8(ascii: "\""))
        }
        out.append(UInt8(ascii: "}"))
        return String(decoding: out, as: UTF8.self)
    }

    /// Whitespace held back while it was not yet known whether anything
    /// followed it: kept when it is inside the element, dropped when it is
    /// the run before the element began.
    private static func flush(_ value: inout [UInt8], _ pending: inout [UInt8], _ written: Bool) {
        if !value.isEmpty || written { value.append(contentsOf: pending) }
        pending.removeAll()
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n")
            || c == UInt8(ascii: "\r")
    }

    /// The unquoted word NULL, in any case, as PostgreSQL reads it.
    private static func isNULL(_ value: [UInt8]) -> Bool {
        guard value.count == 4 else { return false }
        let lower = value.map { $0 | 0x20 }
        return lower == Array("null".utf8)
    }
}
