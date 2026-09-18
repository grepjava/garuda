import Synchronization
import Testing
import CAvian
import AvianCore
import CGarudaSQLite
@testable import Garuda

// SQLite through the system's libsqlite3: one connection driven directly, and
// a database in handlers on a test worker, with its statements on the blocking
// pool. Every test has a file of its own, removed afterwards.

/// Atomic because the three suites in this file run beside one another, and
/// each of them makes databases. The names they ask for differ, so a torn
/// count never collided, but a plain `var` read and written from several
/// threads is a data race whether or not it is got away with.
private let fileCounter = Atomic<Int>(0)

/// A database path no other test uses, and its removal with its WAL files.
private final class TemporaryDatabase {
    let path: String

    init(_ name: String) {
        let number = fileCounter.wrappingAdd(1, ordering: .relaxed).newValue
        path = "/tmp/garuda-sqlite-\(av_getpid())-\(number)-\(name).db"
        remove()
    }

    deinit { remove() }

    func remove() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            _ = (path + suffix).withCString { av_unlink($0) }
        }
    }
}

private func pause(_ milliseconds: UInt64) async {
    _ = await Worker.waitTimed(currentWorker!, milliseconds: milliseconds) { _ in }
}

nonisolated(unsafe) private var databaseForTests: SQLiteDatabase? = nil

/// Runs `body` in a handler with a database, and returns what it returns, or
/// the error it threw, written out.
private func run(_ file: TemporaryDatabase, maxReaders: Int = 4,
                 configure: (inout SQLiteConfiguration) -> Void = { _ in },
                 _ body: @escaping @Sendable (SQLiteDatabase) async throws -> String) throws -> String {
    var configuration = SQLiteConfiguration(path: file.path)
    configure(&configuration)
    let settled = configuration
    let app = Application()
    app.state { _ in
        let db = try SQLiteDatabase(settled, maxReaders: maxReaders)
        databaseForTests = db
        return db
    }
    app.get("/run") { (db: State<SQLiteDatabase>) async -> String in
        do {
            return try await body(db.value)
        } catch {
            return "threw \(error)"
        }
    }
    let client = app.test
    client.timeoutMillis = 15_000
    return try client.get("/run").text
}

struct Item: Codable, Equatable {
    let id: Int
    let name: String
    let price: Double?
    let active: Bool
}

@Suite("SQLite connection", .serialized, .enabled(if: gsq_available() != 0, "no libsqlite3"))
struct SQLiteConnectionTests {
    private func open(_ file: TemporaryDatabase, _ configure: (inout SQLiteConfiguration) -> Void = { _ in })
        throws -> SQLiteConnection {
        var configuration = SQLiteConfiguration(path: file.path)
        configure(&configuration)
        return try SQLiteConnection.open(configuration, readOnly: false)
    }

    @Test func everyStorageClassRoundTrips() throws {
        let file = TemporaryDatabase("classes")
        let c = try open(file)
        try c.runScript("create table t (v)")
        let values: [SQLiteValue] = [
            .null, .integer(0), .integer(.max), .integer(.min), .real(-2.5), .real(1e300),
            .text(""), .text("héllo ✓"), .text("a\u{0}b"), .blob([]), .blob((0...255).map { UInt8($0) }),
        ]
        for value in values { _ = try c.run("insert into t values (?)", [value]) }
        let rows = try c.run("select v from t order by rowid", [])
        #expect(rows.columns == ["v"])
        #expect((0..<rows.count).map { rows.value(row: $0, column: 0) } == values)
        // Empty text and an empty blob are not NULL.
        #expect(try c.run("select count(*) from t where v is null", []).value(row: 0, column: 0) == .integer(1))
    }

