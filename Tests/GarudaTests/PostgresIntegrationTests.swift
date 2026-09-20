import Testing
import CAvian
import AvianCore
import GarudaPostgres
@testable import Garuda
import GarudaSQL

// The PostgreSQL driver against a real server.
//
// Opt-in: set GARUDA_POSTGRES to host:port:user:password:database, for example
//
//     GARUDA_POSTGRES=127.0.0.1:55432:garuda:garuda-secret:postgres swift test
//
// and these run; without it they are skipped, so the unit suite never depends
// on a database being up. The scripted-server tests cover what an honest
// server never does; these cover what it does, which a script can only agree
// with.

nonisolated(unsafe) private var outcome = ""
nonisolated(unsafe) private var run: (@Sendable (UnsafeMutablePointer<Worker>) async -> String)? = nil

private let target: PostgresConfiguration? = {
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

/// The same server over a unix socket, when GARUDA_POSTGRES_SOCKET names the
/// directory it keeps one in.
private let socketTarget: PostgresConfiguration? = {
    guard let raw = av_getenv("GARUDA_POSTGRES_SOCKET"), let over = target else { return nil }
    var configuration = PostgresConfiguration(unixSocketPath: String(cString: raw),
                                              user: over.user, password: over.password,
                                              database: over.database, port: over.port)
    configuration.timeoutMilliseconds = 5_000
    return configuration
}()

private func app() -> Application {
    let app = Application()
    app.onAsync(.get, "/run") { request, response in
        let worker = request.worker
        outcome = await run?(worker) ?? "no body"
        response.send(outcome)
    }
    return app
}

/// Runs `body` inside a handler on a worker, and returns what it reported.
private func onWorker(_ body: @escaping @Sendable (UnsafeMutablePointer<Worker>) async -> String) throws -> String {
    outcome = ""
    run = body
    let client = app().test
    let wire = try TestWire(client)
    wire.send("GET /run HTTP/1.1\r\nHost: test\r\n\r\n")
    _ = wire.turn(until: { !outcome.isEmpty }, turns: 2_000_000)
    return outcome
}

private func describe(_ error: Error) -> String {
    if let error = error as? PostgresClientError,
       case .postgres(.server(let fields)) = error {
        return "server:\(fields.code)"
    }
    return "\(error)"
}

@Suite("PostgreSQL against a real server", .serialized,
       .enabled(if: target != nil, "set GARUDA_POSTGRES to run"))
struct PostgresIntegrationTests {

    @Test func connectsWithSCRAMAndRunsAQuery() throws {
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query("select $1::int + 1 as answer", ["41"])
                return rows.text(row: 0, column: 0) ?? "null"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "42")
    }

    @Test func aWrongPasswordIsRefusedByTheServer() throws {
        var wrong = try #require(target)
        wrong.password = "not-the-password"
        let configuration = wrong
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                connection.close()
                return "connected"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "server:28P01")
    }

    @Test func aFailedStatementLeavesTheConnectionUsable() throws {
        // The server refuses the statement and then says it is ready. That is
        // a statement failing, not a connection failing, and the next query
        // on the same connection has to work.
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                var first = ""
                do {
                    _ = try await connection.query("select * from no_such_table")
                    first = "unexpectedly ran"
                } catch {
                    first = describe(error)
                }
                let rows = try await connection.query("select 'still here'")
                return first + "|" + (rows.text(row: 0, column: 0) ?? "null")
            } catch {
                return describe(error)
            }
        }
        #expect(text == "server:42P01|still here")
    }

    @Test func manyRowsAndNullsComeBack() throws {
        let configuration = try #require(target)
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query(
                    "select n, case when n % 10 = 0 then null else 'v' || n end from generate_series(1, 5000) n")
                let nulls = (0..<rows.count).filter { rows.text(row: $0, column: 1) == nil }.count
                return "\(rows.count)|\(nulls)|\(rows.text(row: 4999, column: 0) ?? "")|\(rows.affected)"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "5000|500|5000|5000")
    }

    @Test func anInjectionStringIsOnlyEverAValue() throws {
        let configuration = try #require(target)
        let hostile = "x'); drop table pg_class; --"
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query("select $1::text, length($1::text)", [hostile])
                return (rows.text(row: 0, column: 0) ?? "") + "|" + (rows.text(row: 0, column: 1) ?? "")
            } catch {
                return describe(error)
            }
        }
        #expect(text == "\(hostile)|\(hostile.count)")
    }

    @Test func requiringTLSNeverSettlesForLess() throws {
        // Required means required, and there are two ways a test server falls
        // short of it. One with no TLS answers the request with N, and the
        // connection fails rather than carrying on in the clear. One with TLS
        // on a certificate nobody vouches for -- Ubuntu's packages ship with
        // a self-signed "snakeoil" one -- answers S and then fails
        // verification. Both are refusals; what must never happen is
        // connecting. Which one a given server produces is its configuration,
        // not this client's choice, so both are accepted.
        var required = try #require(target)
        required.tls = .require
        let configuration = required
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                connection.close()
                return "connected"
            } catch {
                return "\(error)"
            }
        }
        #expect(text == "tlsUnavailable" || text.hasPrefix("connect("), "got \(text)")
    }

    // MARK: Prepared statements

    /// Runs `body` on one connection with a statement cache of `capacity`.
    private func onConnection(capacity: Int = 256,
                              _ body: @escaping @Sendable (PostgresConnection) async throws -> String) throws -> String {
        var configuration = try #require(target)
        configuration.statementCacheCapacity = capacity
        let settings = configuration
        return try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, settings)
                defer { connection.close() }
                return try await body(connection)
            } catch {
                return describe(error)
            }
        }
    }

    /// What the server says this session has prepared, counting the statement
    /// asking, which is prepared too.
    private static func preparedOnServer(_ connection: PostgresConnection) async throws -> String {
        try await connection.query("select count(*) from pg_prepared_statements").text(row: 0, column: 0) ?? "null"
    }

    /// The name the cache prepared `sql` under.
    private static func nameOf(_ sql: String, _ connection: PostgresConnection) -> String {
        connection.prepared.first { $0.key.sql == sql }?.value.name ?? "none"
    }

    @Test func aStatementRunAgainIsPreparedOnce() throws {
        let text = try onConnection { connection in
            var answers: [String] = []
            for n in 1...3 {
                let rows = try await connection.query("select $1::int + 1", [String(n)])
                answers.append(rows.text(row: 0, column: 0) ?? "null")
            }
            return answers.joined(separator: ",") + "|" + (try await Self.preparedOnServer(connection))
                + "|" + String(connection.prepared.count)
        }
        #expect(text == "2,3,4|2|2")
    }

    @Test func aFullCacheClosesTheLeastRecentlyUsed() throws {
        let text = try onConnection(capacity: 3) { connection in
            _ = try await connection.query("select 1")
            _ = try await connection.query("select 2")
            _ = try await connection.query("select 1")   // 2 is now the least recent
            _ = try await connection.query("select 3")
            let server = try await Self.preparedOnServer(connection)
            let kept = connection.prepared.keys.map(\.sql).sorted().joined(separator: ",")
            return server + "|" + kept
        }
        #expect(text == "3|select 1,select 3,select count(*) from pg_prepared_statements")
    }

    @Test func aCacheOfNothingPreparesNothing() throws {
        let text = try onConnection(capacity: 0) { connection in
            _ = try await connection.query("select 1")
            return try await Self.preparedOnServer(connection) + "|" + String(connection.prepared.count)
        }
        #expect(text == "0|0")
    }

    @Test func discardAllEmptiesTheCache() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("select 1")
            _ = try await connection.query("discard all")
            let after = connection.prepared.count
            let rows = try await connection.query("select 1")
            return "\(after)|" + (rows.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "0|1")
    }

    @Test func aStatementDeallocatedBehindTheCachesBackIsPreparedAgain() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("select 'first'")
            let name = Self.nameOf("select 'first'", connection)
            _ = try await connection.query("deallocate \(name)")
            let rows = try await connection.query("select 'first'")
            return rows.text(row: 0, column: 0) ?? "null"
        }
        #expect(text == "first")
    }

    @Test func aTableThatChangesShapeUnderAStatementIsPreparedAgain() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("create temporary table shapes (a int)")
            _ = try await connection.query("insert into shapes values (7)")
            let before = try await connection.query("select * from shapes")
            _ = try await connection.query("alter table shapes add column b text default 'new'")
            let after = try await connection.query("select * from shapes")
            return "\(before.columns.count)|\(after.columns.count)|" + (after.text(row: 0, column: 1) ?? "null")
        }
        #expect(text == "1|2|new")
    }

    /// The result is described on every run, and a description the same as
    /// the last one reuses the columns read from it then. A renamed column
    /// makes a different description, which must be read again: a server that
    /// no longer refuses the old plan over a new name leaves the description
    /// as all that stands between the rename and a row decoded by the old one.
    @Test func aColumnRenamedUnderAStatementIsReadByItsNewName() throws {
        let text = try onConnection { connection in
            _ = try await connection.query("create temporary table renames (a int)")
            _ = try await connection.query("insert into renames values (7)")
            for _ in 0..<3 { _ = try await connection.query("select * from renames") }
            _ = try await connection.query("alter table renames rename column a to b")
            let after = try await connection.query("select * from renames")
            let again = try await connection.query("select * from renames")
            return after.columns.map(\.name).joined() + again.columns.map(\.name).joined()
                + "|" + (again.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "bb|7")
    }

    @Test func aStaleStatementInsideATransactionIsReportedNotRetried() throws {
        // The refusal has already failed the transaction: running the
        // statement again inside it could only be refused again.
        let text = try onConnection { connection in
            _ = try await connection.query("select 'x'")
            let name = Self.nameOf("select 'x'", connection)
            _ = try await connection.query("begin")
            _ = try await connection.query("deallocate \(name)")
            var outcome = ""
            do {
                _ = try await connection.query("select 'x'")
                outcome = "ran"
            } catch {
                outcome = describe(error)
            }
            _ = try await connection.query("rollback")
            let rows = try await connection.query("select 'x'")
            return outcome + "|" + (rows.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "server:26000|x")
    }

    @Test func theSameSQLWithValuesOfAnotherTypeIsAnotherStatement() throws {
        // Bytes declare their type when the statement is parsed. Reusing that
        // statement for text would have the server read the text as bytea.
        let text = try onConnection { connection in
            let bytes = try await connection.query("select $1::text", values: [.binary(Array("hi".utf8), type: PostgresType.bytea)])
            let words = try await connection.query("select $1::text", values: [PostgresValue("hello")])
            return (bytes.text(row: 0, column: 0) ?? "null") + "|" + (words.text(row: 0, column: 0) ?? "null")
        }
        #expect(text == "\\x6869|hello")
    }

    @Test func aStatementThatFailsToParseIsNotKept() throws {
        let text = try onConnection { connection in
            var outcome = ""
            do {
                _ = try await connection.query("selec 1")
            } catch {
                outcome = describe(error)
            }
            return outcome + "|" + String(connection.prepared.count)
        }
        #expect(text == "server:42601|0")
    }

    @Test func onlyTheStatementThatFoundItsPreparationStaleIsRunAgain() throws {
        // A sequence is not rolled back with the statement that advanced it,
        // so it counts how many times a failing statement really ran.
        let text = try onConnection { connection in
            _ = try await connection.query("create temporary sequence attempts")
            _ = try await connection.query("select 'stale soon'")
            let name = Self.nameOf("select 'stale soon'", connection)
            _ = try await connection.query("deallocate \(name)")
            _ = try await connection.query("select 'stale soon'")        // refused once, run again
            do {
                _ = try await connection.query("select nextval('attempts') / 0")
            } catch {}
            return try await connection.query("select last_value from attempts").text(row: 0, column: 0) ?? "null"
        }
        #expect(text == "1")
    }

    // MARK: Binary results

    /// Every decodable type, at its edges.
    private static let typesSQL = """
        select b, i2, i4, i8, f4, f8, bytes, label from (values
          (true, '32767'::int2, '2147483647'::int4, '9223372036854775807'::int8, '0.1'::float4, '0.1'::float8, '\\x00ff'::bytea, 'a'),
          (false, '-32768'::int2, '-2147483648'::int4, '-9223372036854775808'::int8, '1e6'::float4, '1e15'::float8, ''::bytea, 'b'),
          (null, '0'::int2, '0'::int4, '0'::int8, '3.4e38'::float4, '123456789012345'::float8, null, null),
          (true, '1'::int2, '1'::int4, '1'::int8, 'NaN'::float4, 'Infinity'::float8, '\\x01'::bytea, 'c'),
          (true, '1'::int2, '1'::int4, '1'::int8, '-Infinity'::float4, '1e-5'::float8, '\\x01'::bytea, 'd'),
          (true, '1'::int2, '1'::int4, '1'::int8, '1.5e-7'::float4, '5e-324'::float8, '\\x01'::bytea, 'e'),
          (true, '1'::int2, '1'::int4, '1'::int8, '123456'::float4, '-0'::float8, '\\x01'::bytea, 'f'),
          (true, '1'::int2, '1'::int4, '1'::int8, '12.25'::float4, '1.7976931348623157e308'::float8, '\\x01'::bytea, 'g'),
          (true, '1'::int2, '1'::int4, '1'::int8, '100'::float4, '0.000123'::float8, '\\x01'::bytea, 'h')
        ) as t(b, i2, i4, i8, f4, f8, bytes, label)
        """

    struct TypeRow: Decodable, Equatable {
        let b: Bool?
        let i2: Int16
        let i4: Int32
        let i8: Int64
        let f4: Float
        let f8: Double
        let bytes: [UInt8]?
        let label: String?

        static func == (a: TypeRow, b: TypeRow) -> Bool {
            a.b == b.b && a.i2 == b.i2 && a.i4 == b.i4 && a.i8 == b.i8
                && (a.f4 == b.f4 || (a.f4.isNaN && b.f4.isNaN))
                && a.f8.bitPattern == b.f8.bitPattern && a.bytes == b.bytes && a.label == b.label
        }
    }

    @Test func aRepeatedStatementComesBackInBinaryAndReadsTheSame() throws {
        let text = try onConnection { connection in
            let first = try await connection.query(Self.typesSQL)
            let second = try await connection.query(Self.typesSQL)
            let formats = second.columns.map { $0.binary ? "b" : "t" }.joined()
            guard !first.columns.contains(where: \.binary) else { return "first run was binary" }
            var mismatches: [String] = []
            for row in 0..<first.count {
                for column in 0..<first.columns.count {
                    let a = first.text(row: row, column: column)
                    let b = second.text(row: row, column: column)
                    if a != b { mismatches.append("\(first.columns[column].name)[\(row)]: \(a ?? "null") vs \(b ?? "null")") }
                }
            }
            let same = try decodeAll(TypeRow.self, first) == decodeAll(TypeRow.self, second)
            return formats + "|" + mismatches.joined(separator: "; ") + "|" + String(same)
        }
        #expect(text == "bbbbbbbt||true")
    }

    @Test func aBinaryIntegerOutOfRangeForItsPropertyIsRefused() throws {
        struct Small: Decodable { let n: Int8 }
        let text = try onConnection { connection in
            var outcomes: [String] = []
            for _ in 0..<2 {
                let rows = try await connection.query("select 300 as n")
                do {
                    _ = try decodeAll(Small.self, rows)
                    outcomes.append("decoded")
                } catch let error as PostgresDecodingError {
                    outcomes.append(rows.columns[0].binary ? "binary:\(error)" : "text:\(error)")
                }
            }
            return outcomes.joined(separator: "|")
        }
        #expect(text == #"text:notConvertible(column: "n", value: "300", expected: "Int8")|binary:notConvertible(column: "n", value: "300", expected: "Int8")"#)
    }

    @Test func aBinaryColumnReadAsAnotherTypeGoesThroughItsText() throws {
        // Asked for as a String, or as a Double from a float4, a binary value
        // reads as its text would have: 0.1, not 0.10000000149011612.
        struct Loose: Decodable { let n: String; let f: Double; let raw: [UInt8] }
        let text = try onConnection { connection in
            var outcomes: [String] = []
            for _ in 0..<2 {
                let rows = try await connection.query("select 42 as n, 0.1::float4 as f, 7 as raw")
                let value = try decodeAll(Loose.self, rows)[0]
                outcomes.append("\(value.n),\(value.f),\(value.raw)")
            }
            return outcomes.joined(separator: "|")
        }
        #expect(text == "42,0.1,[55]|42,0.1,[55]")
    }

    // MARK: UUID and Timestamp

    struct Stamped: Decodable, Equatable {
        let id: UUID
        let at: Timestamp
        let wall: Timestamp
        let maybe: UUID?
    }

    @Test func uuidsAndTimestampsRoundTripInTextAndBinary() throws {
        let id = UUID.random()
        let instants = [Timestamp(microsecondsSinceEpoch: 1_789_591_223_196_123),
                        Timestamp(microsecondsSinceEpoch: 0),
                        Timestamp(microsecondsSinceEpoch: -1),                        // before 1970
                        Timestamp(microsecondsSinceEpoch: -2_000_000_000_000_000),    // 1906, before 2000 too
                        Timestamp("0044-03-15 12:00:00+00 BC")!]
        let text = try onConnection { connection in
            _ = try await connection.query("set time zone 'UTC'")
            _ = try await connection.query("create temporary table stamps (n int, id uuid, at timestamptz, wall timestamp, maybe uuid)")
            for (n, instant) in instants.enumerated() {
                let values: [PostgresValue] = [PostgresValue(String(n)), id.postgresValue,
                                               instant.postgresValue, instant.postgresValue,
                                               UUID?.none.postgresValue]
                _ = try await connection.query("insert into stamps values ($1, $2, $3, $4, $5)",
                                               values: values)
            }
            let sql = "select id, at, wall, maybe from stamps order by n"
            let first = try await connection.query(sql)
            let second = try await connection.query(sql)
            let formats = second.columns.map { $0.binary ? "b" : "t" }.joined()
            let a = try decodeAll(Stamped.self, first)
            let b = try decodeAll(Stamped.self, second)
            let expected = instants.map { Stamped(id: id, at: $0, wall: $0, maybe: nil) }
            var mismatches: [String] = []
            for row in 0..<first.count {
                for column in 0..<first.columns.count where first.text(row: row, column: column) != second.text(row: row, column: column) {
                    mismatches.append("\(first.text(row: row, column: column) ?? "null") vs \(second.text(row: row, column: column) ?? "null")")
                }
            }
            // And the server agrees on what the bound values meant.
            let check = try await connection.query("select $1::uuid::text, extract(epoch from $2::timestamptz)::text",
                                                   values: [id.postgresValue, instants[0].postgresValue])
            // Built up rather than added together: a + chain this long over
            // strings, interpolations and ternaries is more than Swift 6.2's
            // type checker will work through.
            let sameID = check.text(row: 0, column: 0) == id.description ? "id" : "id?"
            let epoch = check.text(row: 0, column: 1) ?? "null"
            var parts: [String] = [formats]
            parts.append("\(a == expected)")
            parts.append("\(b == expected)")
            parts.append(mismatches.joined(separator: "; "))
            parts.append(sameID + "," + epoch)
            return parts.joined(separator: "|")
        }
        #expect(text == "bbbb|true|true||id,1789591223.196123")
    }

    @Test func infinityIsNotATimestamp() throws {
        struct At: Decodable { let at: Timestamp }
        let text = try onConnection { connection in
            var outcomes: [String] = []
            for value in ["infinity", "-infinity"] {
                var texts: [String] = []
                for _ in 0..<2 {
                    let rows = try await connection.query("select '\(value)'::timestamptz as at")
                    texts.append(rows.text(row: 0, column: 0) ?? "null")
                    do {
                        _ = try decodeAll(At.self, rows)
                        outcomes.append("decoded")
                    } catch {
                        outcomes.append(rows.columns[0].binary ? "binary refused" : "text refused")
                    }
                }
                outcomes.append(texts.joined(separator: "="))
            }
            return outcomes.joined(separator: "|")
        }
        #expect(text == "text refused|binary refused|infinity=infinity|text refused|binary refused|-infinity=-infinity")
    }

    /// Over a unix socket, which is how a server on the same machine is
    /// usually reached. No TLS: there is no network on it to encrypt.
    @Test(.enabled(if: socketTarget != nil, "set GARUDA_POSTGRES_SOCKET to run"))
    func aUnixSocketConnects() throws {
        let configuration = socketTarget!
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                defer { connection.close() }
                let rows = try await connection.query(
                    "select $1::int + 1 as answer, current_setting('unix_socket_directories') <> '' as socketed",
                    ["41"])
                return (rows.text(row: 0, column: 0) ?? "null") + "|" + (rows.text(row: 0, column: 1) ?? "null")
            } catch {
                return describe(error)
            }
        }
        #expect(text == "42|t", "\(text)")
    }

    /// TLS over a socket is refused rather than quietly gone without.
    @Test(.enabled(if: socketTarget != nil, "set GARUDA_POSTGRES_SOCKET to run"))
    func tlsOverASocketIsRefused() throws {
        var insisting = socketTarget!
        insisting.tls = .require
        let configuration = insisting
        let text = try onWorker { worker in
            do {
                let connection = try await PostgresConnection.connect(worker, configuration)
                connection.close()
                return "connected"
            } catch {
                return describe(error)
            }
        }
        #expect(text == "tlsUnavailable", "\(text)")
    }

    @Test func theSessionIsAskedForUTF8AndISODates() throws {
        let text = try onConnection { connection in
            let rows = try await connection.query("select current_setting('client_encoding'), current_setting('DateStyle')")
            return (rows.text(row: 0, column: 0) ?? "") + "|" + (rows.text(row: 0, column: 1) ?? "")
        }
        #expect(text.hasPrefix("UTF8|ISO"))
    }
}

