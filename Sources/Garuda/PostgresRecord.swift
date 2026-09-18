//===----------------------------------------------------------------------===//
// Composite types: a row inside a column.
//
//     create type address as (street text, city text, postcode text);
//     create table people (name text, home address);
//
//     struct Person: Decodable { let name: String; let home: PostgresRecord }
//     let home = try await pool.first(Person.self, "select name, home from people")?.home
//     home.fields          // ["12 Mill Lane", "Cambridge", "CB1 2AB"]
//
// A composite arrives as `(12 Mill Lane,Cambridge,CB1 2AB)`: fields in the
// order the type declares them, and no names, because the wire does not carry
// them. So this is fields by position, not a keyed decode -- what the server
// sends is what you get, and naming them is the caller's to do.
//
// An enum needs nothing of its own: it arrives as its label, so a Swift enum
// backed by `String` decodes from it like any other single-column value.
//===----------------------------------------------------------------------===//

import GarudaPostgres

/// One composite value, as its fields in order. An empty unquoted field is a
/// NULL, which is how a composite writes one.
public struct PostgresRecord: Sendable, Hashable, CustomStringConvertible {
    public let fields: [String?]

    public init(_ fields: [String?]) {
        self.fields = fields
    }

    /// Reads `(a,b,"c,d")`, or nil for text that is not a composite.
    public init?(_ text: String) {
        guard let fields = PostgresRecordText.parse(text) else { return nil }
        self.fields = fields
    }

    /// The field at `index`, or nil when there is none there or it is NULL.
    public subscript(_ index: Int) -> String? {
        index >= 0 && index < fields.count ? fields[index] : nil
    }

    public var description: String { PostgresRecordText.format(fields) }
}

extension PostgresRecord: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let fields = PostgresRecordText.parse(text) else {
            throw PostgresDecodingError.notConvertible(column: "", value: text,
                                                       expected: "PostgresRecord")
        }
        self.fields = fields
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension PostgresRecord: PostgresBindable {
    public var postgresValue: PostgresValue { PostgresValue(description) }
}

/// A composite type's text form, which is not an array's: a field is NULL by
/// being empty rather than by being the word NULL, and a quote inside a
/// quoted field is doubled.
public enum PostgresRecordText {
    /// The fields of one composite, or nil for text that is not one.
    public static func parse(_ text: String) -> [String?]? {
        let bytes = Array(text.utf8)
        var i = 0
        while i < bytes.count, isSpace(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "(") else { return nil }
        var end = bytes.count
        while end > i, isSpace(bytes[end - 1]) { end -= 1 }
        guard end > i, bytes[end - 1] == UInt8(ascii: ")") else { return nil }
        i += 1
        end -= 1
        // `()` is one field that is NULL, as PostgreSQL reads it: a composite
        // has at least one field.
        if i == end { return [nil] }

        var fields: [String?] = []
        var value: [UInt8] = []
        var pending: [UInt8] = []
        var quoted = false
        var written = false
        while i < end {
            let c = bytes[i]
            if quoted {
                switch c {
                case UInt8(ascii: "\""):
                    // Two quotes inside quotes are one quote.
                    if i + 1 < end, bytes[i + 1] == UInt8(ascii: "\"") {
                        value.append(c)
                        i += 1
                    } else {
                        quoted = false
                    }
                case UInt8(ascii: "\\"):
                    i += 1
                    guard i < end else { return nil }
                    value.append(bytes[i])
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
                fields.append(written || !value.isEmpty ? String(decoding: value, as: UTF8.self) : nil)
                value.removeAll()
                pending.removeAll()
                written = false
            case UInt8(ascii: "\\"):
                i += 1
                guard i < end else { return nil }
                if !value.isEmpty || written { value.append(contentsOf: pending) }
                pending.removeAll()
                value.append(bytes[i])
                written = true
            default:
                if isSpace(c) {
                    pending.append(c)
                } else {
                    if !value.isEmpty || written { value.append(contentsOf: pending) }
                    pending.removeAll()
                    value.append(c)
                }
            }
            i += 1
        }
        guard !quoted else { return nil }
        fields.append(written || !value.isEmpty ? String(decoding: value, as: UTF8.self) : nil)
        return fields
    }

    /// A composite literal PostgreSQL reads back: every field that is not
    /// NULL quoted, since quoting is never wrong, and NULL written as nothing
    /// at all.
    public static func format(_ fields: [String?]) -> String {
        var out: [UInt8] = [UInt8(ascii: "(")]
        for (i, field) in fields.enumerated() {
            if i > 0 { out.append(UInt8(ascii: ",")) }
            guard let field else { continue }
            out.append(UInt8(ascii: "\""))
            for byte in field.utf8 {
                if byte == UInt8(ascii: "\"") {
                    out.append(byte)
                } else if byte == UInt8(ascii: "\\") {
                    out.append(byte)
                }
                out.append(byte)
            }
            out.append(UInt8(ascii: "\""))
        }
        out.append(UInt8(ascii: ")"))
        return String(decoding: out, as: UTF8.self)
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n")
            || c == UInt8(ascii: "\r")
    }
}