    @Test func onlyOneStatementRuns() throws {
        let file = TemporaryDatabase("one")
        let c = try open(file)
        try c.runScript("create table t (n integer)")
        #expect(throws: SQLiteClientError.multipleStatements) {
            try c.run("insert into t values (1); insert into t values (2)", [])
        }
        #expect(try c.run("select count(*) from t", []).value(row: 0, column: 0) == .integer(0))
        // A trailing semicolon, whitespace and comments are not a statement.
        _ = try c.run("insert into t values (3);  -- the end\n /* really */ ", [])
        #expect(try c.run("select count(*) from t", []).value(row: 0, column: 0) == .integer(1))
        // Nothing at all runs nothing.
        #expect(try c.run("  -- nothing", []).count == 0)
    }

    @Test func valuesMustMatchTheParameters() throws {
        let file = TemporaryDatabase("params")
        let c = try open(file)
        #expect(throws: SQLiteClientError.parameterCount(expected: 2, given: 1)) {
            try c.run("select ?, ?", [.integer(1)])
        }
        // The statement was reset: the next run of it binds afresh.
        #expect(try c.run("select ?, ?", [.integer(1), .text("x")]).value(row: 0, column: 1) == .text("x"))
    }

    @Test func resultsAreHeldToTheirLimits() throws {
        let file = TemporaryDatabase("limits")
        let c = try open(file)
        let series = "with recursive n(i) as (select 1 union all select i + 1 from n where i < 100) select i from n"
        #expect(try c.run(series, [], limits: SQLiteLimits(maxRows: 100, maxResultBytes: 10)).count == 100)
        #expect(throws: SQLiteClientError.tooManyRows) {
            try c.run(series, [], limits: SQLiteLimits(maxRows: 99, maxResultBytes: .max))
        }
        #expect(throws: SQLiteClientError.resultTooLarge) {
            try c.run("select zeroblob(11)", [], limits: SQLiteLimits(maxRows: 10, maxResultBytes: 10))
        }
        #expect(try c.run("select zeroblob(10)", [], limits: SQLiteLimits(maxRows: 10, maxResultBytes: 10)).count == 1)
        // Text counts the same, in bytes of UTF-8.
        #expect(throws: SQLiteClientError.resultTooLarge) {
            try c.run("select 'héllo', 'world'", [], limits: SQLiteLimits(maxRows: 10, maxResultBytes: 10))
        }
        #expect(try c.run("select 'hello', 'world'", [], limits: SQLiteLimits(maxRows: 10, maxResultBytes: 10)).count == 1)
    }

    @Test func refusalsCarrySQLitesCodes() throws {
        let file = TemporaryDatabase("codes")
        let c = try open(file)
        try c.runScript("""
            create table parent (id integer primary key, email text unique not null);
            create table child (parent integer references parent(id));
            insert into parent values (1, 'a@example.com');
            """)
        func refusal(_ sql: String) -> SQLiteClientError? {
            do {
                _ = try c.run(sql, [])
                return nil
            } catch {
                return error
            }
        }
        let unique = refusal("insert into parent values (2, 'a@example.com')")
        #expect(unique?.sqliteCode == 2067)
        #expect(unique?.isConstraintViolation == true)
        #expect(refusal("insert into parent values (3, null)")?.sqliteCode == 1299)
        // Enforced, because the configuration turns foreign keys on.
        #expect(refusal("insert into child values (42)")?.sqliteCode == 787)
        let syntax = refusal("selec 1")
        #expect(syntax?.sqliteCode == 1)
        #expect(syntax?.isConstraintViolation == false)
        if case .sqlite(let failure) = syntax { #expect(failure.message.contains("syntax error")) }
    }

    @Test func aStatementThatCannotWriteReportsNoChanges() throws {
        let file = TemporaryDatabase("changes")
        let c = try open(file)
        try c.runScript("create table t (n integer); insert into t values (1), (2), (3)")
        let update = try c.run("update t set n = n + 1 where n > 1", [])
        #expect(update.affected == 2)
        #expect(!update.readOnly)
        // sqlite3_changes still says 2 here; a select changed nothing.
        let select = try c.run("select n from t", [])
        #expect(select.affected == 0)
        #expect(select.readOnly)
        let insert = try c.run("insert into t values (9)", [])
        #expect(insert.lastInsertRowID == 4)
    }

    @Test func theStatementCacheIsBoundedAndFollowsTheSchema() throws {
        let file = TemporaryDatabase("cache")
        let c = try open(file) { $0.statementCacheCapacity = 3 }
        try c.runScript("create table t (a integer)")
        for i in 0..<10 { _ = try c.run("select \(i)", []) }
        #expect(c.cachedStatements == 3)
        _ = try c.run("insert into t values (1)", [])
        #expect(try c.run("select * from t", []).columns == ["a"])
        // The cached `select *` is prepared again by SQLite after the schema
        // changes, and has another column now.
        try c.runScript("alter table t add column b text default 'x'")
        let after = try c.run("select * from t", [])
        #expect(after.columns == ["a", "b"])
        #expect(after.value(row: 0, column: 1) == .text("x"))
    }

    @Test func aScriptRunsEveryStatementAndStopsAtAFailure() throws {
        let file = TemporaryDatabase("script")
        let c = try open(file)
        try c.runScript("""
            -- a comment first
            create table t (n integer);
            insert into t values (1); /* between */ insert into t values (2);
            """)
        #expect(try c.run("select count(*) from t", []).value(row: 0, column: 0) == .integer(2))
        #expect(throws: SQLiteClientError.self) {
            try c.runScript("insert into t values (3); insert into nowhere values (4); insert into t values (5)")
        }
        #expect(try c.run("select count(*) from t", []).value(row: 0, column: 0) == .integer(3))
    }

    @Test func aFileOpensInWriteAheadLogMode() throws {
        let file = TemporaryDatabase("wal")
        let c = try open(file)
        #expect(try c.run("pragma journal_mode", []).value(row: 0, column: 0) == .text("wal"))
        #expect(try c.run("pragma foreign_keys", []).value(row: 0, column: 0) == .integer(1))
        #expect(try c.run("pragma synchronous", []).value(row: 0, column: 0) == .integer(1))
        let other = TemporaryDatabase("rollback")
        let d = try open(other) { $0.writeAheadLog = false; $0.synchronous = .full; $0.foreignKeys = false }
        #expect(try d.run("pragma journal_mode", []).value(row: 0, column: 0) == .text("delete"))
        #expect(try d.run("pragma foreign_keys", []).value(row: 0, column: 0) == .integer(0))
        #expect(try d.run("pragma synchronous", []).value(row: 0, column: 0) == .integer(2))
    }

    @Test func aMissingFileIsNotCreatedReadOnly() throws {
        let file = TemporaryDatabase("missing")
        var configuration = SQLiteConfiguration(path: file.path)
        configuration.mode = .readOnly
        #expect(throws: SQLiteClientError.self) { try SQLiteConnection.open(configuration, readOnly: true) }
        #expect(throws: SQLiteClientError.self) { try SQLiteDatabase(configuration) }
    }

    @Test func timestampsBindAsTextThatSortsAndSQLiteReads() throws {
        let file = TemporaryDatabase("time")
        let c = try open(file)
        let whole = Timestamp(secondsSinceEpoch: 1_789_000_000)
        let later = whole.adding(microseconds: 120_000)
        #expect(whole.sqliteText == "2026-09-10 00:26:40.000000")
        #expect(later.sqliteText == "2026-09-10 00:26:40.120000")
        // As text, the later instant sorts later -- which ISO 8601 with its
        // trailing zeros dropped would not: "40.12Z" < "40Z".
        #expect(whole.sqliteText < later.sqliteText)
        #expect(try c.run("select datetime(?)", [later.sqliteValue]).value(row: 0, column: 0)
                == .text("2026-09-10 00:26:40"))
        #expect(Timestamp(microsecondsSinceEpoch: -62_135_596_800_000_000).sqliteText == "0001-01-01 00:00:00.000000")
    }
}