// MARK: - A row read without Codable

// `@PostgresRow` writes the reader; these check it reads what Codable read.
// Each is a real query, because what a column decodes to depends on whether
// the server sent it in text or binary, and only a server decides that.

@PostgresRow private struct MacroPerson: Codable, Equatable {
    var id: Int
    var name: String
}

private struct PlainPerson: Codable, Equatable {
    var id: Int
    var name: String
}

@PostgresRow private struct MacroSparse: Codable, Equatable {
    var id: Int32
    var nickname: String?
    var score: Double?
}

private struct PlainSparse: Codable, Equatable {
    var id: Int32
    var nickname: String?
    var score: Double?
}

// Part of the suite above rather than a suite of its own: `onWorker` drives
// one test application through file-scope state, so two suites running at
// once would read each other's answers.
extension PostgresIntegrationTests {
    @Test func itReadsWhatCodableReads() throws {
        let text = try onConnection { connection in
            let rows = try await connection.query(
                "select 7 as id, 'ana' as name union all select 8, 'bo' order by id")
            let mine = try decodeAll(MacroPerson.self, rows)
            let plain = try decodeAll(PlainPerson.self, rows)
            let same = mine.map(\.id) == plain.map(\.id) && mine.map(\.name) == plain.map(\.name)
            let read = mine == [MacroPerson(id: 7, name: "ana"), MacroPerson(id: 8, name: "bo")]
            return "\(read)|\(same)"
        }
        #expect(text == "true|true")
    }

