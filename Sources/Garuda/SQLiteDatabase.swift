//===----------------------------------------------------------------------===//
// A SQLite database for one worker: a writer and a few readers.
//
//     app.state { _ in
//         let db = try SQLiteDatabase(SQLiteConfiguration(path: "/var/lib/app/app.db"))
//         try db.migrate([
//             "create table users (id integer primary key, name text not null)",
//             "alter table users add column email text",
//         ])
//         return db
//     }
//
//     app.get("/user/:id") { (id: Path<Int>, db: State<SQLiteDatabase>) async throws in
//         try await db.value.first(User.self, "select id, name, email from users where id = ?", id.value)
//             .map { JSON($0) }
//     }
//
// SQLite lets one connection write at a time, across every process that has
// the file open, and with write-ahead logging lets any number read while it
// does. So each worker keeps one connection that writes and up to `maxReaders`
// that only read. A statement goes to a reader once SQLite has said, on the
// writer, that it cannot write; until then, and for anything that can, it goes
// to the writer. A transaction holds the writer from BEGIN IMMEDIATE to COMMIT,
// so it never has to upgrade a read lock into a write lock halfway through --
// the upgrade SQLite answers with SQLITE_BUSY at once rather than waiting.
//
// Workers are processes, each with its own writer, so writes from different
// workers wait on each other through SQLite's file locks, for up to
// `busyTimeoutMilliseconds`, on blocking threads rather than on workers.
//===----------------------------------------------------------------------===//

import AvianCore

public final class SQLiteDatabase: @unchecked Sendable {
    public let configuration: SQLiteConfiguration
    /// Connections that only read, opened as they are needed. 0 in memory,
    /// where another connection would be another database.
    public let maxReaders: Int

    private var writer: SQLiteConnection?
    private var writerBusy = false
    private var writerWaiting: [Int32] = []

    private var idleReaders: [SQLiteConnection] = []
    /// Readers that exist, idle or in use, including one being opened.
    private var openReaders = 0
    private var readerWaiting: [Int32] = []

    /// SQL SQLite has said cannot write, learned on the writer.
    private var readOnlySQL: Set<String> = []
    private var closed = false

    private var limits: SQLiteLimits {
        SQLiteLimits(maxRows: configuration.maxRows, maxResultBytes: configuration.maxResultBytes)
    }

    /// Opens the database and its writer now, so a file that cannot be opened
    /// stops the worker starting rather than failing its first request. Blocks
    /// while it opens: build it in `app.state`, not in a handler.
    public init(_ configuration: SQLiteConfiguration, maxReaders: Int = 4) throws(SQLiteClientError) {
        self.configuration = configuration
        let readOnly = configuration.mode == .readOnly
        self.maxReaders = configuration.isMemory ? 0 : max(0, maxReaders)
        writer = try SQLiteConnection.open(configuration, readOnly: readOnly)
    }

    deinit { close() }

    // MARK: Statements