@Suite("SQLite decoding", .enabled(if: gsq_available() != 0, "no libsqlite3"))
struct SQLiteDecodingTests {
    private func rows(_ columns: [String], _ values: [SQLiteValue]) -> SQLiteRows {
        SQLiteRows(columns: columns, values: values, affected: 0, lastInsertRowID: 0, readOnly: true)
    }

    private func one<T: Decodable>(_ type: T.Type, _ value: SQLiteValue) throws -> T {
        try decodeAllSQLite(type, rows(["v"], [value]))[0]
    }

    @Test func rowsDecodeByColumnName() throws {
        let result = rows(["active", "name", "id", "price"],
                          [.integer(1), .text("tea"), .integer(7), .null,
                           .integer(0), .text("cake"), .integer(8), .real(3.5)])
        #expect(try decodeAllSQLite(Item.self, result) == [
            Item(id: 7, name: "tea", price: nil, active: true),
            Item(id: 8, name: "cake", price: 3.5, active: false),
        ])
    }

    @Test func conversionsThatLoseNothingAreMade() throws {
        #expect(try one(Double.self, .integer(3)) == 3)
        #expect(try one(Int.self, .real(4)) == 4)
        #expect(try one(Int8.self, .integer(-128)) == -128)
        #expect(try one(String.self, .integer(12)) == "12")
        #expect(try one(Float.self, .real(0.1)) == Float(0.1))
        #expect(try one([UInt8].self, .text("ab")) == [97, 98])
        let id = UUID(high: 0x0123_4567_89ab_cdef, low: 0xfedc_ba98_7654_3210)
        #expect(try one(UUID.self, .text(id.description)) == id)
        #expect(try one(UUID.self, .blob(id.bytes)) == id)
        #expect(try one(Timestamp.self, .text("2026-09-17 06:19:31")) == Timestamp(secondsSinceEpoch: 1_789_625_971))
        #expect(try one(Timestamp.self, .integer(1_789_625_971)) == Timestamp(secondsSinceEpoch: 1_789_625_971))
        #expect(try one(Int?.self, .null) == nil)
    }

    @Test func conversionsThatWouldGuessAreRefused() throws {
        #expect(throws: SQLiteDecodingError.notConvertible(column: "v", value: "4.5", expected: "Int")) {
            try one(Int.self, .real(4.5))
        }
        #expect(throws: SQLiteDecodingError.notConvertible(column: "v", value: "300", expected: "UInt8")) {
            try one(UInt8.self, .integer(300))
        }
        #expect(throws: SQLiteDecodingError.notConvertible(column: "v", value: "12", expected: "Int")) {
            try one(Int.self, .text("12"))
        }
        #expect(throws: SQLiteDecodingError.notConvertible(column: "v", value: "2", expected: "Bool")) {
            try one(Bool.self, .integer(2))
        }
        #expect(throws: SQLiteDecodingError.null(column: "v")) { try one(String.self, .null) }
        #expect(throws: SQLiteDecodingError.missingColumn("active")) {
            try decodeAllSQLite(Item.self, rows(["id", "name"], [.integer(1), .text("x")]))
        }
        // A missing column into an Optional is nil, as synthesized Decodable
        // asks with decodeIfPresent.
        #expect(try decodeAllSQLite(Item.self, rows(["id", "name", "active"], [.integer(1), .text("x"), .integer(1)]))
                == [Item(id: 1, name: "x", price: nil, active: true)])
        #expect(throws: SQLiteDecodingError.self) {
            try decodeAllSQLite(Int.self, rows(["a", "b"], [.integer(1), .integer(2)]))
        }
    }

    @Test func swiftValuesBindAsSQLiteStoresThem() {
        #expect(true.sqliteValue == .integer(1))
        #expect(Float(0.1).sqliteValue == .real(0.1))
        #expect(Int?.none.sqliteValue == .null)
        #expect([UInt8]().sqliteValue == .blob([]))
        #expect("x"[...].sqliteValue == .text("x"))
    }
}

