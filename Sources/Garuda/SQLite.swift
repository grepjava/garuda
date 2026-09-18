//===----------------------------------------------------------------------===//
// SQLite connections, used from the blocking pool.
//
// SQLite is a C library that reads and writes files on the thread that calls
// it, and waits on other processes' locks there too, so none of it may run on
// a worker. Each statement goes to a thread of the worker's blocking pool
// (BlockingPool.swift) whole: prepared or taken from the connection's cache,
// bound, stepped to the end, its rows copied out and the statement reset. The
// worker decodes the copied rows once the task resumes.
//
// A connection is only ever used by one thread at a time -- the pool hands it
// to one statement, and takes it back before handing it to another -- which
// is what SQLite's multi-thread mode asks, so it is opened without its own
// mutex.
//
// The library is the system's, loaded when the first database opens
// (CGarudaSQLite). Building Garuda needs no SQLite headers.
//===----------------------------------------------------------------------===//

import AvianCore
import CGarudaSQLite

/// Where a SQLite database is and how to open it.
public struct SQLiteConfiguration: Sendable {
    public enum Mode: Sendable {
        /// Reads and writes, creating the file if it does not exist.
        case readWrite
        /// Reads only. The file must exist.
        case readOnly
    }

    /// How hard SQLite works to make a commit survive a power loss.
    public enum Synchronous: String, Sendable {
        /// Leaves flushing to the operating system. A crash of the machine can
        /// lose commits or corrupt the file.
        case off = "OFF"
        /// With WAL, a power loss can lose the last commits but never corrupts
        /// the file. The usual choice for WAL.
        case normal = "NORMAL"
        /// Every commit is flushed before it returns.
        case full = "FULL"
    }

    /// A file path, or `:memory:` for a database that lives in the connection
    /// and disappears with it.
    public var path: String
    public var mode: Mode = .readWrite
    /// Write-ahead logging, so readers do not wait for a writer, nor it for
    /// them. Kept in the file once set; ignored in memory and read-only.
    public var writeAheadLog = true
    public var synchronous: Synchronous = .normal
    /// Whether `REFERENCES` constraints are enforced. SQLite's own default is
    /// off, for compatibility with databases older than the feature.
    public var foreignKeys = true
    /// How long a statement waits for another connection's lock -- another
    /// worker's write, say -- before failing with `SQLITE_BUSY`. The wait is on
    /// a blocking thread, not the worker.
    public var busyTimeoutMilliseconds: Int32 = 5_000
    /// How long a statement waits for a connection of this pool when every one
    /// is in use.
    public var acquireTimeoutMilliseconds: UInt64 = 10_000
    /// Statements each connection keeps prepared, by SQL.
    public var statementCacheCapacity = 64
    /// Rows a single result may hold before the statement fails.
    public var maxRows = 1_000_000
    /// Bytes of text and blobs a single result may hold before the statement
    /// fails.
    public var maxResultBytes = 64 * 1024 * 1024

    public init(path: String) {
        self.path = path
    }

    /// Whether the database lives in the connection rather than in a file, so
    /// that a second connection would open a different, empty database.
    var isMemory: Bool {
        path == ":memory:" || path.isEmpty || path.hasPrefix("file::memory:")
    }
}

// MARK: - Errors

/// What SQLite said when it refused something.
public struct SQLiteFailure: Error, Equatable, Sendable, CustomStringConvertible {
    /// The primary result code: 19 (`SQLITE_CONSTRAINT`) for any constraint.
    public var code: Int32 { extendedCode & 0xFF }
    /// The extended result code: 2067 (`SQLITE_CONSTRAINT_UNIQUE`), 787
    /// (`SQLITE_CONSTRAINT_FOREIGNKEY`).
    public let extendedCode: Int32
    public let message: String

    public init(extendedCode: Int32, message: String) {
        self.extendedCode = extendedCode
        self.message = message
    }

    public var description: String { "SQLite error \(extendedCode): \(message)" }
}

