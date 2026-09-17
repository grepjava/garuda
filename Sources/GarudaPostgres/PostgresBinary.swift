//===----------------------------------------------------------------------===//
// Values in PostgreSQL's binary format.
//
// A statement the connection has run before knows its columns' types, and
// asks for the ones listed here in binary: an integer is its bytes rather
// than digits to parse, a bytea its bytes rather than hex at twice the size.
// A statement run for the first time asks for text, so everything here has a
// text twin, and a binary value's `text` is what the server would have sent
// as text -- which the tests hold it to, against a real server.
//===----------------------------------------------------------------------===//

import AvianCore

public enum PostgresBinary {

    /// Whether results of this type are asked for in binary.
    public static func isDecodable(_ type: UInt32) -> Bool {
        switch type {
        case PostgresType.bool, PostgresType.bytea, PostgresType.int2, PostgresType.int4,
             PostgresType.int8, PostgresType.float4, PostgresType.float8, PostgresType.uuid,
             PostgresType.timestamp, PostgresType.timestamptz:
            return true
        default:
            return false
        }
    }

    /// A format per column -- binary where the type is decodable -- or empty,
    /// meaning all text, when none is.
    public static func resultFormats(_ columns: [PostgresColumn]) -> [Int16] {
        guard columns.contains(where: { isDecodable($0.typeOID) }) else { return [] }
        return columns.map { isDecodable($0.typeOID) ? 1 : 0 }
    }

    // MARK: Reading

    /// An int2, int4 or int8, by its length.
    public static func integer(_ bytes: ArraySlice<UInt8>) -> Int64? {
        switch bytes.count {
        case 2: return Int64(Int16(bitPattern: UInt16(bigEndian: bytes)))
        case 4: return Int64(Int32(bitPattern: UInt32(bigEndian: bytes)))
        case 8: return Int64(bitPattern: UInt64(bigEndian: bytes))
        default: return nil
        }
    }

    public static func float8(_ bytes: ArraySlice<UInt8>) -> Double? {
        guard bytes.count == 8 else { return nil }
        return Double(bitPattern: UInt64(bigEndian: bytes))
    }

    public static func float4(_ bytes: ArraySlice<UInt8>) -> Float? {
        guard bytes.count == 4 else { return nil }
        return Float(bitPattern: UInt32(bigEndian: bytes))
    }

    public static func bool(_ bytes: ArraySlice<UInt8>) -> Bool? {
        guard bytes.count == 1, bytes[bytes.startIndex] <= 1 else { return nil }
        return bytes[bytes.startIndex] == 1
    }

    // MARK: As text

    /// The text the server would have sent for a binary value of `type`, or
    /// nil when the bytes are not a value of that type.
    public static func text(_ bytes: ArraySlice<UInt8>, type: UInt32) -> String? {
        switch type {
        case PostgresType.bool:
            return bool(bytes).map { $0 ? "t" : "f" }
        case PostgresType.int2, PostgresType.int4, PostgresType.int8:
            return integer(bytes).map { String($0) }
        case PostgresType.float8:
            return float8(bytes).map { floatText($0.description, significant: 15) }
        case PostgresType.float4:
            return float4(bytes).map { floatText($0.description, significant: 6) }
        case PostgresType.bytea:
            return byteaText(bytes)
        case PostgresType.uuid:
            return bytes.count == 16 ? UUIDText.format(Array(bytes)) : nil
        case PostgresType.timestamptz, PostgresType.timestamp:
            // In UTC: what the server writes when the session's TimeZone is
            // UTC. The binary value is the instant, whatever the zone.
            guard let micros = timestampMicroseconds(bytes) else {
                return integer(bytes).map { $0 > 0 ? "infinity" : "-infinity" }
            }
            return CivilTime.format(microseconds: micros,
                                    type == PostgresType.timestamptz ? .postgres : .postgresWithoutZone)
        default:
            return nil
        }
    }

    /// A timestamp's microseconds since 1970, or nil for infinity and for a
    /// value past what Int64 holds from 1970.
    public static func timestampMicroseconds(_ bytes: ArraySlice<UInt8>) -> Int64? {
        guard bytes.count == 8, let since2000 = integer(bytes),
              since2000 != .max, since2000 != .min else { return nil }
        let (micros, overflow) = since2000.addingReportingOverflow(946_684_800_000_000)
        return overflow ? nil : micros
    }

    static func byteaText(_ bytes: ArraySlice<UInt8>) -> String {
        let digits: StaticString = "0123456789abcdef"
        var out: [UInt8] = [UInt8(ascii: "\\"), UInt8(ascii: "x")]
        out.reserveCapacity(2 + bytes.count * 2)
        for byte in bytes {
            out.append(digits.utf8Start[Int(byte >> 4)])
            out.append(digits.utf8Start[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// A float as PostgreSQL 12 and later write one: the shortest digits that
    /// read back as the same value -- which Swift's description already is --
    /// laid out in plain notation when the decimal exponent is from -4 to
    /// below `significant` (15 for float8, 6 for float4), and as `1.5e+20`
    /// otherwise, with at least two exponent digits.
    static func floatText(_ description: String, significant: Int) -> String {
        switch description {
        case "nan", "-nan": return "NaN"
        case "inf": return "Infinity"
        case "-inf": return "-Infinity"
        default: break
        }
        var text = Substring(description)
        var negative = false
        if text.first == "-" {
            negative = true
            text = text.dropFirst()
        }
        // Split into the digits and where the decimal point falls among them.
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(text[text.index(after: e)...]) ?? 0
            text = text[..<e]
        }
        var digits = ""
        var point = text.count
        for (i, c) in text.enumerated() {
            if c == "." { point = i } else { digits.append(c) }
        }
        // value = 0.digits * 10^(point + exponent), before trimming zeros.
        var decimalPoint = point + exponent
        while digits.first == "0" {
            digits.removeFirst()
            decimalPoint -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return negative ? "-0" : "0" }

        // The exponent of the first digit, in d.ddd x 10^x form.
        let x = decimalPoint - 1
        var out = negative ? "-" : ""
        if x < -4 || x >= significant {
            out.append(digits.first!)
            if digits.count > 1 {
                out.append(".")
                out.append(contentsOf: digits.dropFirst())
            }
            out.append(x < 0 ? "e-" : "e+")
            let magnitude = String(abs(x))
            if magnitude.count < 2 { out.append("0") }
            out.append(magnitude)
        } else if decimalPoint <= 0 {
            out.append("0.")
            out.append(String(repeating: "0", count: -decimalPoint))
            out.append(digits)
        } else if decimalPoint >= digits.count {
            out.append(digits)
            out.append(String(repeating: "0", count: decimalPoint - digits.count))
        } else {
            out.append(contentsOf: digits.prefix(decimalPoint))
            out.append(".")
            out.append(contentsOf: digits.dropFirst(decimalPoint))
        }
        return out
    }
}

extension FixedWidthInteger {
    /// Reads a big-endian integer from exactly `MemoryLayout<Self>.size` bytes.
    init(bigEndian bytes: ArraySlice<UInt8>) {
        var value: Self = 0
        for byte in bytes { value = value << 8 | Self(byte) }
        self = value
    }
}