@Suite("SQLite database", .serialized, .enabled(if: gsq_available() != 0, "no libsqlite3"))
struct SQLiteDatabaseTests {
    private let schema = [
        "create table items (id integer primary key, name text not null unique, price real, active integer not null default 1)",
    ]

    @Test func crudInHandlers() throws {
        let file = TemporaryDatabase("crud")
        let result = try run(file) { [schema] db in
            try db.migrate(schema)
            var out: [String] = []
            let created = try await db.first(Item.self, "insert into items (name, price) values (?, ?) returning *",
                                             "tea", 2.5)
            out.append("\(created.map { "\($0.id) \($0.name) \($0.price ?? 0) \($0.active)" } ?? "nil")")
            try await db.execute("insert into items (name) values (?)", "cake")
            do {
                try await db.execute("insert into items (name) values (?)", "tea")
                out.append("duplicate inserted")
            } catch let error as SQLiteClientError where error.isConstraintViolation {
                out.append("conflict \(error.sqliteCode ?? 0)")
            }
            out.append("\(try await db.execute("update items set active = 0 where name = ?", "cake"))")
            let items = try await db.query(Item.self, "select id, name, price, active from items order by id")
            out.append(items.map { "\($0.name):\($0.active)" }.joined(separator: ","))
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            out.append("\(try await db.first(Item.self, "select * from items where id = ?", 99).map { $0.name } ?? "none")")
            return out.joined(separator: "|")
        }
        #expect(result == "1 tea 2.5 true|conflict 2067|1|tea:true,cake:false|2|none")
    }