/// Why a SQLite operation did not complete.
public enum SQLiteClientError: Error, Equatable, Sendable {
    /// No usable libsqlite3 could be loaded: not installed, missing a function
    /// Garuda uses, or built without thread support.
    case unavailable
    /// The database could not be opened or set up.
    case open(SQLiteFailure)
    /// SQLite refused a statement.
    case sqlite(SQLiteFailure)
    /// The SQL held more than one statement. Only a migration may.
    case multipleStatements
    /// The statement has a different number of parameters than values given.
    case parameterCount(expected: Int, given: Int)
    /// The result had more than `maxRows` rows.
    case tooManyRows
    /// The result held more than `maxResultBytes` of text and blobs.
    case resultTooLarge
    /// A statement outside `transaction` began a transaction and did not end
    /// it. It was rolled back: the next statement on that connection could be
    /// any request's.
    case transactionLeftOpen
    /// The database has migrations this program does not know: it was
    /// migrated by a newer version.
    case unknownSchemaVersion(found: Int, known: Int)
    /// Every connection stayed in use for `acquireTimeoutMilliseconds`.
    case poolTimedOut
    /// The request was cancelled while waiting for a connection, or the
    /// statement was run where there is no worker to wait on.
    case cancelled
    /// The database was closed.
    case closed
}

extension SQLiteClientError {
    /// SQLite's extended result code when SQLite refused the statement --
    /// 2067 for a unique violation -- or nil when the failure was not SQLite's.
    public var sqliteCode: Int32? {
        switch self {
        case .sqlite(let failure), .open(let failure): return failure.extendedCode
        default: return nil
        }
    }

    /// Whether SQLite refused the statement for breaking a constraint: unique,
    /// not null, foreign key, check.
    public var isConstraintViolation: Bool {
        sqliteCode.map { $0 & 0xFF == GSQ_CONSTRAINT } ?? false
    }
}

/// Why a row could not become the type asked for.
public enum SQLiteDecodingError: Error, Equatable {
    case missingColumn(String)
    case notConvertible(column: String, value: String, expected: String)
    case null(column: String)
    case unsupported(String)
}

// MARK: - Values

/// A value as SQLite stores it.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])
}

/// A Swift value that binds to a statement parameter.
///
/// `UInt` and `UInt64` do not conform: SQLite's integers are signed 64-bit,
/// and half their range would not fit.
public protocol SQLiteBindable {
    var sqliteValue: SQLiteValue { get }
}

extension SQLiteValue: SQLiteBindable { public var sqliteValue: SQLiteValue { self } }
extension String: SQLiteBindable { public var sqliteValue: SQLiteValue { .text(self) } }
extension Substring: SQLiteBindable { public var sqliteValue: SQLiteValue { .text(String(self)) } }
extension Int: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int8: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int16: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int32: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Int64: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self) } }
extension UInt8: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension UInt16: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension UInt32: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(Int64(self)) } }
extension Double: SQLiteBindable { public var sqliteValue: SQLiteValue { .real(self) } }
extension Float: SQLiteBindable {
    /// Through its shortest decimal form, so 0.1 is stored as 0.1 and not as
    /// the 0.10000000149011612 that widening the Float itself would give.
    public var sqliteValue: SQLiteValue { .real(Double(description) ?? Double(self)) }
}
extension Bool: SQLiteBindable { public var sqliteValue: SQLiteValue { .integer(self ? 1 : 0) } }
extension Array: SQLiteBindable where Element == UInt8 {
    public var sqliteValue: SQLiteValue { .blob(self) }
}
extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    public var sqliteValue: SQLiteValue { self?.sqliteValue ?? .null }
}
extension UUID: SQLiteBindable {
    /// Text, lowercase with hyphens: readable in the `sqlite3` shell, and
    /// equal to itself in a comparison with text written the same way.
    public var sqliteValue: SQLiteValue { .text(description) }
}
extension Timestamp: SQLiteBindable {
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
}

// MARK: - Rows

/// A statement's result, copied out of SQLite.
public struct SQLiteRows: Sendable {
    public let columns: [String]
    /// Row by row, a column at a time.
    let values: [SQLiteValue]
    /// Rows changed by an INSERT, UPDATE or DELETE; 0 for anything else.
    public let affected: Int
    /// The rowid of the last row this connection inserted.
    public let lastInsertRowID: Int64
    /// Whether SQLite said the statement cannot write.
    let readOnly: Bool

    public var count: Int { columns.isEmpty ? 0 : values.count / columns.count }

    public func value(row: Int, column: Int) -> SQLiteValue {
        values[row * columns.count + column]
    }
}

// MARK: - One connection

struct SQLiteLimits: Sendable {
    var maxRows: Int
    var maxResultBytes: Int
}

final class SQLiteConnection: @unchecked Sendable {
    private struct Cached {
        let statement: OpaquePointer
        let readOnly: Bool
        var used: UInt64
    }

