//===----------------------------------------------------------------------===//
// The PostgreSQL types that had no Swift type of their own: `date`, `time`,
// `interval`, `numeric`, and `json`/`jsonb`.
//
//     struct Invoice: Codable {
//         let id: Int
//         let issued: PostgresDate           // date
//         let due: PostgresDate
//         let total: PostgresNumeric         // numeric(12,2), exact
//         let terms: PostgresInterval        // interval
//         let meta: PostgresJSON<Metadata>   // jsonb, decoded into your type
//     }
//
//     try await pool.query(Invoice.self, "select id, issued, due, total, terms, meta from invoices")
//     try await pool.execute("insert into invoices (issued, total) values ($1, $2)",
//                            PostgresDate(2026, 9, 18)!, PostgresNumeric("1234.56")!)
//
// Each reads the binary form the driver asks for and the text form as a
// fallback, and binds as text PostgreSQL accepts whatever its `DateStyle` or
// `IntervalStyle` is set to: ISO dates and times, and ISO-8601 intervals.
//
// Why not Foundation's `Date` and `Decimal`: the engine has no Foundation
// anywhere, `Date` is an instant rather than a calendar date (which is what
// `date` holds), and `Decimal` cannot hold what `numeric` can. `Timestamp`
// stays the type for `timestamptz`.
//
// `numeric` is kept as its digits, not as a `Double`: a total of 1234.56 is
// 1234.56, not 1234.5599999999999. Arithmetic on it is not offered here --
// the database is better at it than a wrapper would be.
//===----------------------------------------------------------------------===//

import GarudaPostgres

// MARK: - date

/// A calendar date, as PostgreSQL's `date` holds it: no time, no zone.
public struct PostgresDate: Sendable, Hashable, Codable, Comparable, CustomStringConvertible,
                            LosslessStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Nil for a date that does not exist: month 13, or 30 February.
    public init?(_ year: Int, _ month: Int, _ day: Int) {
        guard month >= 1, month <= 12, day >= 1, year >= -4713, year <= 294_276,
              day <= PostgresDate.daysIn(month: month, year: year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// `2026-09-18`, and nothing else: ISO or nil.
    public init?(_ description: String) {
        let parts = description.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count >= 4, let year = Int(parts[0]),
              parts[1].count == 2, let month = Int(parts[1]),
              parts[2].count == 2, let day = Int(parts[2]),
              let value = PostgresDate(year, month, day) else { return nil }
        self = value
    }

    public var description: String {
        let y = year < 0 ? "-" + PostgresDate.pad(-year, 4) : PostgresDate.pad(year, 4)
        return "\(y)-\(PostgresDate.pad(month, 2))-\(PostgresDate.pad(day, 2))"
    }

    public static func < (a: PostgresDate, b: PostgresDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Days since 2000-01-01, which is what the binary form carries.
    public var daysSince2000: Int32 {
        Int32(PostgresDate.julianDay(year, month, day) - PostgresDate.julianDay(2000, 1, 1))
    }

    /// From days since 2000-01-01.
    public init(daysSince2000: Int32) {
        let (year, month, day) = PostgresDate.fromJulianDay(
            PostgresDate.julianDay(2000, 1, 1) + Int(daysSince2000))
        self.year = year
        self.month = month
        self.day = day
    }

    static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(value)
        while text.count < width { text = "0" + text }
        return text
    }

    static func isLeap(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeap(year) ? 29 : 28
        }
    }

    /// The astronomical Julian day number, the way PostgreSQL's own
    /// date2j does it: arithmetic only, no tables and no library.
    static func julianDay(_ year: Int, _ month: Int, _ day: Int) -> Int {
        var y = year
        var m = month
        if m > 2 {
            m += 1
            y += 4800
        } else {
            m += 13
            y += 4799
        }
        let century = y / 100
        var julian = y * 365 - 32167
        julian += y / 4 - century + century / 4
        return julian + 7834 * m / 256 + day
    }

    static func fromJulianDay(_ julian: Int) -> (year: Int, month: Int, day: Int) {
        var julian = UInt(julian)
        julian += 32044
        var quad = julian / 146097
        let extra = (julian - quad * 146097) * 4 + 3
        julian += 60 + quad * 3 + extra / 146097
        quad = julian / 1461
        julian -= quad * 1461
        var y = julian * 4 / 1461
        julian = (y != 0 ? (julian + 305) % 365 : (julian + 306) % 366) + 123
        y += quad * 4
        let year = Int(y) - 4800
        quad = julian * 2141 / 65536
        let day = Int(julian - 7834 * quad / 256)
        let month = Int((quad + 10) % 12 + 1)
        return (year, month, day)
    }
}