    @Test func statementsThatCannotWriteMoveToReaders() throws {
        let file = TemporaryDatabase("readers")
        let result = try run(file, maxReaders: 2) { [schema] db in
            try db.migrate(schema)
            var out: [String] = []
            try await db.execute("insert into items (name) values ('a')")
            out.append("\(db.counts.openReaders)")
            // The first run is on the writer, which learns it cannot write.
            _ = try await db.first(Int.self, "select count(*) from items")
            out.append("\(db.counts.openReaders)")
            // The second is on a reader, and sees what the writer committed.
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            out.append("\(db.counts.openReaders)")
            try await db.execute("insert into items (name) values ('b')")
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            // A write is never learned as read-only, however often it runs.
            try await db.execute("insert into items (name) values ('c')")
            out.append("\(db.knownReadOnly)")
            return out.joined(separator: "|")
        }
        #expect(result == "0|0|1|1|2|1")
    }

    @Test func aMemoryDatabaseUsesOneConnection() throws {
        let result = try run(TemporaryDatabase("unused"), configure: { $0.path = ":memory:" }) { [schema] db in
            try db.migrate(schema)
            try await db.execute("insert into items (name) values ('a')")
            _ = try await db.first(Int.self, "select count(*) from items")
            let count = try await db.first(Int.self, "select count(*) from items") ?? -1
            return "\(db.maxReaders) \(db.counts.openReaders) \(count)"
        }
        #expect(result == "0 0 1")
    }

    @Test func aTransactionCommitsOrRollsBack() throws {
        let file = TemporaryDatabase("tx")
        let result = try run(file) { [schema] db in
            try db.migrate(schema)
            struct Abandon: Error {}
            var out: [String] = []
            try await db.transaction { tx in
                try await tx.execute("insert into items (name) values ('one')")
                try await tx.execute("insert into items (name) values ('two')")
            }
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            do {
                try await db.transaction { tx in
                    try await tx.execute("insert into items (name) values ('gone')")
                    throw Abandon()
                }
            } catch is Abandon {
                out.append("abandoned")
            }
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            // A failed statement undoes only itself, as in SQLite; the body
            // caught it and returned, so the rest commits.
            let inside = try await db.transaction { tx -> Int in
                try await tx.execute("insert into items (name) values ('three')")
                _ = try? await tx.execute("insert into items (name) values ('one')")
                return try await tx.first(Int.self, "select count(*) from items") ?? -1
            }
            out.append("\(inside)")
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            out.append("\(db.counts.writerBusy)")
            return out.joined(separator: "|")
        }
        #expect(result == "2|abandoned|2|3|3|false")
    }

    @Test func aTransactionLeftOpenIsRolledBackAndRefused() throws {
        let file = TemporaryDatabase("left-open")
        let result = try run(file) { [schema] db in
            try db.migrate(schema)
            var out: [String] = []
            do {
                try await db.execute("begin")
                out.append("left open")
            } catch let error as SQLiteClientError {
                out.append("\(error)")
            }
            // Run on the writer, then learned as read-only: begin twice, so
            // the second goes to a reader, which must refuse it the same way.
            do {
                try await db.execute("begin")
                out.append("left open")
            } catch let error as SQLiteClientError {
                out.append("\(error)")
            }
            do {
                try await db.execute("insert into items (name) values ('x')")
                out.append("inserted")
            } catch {
                out.append("\(error)")
            }
            // Both were rolled back: the insert commits on its own.
            try await db.transaction { tx in try await tx.execute("insert into items (name) values ('y')") }
            out.append("\(try await db.first(Int.self, "select count(*) from items") ?? -1)")
            return out.joined(separator: "|")
        }
        #expect(result == "transactionLeftOpen|transactionLeftOpen|inserted|2")
    }

