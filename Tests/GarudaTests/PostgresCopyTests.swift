import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// COPY: the text format both ways, and bulk in and out of a real server --
// including what an awkward value does to a tab-separated format, a load the
// server refuses, and a load the caller abandons halfway.

@Suite("PostgreSQL COPY")
struct PostgresCopyTextTests {
    @Test func rowsAreWrittenInTheTextFormat() throws {
        func text(_ fields: [String?]) -> String {
            String(decoding: PostgresCopyText.encode(fields), as: UTF8.self)
        }
        #expect(text(["ada", "42"]) == "ada\t42\n")
        #expect(text([nil]) == "\\N\n", "a null is the two characters, unquoted")
        #expect(text(["\\N"]) == "\\\\N\n", "a field of those characters is not a null")
        #expect(text([""]) == "\n", "an empty field is empty, which is not a null")
        // The characters that would otherwise be punctuation.
        #expect(text(["a\tb"]) == "a\\tb\n")
        #expect(text(["a\nb"]) == "a\\nb\n")
        #expect(text(["a\r\nb"]) == "a\\r\\nb\n")
        #expect(text(["a\\b"]) == "a\\\\b\n")
        #expect(text(["a", nil, "b"]) == "a\t\\N\tb\n")
        #expect(String(decoding: PostgresCopyText.encode(rows: [["1"], ["2"]]), as: UTF8.self) == "1\n2\n")
    }

    @Test func rowsAreReadBackFromIt() throws {
        func fields(_ line: String) -> [String?] {
            PostgresCopyText.decode(Array(line.utf8)[...])
        }
        #expect(fields("ada\t42") == ["ada", "42"])
        #expect(fields("\\N") == [nil])
        #expect(fields("a\t\\N\tb") == ["a", nil, "b"])
        #expect(fields("\\\\N") == ["\\N"], "escaped, so the characters and not a null")
        #expect(fields("") == [""])
        #expect(fields("\t") == ["", ""])
        #expect(fields("a\\tb") == ["a\tb"])
        #expect(fields("a\\nb\\r") == ["a\nb\r"])
        #expect(fields("a\\qb") == ["aqb"], "an escape that means nothing is the character itself")
        // A null is a whole field, never part of one.
        #expect(fields("x\\N") == ["xN"])
        #expect(fields("\\Nx") == ["Nx"])

        // Whatever is written comes back.
        for row in [["ada", "42"], [nil], ["\\N"], [""], ["a\tb\nc\\d\re"], ["", nil, "x"]] as [[String?]] {
            let written = PostgresCopyText.encode(row)
            #expect(PostgresCopyText.decode(written.dropLast()[...]) == row, "\(row)")
        }
    }

    @Test func aStreamIsSplitIntoRowsOnItsOwnNewlines() throws {
        let stream = PostgresCopyText.encode(rows: [["a\nb"], ["c"], [nil]])
        let rows = PostgresCopyText.rows(stream[...])
        #expect(rows == [["a\nb"], ["c"], [nil]], "a newline inside a field ends nothing")
        // What the text format ends a file with is not a row.
        let terminated = Array("1\n\\.\n".utf8)
        #expect(PostgresCopyText.rows(terminated[...]) == [["1"]])
        #expect(PostgresCopyText.rows(Array("".utf8)[...]).isEmpty)
        // A row whose newline has not arrived yet is not yet a row.
        #expect(PostgresPool.unescapedNewline(Array("a\\nb".utf8)) == nil)
        #expect(PostgresPool.unescapedNewline(Array("a\\nb\nc".utf8)) == 4)
    }
}

// MARK: - Against a real server