    private var db: OpaquePointer?
    private var cache: [String: Cached] = [:]
    private var uses: UInt64 = 0
    private let cacheCapacity: Int
    let readOnly: Bool

    private init(db: OpaquePointer, cacheCapacity: Int, readOnly: Bool) {
        self.db = db
        self.cacheCapacity = cacheCapacity
        self.readOnly = readOnly
    }

    deinit { close() }

    /// Opens and sets up a connection. Blocks: file I/O, and perhaps a wait
    /// on another process's lock to switch the file to WAL.
    static func open(_ configuration: SQLiteConfiguration, readOnly: Bool) throws(SQLiteClientError) -> SQLiteConnection {
        guard gsq_available() != 0 else { throw .unavailable }
        // A pool's reader opens the file read-write and is held to reads by
        // SQLite rather than by the open flags. A read-only connection cannot
        // create the -shm file a write-ahead log is read through, so it cannot
        // be the first to open a WAL database that nothing has written to yet:
        // on Darwin's SQLite that is "unable to open database file", and the
        // first read of such a database failed. The file was opened for
        // writing by this same pool a moment earlier, so nothing is given up
        // by opening it that way again -- and CREATE is not passed, so a
        // reader still never brings a database into being.
        //
        // A database configured read-only is a different thing: there the
        // whole pool is read-only, the file may be one this process cannot
        // write, and every connection opens read-only.
        let fileReadOnly = configuration.mode == .readOnly
        let holdToReads = readOnly && !fileReadOnly
        var flags = GSQ_OPEN_NOMUTEX | GSQ_OPEN_PRIVATECACHE
        if readOnly && fileReadOnly {
            flags |= GSQ_OPEN_READONLY
        } else if readOnly {
            flags |= GSQ_OPEN_READWRITE
        } else {
            flags |= GSQ_OPEN_READWRITE | GSQ_OPEN_CREATE
        }
        var handle: OpaquePointer? = nil
        let rc = configuration.path.withCString { gsq_open($0, Int32(flags), &handle) }
        guard let handle else { throw .open(SQLiteFailure(extendedCode: rc, message: String(cString: gsq_errstr(rc)))) }
        let connection = SQLiteConnection(db: handle, cacheCapacity: max(0, configuration.statementCacheCapacity),
                                          readOnly: readOnly)
        guard rc == GSQ_OK else {
            let failure = connection.failure()
            connection.close()
            throw .open(failure)
        }
        _ = gsq_extended_result_codes(handle, 1)
        _ = gsq_busy_timeout(handle, max(0, configuration.busyTimeoutMilliseconds))
        do throws(SQLiteClientError) {
            if !readOnly && configuration.writeAheadLog && !configuration.isMemory {
                let mode = try connection.whileBusy(configuration.busyTimeoutMilliseconds) {
                    () throws(SQLiteClientError) -> SQLiteRows in
                    try connection.run("PRAGMA journal_mode=WAL", [], cached: false)
                }
                guard mode.count == 1, case .text(let name) = mode.value(row: 0, column: 0),
                      name.lowercased() == "wal" else {
                    throw .open(SQLiteFailure(extendedCode: GSQ_ERROR,
                                              message: "the database would not switch to write-ahead logging"))
                }
            }
            _ = try connection.run("PRAGMA synchronous=\(configuration.synchronous.rawValue)", [], cached: false)
            _ = try connection.run("PRAGMA foreign_keys=\(configuration.foreignKeys ? "ON" : "OFF")", [], cached: false)
            // Last, so the settings above are still allowed to be made. From
            // here SQLite refuses anything that would change the database on
            // this connection, with SQLITE_READONLY, exactly as the read-only
            // open flag would have.
            if holdToReads {
                _ = try connection.run("PRAGMA query_only=1", [], cached: false)
            }
        } catch {
            connection.close()
            if case .sqlite(let failure) = error { throw .open(failure) }
            throw error
        }
        return connection
    }

    var isOpen: Bool { db != nil }

