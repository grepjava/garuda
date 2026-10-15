//===----------------------------------------------------------------------===//
// GarudaSQLite: SQLite for a Garuda application.
//
//     import Garuda
//     import GarudaSQLite
//
//     let db = app.state { _ in try! SQLiteDatabase(SQLiteConfiguration(path: "app.db")) }
//
// The driver is vega-db's VegaSQLite, re-exported whole. What is here is
// Garuda's `UUID` and `Timestamp` as columns.
//
// Under `--shards` each shard opens the file for itself: SQLite's own locks
// order the writers, and WAL mode lets readers in every shard go on while one
// writes.
//===----------------------------------------------------------------------===//

@_exported import Garuda
@_exported import VegaSQLite
import GarudaWire

extension UUID: SQLiteBindable, SQLiteCellConvertible {
    /// Text, lowercase with hyphens: readable in the `sqlite3` shell, and
    /// equal to itself in a comparison with text written the same way.
    public var sqliteValue: SQLiteValue { .text(description) }

    /// From text, or from the 16 bytes of a blob.
    public init(sqliteValue value: SQLiteValue) throws {
        switch value {
        case .text(let s):
            if let id = UUID(s) { self = id; return }
        case .blob(let b):
            if let id = UUID(bytes: b) { self = id; return }
        default: break
        }
        throw SQLiteDecodingError.notConvertible(column: "", value: "\(value)", expected: "UUID")
    }
}

extension Timestamp: SQLiteBindable, SQLiteCellConvertible {
    /// Text in UTC, `2026-09-17 06:19:31.123456`: what SQLite's date functions
    /// read, and the same width for every instant from year 1 to 9999, so
    /// comparing and ordering the text orders the instants.
    public var sqliteValue: SQLiteValue { .text(sqliteText) }

    var sqliteText: String {
        let lower: Int64 = -62_135_596_800_000_000     // 0001-01-01
        let upper: Int64 = 253_402_300_800_000_000     // 10000-01-01
        guard microsecondsSinceEpoch >= lower && microsecondsSinceEpoch < upper else { return description }
        var text = CivilTime.format(microseconds: microsecondsSinceEpoch, .postgresWithoutZone)
        var digits = 0
        if let dot = text.utf8.firstIndex(of: UInt8(ascii: ".")) {
            digits = text.utf8.distance(from: dot, to: text.utf8.endIndex) - 1
        } else {
            text.append(".")
        }
        if digits < 6 { text.append(String(repeating: "0", count: 6 - digits)) }
        return text
    }

    /// From text -- as a Timestamp binds, as `CURRENT_TIMESTAMP` writes, or
    /// ISO 8601 -- or from an integer of seconds since 1970, as `unixepoch()`
    /// returns.
    public init(sqliteValue value: SQLiteValue) throws {
        switch value {
        case .text(let s):
            if let t = Timestamp(s) { self = t; return }
        case .integer(let n):
            let (micros, overflow) = n.multipliedReportingOverflow(by: 1_000_000)
            if !overflow { self.init(microsecondsSinceEpoch: micros); return }
        default: break
        }
        throw SQLiteDecodingError.notConvertible(column: "", value: "\(value)", expected: "Timestamp")
    }
}