private let copyTarget: PostgresConfiguration? = {
    guard let raw = av_getenv("GARUDA_POSTGRES") else { return nil }
    let parts = String(cString: raw).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, let port = UInt16(parts[1]) else { return nil }
    var configuration = PostgresConfiguration(host: String(parts[0]), port: port,
                                              user: String(parts[2]), password: String(parts[3]),
                                              database: String(parts[4]))
    configuration.tls = .disable
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

private struct Refuse: Error {}

@Suite("PostgreSQL COPY round trip", .serialized)
struct PostgresCopyRoundTripTests {
    private func onPool(_ body: @escaping @Sendable (PostgresPool) async throws -> String) throws -> String {
        let configuration = copyTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            do {
                return try await body(db.value)
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 30_000
        return try client.get("/run").text
    }

    /// In and out again, with the values that make a tab-separated format
    /// interesting, all inside one transaction so a temp table is visible to
    /// both halves.
    @Test(.enabled(if: copyTarget != nil, "set GARUDA_POSTGRES to run"))
    func rowsGoInAndComeBackOut() throws {
        let text = try onPool { pool in
            try await pool.transaction { tx -> String in
                try await tx.execute("create temp table copy_test (id int, name text, note text)")
                let rows: [[String?]] = [
                    ["1", "ada", "plain"],
                    ["2", nil, "a\tb"],
                    ["3", "", "line\nbreak"],
                    ["4", "back\\slash", "\\N"],
                    ["5", "carriage\rreturn", "done"],
                ]
                var out: [String] = []
                out.append("\(try await tx.copyIn("copy copy_test from stdin", rows: rows))")

                // What the server has, read the ordinary way.
                struct Row: Decodable { let id: Int; let name: String?; let note: String }
                let read = try await tx.query(Row.self, "select id, name, note from copy_test order by id")
                out.append("\(read.count)")
                out.append(read[1].name == nil ? "null" : "not null")
                out.append(read[1].note == "a\tb" ? "tab" : read[1].note)
                out.append(read[2].name == "" ? "empty" : "?")
                out.append(read[2].note == "line\nbreak" ? "newline" : "?")
                out.append(read[3].name == "back\\slash" ? "backslash" : "?")
                out.append(read[3].note == "\\N" ? "literal null" : read[3].note)
                out.append(read[4].note == "done" ? "return" : "?")

                // And out again, as rows.
                var back: [[String?]] = []
                let copied = try await tx.copyOutRows("copy copy_test to stdout") { back.append($0) }
                out.append("\(copied)")
                out.append("\(back == rows)")
                return out.joined(separator: "|")
            }
        }
        #expect(text == "5|5|null|tab|empty|newline|backslash|literal null|return|5|true", "\(text)")
    }

    /// A big load, in chunks the caller decides, and out as raw bytes: no row
    /// of it is ever held in one piece.
    @Test(.enabled(if: copyTarget != nil, "set GARUDA_POSTGRES to run"))
    func aBigLoadGoesInAndOutInPieces() throws {
        let text = try onPool { pool in
            try await pool.transaction { tx -> String in
                try await tx.execute("create temp table copy_big (n int, v text)")
                var next = 1
                let batch = 1_000
                let total = 20_000
                // A chunk per batch, which is what keeps memory flat.
                let sent = try await tx.copyIn("copy copy_big from stdin") { () -> [UInt8]? in
                    guard next <= total else { return nil }
                    var rows: [[String?]] = []
                    rows.reserveCapacity(batch)
                    for n in next..<min(next + batch, total + 1) { rows.append(["\(n)", "v\(n)"]) }
                    next += batch
                    return PostgresCopyText.encode(rows: rows)
                }
                var bytes = 0
                var chunks = 0
                let read = try await tx.copyOut("copy copy_big to stdout") { chunk in
                    bytes += chunk.count
                    chunks += 1
                }
                struct Count: Decodable { let n: Int }
                let counted = try await tx.first(Count.self, "select count(*)::int as n from copy_big")
                // CSV as well, since the bytes are whatever the statement said.
                var csv: [UInt8] = []
                _ = try await tx.copyOut("copy (select n, v from copy_big order by n limit 2) to stdout with (format csv)") {
                    csv.append(contentsOf: $0)
                }
                return "\(sent)|\(read)|\(counted?.n ?? -1)|\(bytes > 100_000)|\(chunks > 1)"
                    + "|" + String(decoding: csv, as: UTF8.self).trimmingWhitespace()
            }
        }
        #expect(text == "20000|20000|20000|true|true|1,v1\n2,v2", "\(text)")
    }

    /// A load the server refuses, and a load the caller abandons. Either way
    /// the transaction it was in is rolled back whole, and the connection is
    /// fit for the next statement -- which for the abandoned one is the point
    /// of telling the server with CopyFail rather than simply hanging up.
    @Test(.enabled(if: copyTarget != nil, "set GARUDA_POSTGRES to run"))
    func aRefusedOrAbandonedLoadLeavesNothingBehind() throws {
        let text = try onPool { pool in
            var out: [String] = []
            struct One: Decodable { let one: Int }

            // The server refusing: a row with a column too many. That fails
            // the statement, and with it the transaction, so the error comes
            // out rather than being swallowed inside.
            do {
                try await pool.transaction { tx in
                    try await tx.execute("create temp table copy_bad (id int)")
                    _ = try await tx.copyIn("copy copy_bad from stdin", rows: [["1", "extra"]])
                }
                out.append("accepted")
            } catch let error as PostgresClientError {
                out.append(error.sqlState ?? "\(error)")
            }
            out.append("\(try await pool.first(One.self, "select 1 as one")?.one ?? -1)")

            // The caller giving up halfway.
            var sent = 0
            do {
                try await pool.transaction { tx in
                    try await tx.execute("create temp table copy_half (id int)")
                    _ = try await tx.copyIn("copy copy_half from stdin") { () -> [UInt8]? in
                        sent += 1
                        if sent > 2 { throw Refuse() }
                        return PostgresCopyText.encode(["\(sent)"])
                    }
                }
                out.append("finished")
            } catch is Refuse {
                out.append("stopped after \(sent)")
            }
            // The connection was kept, not closed: the same one answers next.
            out.append("\(try await pool.first(One.self, "select 1 as one")?.one ?? -1)")
            out.append("\(pool.counts.open)")
            return out.joined(separator: "|")
        }
        #expect(text == "22P04|1|stopped after 3|1|1", "\(text)")
    }
}