    @Test func aNullOptionalIsNilAndSoIsAColumnThatIsNotThere() throws {
        let text = try onConnection { connection in
            let withNulls = try await connection.query(
                "select 1::int4 as id, null::text as nickname, null::float8 as score")
            let narrow = try await connection.query("select 2::int4 as id")
            let a = try decodeAll(MacroSparse.self, withNulls)[0]
            let b = try decodeAll(PlainSparse.self, withNulls)[0]
            let c = try decodeAll(MacroSparse.self, narrow)[0]
            let d = try decodeAll(PlainSparse.self, narrow)[0]
            return "\(a == MacroSparse(id: 1, nickname: nil, score: nil))"
                 + "|\(a.nickname == b.nickname && a.score == b.score)"
                 + "|\(c == MacroSparse(id: 2, nickname: nil, score: nil))"
                 + "|\(c.nickname == d.nickname)"
        }
        #expect(text == "true|true|true|true")
    }

    @Test func aFilledOptionalIsRead() throws {
        let text = try onConnection { connection in
            let rows = try await connection.query(
                "select 3::int4 as id, 'bo'::text as nickname, 1.5::float8 as score")
            let one = try decodeAll(MacroSparse.self, rows)[0]
            return "\(one == MacroSparse(id: 3, nickname: "bo", score: 1.5))"
        }
        #expect(text == "true")
    }

    // A NULL into a property that is not optional, and a column the result
    // does not carry at all: both are errors for Codable, and both have to
    // stay errors here or a generated reader quietly invents values.
    @Test func aNullOrAMissingColumnForANonOptionalIsRefused() throws {
        let text = try onConnection { connection in
            var outcomes: [String] = []
            for sql in ["select 4 as id, null::text as name", "select 5 as id"] {
                let rows = try await connection.query(sql)
                do {
                    _ = try decodeAll(MacroPerson.self, rows)
                    outcomes.append("decoded")
                } catch let error as PostgresDecodingError {
                    outcomes.append("\(error)")
                }
            }
            return outcomes.joined(separator: "|")
        }
        #expect(text == "null(column: \"name\")|missingColumn(\"name\")")
    }
}