    /// Runs `body` again while SQLite says the database is busy, for up to
    /// `milliseconds`. Switching a file to WAL takes an exclusive lock that
    /// SQLite does not wait for through the busy timeout, so workers starting
    /// together on a new file would otherwise fail all but one of them.
    func whileBusy<T>(_ milliseconds: Int32, _ body: () throws(SQLiteClientError) -> T) throws(SQLiteClientError) -> T {
        var waited: Int32 = 0
        var pause: Int32 = 1
        while true {
            do {
                return try body()
            } catch {
                guard case .sqlite(let failure) = error,
                      failure.code == GSQ_BUSY || failure.code == GSQ_LOCKED,
                      waited < milliseconds else { throw error }
                gsq_sleep(pause)
                waited += pause
                pause = min(pause * 2, 50)
            }
        }
    }

    /// Inside a transaction: one begun and not yet committed or rolled back.
    var inTransaction: Bool {
        guard let db else { return false }
        return gsq_get_autocommit(db) == 0
    }

    func close() {
        guard let db else { return }
        for entry in cache.values { _ = gsq_finalize(entry.statement) }
        cache.removeAll()
        _ = gsq_close(db)
        self.db = nil
    }

    private func failure() -> SQLiteFailure {
        guard let db else { return SQLiteFailure(extendedCode: GSQ_MISUSE, message: "the connection is closed") }
        return SQLiteFailure(extendedCode: gsq_extended_errcode(db), message: String(cString: gsq_errmsg(db)))
    }

