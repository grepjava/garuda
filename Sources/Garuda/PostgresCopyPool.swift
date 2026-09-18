//===----------------------------------------------------------------------===//
// COPY on a pool and inside a transaction: bulk in and bulk out.
//
//     // In: a million rows without a million round trips.
//     try await pool.copyIn("copy users (name, email) from stdin",
//                           rows: people.map { [$0.name, $0.email] })
//
//     // Out: a chunk at a time, so a big table is not a big allocation.
//     try await pool.copyOut("copy users to stdout") { chunk in
//         try file.write(chunk)
//     }
//
// The bytes are whatever the statement asked for. `rows:` and `rows(of:)`
// speak the default text format; `csv` or `binary` in the statement means the
// bytes are yours to write and read.
//
// COPY takes no parameters -- there is no `$1` in it -- so the statement is
// the caller's to compose, and an identifier in it has to be quoted by
// whoever composes it. Values never go in the statement: they go in the data.
//===----------------------------------------------------------------------===//

import CAvian
import AvianCore
import GarudaPostgres

// MARK: - The pool and a transaction

extension PostgresPool {
    /// Runs a `COPY ... TO STDOUT`, handing each chunk to `chunk` as it
    /// arrives, and returns how many rows the server sent.
    @discardableResult
    public func copyOut(_ sql: String,
                        _ chunk: (ArraySlice<UInt8>) throws -> Void) async throws -> Int {
        try await withConnectionForCopy { connection in
            try await connection.copyOut(sql, chunk)
        }
    }

    /// Runs a `COPY ... TO STDOUT` in the text format and hands over each row.
    @discardableResult
    public func copyOutRows(_ sql: String, _ row: ([String?]) throws -> Void) async throws -> Int {
        var pending: [UInt8] = []
        let copied = try await copyOut(sql) { chunk in
            pending.append(contentsOf: chunk)
            // Whole rows only: a chunk can end in the middle of one.
            while let newline = PostgresPool.unescapedNewline(pending) {
                let line = pending[pending.startIndex..<newline]
                pending.removeFirst(newline + 1)
                for line in PostgresCopyText.rows(line) { try row(line) }
            }
        }
        if !pending.isEmpty {
            for line in PostgresCopyText.rows(pending[...]) { try row(line) }
        }
        return copied
    }

    /// Runs a `COPY ... FROM STDIN`, asking `next` for data until it returns
    /// nil, and returns how many rows the server took.
    @discardableResult
    public func copyIn(_ sql: String, _ next: () throws -> [UInt8]?) async throws -> Int {
        try await withConnectionForCopy { connection in
            try await connection.copyIn(sql, next)
        }
    }

    /// Runs a `COPY ... FROM STDIN` in the text format, sending `rows`.
    @discardableResult
    public func copyIn(_ sql: String, rows: [[String?]]) async throws -> Int {
        var sent = false
        return try await copyIn(sql) {
            guard !sent else { return nil }
            sent = true
            return PostgresCopyText.encode(rows: rows)
        }
    }

    /// The index of a newline that ends a row, rather than one inside a field.
    static func unescapedNewline(_ bytes: [UInt8]) -> Int? {
        var escaped = false
        for (i, byte) in bytes.enumerated() {
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\n") {
                return i
            }
        }
        return nil
    }

}

extension PostgresTransaction {
    /// Runs a `COPY ... TO STDOUT` on this transaction's connection.
    @discardableResult
    public func copyOut(_ sql: String,
                        _ chunk: (ArraySlice<UInt8>) throws -> Void) async throws -> Int {
        try await connection.copyOut(sql, chunk)
    }

    /// Runs a `COPY ... FROM STDIN` on this transaction's connection, asking
    /// `next` for data until it returns nil.
    @discardableResult
    public func copyIn(_ sql: String, _ next: () throws -> [UInt8]?) async throws -> Int {
        try await connection.copyIn(sql, next)
    }

    /// Runs a `COPY ... FROM STDIN` in the text format, sending `rows`. The
    /// load is part of the transaction: it is there if it commits and gone if
    /// it does not.
    @discardableResult
    public func copyIn(_ sql: String, rows: [[String?]]) async throws -> Int {
        var sent = false
        return try await copyIn(sql) {
            guard !sent else { return nil }
            sent = true
            return PostgresCopyText.encode(rows: rows)
        }
    }

    /// Runs a `COPY ... TO STDOUT` in the text format and hands over each row.
    @discardableResult
    public func copyOutRows(_ sql: String, _ row: ([String?]) throws -> Void) async throws -> Int {
        var pending: [UInt8] = []
        let copied = try await copyOut(sql) { chunk in
            pending.append(contentsOf: chunk)
            while let newline = PostgresPool.unescapedNewline(pending) {
                let line = pending[pending.startIndex..<newline]
                pending.removeFirst(newline + 1)
                for line in PostgresCopyText.rows(line) { try row(line) }
            }
        }
        if !pending.isEmpty {
            for line in PostgresCopyText.rows(pending[...]) { try row(line) }
        }
        return copied
    }
}
