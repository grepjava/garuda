import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// The types for `date`, `time`, `interval`, `numeric` and json: their text
// forms, their binary forms, and a round trip through a real PostgreSQL.

@Suite("PostgreSQL types")
struct PostgresTypesTests {
    @Test func dates() throws {
        let day = try #require(PostgresDate(2026, 9, 18))
        #expect(day.description == "2026-09-18")
        #expect(PostgresDate("2026-09-18") == day)
        #expect(try #require(PostgresDate("0001-01-01")).description == "0001-01-01")

        // A day that does not exist, and text that is not a date.
        #expect(PostgresDate(2026, 2, 30) == nil)
        #expect(PostgresDate(2026, 13, 1) == nil)
        #expect(PostgresDate(2024, 2, 29) != nil, "a leap year has one")
        #expect(PostgresDate(1900, 2, 29) == nil, "1900 was not one")
        #expect(PostgresDate("18/09/2026") == nil)
        #expect(PostgresDate("2026-9-18") == nil)
        #expect(PostgresDate("") == nil)

        // The wire's days since 2000-01-01, both ways.
        #expect(try #require(PostgresDate(2000, 1, 1)).daysSince2000 == 0)
        #expect(try #require(PostgresDate(2000, 1, 2)).daysSince2000 == 1)
        #expect(try #require(PostgresDate(1999, 12, 31)).daysSince2000 == -1)
        #expect(day.daysSince2000 == 9_757)
        #expect(PostgresDate(daysSince2000: 9_757) == day)
        for days in Int32(-100_000)...Int32(-99_900) {
            #expect(PostgresDate(daysSince2000: days).daysSince2000 == days)
        }
        for days in Int32(0)...Int32(2_000) {
            #expect(PostgresDate(daysSince2000: days).daysSince2000 == days)
        }
        #expect(PostgresDate(2026, 1, 1)! < PostgresDate(2026, 1, 2)!)
    }

    @Test func times() throws {
        let noon = try #require(PostgresTime(12, 0))
        #expect(noon.description == "12:00:00")
        #expect(noon.microsecondsSinceMidnight == 43_200_000_000)
        let precise = try #require(PostgresTime("14:30:05.25"))
        #expect(precise.description == "14:30:05.250000")
        #expect(precise.hour == 14 && precise.minute == 30 && precise.second == 5)
        #expect(precise.microsecond == 250_000)
        #expect(PostgresTime("14:30") == PostgresTime(14, 30))
        // PostgreSQL's own upper bound.
        #expect(PostgresTime("24:00:00") != nil)
        #expect(PostgresTime(24, 0, 1) == nil)
        #expect(PostgresTime("25:00:00") == nil)
        #expect(PostgresTime("12:60:00") == nil)
        #expect(PostgresTime("noon") == nil)
        #expect(PostgresTime("12:00:00.1234567") == nil, "beyond microseconds")
    }

    @Test func intervals() throws {
        let full = PostgresInterval(years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6)
        #expect(full.months == 14 && full.days == 3)
        #expect(full.description == "P1Y2M3DT4H5M6S")
        #expect(PostgresInterval(months: 0, days: 0, microseconds: 0).description == "PT0S")
        #expect(PostgresInterval(seconds: 0, microseconds: 500_000).description == "PT0.500000S")

        // Every style PostgreSQL writes.
        #expect(PostgresInterval("P1Y2M3DT4H5M6S") == full)
        #expect(PostgresInterval("1 year 2 mons 3 days 04:05:06") == full)
        #expect(PostgresInterval("1 year 2 mons 3 days 04:05:06.5")
                    == PostgresInterval(years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6,
                                        microseconds: 500_000))
        #expect(PostgresInterval("1-2 3 4:05:06") == full, "sql_standard")
        #expect(PostgresInterval("2 days") == PostgresInterval(days: 2))
        #expect(PostgresInterval("00:00:30") == PostgresInterval(seconds: 30))
        #expect(PostgresInterval("2 days ago") == PostgresInterval(days: -2))
        #expect(PostgresInterval("-PT1H") == PostgresInterval(hours: -1))
        #expect(PostgresInterval("not an interval") == nil)
        #expect(PostgresInterval("") == nil)

