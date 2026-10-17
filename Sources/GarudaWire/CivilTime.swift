//===----------------------------------------------------------------------===//
// Instants as text, without Foundation: the proleptic Gregorian calendar in
// UTC, to the microsecond.
//
// Days and dates convert with Howard Hinnant's civil-from-days algorithms,
// which are exact over the whole Int64 day range and need no tables. Two
// layouts are written -- ISO 8601 (`2026-09-16T20:53:43.196Z`) and
// PostgreSQL's ISO DateStyle (`2026-09-16 20:53:43.196+00`) -- and one reader
// takes both, with any UTC offset.
//===----------------------------------------------------------------------===//

public enum CivilTime {
    public static let microsecondsPerSecond: Int64 = 1_000_000
    public static let microsecondsPerDay: Int64 = 86_400_000_000

    /// Days since 1970-01-01 of a proleptic Gregorian date. Year 0 is 1 BC.
    public static func days(year: Int64, month: Int64, day: Int64) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// The date `days` after 1970-01-01.
    public static func date(days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    public static func daysInMonth(year: Int64, month: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    // MARK: Writing

    public enum Layout: Sendable {
        /// `2026-09-16T20:53:43.196Z`. A year before 1 is written as ISO 8601
        /// numbers it, 0 for 1 BC and negative before that.
        case iso8601
        /// `2026-09-16 20:53:43.196+00`, as PostgreSQL writes a timestamptz in
        /// UTC with DateStyle ISO, `0044-03-15 12:00:00+00 BC` before year 1.
        case postgres
        /// The same without the offset, as a timestamp without time zone.
        case postgresWithoutZone
    }

    public static func format(microseconds: Int64, _ layout: Layout) -> String {
        var days = microseconds / microsecondsPerDay
        var time = microseconds % microsecondsPerDay
        if time < 0 {
            days -= 1
            time += microsecondsPerDay
        }
        let (year, month, day) = date(days: days)
        let bc = layout != .iso8601 && year <= 0
        var out = ""
        if bc {
            appendPadded(&out, 1 - year, 4)
        } else if year < 0 {
            out.append("-")
            appendPadded(&out, -year, 4)
        } else {
            appendPadded(&out, year, 4)
        }
        out.append("-")
        appendPadded(&out, month, 2)
        out.append("-")
        appendPadded(&out, day, 2)
        out.append(layout == .iso8601 ? "T" : " ")
        let seconds = time / microsecondsPerSecond
        appendPadded(&out, seconds / 3600, 2)
        out.append(":")
        appendPadded(&out, seconds / 60 % 60, 2)
        out.append(":")
        appendPadded(&out, seconds % 60, 2)
        var fraction = time % microsecondsPerSecond
        if fraction > 0 {
            var width = 6
            while fraction % 10 == 0 {
                fraction /= 10
                width -= 1
            }
            out.append(".")
            appendPadded(&out, fraction, width)
        }
        switch layout {
        case .iso8601: out.append("Z")
        case .postgres: out.append("+00")
        case .postgresWithoutZone: break
        }
        if bc { out.append(" BC") }
        return out
    }

    private static func appendPadded(_ out: inout String, _ value: Int64, _ width: Int) {
        let digits = String(value)
        if digits.count < width { out.append(String(repeating: "0", count: width - digits.count)) }
        out.append(digits)
    }

    // MARK: Reading

    /// Microseconds since 1970-01-01T00:00:00Z, from
    /// `YYYY-MM-DD[T ]HH:MM:SS[.fraction][Z|±HH[:MM[:SS]]][ BC]`. No offset
    /// means UTC. Digits past the sixth of a fraction are dropped. Nil for
    /// anything else, including a date that does not exist.
    public static func parse<Text: Collection<UInt8>>(_ text: Text) -> Int64? {
        let bytes = Array(text)
        var i = 0

        func digits(min: Int, max: Int) -> Int64? {
            var value: Int64 = 0
            var count = 0
            while i < bytes.count, count < max, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                value = value * 10 + Int64(bytes[i] - 0x30)
                i += 1
                count += 1
            }
            return count >= min ? value : nil
        }
        func expect(_ c: UInt8) -> Bool {
            guard i < bytes.count, bytes[i] == c else { return false }
            i += 1
            return true
        }

        var yearSign: Int64 = 1
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") || bytes[i] == UInt8(ascii: "+") {
            yearSign = bytes[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
        }
        let signed = i > 0
        guard var year = digits(min: 4, max: 6), expect(UInt8(ascii: "-")),
              let month = digits(min: 2, max: 2), expect(UInt8(ascii: "-")),
              let day = digits(min: 2, max: 2) else { return nil }
        year *= yearSign
        guard i < bytes.count,
              bytes[i] == UInt8(ascii: "T") || bytes[i] == UInt8(ascii: "t") || bytes[i] == UInt8(ascii: " ") else {
            return nil
        }
        i += 1
        guard let hour = digits(min: 2, max: 2), expect(UInt8(ascii: ":")),
              let minute = digits(min: 2, max: 2), expect(UInt8(ascii: ":")),
              let second = digits(min: 2, max: 2) else { return nil }
        var micros: Int64 = 0
        if expect(UInt8(ascii: ".")) {
            var place: Int64 = 100_000
            var count = 0
            while i < bytes.count, bytes[i] >= 0x30, bytes[i] <= 0x39 {
                micros += Int64(bytes[i] - 0x30) * place
                place /= 10
                i += 1
                count += 1
            }
            guard count > 0 else { return nil }
        }
        var offset: Int64 = 0
        if i < bytes.count, bytes[i] == UInt8(ascii: "Z") || bytes[i] == UInt8(ascii: "z") {
            i += 1
        } else if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") {
            let sign: Int64 = bytes[i] == UInt8(ascii: "-") ? -1 : 1
            i += 1
            guard let hours = digits(min: 2, max: 2), hours <= 23 else { return nil }
            var minutes: Int64 = 0
            var seconds: Int64 = 0
            if expect(UInt8(ascii: ":")) || (i < bytes.count && bytes[i] >= 0x30 && bytes[i] <= 0x39) {
                guard let m = digits(min: 2, max: 2), m <= 59 else { return nil }
                minutes = m
                if expect(UInt8(ascii: ":")) {
                    guard let s = digits(min: 2, max: 2), s <= 59 else { return nil }
                    seconds = s
                }
            }
            offset = sign * (hours * 3600 + minutes * 60 + seconds)
        }
        if i + 3 == bytes.count, bytes[i] == UInt8(ascii: " "), bytes[i + 1] == UInt8(ascii: "B"),
           bytes[i + 2] == UInt8(ascii: "C") {
            // BC counts years from 1 with no year 0; a signed year is already
            // astronomical, and both at once is not a date.
            guard !signed, year >= 1 else { return nil }
            year = 1 - year
            i += 3
        }
        guard i == bytes.count,
              (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month),
              hour <= 23, minute <= 59, second <= 59 else { return nil }
        let clock = (hour * 3600 + minute * 60 + second - offset) * microsecondsPerSecond + micros
        return days(year: year, month: month, day: day) * microsecondsPerDay + clock
    }
}

// MARK: - UUIDs as text

public enum UUIDText {
    /// `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, lower case.
    public static func format(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 16)
        let hex: StaticString = "0123456789abcdef"
        var out: [UInt8] = []
        out.reserveCapacity(36)
        for (i, byte) in bytes.enumerated() {
            if i == 4 || i == 6 || i == 8 || i == 10 { out.append(UInt8(ascii: "-")) }
            out.append(hex.utf8Start[Int(byte >> 4)])
            out.append(hex.utf8Start[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The 16 bytes of a UUID written with its hyphens, or as 32 hex digits
    /// without them, in either case.
    public static func parse<Text: Collection<UInt8>>(_ text: Text) -> [UInt8]? {
        let chars = Array(text)
        let hyphenated = chars.count == 36
        guard hyphenated || chars.count == 32 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        var i = 0
        while out.count < 16 {
            if hyphenated && (i == 8 || i == 13 || i == 18 || i == 23) {
                guard chars[i] == UInt8(ascii: "-") else { return nil }
                i += 1
            }
            guard let high = nibble(chars[i]), let low = nibble(chars[i + 1]) else { return nil }
            out.append(high << 4 | low)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