// MARK: - time

/// A time of day, as PostgreSQL's `time` holds it: microsecond resolution, no
/// date and no zone.
public struct PostgresTime: Sendable, Hashable, Codable, Comparable, CustomStringConvertible,
                            LosslessStringConvertible {
    /// 0 up to 24 hours, which PostgreSQL allows as `24:00:00`.
    public let microsecondsSinceMidnight: Int64

    public init?(microsecondsSinceMidnight micros: Int64) {
        guard micros >= 0, micros <= 86_400_000_000 else { return nil }
        microsecondsSinceMidnight = micros
    }

    public init?(_ hour: Int, _ minute: Int, _ second: Int = 0, microsecond: Int = 0) {
        guard hour >= 0, hour <= 24, minute >= 0, minute < 60, second >= 0, second < 60,
              microsecond >= 0, microsecond < 1_000_000 else { return nil }
        let micros = Int64(hour) * 3_600_000_000 + Int64(minute) * 60_000_000
            + Int64(second) * 1_000_000 + Int64(microsecond)
        guard micros <= 86_400_000_000 else { return nil }
        microsecondsSinceMidnight = micros
    }

    /// `14:30`, `14:30:05` or `14:30:05.250000`.
    public init?(_ description: String) {
        let parts = description.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let hour = Int(parts[0]), let minute = Int(parts[1]) else {
            return nil
        }
        var second = 0
        var microsecond = 0
        if parts.count == 3 {
            let halves = parts[2].split(separator: ".", omittingEmptySubsequences: false)
            guard let whole = Int(halves[0]) else { return nil }
            second = whole
            if halves.count == 2 {
                var digits = String(halves[1])
                guard digits.count <= 6, digits.allSatisfy(\.isNumber) else { return nil }
                while digits.count < 6 { digits += "0" }
                guard let fraction = Int(digits) else { return nil }
                microsecond = fraction
            } else if halves.count > 2 {
                return nil
            }
        }
        guard let value = PostgresTime(hour, minute, second, microsecond: microsecond) else { return nil }
        self = value
    }

    public var hour: Int { Int(microsecondsSinceMidnight / 3_600_000_000) }
    public var minute: Int { Int(microsecondsSinceMidnight / 60_000_000 % 60) }
    public var second: Int { Int(microsecondsSinceMidnight / 1_000_000 % 60) }
    public var microsecond: Int { Int(microsecondsSinceMidnight % 1_000_000) }

    public var description: String {
        let base = "\(PostgresDate.pad(hour, 2)):\(PostgresDate.pad(minute, 2)):\(PostgresDate.pad(second, 2))"
        return microsecond == 0 ? base : base + "." + PostgresDate.pad(microsecond, 6)
    }

    public static func < (a: PostgresTime, b: PostgresTime) -> Bool {
        a.microsecondsSinceMidnight < b.microsecondsSinceMidnight
    }
}

// MARK: - interval

/// A length of time, as PostgreSQL's `interval` holds it: months, days and
/// microseconds kept apart, because a month is not 30 days and a day is not
/// always 24 hours.
public struct PostgresInterval: Sendable, Hashable, Codable, CustomStringConvertible {
    public let months: Int32
    public let days: Int32
    public let microseconds: Int64

    public init(months: Int32 = 0, days: Int32 = 0, microseconds: Int64 = 0) {
        self.months = months
        self.days = days
        self.microseconds = microseconds
    }

    public init(years: Int = 0, months: Int = 0, days: Int = 0,
                hours: Int = 0, minutes: Int = 0, seconds: Int = 0, microseconds: Int = 0) {
        self.months = Int32(years * 12 + months)
        self.days = Int32(days)
        self.microseconds = Int64(hours) * 3_600_000_000 + Int64(minutes) * 60_000_000
            + Int64(seconds) * 1_000_000 + Int64(microseconds)
    }

    /// ISO-8601, which PostgreSQL reads whatever its `IntervalStyle` is:
    /// `P1Y2M3DT4H5M6.5S`.
    public var description: String {
        var out = "P"
        let years = months / 12
        let leftoverMonths = months % 12
        if years != 0 { out += "\(years)Y" }
        if leftoverMonths != 0 { out += "\(leftoverMonths)M" }
        if days != 0 { out += "\(days)D" }
        let hours = microseconds / 3_600_000_000
        let minutes = microseconds / 60_000_000 % 60
        let micros = microseconds % 60_000_000
        if hours != 0 || minutes != 0 || micros != 0 {
            out += "T"
            if hours != 0 { out += "\(hours)H" }
            if minutes != 0 { out += "\(minutes)M" }
            if micros != 0 {
                let seconds = micros / 1_000_000
                let fraction = Int(abs(micros % 1_000_000))
                if fraction == 0 {
                    out += "\(seconds)S"
                } else {
                    // A negative fraction of a second still needs its sign,
                    // and -0.5 has no sign in its whole part.
                    let whole = seconds == 0 && micros < 0 ? "-0" : "\(seconds)"
                    out += whole + "." + PostgresDate.pad(fraction, 6) + "S"
                }
            }
        }
        return out == "P" ? "PT0S" : out
    }