    @Test func migrationsRunOnceInOrder() throws {
        let file = TemporaryDatabase("migrate")
        let first = [
            "create table a (n integer)",
            "insert into a values (1); insert into a values (2)",
        ]
        let result = try run(file) { db in
            var out: [String] = []
            try db.migrate(first)
            try db.migrate(first)
            out.append("\(try await db.first(Int.self, "select count(*) from a") ?? -1)")
            out.append("\(try await db.first(Int.self, "pragma user_version") ?? -1)")
            try db.migrate(first + ["alter table a add column m text default 'z'"])
            out.append("\(try await db.first(Int.self, "pragma user_version") ?? -1)")
            // A failing script undoes the whole run, scripts before it
            // included, and leaves the version where it was.
            do {
                try db.migrate(first + ["alter table a add column m text default 'z'",
                                        "create table b (n integer)",
                                        "insert into nowhere values (1)"])
                out.append("migrated")
            } catch let error as SQLiteClientError {
                out.append("failed \(error.sqliteCode ?? 0)")
            }
            out.append("\(try await db.first(Int.self, "pragma user_version") ?? -1)")
            out.append("\(try await db.first(Int.self, "select count(*) from sqlite_master where name = 'b'") ?? -1)")
            // A database from a newer program is refused.
            do {
                try db.migrate(first)
                out.append("migrated")
            } catch let error as SQLiteClientError {
                out.append("\(error)")
            }
            return out.joined(separator: "|")
        }
        #expect(result == "2|2|3|failed 1|3|0|unknownSchemaVersion(found: 3, known: 2)")
    }

    @Test func requestsWaitTheirTurnForTheWriter() throws {
        let file = TemporaryDatabase("turns")
        let app = Application()
        let path = file.path
        app.state { _ in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            try db.migrate(["create table n (v integer)"])
            databaseForTests = db
            return db
        }
        app.get("/hold") { (db: State<SQLiteDatabase>) async throws -> String in
            try await db.value.transaction { tx in
                try await tx.execute("insert into n values (1)")
                await pause(30)
            }
            return "held"
        }
        app.get("/count") { (db: State<SQLiteDatabase>) async throws -> String in
            String(try await db.value.first(Int.self, "select count(*) from n") ?? -1)
        }
        let client = app.test
        let wires = try (0..<5).map { _ in try TestWire(client) }
        for wire in wires { wire.send("GET /hold HTTP/1.1\r\nHost: test\r\n\r\n") }
        let answers = wires.map { $0.receive(turns: 2_000_000) ?? "no response" }
        #expect(answers.allSatisfy { $0.hasSuffix("held") }, "\(answers)")
        #expect(try client.get("/count").text == "5")
    }