        // A month is not thirty days, so they are kept apart.
        #expect(PostgresInterval(months: 1) != PostgresInterval(days: 30))
    }

    @Test func numerics() throws {
        let total = try #require(PostgresNumeric("1234.56"))
        #expect(total.description == "1234.56")
        #expect(total.doubleValue == 1234.56)
        #expect(total.intValue == nil, "it has a fraction")
        #expect(try #require(PostgresNumeric("42")).intValue == 42)
        #expect(PostgresNumeric(-7).description == "-7")

        // The forms text can take.
        #expect(try #require(PostgresNumeric("-0.005")).description == "-0.005")
        #expect(try #require(PostgresNumeric("0.10")).description == "0.1", "trailing zeros do not count")
        #expect(try #require(PostgresNumeric("000123")).description == "123")
        #expect(try #require(PostgresNumeric("1e3")).description == "1000")
        #expect(try #require(PostgresNumeric("1.5e-2")).description == "0.015")
        #expect(try #require(PostgresNumeric("-0")).description == "0", "zero has no sign")
        #expect(try #require(PostgresNumeric("NaN")).isNaN)
        #expect(PostgresNumeric("1,234") == nil)
        #expect(PostgresNumeric("") == nil)
        #expect(PostgresNumeric(".") == nil)

        // Value, not spelling.
        #expect(PostgresNumeric("1.50") == PostgresNumeric("1.5"))
        #expect(PostgresNumeric("1.5")! < PostgresNumeric("1.51")!)
        #expect(PostgresNumeric("-2")! < PostgresNumeric("-1")!)
        #expect(PostgresNumeric("9.99")! < PostgresNumeric("10")!)
        #expect(!(PostgresNumeric("10")! < PostgresNumeric("9.99")!))

        // Exactly, where a Double would not be.
        let exact = try #require(PostgresNumeric("179769313486231570000000000000000000000.12345678901234567890"))
        #expect(exact.description == "179769313486231570000000000000000000000.1234567890123456789")
    }

    @Test func numericFromTheWire() throws {
        // ndigits, weight, sign, dscale, then base-10000 groups.
        func bytes(_ words: [Int]) -> ArraySlice<UInt8> {
            var out: [UInt8] = []
            for word in words {
                let value = UInt16(bitPattern: Int16(truncatingIfNeeded: word))
                out.append(UInt8(value >> 8))
                out.append(UInt8(value & 0xFF))
            }
            return out[...]
        }
        func read(_ words: [Int]) throws -> PostgresNumeric {
            let parts = try #require(PostgresBinary.numeric(bytes(words)))
            return try #require(PostgresNumeric(parts))
        }
        // 1234.56 is two groups: 1234 and 5600, weight 0, scale 2.
        #expect(try read([2, 0, 0x0000, 2, 1234, 5600]).description == "1234.56")
        #expect(try read([1, 0, 0x4000, 0, 7]).description == "-7")
        // Weight -1 puts the group in the first four decimal places: 1500
        // there is 0.15, and 0.015 is the group 0150.
        #expect(try read([1, -1, 0x0000, 4, 1500]).description == "0.15")
        #expect(try read([1, -1, 0x0000, 3, 150]).description == "0.015")
        #expect(try read([1, -2, 0x0000, 8, 5000]).description == "0.00005")
        #expect(try read([0, 0, 0x0000, 0]).description == "0")
        #expect(try read([0, 0, 0xC000, 0]).isNaN)
        // 100000000 is three groups of which two are zero: 1, 0000, 0000.
        #expect(try read([1, 2, 0x0000, 0, 1]).description == "100000000")
        // Infinity is not a decimal.
        #expect(PostgresBinary.numeric(bytes([0, 0, 0xD000, 0])) == nil)
        // A group beyond 9999, and a length that disagrees with the count.
        #expect(PostgresBinary.numeric(bytes([1, 0, 0x0000, 0, 10_000])) == nil)
        #expect(PostgresBinary.numeric(bytes([2, 0, 0x0000, 0, 1])) == nil)
    }

    @Test func datesAndTimesFromTheWire() throws {
        func int32(_ value: Int32) -> ArraySlice<UInt8> {
            withUnsafeBytes(of: value.bigEndian) { Array($0)[...] }
        }
        func int64(_ value: Int64) -> ArraySlice<UInt8> {
            withUnsafeBytes(of: value.bigEndian) { Array($0)[...] }
        }
        #expect(PostgresBinary.dateDays(int32(9_757)) == 9_757)
        #expect(PostgresBinary.dateDays(int32(.max)) == nil, "infinity names no day")
        #expect(PostgresBinary.dateDays(int32(.min)) == nil)
        #expect(PostgresBinary.timeMicroseconds(int64(43_200_000_000)) == 43_200_000_000)
        #expect(PostgresBinary.timeMicroseconds(int64(-1)) == nil)
        #expect(PostgresBinary.timeMicroseconds(int64(86_400_000_001)) == nil)

        // An interval is microseconds, days, then months.
        let wire = Array(int64(14_706_000_000)) + Array(int32(3)) + Array(int32(14))
        let parts = try #require(PostgresBinary.interval(wire[...]))
        #expect(parts.months == 14 && parts.days == 3 && parts.microseconds == 14_706_000_000)
        #expect(PostgresBinary.interval(wire.dropLast()[...]) == nil)
    }

    @Test func jsonColumnsEncodeAndDecode() throws {
        struct Metadata: Codable, Equatable, Sendable {
            let source: String
            let tags: [String]
        }
        let value = Metadata(source: "import", tags: ["a", "b"])
        let column = PostgresJSON(value)
        // Bound as JSON text, which is what the column takes.
        #expect(boundText(column.postgresValue) == #"{"source":"import","tags":["a","b"]}"#)
        // And read back from the same text.
        let read = try PostgresJSON<Metadata>.fromJSONBytes(Array(#"{"source":"import","tags":["a","b"]}"#.utf8))
        #expect(read.value == value)
    }

    @Test func boundAsTextPostgresAccepts() throws {
        #expect(boundText(PostgresDate(2026, 9, 18)!.postgresValue) == "2026-09-18")
        #expect(boundText(PostgresTime(14, 30, 5)!.postgresValue) == "14:30:05")
        #expect(boundText(PostgresInterval(days: 1, hours: 2).postgresValue) == "P1DT2H")
        #expect(boundText(PostgresNumeric("1234.56")!.postgresValue) == "1234.56")
    }
}

/// What a bound value carries, as text.
private func boundText(_ value: PostgresValue) -> String? {
    guard case .text(let bytes) = value else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}
