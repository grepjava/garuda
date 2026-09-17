import Testing
import AvianCore
import GarudaPostgres
@testable import Garuda

// UUID and Timestamp, and the calendar and text code under them.

@Suite("UUID and Timestamp")
struct TimeAndUUIDTests {

    // MARK: Calendar

    @Test func daysAndDatesAgreeAcrossEveryKindOfYear() {
        // 1600 and 2000 are leap years, 1700 and 1900 are not, and year 0 is
        // 1 BC, which is.
        for (year, month, day, days) in [(1970, 1, 1, 0), (2000, 3, 1, 11_017), (1969, 12, 31, -1),
                                         (1600, 2, 29, -135_081), (0, 2, 29, -719_469)] as [(Int64, Int64, Int64, Int64)] {
            #expect(CivilTime.days(year: year, month: month, day: day) == days)
            #expect(CivilTime.date(days: days) == (year, month, day))
        }
        var days = CivilTime.days(year: -400, month: 1, day: 1)
        let end = CivilTime.days(year: 2400, month: 12, day: 31)
        var previous = CivilTime.date(days: days - 1)
        while days <= end {
            let date = CivilTime.date(days: days)
            #expect(CivilTime.days(year: date.year, month: date.month, day: date.day) == days)
            let nextDay = date.day == previous.day + 1 && date.month == previous.month
            let nextMonth = date.day == 1 && previous.day == CivilTime.daysInMonth(year: previous.year, month: previous.month)
            if !(nextDay || nextMonth) {
                Issue.record("\(previous) then \(date)")
                break
            }
            previous = date
            days += 1
        }
        #expect(CivilTime.daysInMonth(year: 1900, month: 2) == 28)
        #expect(CivilTime.daysInMonth(year: 2000, month: 2) == 29)
    }

    @Test func instantsAreWrittenInBothLayouts() {
        let moment: Int64 = 1_789_591_223_196_000   // 2026-09-16T20:40:23.196Z
        #expect(CivilTime.format(microseconds: moment, .iso8601) == "2026-09-16T20:40:23.196Z")
        #expect(CivilTime.format(microseconds: moment, .postgres) == "2026-09-16 20:40:23.196+00")
        #expect(CivilTime.format(microseconds: 0, .iso8601) == "1970-01-01T00:00:00Z")
        #expect(CivilTime.format(microseconds: -1, .iso8601) == "1969-12-31T23:59:59.999999Z")
        #expect(CivilTime.format(microseconds: 1_000_010, .postgresWithoutZone) == "1970-01-01 00:00:01.00001")
        let ides = CivilTime.days(year: -43, month: 3, day: 15) * CivilTime.microsecondsPerDay
        #expect(CivilTime.format(microseconds: ides, .postgres) == "0044-03-15 00:00:00+00 BC")
        #expect(CivilTime.format(microseconds: ides, .iso8601) == "-0043-03-15T00:00:00Z")
    }

    @Test func instantsAreReadFromEitherLayoutAndAnyOffset() {
        let moment: Int64 = 1_789_591_223_196_000
        for text in ["2026-09-16T20:40:23.196Z", "2026-09-16 20:40:23.196+00", "2026-09-16t20:40:23.196z",
                     "2026-09-16T20:40:23.196", "2026-09-17T02:10:23.196+05:30", "2026-09-16T15:40:23.196-05",
                     "2026-09-16T20:40:23.196000999Z", "2026-09-17 02:10:23.196+0530"] {
            #expect(CivilTime.parse(text.utf8) == moment, "\(text)")
        }
        #expect(CivilTime.parse("0044-03-15 00:00:00+00 BC".utf8)
                == CivilTime.days(year: -43, month: 3, day: 15) * CivilTime.microsecondsPerDay)
        #expect(CivilTime.parse("1970-01-01 00:00:00+00:00:30".utf8) == -30_000_000)
    }

    @Test func textThatIsNotAnInstantIsRefused() {
        for text in ["", "2026-09-16", "2026-02-29T00:00:00Z", "2026-13-01T00:00:00Z", "2026-09-16T24:00:00Z",
                     "2026-09-16T20:60:00Z", "2026-09-16T20:40Z", "2026-09-16T20:40:23.Z", "2026-9-16T20:40:23Z",
                     "2026-09-16T20:40:23Zjunk", "infinity", "0000-01-01 00:00:00+00 BC",
                     "-0001-01-01 00:00:00+00 BC", "+0044-03-15 00:00:00+00 BC", "2026-09-16T20:40:23+24:00"] {
            #expect(CivilTime.parse(text.utf8) == nil, "\(text)")
        }
    }

    // MARK: Timestamp

    @Test func aTimestampRoundTripsThroughTextAndJSON() throws {
        let moment = Timestamp(microsecondsSinceEpoch: 1_789_591_223_196_123)
        #expect(moment.description == "2026-09-16T20:40:23.196123Z")
        #expect(Timestamp(moment.description) == moment)
        let json = try JSONCoder.encode(["at": moment])
        #expect(String(decoding: json, as: UTF8.self) == #"{"at":"2026-09-16T20:40:23.196123Z"}"#)
        #expect(try JSONCoder.decode([String: Timestamp].self, from: json)["at"] == moment)
        #expect(throws: (any Error).self) { try JSONCoder.decode([String: Timestamp].self, from: Array(#"{"at":"soon"}"#.utf8)) }
        #expect(Timestamp(microsecondsSinceEpoch: -1).secondsSinceEpoch == -1)
        #expect(Timestamp.now > Timestamp("2026-01-01T00:00:00Z")!)
    }

    // MARK: UUID

    @Test func aUUIDIsReadAndWrittenAsText() throws {
        let text = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let id = try #require(UUID(text))
        #expect(id.description == text)
        #expect(UUID("0F8FAD5BD9CB469FA16570867728950E") == id)
        #expect(id.bytes.count == 16)
        #expect(UUID(bytes: id.bytes) == id)
        #expect(id.version == 4)
        for bad in ["", "0f8fad5b-d9cb-469f-a165-70867728950", "0f8fad5bxd9cb-469f-a165-70867728950e",
                    "0f8fad5b-d9cb-469f-a165-70867728950g", "{0f8fad5b-d9cb-469f-a165-70867728950e}"] {
            #expect(UUID(bad) == nil, "\(bad)")
        }
        let json = try JSONCoder.encode([id])
        #expect(String(decoding: json, as: UTF8.self) == "[\"\(text)\"]")
        #expect(try JSONCoder.decode([UUID].self, from: json) == [id])
    }

    @Test func randomUUIDsAreVersionFourAndDoNotRepeat() {
        var seen = Set<UUID>()
        for _ in 0..<1000 {
            let id = UUID.random()
            #expect(id.version == 4)
            #expect(id.bytes[8] & 0xC0 == 0x80)
            seen.insert(id)
        }
        #expect(seen.count == 1000)
    }
}