    /// Reads what PostgreSQL writes in any of its interval styles: ISO-8601
    /// (`P1Y2M3DT4H5M6S`), the default (`1 year 2 mons 3 days 04:05:06`), and
    /// `sql_standard` (`1-2 3 4:05:06`).
    public init?(_ text: String) {
        let trimmed = text.trimmingWhitespace()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("P") || trimmed.hasPrefix("-P") {
            guard let value = PostgresInterval.readISO(trimmed) else { return nil }
            self = value
            return
        }
        guard let value = PostgresInterval.readWords(trimmed) else { return nil }
        self = value
    }

    private static func readISO(_ text: String) -> PostgresInterval? {
        let negative = text.hasPrefix("-")
        var rest = Substring(negative ? String(text.dropFirst(2)) : String(text.dropFirst()))
        var months = 0, days = 0, micros = 0
        var inTime = false
        var number = ""
        while let c = rest.first {
            rest = rest.dropFirst()
            if c == "T" {
                inTime = true
                continue
            }
            if c.isNumber || c == "." || c == "-" || c == "+" {
                number.append(c)
                continue
            }
            guard let value = Double(number) else { return nil }
            number = ""
            switch (c, inTime) {
            case ("Y", false): months += Int(value) * 12
            case ("M", false): months += Int(value)
            case ("W", false): days += Int(value) * 7
            case ("D", false): days += Int(value)
            case ("H", true): micros += Int(value * 3_600_000_000)
            case ("M", true): micros += Int(value * 60_000_000)
            case ("S", true): micros += Int((value * 1_000_000).rounded())
            default: return nil
            }
        }
        guard number.isEmpty else { return nil }
        let sign = negative ? -1 : 1
        return PostgresInterval(months: Int32(months * sign), days: Int32(days * sign),
                                microseconds: Int64(micros * sign))
    }

    /// `1 year 2 mons 3 days 04:05:06.5`, and `1-2 3 4:05:06` from
    /// `sql_standard`.
    private static func readWords(_ text: String) -> PostgresInterval? {
        var months = 0, days = 0
        var micros: Int64 = 0
        var pending: Int? = nil
        /// sql_standard writes the days as a bare number between the
        /// year-month field and the clock.
        var daysFromBareNumber = 0
        for field in text.split(separator: " ") {
            if let number = Int(field) {
                pending = number
                continue
            }
            // A clock field: 04:05:06.5, possibly negative. A bare number
            // before it is sql_standard's day count (`1-2 3 4:05:06`).
            if field.contains(":") {
                if let days = pending {
                    // Lost otherwise: nothing later names it.
                    pending = nil
                    micros += 0
                    daysFromBareNumber += days
                }
                let negative = field.hasPrefix("-")
                guard let time = PostgresTime(String(negative ? field.dropFirst() : field)) else { return nil }
                micros += (negative ? -1 : 1) * time.microsecondsSinceMidnight
                continue
            }
            // sql_standard's year-month: 1-2.
            if field.contains("-"), !field.hasPrefix("-"), let dash = field.firstIndex(of: "-"),
               let years = Int(field[field.startIndex..<dash]),
               let extra = Int(field[field.index(after: dash)...]) {
                months += years * 12 + extra
                pending = nil
                continue
            }
            // "ago" negates everything and carries no number of its own.
            if field.lowercased() == "ago" {
                months = -months
                days = -days
                daysFromBareNumber = -daysFromBareNumber
                micros = -micros
                continue
            }
            guard let number = pending else { return nil }
            pending = nil
            switch field.lowercased() {
            case "year", "years", "yr", "yrs": months += number * 12
            case "mon", "mons", "month", "months": months += number
            case "week", "weeks": days += number * 7
            case "day", "days": days += number
            case "hour", "hours", "hr", "hrs": micros += Int64(number) * 3_600_000_000
            case "min", "mins", "minute", "minutes": micros += Int64(number) * 60_000_000
            case "sec", "secs", "second", "seconds": micros += Int64(number) * 1_000_000
            default: return nil
            }
        }
        // A bare number with no unit, as sql_standard's day field.
        if let number = pending { daysFromBareNumber += number }
        return PostgresInterval(months: Int32(months), days: Int32(days + daysFromBareNumber),
                                microseconds: micros)
    }
}

