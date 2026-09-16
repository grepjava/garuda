//===----------------------------------------------------------------------===//
// An instant, without Foundation.
//
//     let placed = Timestamp.now
//     placed.description                   // "2026-09-16T20:53:43.196Z"
//
// Microseconds since 1970-01-01T00:00:00Z: PostgreSQL's resolution, and a
// range of about 292,000 years either side. It carries no time zone because
// an instant has none; a zone is how one is written, and this writes UTC.
//
// It binds to PostgreSQL as a timestamptz in binary. Keep instants in
// timestamptz columns: a timestamp column without a zone stores the wall
// clock the session's TimeZone makes of it, and reads back as that wall
// clock taken as UTC, which is the same instant only when TimeZone is UTC.
//===----------------------------------------------------------------------===//

import CGaruda
import GarudaCore
import GarudaPostgres

public struct Timestamp: Hashable, Comparable, Sendable {
    public var microsecondsSinceEpoch: Int64

    public init(microsecondsSinceEpoch: Int64) {
        self.microsecondsSinceEpoch = microsecondsSinceEpoch
    }

    public init(secondsSinceEpoch: Int64) {
        microsecondsSinceEpoch = secondsSinceEpoch * CivilTime.microsecondsPerSecond
    }

    /// The system's wall clock, now.
    public static var now: Timestamp {
        Timestamp(microsecondsSinceEpoch: Int64(pg_realtime_us()))
    }

    /// From ISO 8601 or RFC 3339 text -- `2026-09-16T20:53:43.196Z`, any UTC
    /// offset -- or PostgreSQL's `2026-09-16 20:53:43.196+00`. No offset
    /// means UTC.
    public init?(_ text: String) {
        guard let micros = CivilTime.parse(text.utf8) else { return nil }
        microsecondsSinceEpoch = micros
    }

    public var secondsSinceEpoch: Int64 {
        let seconds = microsecondsSinceEpoch / CivilTime.microsecondsPerSecond
        return microsecondsSinceEpoch % CivilTime.microsecondsPerSecond < 0 ? seconds - 1 : seconds
    }

    public func adding(microseconds: Int64) -> Timestamp {
        Timestamp(microsecondsSinceEpoch: microsecondsSinceEpoch + microseconds)
    }

    public func adding(seconds: Int64) -> Timestamp {
        adding(microseconds: seconds * CivilTime.microsecondsPerSecond)
    }

    public static func < (a: Timestamp, b: Timestamp) -> Bool {
        a.microsecondsSinceEpoch < b.microsecondsSinceEpoch
    }

    /// PostgreSQL counts from 2000-01-01, not 1970.
    static let postgresEpochOffset: Int64 = 946_684_800_000_000
}

extension Timestamp: CustomStringConvertible, LosslessStringConvertible {
    /// ISO 8601 in UTC, to the microsecond, with trailing zeros dropped.
    public var description: String { CivilTime.format(microseconds: microsecondsSinceEpoch, .iso8601) }
}

extension Timestamp: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try String(from: decoder)
        guard let value = Timestamp(text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "not a timestamp: \(text)"))
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        try description.encode(to: encoder)
    }
}

extension Timestamp: PostgresBindable {
    public var postgresValue: PostgresValue {
        let (since2000, overflow) = microsecondsSinceEpoch.subtractingReportingOverflow(Timestamp.postgresEpochOffset)
        // Only within 32 years of Int64's floor, far outside what the server
        // accepts anyway; as text it gets the server's own range error.
        if overflow { return PostgresValue(CivilTime.format(microseconds: microsecondsSinceEpoch, .postgres)) }
        return .binary(withUnsafeBytes(of: since2000.bigEndian) { Array($0) }, type: PostgresType.timestamptz)
    }
}