    /// Every row, decoded.
    public func query<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any SQLiteBindable...) async throws -> [Row] {
        try decodeAllSQLite(type, try await run(sql, values.map(\.sqliteValue)))
    }

    /// The first row decoded, or nil if there were none.
    public func first<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any SQLiteBindable...) async throws -> Row? {
        let rows = try await run(sql, values.map(\.sqliteValue))
        guard rows.count > 0 else { return nil }
        return try decodeSQLiteRow(type, rows, 0, sqliteColumnIndex(rows))
    }

    /// Runs a statement and returns how many rows it changed.
    @discardableResult
    public func execute(_ sql: String, _ values: any SQLiteBindable...) async throws -> Int {
        try await run(sql, values.map(\.sqliteValue)).affected
    }

    /// Runs a statement and returns its whole result: the rows as SQLite
    /// values, the rows changed and the last rowid inserted.
    public func rows(_ sql: String, _ values: any SQLiteBindable...) async throws -> SQLiteRows {
        try await run(sql, values.map(\.sqliteValue))
    }

    /// Runs `body` in a transaction on the writer: committed if `body` returns,
    /// rolled back if it throws.
    ///
    /// ```
    /// try await db.value.transaction { tx in
    ///     try await tx.execute("update accounts set balance = balance - ? where id = ?", amount, from)
    ///     try await tx.execute("update accounts set balance = balance + ? where id = ?", amount, to)
    /// }
    /// ```
    ///
    /// A statement that fails inside it undoes only itself, as SQLite does: a
    /// `body` that catches the error and returns commits the rest. When SQLite
    /// rolls the whole transaction back itself -- on a full disk, say -- the
    /// commit fails and says so.
    ///
    /// The writer is held until the transaction ends, so a transaction started
    /// inside `body` waits for it, and fails with `poolTimedOut`.
    public func transaction<Result>(_ body: (SQLiteTransaction) async throws -> Result) async throws -> Result {
        let connection = try await acquireWriter()
        do {
            _ = try await perform(connection, "BEGIN IMMEDIATE", [], allowTransaction: true)
            let result = try await body(SQLiteTransaction(database: self, connection: connection))
            _ = try await perform(connection, "COMMIT", [], allowTransaction: true)
            releaseWriter(connection)
            return result
        } catch {
            if connection.inTransaction {
                let rollback = limits
                _ = try? await blocking { try connection.run("ROLLBACK", [], limits: rollback) }
                // The blocking pool may have refused it. Rolled back here
                // instead, on the worker, rather than handing the next
                // statement a transaction it never began.
                if connection.inTransaction { try? connection.runScript("ROLLBACK") }
            }
            releaseWriter(connection)
            throw error
        }
    }

    /// Brings the schema up to date: runs each script in `migrations` past the
    /// database's `user_version`, then sets it to their count, all in one
    /// transaction. A script may hold several statements.
    ///
    /// Append to the list; never change or remove a script that has run. Every
    /// worker calls this as it starts, and the first to take the write lock
    /// migrates while the others wait for it and find nothing left to do.
    ///
    /// Blocks: call it in `app.state`, where the database is built.
    public func migrate(_ migrations: [String]) throws(SQLiteClientError) {
        guard let writer, !closed else { throw .closed }
        precondition(!writerBusy, "migrate called while the writer is in use; call it in app.state")
        try writer.runScript("BEGIN IMMEDIATE")
        do throws(SQLiteClientError) {
            let version = try writer.run("PRAGMA user_version", [], cached: false)
            guard version.count == 1, case .integer(let found) = version.value(row: 0, column: 0) else {
                throw .sqlite(SQLiteFailure(extendedCode: 1, message: "PRAGMA user_version returned no version"))
            }
            guard found <= migrations.count else {
                throw .unknownSchemaVersion(found: Int(found), known: migrations.count)
            }
            for script in migrations[Int(found)...] {
                try writer.runScript(script)
            }
            if Int(found) < migrations.count {
                try writer.runScript("PRAGMA user_version = \(migrations.count)")
            }
            try writer.runScript("COMMIT")
        } catch {
            if writer.inTransaction { try? writer.runScript("ROLLBACK") }
            throw error
        }
    }

    /// Closes every connection not in use now, and each one in use when its
    /// statement returns. For `app.state`'s shutdown.
    public func close() {
        closed = true
        if !writerBusy {
            writer?.close()
            writer = nil
        }
        for connection in idleReaders { connection.close() }
        openReaders -= idleReaders.count
        idleReaders.removeAll()
        let worker = currentWorker
        for id in writerWaiting + readerWaiting { _ = worker?.pointee.wakeTimed(id) }
        writerWaiting.removeAll()
        readerWaiting.removeAll()
    }

    // MARK: Routing

    fileprivate func run(_ sql: String, _ values: [SQLiteValue]) async throws -> SQLiteRows {
        if maxReaders > 0 && readOnlySQL.contains(sql) {
            let connection = try await acquireReader()
            do {
                let rows = try await perform(connection, sql, values, allowTransaction: false)
                releaseReader(connection)
                return rows
            } catch {
                releaseReader(connection)
                throw error
            }
        }
        let connection = try await acquireWriter()
        do {
            let rows = try await perform(connection, sql, values, allowTransaction: false)
            releaseWriter(connection)
            if rows.readOnly && maxReaders > 0 {
                // Bounded, because SQL built by concatenation would otherwise
                // grow this without end. Forgetting only costs one more trip
                // through the writer each.
                if readOnlySQL.count >= 4096 { readOnlySQL.removeAll(keepingCapacity: true) }
                readOnlySQL.insert(sql)
            }
            return rows
        } catch {
            releaseWriter(connection)
            throw error
        }
    }

    /// Runs one statement on a blocking thread. Outside a transaction, a
    /// statement that leaves one open has it rolled back and is refused.
    fileprivate func perform(_ connection: SQLiteConnection, _ sql: String, _ values: [SQLiteValue],
                             allowTransaction: Bool) async throws -> SQLiteRows {
        let limits = self.limits
        return try await blocking { () throws -> SQLiteRows in
            do {
                let rows = try connection.run(sql, values, limits: limits)
                if !allowTransaction && connection.inTransaction {
                    try? connection.runScript("ROLLBACK")
                    throw SQLiteClientError.transactionLeftOpen
                }
                return rows
            } catch {
                // A statement that failed inside a BEGIN it ran itself leaves
                // the transaction open just the same.
                if !allowTransaction && connection.inTransaction { try? connection.runScript("ROLLBACK") }
                throw error
            }
        }
    }

    // MARK: Connections

    private func acquireWriter() async throws -> SQLiteConnection {
        while true {
            guard !closed, let writer else { throw SQLiteClientError.closed }
            if !writerBusy {
                writerBusy = true
                return writer
            }
            try await wait(in: \.writerWaiting)
        }
    }

    private func releaseWriter(_ connection: SQLiteConnection) {
        writerBusy = false
        if closed {
            connection.close()
            writer = nil
        }
        wakeOne(\.writerWaiting)
    }

    private func acquireReader() async throws -> SQLiteConnection {
        while true {
            guard !closed else { throw SQLiteClientError.closed }
            if let connection = idleReaders.popLast() { return connection }
            if openReaders < maxReaders {
                openReaders += 1
                let configuration = self.configuration
                do {
                    return try await blocking { () throws -> SQLiteConnection in
                        try SQLiteConnection.open(configuration, readOnly: true)
                    }
                } catch {
                    openReaders -= 1
                    wakeOne(\.readerWaiting)
                    throw error
                }
            }
            try await wait(in: \.readerWaiting)
        }
    }

    private func releaseReader(_ connection: SQLiteConnection) {
        if closed {
            connection.close()
            openReaders -= 1
        } else {
            idleReaders.append(connection)
        }
        wakeOne(\.readerWaiting)
    }

    private func wait(in queue: ReferenceWritableKeyPath<SQLiteDatabase, [Int32]>) async throws {
        guard let worker = currentWorker else {
            // Nothing to wait on off a worker, and nothing else there could
            // be holding the connection for long.
            throw SQLiteClientError.cancelled
        }
        var id: Int32 = -1
        let outcome = await Worker.waitTimed(worker, milliseconds: configuration.acquireTimeoutMilliseconds) {
            id = $0
            self[keyPath: queue].append($0)
        }
        switch outcome {
        case .woken:
            return
        case .timedOut:
            self[keyPath: queue].removeAll { $0 == id }
            throw SQLiteClientError.poolTimedOut
        case .cancelled:
            self[keyPath: queue].removeAll { $0 == id }
            throw SQLiteClientError.cancelled
        }
    }

    /// Wakes the oldest wait still waiting; see PostgresPool.wakeOne.
    private func wakeOne(_ queue: ReferenceWritableKeyPath<SQLiteDatabase, [Int32]>) {
        guard let worker = currentWorker else { return }
        while !self[keyPath: queue].isEmpty {
            if worker.pointee.wakeTimed(self[keyPath: queue].removeFirst()) { return }
        }
    }

    /// For tests.
    var counts: (openReaders: Int, idleReaders: Int, writerBusy: Bool) {
        (openReaders, idleReaders.count, writerBusy)
    }
    var knownReadOnly: Int { readOnlySQL.count }
}

/// Statements inside one transaction, all on the writer.
public struct SQLiteTransaction {
    let database: SQLiteDatabase
    let connection: SQLiteConnection

    public func query<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any SQLiteBindable...) async throws -> [Row] {
        try decodeAllSQLite(type, try await run(sql, values.map(\.sqliteValue)))
    }

    public func first<Row: Decodable>(_ type: Row.Type, _ sql: String,
                                      _ values: any SQLiteBindable...) async throws -> Row? {
        let rows = try await run(sql, values.map(\.sqliteValue))
        guard rows.count > 0 else { return nil }
        return try decodeSQLiteRow(type, rows, 0, sqliteColumnIndex(rows))
    }

    @discardableResult
    public func execute(_ sql: String, _ values: any SQLiteBindable...) async throws -> Int {
        try await run(sql, values.map(\.sqliteValue)).affected
    }

    public func rows(_ sql: String, _ values: any SQLiteBindable...) async throws -> SQLiteRows {
        try await run(sql, values.map(\.sqliteValue))
    }

    private func run(_ sql: String, _ values: [SQLiteValue]) async throws -> SQLiteRows {
        try await database.perform(connection, sql, values, allowTransaction: true)
    }
}