// MARK: - numeric

/// An exact decimal, as PostgreSQL's `numeric` holds it: kept as its digits,
/// so 1234.56 stays 1234.56.
///
/// Comparisons and `Equatable` are by value, so `1.50` and `1.5` are equal.
/// Arithmetic is not offered: do it in the database, or in a type built for
/// it.
public struct PostgresNumeric: Sendable, Hashable, Codable, Comparable, CustomStringConvertible,
                               LosslessStringConvertible {
    /// True for `numeric 'NaN'`, which PostgreSQL allows.
    public let isNaN: Bool
    let negative: Bool
    /// The digits, most significant first, with no leading zeros.
    let digits: [UInt8]
    /// How many of `digits` are after the point.
    let scale: Int

    public static let nan = PostgresNumeric(isNaN: true, negative: false, digits: [], scale: 0)

    init(isNaN: Bool, negative: Bool, digits: [UInt8], scale: Int) {
        self.isNaN = isNaN
        self.negative = negative
        self.digits = digits
        self.scale = scale
    }

    /// `-1234.56`, `NaN`, `1e3`. Nil for anything else.
    public init?(_ description: String) {
        let text = description.trimmingWhitespace()
        if text.lowercased() == "nan" {
            self = .nan
            return
        }
        var body = Substring(text)
        var negative = false
        if body.hasPrefix("-") {
            negative = true
            body = body.dropFirst()
        } else if body.hasPrefix("+") {
            body = body.dropFirst()
        }
        // An exponent is expanded, so the digits are the whole story.
        var exponent = 0
        if let e = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            guard let value = Int(body[body.index(after: e)...]) else { return nil }
            exponent = value
            body = body[body.startIndex..<e]
        }
        let halves = body.split(separator: ".", omittingEmptySubsequences: false)
        guard halves.count <= 2, !halves.isEmpty else { return nil }
        let whole = halves[0]
        let fraction = halves.count == 2 ? halves[1] : ""
        guard !(whole.isEmpty && fraction.isEmpty),
              whole.allSatisfy(\.isNumber), fraction.allSatisfy(\.isNumber) else { return nil }
        var all = Array(whole.utf8.map { $0 - UInt8(ascii: "0") }) + fraction.utf8.map { $0 - UInt8(ascii: "0") }
        var scale = fraction.count - exponent
        // A negative scale means trailing zeros the digits do not hold.
        while scale < 0 {
            all.append(0)
            scale += 1
        }
        self = PostgresNumeric.normalized(negative: negative, digits: all, scale: scale)
    }

    /// From a whole number.
    public init(_ value: some FixedWidthInteger & SignedInteger) {
        let negative = value < 0
        let magnitude = String(value.magnitude)
        self = PostgresNumeric.normalized(negative: negative,
                                          digits: Array(magnitude.utf8.map { $0 - UInt8(ascii: "0") }),
                                          scale: 0)
    }

    /// From the wire's base-10000 groups: the first group is multiplied by
    /// 10000 to the power of `weight`, and `scale` decimal places are kept.
    init?(_ parts: (negative: Bool, isNaN: Bool, weight: Int, digits: [UInt16], scale: Int)) {
        if parts.isNaN {
            self = .nan
            return
        }
        func group(_ index: Int) -> UInt16 {
            index >= 0 && index < parts.digits.count ? parts.digits[index] : 0
        }
        var decimal: [UInt8] = []
        // The whole part: groups 0 through `weight`, or a single zero when the
        // number is smaller than one.
        if parts.weight >= 0 {
            for index in 0...parts.weight {
                let text = PostgresDate.pad(Int(group(index)), 4)
                decimal.append(contentsOf: text.utf8.map { $0 - UInt8(ascii: "0") })
            }
        } else {
            decimal.append(0)
        }
        // The fraction: whatever the scale asks for, taken from the groups
        // after the point, with leading zero groups where the weight says the
        // number begins further right.
        var fraction: [UInt8] = []
        if parts.weight < -1 {
            fraction.append(contentsOf: [UInt8](repeating: 0, count: (-parts.weight - 1) * 4))
        }
        var index = max(parts.weight + 1, 0)
        while fraction.count < parts.scale {
            let text = PostgresDate.pad(Int(group(index)), 4)
            fraction.append(contentsOf: text.utf8.map { $0 - UInt8(ascii: "0") })
            index += 1
        }
        fraction = Array(fraction.prefix(parts.scale))
        self = PostgresNumeric.normalized(negative: parts.negative, digits: decimal + fraction,
                                          scale: parts.scale)
    }

    /// Strips leading zeros in the whole part, keeping the scale.
    static func normalized(negative: Bool, digits: [UInt8], scale: Int) -> PostgresNumeric {
        var digits = digits
        var scale = scale
        // Trailing zeros past the point do not change the value.
        while scale > 0, digits.last == 0 {
            digits.removeLast()
            scale -= 1
        }
        while digits.count > scale + 1, digits.first == 0 {
            digits.removeFirst()
        }
        let allZero = digits.allSatisfy { $0 == 0 }
        return PostgresNumeric(isNaN: false, negative: allZero ? false : negative,
                               digits: digits, scale: scale)
    }

    public var description: String {
        guard !isNaN else { return "NaN" }
        var text = negative ? "-" : ""
        let whole = digits.count - scale
        if whole <= 0 {
            text += "0"
        } else {
            text += String(decoding: digits[0..<whole].map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
        }
        if scale > 0 {
            text += "."
            if whole < 0 { text += String(repeating: "0", count: -whole) }
            let start = max(0, whole)
            text += String(decoding: digits[start...].map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
        }
        return text
    }

    /// The nearest `Double`, which may not be exact: that is what it is for.
    public var doubleValue: Double { Double(description) ?? .nan }

    /// The value as a whole number, or nil when it has a fraction or does not
    /// fit.
    public var intValue: Int? {
        guard !isNaN, scale == 0 else { return nil }
        return Int(description)
    }

    public static func < (a: PostgresNumeric, b: PostgresNumeric) -> Bool {
        guard !a.isNaN, !b.isNaN else { return b.isNaN && !a.isNaN }
        if a.negative != b.negative { return a.negative }
        let magnitude = PostgresNumeric.compareMagnitude(a, b)
        return a.negative ? magnitude > 0 : magnitude < 0
    }

    /// -1, 0 or 1, ignoring the sign.
    static func compareMagnitude(_ a: PostgresNumeric, _ b: PostgresNumeric) -> Int {
        let wholeA = a.digits.count - a.scale
        let wholeB = b.digits.count - b.scale
        if wholeA != wholeB { return wholeA < wholeB ? -1 : 1 }
        let scale = max(a.scale, b.scale)
        func digit(_ value: PostgresNumeric, _ index: Int) -> UInt8 {
            let padded = value.digits.count + (scale - value.scale)
            return index < padded - (scale - value.scale) ? value.digits[index] : 0
        }
        for i in 0..<(wholeA + scale) {
            let left = digit(a, i)
            let right = digit(b, i)
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }
}

// MARK: - json and jsonb

/// A `json` or `jsonb` column, decoded into `Value`.
///
/// ```
/// struct Row: Decodable { let meta: PostgresJSON<Metadata> }
/// let metadata = try await pool.first(Row.self, "select meta from things")?.meta.value
/// ```
public struct PostgresJSON<Value: Codable & Sendable>: Sendable, Codable, CustomStringConvertible {
    public var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        // From a row, the column's text is handed over by the driver; from
        // anything else, it decodes as the value itself.
        value = try Value(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try value.encode(to: encoder)
    }

    public var description: String {
        (try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "\(value)"
    }
}

/// What the row decoder uses to build a `PostgresJSON` from a column's bytes.
protocol PostgresJSONColumn {
    static func fromJSONBytes(_ bytes: [UInt8]) throws -> Self
}

extension PostgresJSON: PostgresJSONColumn {
    static func fromJSONBytes(_ bytes: [UInt8]) throws -> PostgresJSON<Value> {
        PostgresJSON(try JSONCoder.decode(Value.self, from: bytes))
    }
}

// MARK: - Binding

extension PostgresDate: PostgresBindable {
    public var postgresValue: PostgresValue { PostgresValue(description) }
}

extension PostgresTime: PostgresBindable {
    public var postgresValue: PostgresValue { PostgresValue(description) }
}

extension PostgresInterval: PostgresBindable {
    public var postgresValue: PostgresValue { PostgresValue(description) }
}

extension PostgresNumeric: PostgresBindable {
    public var postgresValue: PostgresValue { PostgresValue(description) }
}

extension PostgresJSON: PostgresBindable {
    public var postgresValue: PostgresValue {
        PostgresValue((try? String(decoding: JSONCoder.encode(value), as: UTF8.self)) ?? "null")
    }
}