    /// Runs one statement to its end and copies out its rows.
    func run(_ sql: String, _ values: [SQLiteValue], cached: Bool = true,
             limits: SQLiteLimits = SQLiteLimits(maxRows: .max, maxResultBytes: .max)) throws(SQLiteClientError) -> SQLiteRows {
        guard let db else { throw .closed }
        let entry = try statement(sql, cached: cached && cacheCapacity > 0)
        guard let entry else {
            // Only whitespace and comments: nothing to run.
            return SQLiteRows(columns: [], values: [], affected: 0,
                              lastInsertRowID: gsq_last_insert_rowid(db), readOnly: true)
        }
        let statement = entry.statement
        defer {
            _ = gsq_reset(statement)
            _ = gsq_clear_bindings(statement)
            if !(cached && cacheCapacity > 0) { _ = gsq_finalize(statement) }
        }

        let expected = Int(gsq_bind_parameter_count(statement))
        guard expected == values.count else { throw .parameterCount(expected: expected, given: values.count) }
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = gsq_bind_null(statement, index)
            case .integer(let n):
                rc = gsq_bind_int64(statement, index, n)
            case .real(let d):
                rc = gsq_bind_double(statement, index, d)
            case .text(let s):
                var s = s
                rc = s.withUTF8 { utf8 in
                    guard utf8.count <= Int32.max else { return GSQ_RANGE }
                    return utf8.withMemoryRebound(to: CChar.self) {
                        gsq_bind_text(statement, index, $0.baseAddress, Int32(utf8.count))
                    }
                }
            case .blob(let bytes):
                rc = bytes.withUnsafeBytes { raw in
                    guard raw.count <= Int32.max else { return GSQ_RANGE }
                    return gsq_bind_blob(statement, index, raw.baseAddress, Int32(raw.count))
                }
            }
            guard rc == GSQ_OK else { throw .sqlite(failure()) }
        }

        var width = 0
        var columns: [String] = []
        var out: [SQLiteValue] = []
        var rows = 0
        var bytes = 0
        var stepped = false
        while true {
            let rc = gsq_step(statement)
            if !stepped {
                // Read after the first step, every run: SQLite prepares a
                // cached statement again inside the step when the schema has
                // changed, and `select *` may then have other columns.
                stepped = true
                width = Int(gsq_column_count(statement))
                columns.reserveCapacity(width)
                for column in 0..<Int32(width) {
                    columns.append(gsq_column_name(statement, column).map { String(cString: $0) } ?? "")
                }
            }
            if rc == GSQ_DONE { break }
            guard rc == GSQ_ROW else { throw .sqlite(failure()) }
            rows += 1
            guard rows <= limits.maxRows else { throw .tooManyRows }
            for column in 0..<Int32(width) {
                switch gsq_column_type(statement, column) {
                case GSQ_INTEGER:
                    out.append(.integer(gsq_column_int64(statement, column)))
                case GSQ_FLOAT:
                    out.append(.real(gsq_column_double(statement, column)))
                case GSQ_TEXT:
                    let text = gsq_column_text(statement, column)
                    let count = Int(gsq_column_bytes(statement, column))
                    bytes += count
                    guard bytes <= limits.maxResultBytes else { throw .resultTooLarge }
                    guard let text else { throw .sqlite(failure()) }
                    out.append(.text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)))
                case GSQ_BLOB:
                    let blob = gsq_column_blob(statement, column)
                    let count = Int(gsq_column_bytes(statement, column))
                    bytes += count
                    guard bytes <= limits.maxResultBytes else { throw .resultTooLarge }
                    if let blob, count > 0 {
                        out.append(.blob(Array(UnsafeRawBufferPointer(start: blob, count: count))))
                    } else {
                        out.append(.blob([]))
                    }
                default:
                    out.append(.null)
                }
            }
        }
        // A statement that changed nothing leaves the count of the last one
        // that did, so only a statement that can write reports it.
        let affected = entry.readOnly ? 0 : Int(gsq_changes(db))
        return SQLiteRows(columns: columns, values: out, affected: affected,
                          lastInsertRowID: gsq_last_insert_rowid(db), readOnly: entry.readOnly)
    }

    /// Runs every statement in `script`, discarding rows. For migrations.
    func runScript(_ script: String) throws(SQLiteClientError) {
        guard let db else { throw .closed }
        var utf8 = Array(script.utf8)
        utf8.append(0)
        var offset = 0
        while offset < utf8.count - 1 {
            var statement: OpaquePointer? = nil
            var consumed = 0
            let rc = utf8.withUnsafeBufferPointer { buffer -> Int32 in
                buffer.withMemoryRebound(to: CChar.self) { chars in
                    let start = chars.baseAddress! + offset
                    var tail: UnsafePointer<CChar>? = nil
                    let rc = gsq_prepare(db, start, Int32(chars.count - 1 - offset), &statement, &tail)
                    consumed = tail.map { $0 - UnsafePointer(start) } ?? (chars.count - 1 - offset)
                    return rc
                }
            }
            guard rc == GSQ_OK else { throw .sqlite(failure()) }
            guard consumed > 0 || statement != nil else { break }
            offset += consumed
            guard let statement else { continue }
            var step = gsq_step(statement)
            while step == GSQ_ROW { step = gsq_step(statement) }
            let stepFailure = step == GSQ_DONE ? nil : failure()
            _ = gsq_finalize(statement)
            if let stepFailure { throw .sqlite(stepFailure) }
        }
    }

    /// The prepared statement for `sql`, from the cache or newly prepared; nil
    /// when the SQL holds no statement.
    private func statement(_ sql: String, cached: Bool) throws(SQLiteClientError) -> Cached? {
        if cached, var hit = cache[sql] {
            uses += 1
            hit.used = uses
            cache[sql] = hit
            return hit
        }
        guard let db else { throw .closed }
        var sql = sql
        var prepared: OpaquePointer? = nil
        var rest = false
        let rc = sql.withUTF8 { utf8 -> Int32 in
            guard utf8.count < Int32.max else { return GSQ_RANGE }
            return utf8.withMemoryRebound(to: CChar.self) { chars -> Int32 in
                var tail: UnsafePointer<CChar>? = nil
                let rc = gsq_prepare(db, chars.baseAddress, Int32(chars.count), &prepared, &tail)
                guard rc == GSQ_OK, let tail, let base = chars.baseAddress else { return rc }
                // What follows the first statement must hold none: preparing
                // it yields no statement when it is only whitespace and
                // comments. Running the first and ignoring the rest would
                // silently skip SQL the caller wrote.
                let used = tail - base
                if used < chars.count {
                    var extra: OpaquePointer? = nil
                    let extraRC = gsq_prepare(db, tail, Int32(chars.count - used), &extra, nil)
                    if extra != nil {
                        _ = gsq_finalize(extra)
                        rest = true
                    } else if extraRC != GSQ_OK {
                        rest = true
                    }
                }
                return rc
            }
        }
        guard rc == GSQ_OK else { throw .sqlite(failure()) }
        guard let prepared else { return nil }
        if rest {
            _ = gsq_finalize(prepared)
            throw .multipleStatements
        }
        uses += 1
        let entry = Cached(statement: prepared, readOnly: gsq_stmt_readonly(prepared) != 0, used: uses)
        guard cached else { return entry }
        if cache.count >= cacheCapacity, let oldest = cache.min(by: { $0.value.used < $1.value.used }) {
            _ = gsq_finalize(oldest.value.statement)
            cache.removeValue(forKey: oldest.key)
        }
        cache[sql] = entry
        return entry
    }

    /// For tests: statements held prepared.
    var cachedStatements: Int { cache.count }
}