    @Test func aWaitForTheWriterGivesUpAtItsDeadline() throws {
        let file = TemporaryDatabase("deadline")
        let app = Application()
        let path = file.path
        app.state { _ in
            var configuration = SQLiteConfiguration(path: path)
            configuration.acquireTimeoutMilliseconds = 50
            let db = try SQLiteDatabase(configuration)
            databaseForTests = db
            return db
        }
        app.get("/hold") { (db: State<SQLiteDatabase>) async throws -> String in
            try await db.value.transaction { _ in await pause(400) }
            return "held"
        }
        app.get("/write") { (db: State<SQLiteDatabase>) async -> String in
            do {
                return String(try await db.value.execute("create table if not exists t (n integer)"))
            } catch {
                return "\(error)"
            }
        }
        let client = app.test
        let holder = try TestWire(client)
        holder.send("GET /hold HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(holder.turn(until: { databaseForTests?.counts.writerBusy == true }, turns: 200_000))
        let began = av_monotonic_us()
        let waiter = try TestWire(client)
        waiter.send("GET /write HTTP/1.1\r\nHost: test\r\n\r\n")
        let refused = waiter.receive(turns: 2_000_000) ?? "no response"
        let waited = (av_monotonic_us() &- began) / 1000
        #expect(refused.hasSuffix("poolTimedOut"), "\(refused)")
        #expect(waited >= 50 && waited < 350, "waited \(waited) ms")
        #expect((holder.receive(turns: 2_000_000) ?? "").hasSuffix("held"))
        #expect(try client.get("/write").text == "0")
        #expect(client.worker.pointee.timedWaits.isEmpty)
    }

    @Test func anotherConnectionsLockIsWaitedForOffTheWorker() throws {
        // A second database on the same file stands in for another worker
        // process: its write lock is SQLite's, not this pool's. While a
        // statement waits out the busy timeout on a blocking thread, the
        // worker still answers.
        let file = TemporaryDatabase("busy")
        let app = Application()
        let path = file.path
        app.state { _ in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            try db.migrate(["create table n (v integer)"])
            return db
        }
        final class Other: @unchecked Sendable {
            let db: SQLiteDatabase
            init(_ db: SQLiteDatabase) { self.db = db }
        }
        var otherConfiguration = SQLiteConfiguration(path: path)
        otherConfiguration.busyTimeoutMilliseconds = 50
        let other = Other(try SQLiteDatabase(otherConfiguration))
        app.get("/other-holds") { (_: State<SQLiteDatabase>) async throws -> String in
            try await other.db.transaction { tx in
                try await tx.execute("insert into n values (1)")
                await pause(300)
            }
            return "released"
        }
        app.get("/write") { (db: State<SQLiteDatabase>) async -> String in
            do {
                try await db.value.execute("insert into n values (2)")
                return "written"
            } catch {
                return "\(error)"
            }
        }
        app.get("/other-write") { (_: State<SQLiteDatabase>) async -> String in
            do {
                try await other.db.execute("insert into n values (3)")
                return "written"
            } catch let error as SQLiteClientError {
                return "busy \(error.sqliteCode ?? 0)"
            } catch {
                return "\(error)"
            }
        }
        app.get("/main-holds") { (db: State<SQLiteDatabase>) async throws -> String in
            try await db.value.transaction { tx in
                try await tx.execute("insert into n values (4)")
                await pause(300)
            }
            return "released"
        }
        app.get("/ping") { () -> String in "pong" }
        let client = app.test

        let holder = try TestWire(client)
        holder.send("GET /other-holds HTTP/1.1\r\nHost: test\r\n\r\n")
        #expect(holder.turn(until: { other.db.counts.writerBusy }, turns: 200_000))
        // Long enough for BEGIN IMMEDIATE and the insert to have run.
        let settle = av_monotonic_ms()
        while av_monotonic_ms() &- settle < 50 { client.turn() }

        let writer = try TestWire(client)
        writer.send("GET /write HTTP/1.1\r\nHost: test\r\n\r\n")
        // The write waits on SQLite's lock; the worker does not.
        let began = av_monotonic_ms()
        #expect(try client.get("/ping").text == "pong")
        #expect(av_monotonic_ms() &- began < 100)
        #expect((writer.receive(turns: 5_000_000) ?? "").hasSuffix("written"))
        #expect((holder.receive(turns: 5_000_000) ?? "").hasSuffix("released"))

        // The other way round, with a busy timeout far shorter than the hold:
        // the wait gives up with SQLITE_BUSY (5).
        let mainHolder = try TestWire(client)
        mainHolder.send("GET /main-holds HTTP/1.1\r\nHost: test\r\n\r\n")
        let settle2 = av_monotonic_ms()
        while av_monotonic_ms() &- settle2 < 50 { client.turn() }
        #expect(try client.get("/other-write").text == "busy 5")
        #expect((mainHolder.receive(turns: 5_000_000) ?? "").hasSuffix("released"))
        #expect(try client.get("/other-write").text == "written")
        other.db.close()
    }

    @Test func aTransactionThatReadsFirstStillWrites() throws {
        // A transaction reads, then writes. Begun deferred, it would hold a
        // read snapshot, and another connection committing meanwhile would
        // make its write fail at once with SQLITE_BUSY_SNAPSHOT -- no busy
        // timeout helps. Begun IMMEDIATE, it holds the write lock from the
        // start, and the other connection waits for it instead.
        let file = TemporaryDatabase("immediate")
        let app = Application()
        let path = file.path
        app.state { _ in
            let db = try SQLiteDatabase(SQLiteConfiguration(path: path))
            try db.migrate(["create table n (v integer)"])
            return db
        }
        final class Other: @unchecked Sendable {
            let db: SQLiteDatabase
            init(_ db: SQLiteDatabase) { self.db = db }
        }
        let other = Other(try SQLiteDatabase(SQLiteConfiguration(path: path)))
        app.get("/read-then-write") { (db: State<SQLiteDatabase>) async -> String in
            do {
                try await db.value.transaction { tx in
                    let count = try await tx.first(Int.self, "select count(*) from n") ?? -1
                    await pause(150)
                    try await tx.execute("insert into n values (?)", count)
                }
                return "committed"
            } catch {
                return "\(error)"
            }
        }
        app.get("/other-write") { (_: State<SQLiteDatabase>) async -> String in
            do {
                try await other.db.execute("insert into n values (100)")
                return "written"
            } catch {
                return "\(error)"
            }
        }
        let client = app.test
        let first = try TestWire(client)
        first.send("GET /read-then-write HTTP/1.1\r\nHost: test\r\n\r\n")
        let settle = av_monotonic_ms()
        while av_monotonic_ms() &- settle < 50 { client.turn() }
        let second = try TestWire(client)
        second.send("GET /other-write HTTP/1.1\r\nHost: test\r\n\r\n")
        let firstAnswer = first.receive(turns: 5_000_000) ?? "no response"
        let secondAnswer = second.receive(turns: 5_000_000) ?? "no response"
        #expect(firstAnswer.hasSuffix("committed"), "\(firstAnswer)")
        #expect(secondAnswer.hasSuffix("written"), "\(secondAnswer)")
        other.db.close()
    }

    @Test func workersOpeningANewFileTogetherAllStart() throws {
        // Every worker opens the database as it starts, at the same moment.
        // Switching a new file to WAL takes an exclusive lock SQLite does not
        // wait for through the busy timeout; without retrying, all but one of
        // the opens could fail with SQLITE_BUSY and their workers not start.
        let app = Application()
        app.get("/open/:name") { (name: Path<String>) async -> String in
            let file = TemporaryDatabase("together-\(name.value)")
            let configuration = SQLiteConfiguration(path: file.path)
            final class Box: @unchecked Sendable { let c: SQLiteConnection; init(_ c: SQLiteConnection) { self.c = c } }
            var opened = 0
            var failures: [String] = []
            await withTaskGroup(of: Result<Box, any Error>.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        do {
                            return .success(Box(try await blocking { try SQLiteConnection.open(configuration, readOnly: false) }))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                for await result in group {
                    switch result {
                    case .success(let box): opened += 1; box.c.close()
                    case .failure(let error): failures.append("\(error)")
                    }
                }
            }
            return failures.isEmpty ? "\(opened)" : failures.joined(separator: ",")
        }
        let client = app.test
        for round in 0..<10 {
            #expect(try client.get("/open/\(round)").text == "8")
        }
    }

    @Test func aReadOnlyDatabaseRefusesWrites() throws {
        let file = TemporaryDatabase("read-only")
        do {
            let writer = try SQLiteDatabase(SQLiteConfiguration(path: file.path))
            try writer.migrate(["create table t (n integer); insert into t values (7)"])
            writer.close()
        }
        let result = try run(file, configure: { $0.mode = .readOnly }) { db in
            var out: [String] = []
            out.append("\(try await db.first(Int.self, "select n from t") ?? -1)")
            do {
                try await db.execute("insert into t values (8)")
                out.append("written")
            } catch let error as SQLiteClientError {
                out.append("refused \((error.sqliteCode ?? 0) & 0xFF)")
            }
            return out.joined(separator: "|")
        }
        #expect(result == "7|refused 8")
    }

    @Test func aClosedDatabaseRefusesStatements() throws {
        let file = TemporaryDatabase("closed")
        let result = try run(file) { db in
            _ = try await db.first(Int.self, "select 1")
            _ = try await db.first(Int.self, "select 1")
            db.close()
            do {
                _ = try await db.first(Int.self, "select 1")
                return "ran"
            } catch {
                return "\(error) \(db.counts.openReaders)"
            }
        }
        #expect(result == "closed 0")
    }
}
