import Testing
@testable import AvianCore
@testable import GarudaPostgres

// The session and query machines against scripted servers. Mostly servers that
// misbehave: an honest PostgreSQL never skips proving itself, never asks for a
// cleartext password it does not need, never says it is ready before anyone
// has authenticated -- which is why only a scripted one can test the refusals.
// The paths an honest server takes are proven against a real one.

private func i16(_ v: Int16) -> [UInt8] {
    let u = UInt16(bitPattern: v)
    return [UInt8(u >> 8), UInt8(truncatingIfNeeded: u)]
}

private func i32(_ v: Int32) -> [UInt8] {
    let u = UInt32(bitPattern: v)
    return [UInt8(u >> 24), UInt8(truncatingIfNeeded: u >> 16),
            UInt8(truncatingIfNeeded: u >> 8), UInt8(truncatingIfNeeded: u)]
}

private func cstr(_ s: String) -> [UInt8] { Array(s.utf8) + [0] }

private func feed(_ startup: inout PostgresStartup, _ type: Character,
                  _ body: [UInt8]) throws -> PostgresStep {
    let storage = body.isEmpty ? [UInt8(0)] : body
    return try storage.withUnsafeBufferPointer { buf in
        try startup.receive(UInt8(ascii: type.unicodeScalars.first!),
                            PostgresReader(buf.baseAddress!, body.count))
    }
}

private func feed(_ query: inout PostgresQuery, _ type: Character,
                  _ body: [UInt8]) throws -> Bool {
    let storage = body.isEmpty ? [UInt8(0)] : body
    return try storage.withUnsafeBufferPointer { buf in
        try query.receive(UInt8(ascii: type.unicodeScalars.first!),
                          PostgresReader(buf.baseAddress!, body.count))
    }
}

private func thrown(_ body: () throws -> Void) -> PostgresError? {
    do {
        try body()
        return nil
    } catch {
        return error as? PostgresError
    }
}

private let nonce = "clientnonce123"
private let serverFirst = "r=\(nonce)servernonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"

@Suite("PostgreSQL session")
struct PostgresSessionTests {

    // MARK: Authentication a client must refuse

    @Test func aServerThatSaysOkWithoutFinishingSCRAMIsRefused() {
        // An impostor relays the exchange as far as the client's proof, then
        // skips the one message that would show it knows the password, and
        // simply says ok.
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil,
                                      nonce: nonce)
        let error = thrown {
            _ = try feed(&startup, "R", i32(10) + cstr("SCRAM-SHA-256") + [0])
            _ = try feed(&startup, "R", i32(11) + Array(serverFirst.utf8))
            _ = try feed(&startup, "R", i32(0))
        }
        #expect(error == .refusedAuthentication("the server skipped proving itself"))
    }

    @Test func aForgedSCRAMSignatureIsRefused() {
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil,
                                      nonce: nonce)
        let error = thrown {
            _ = try feed(&startup, "R", i32(10) + cstr("SCRAM-SHA-256") + [0])
            _ = try feed(&startup, "R", i32(11) + Array(serverFirst.utf8))
            _ = try feed(&startup, "R", i32(12)
                         + Array("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=".utf8))
        }
        #expect(error == .scram(.serverSignatureMismatch))
    }

    @Test func aCleartextPasswordRequestIsRefusedByDefault() {
        // The standard way to harvest a password: ask for it in the clear and
        // let the client send it.
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil)
        #expect(thrown { _ = try feed(&startup, "R", i32(3)) }
                == .refusedAuthentication("cleartext password"))
    }

    @Test func aCleartextPasswordIsRefusedOverPlaintextEvenWhenAllowed() {
        // Allowed means allowed where it cannot be read on the way.
        var policy = PostgresStartup.Policy()
        policy.allowCleartext = true
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil,
                                      policy: policy)
        #expect(thrown { _ = try feed(&startup, "R", i32(3)) }
                == .refusedAuthentication("cleartext password"))
    }

    @Test func aCleartextPasswordIsSentWhenAllowedAndEncrypted() throws {
        var policy = PostgresStartup.Policy()
        policy.allowCleartext = true
        policy.encrypted = true
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil,
                                      policy: policy)
        let length = UInt32(4 + 7)
        let expected: [UInt8] = [UInt8(ascii: "p"), 0, 0, 0, UInt8(length)] + cstr("pencil")
        #expect(try feed(&startup, "R", i32(3)) == .send(expected))
    }

    @Test func anMD5PasswordRequestIsAlwaysRefused() {
        // Refused even with cleartext allowed and the connection encrypted:
        // MD5 is deprecated in PostgreSQL, and there is no setting for it.
        var policy = PostgresStartup.Policy()
        policy.allowCleartext = true
        policy.encrypted = true
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil,
                                      policy: policy)
        #expect(thrown { _ = try feed(&startup, "R", i32(5) + [1, 2, 3, 4]) }
                == .refusedAuthentication("md5 password"))
    }

    @Test func aMechanismListWithoutSCRAMIsRefused() {
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil)
        let error = thrown { _ = try feed(&startup, "R", i32(10) + cstr("SCRAM-SHA-256-PLUS") + [0]) }
        #expect(error == .refusedAuthentication("no mechanism in common: [\"SCRAM-SHA-256-PLUS\"]"))
    }

    @Test func readyBeforeAuthenticatingIsRefused() {
        // A server announcing it is ready for queries has skipped the part
        // that says who it is.
        var startup = PostgresStartup(user: "garuda", password: "pencil", database: nil)
        #expect(thrown { _ = try feed(&startup, "Z", [UInt8(ascii: "I")]) }
                == .unexpectedMessage(UInt8(ascii: "Z")))
    }

    @Test func aTrustedConnectionBecomesReady() throws {
        var startup = PostgresStartup(user: "garuda", password: "", database: nil)
        #expect(try feed(&startup, "R", i32(0)) == .wait)
        #expect(try feed(&startup, "S", cstr("server_version") + cstr("16.15")) == .wait)
        #expect(try feed(&startup, "K", i32(99) + i32(7)) == .wait)
        #expect(try feed(&startup, "Z", [UInt8(ascii: "I")]) == .ready)
        #expect(startup.parameters["server_version"] == "16.15")
        #expect(startup.processID == 99)
    }

    @Test func aServerErrorDuringStartupIsReported() {
        var startup = PostgresStartup(user: "garuda", password: "wrong", database: nil)
        var body: [UInt8] = [UInt8(ascii: "S")]
        body += cstr("FATAL")
        body += [UInt8(ascii: "C")]
        body += cstr("28P01")
        body += [UInt8(ascii: "M")]
        body += cstr("password authentication failed")
        body += [0]
        let error = thrown { _ = try feed(&startup, "E", body) }
        guard case .server(let fields) = error else {
            Issue.record("expected a server error, got \(String(describing: error))")
            return
        }
        #expect(fields.code == "28P01")
    }

    // MARK: Queries

    private func rowDescription(_ names: [String]) -> [UInt8] {
        var body = i16(Int16(names.count))
        for name in names {
            body += cstr(name) + i32(0) + i16(0) + i32(25) + i16(-1) + i32(-1) + i16(0)
        }
        return body
    }

    private func dataRow(_ values: [String?]) -> [UInt8] {
        var body = i16(Int16(values.count))
        for value in values {
            if let value {
                body += i32(Int32(value.utf8.count)) + Array(value.utf8)
            } else {
                body += i32(-1)
            }
        }
        return body
    }

    @Test func aResultIsCollected() throws {
        var query = PostgresQuery("select id, name from users")
        #expect(try feed(&query, "1", []) == false)
        #expect(try feed(&query, "2", []) == false)
        #expect(try feed(&query, "T", rowDescription(["id", "name"])) == false)
        #expect(try feed(&query, "D", dataRow(["1", "ada"])) == false)
        #expect(try feed(&query, "D", dataRow(["2", nil])) == false)
        #expect(try feed(&query, "C", cstr("SELECT 2")) == false)
        #expect(try feed(&query, "Z", [UInt8(ascii: "I")]) == true)
        let rows = try query.result().get()
        #expect(rows.count == 2)
        #expect(rows.text(row: 0, column: 1) == "ada")
        #expect(rows.text(row: 1, column: 1) == nil)
        #expect(rows.affected == 2)
    }

    @Test func anErrorDoesNotFinishTheQueryUntilTheServerIsReady() throws {
        // The server discards up to the Sync and only then says it is ready.
        // Until then the connection is mid-query, and handing it on would give
        // the next caller this one's leftovers.
        var query = PostgresQuery("select * from missing")
        let error = [UInt8(ascii: "C")] + cstr("42P01") + [UInt8(ascii: "M")]
            + cstr("relation does not exist") + [0]
        #expect(try feed(&query, "E", error) == false)
        #expect(try feed(&query, "Z", [UInt8(ascii: "I")]) == true)
        guard case .failure(.server(let fields)) = query.result() else {
            Issue.record("expected a server error")
            return
        }
        #expect(fields.code == "42P01")
    }

    @Test func aRowThatDoesNotMatchItsDescriptionIsRefused() {
        var query = PostgresQuery("select id, name from users")
        let error = thrown {
            _ = try feed(&query, "T", rowDescription(["id", "name"]))
            _ = try feed(&query, "D", dataRow(["1"]))
        }
        #expect(error == .unexpectedMessage(UInt8(ascii: "D")))
    }

    @Test func aResultPastItsRowLimitFailsButStillDrainsToReady() throws {
        // Rows are copied as they arrive, so an unbounded SELECT is an
        // unbounded buffer. The query fails -- and keeps reading to the end,
        // so the connection is left usable.
        var query = PostgresQuery("select n from generate_series(1, 5) n", maxRows: 2)
        _ = try feed(&query, "T", rowDescription(["n"]))
        for n in 1...5 { #expect(try feed(&query, "D", dataRow(["\(n)"])) == false) }
        _ = try feed(&query, "C", cstr("SELECT 5"))
        #expect(try feed(&query, "Z", [UInt8(ascii: "I")]) == true)
        guard case .failure(.server(let fields)) = query.result() else {
            Issue.record("expected the row limit to fail the query")
            return
        }
        #expect(fields.code == "54000")
        #expect(query.rows.count == 2)
    }

    @Test func valuesTravelBesideTheSQLNotInsideIt() throws {
        // The whole of SQL injection is a value becoming part of the
        // statement. Here the statement goes in Parse and the value in Bind,
        // and nothing moves between them.
        let hostile = "'; drop table users; --"
        let query = PostgresQuery("select * from users where name = $1", [PostgresValue(hostile)])
        let bytes = try query.messages()
        let parse = cstr("select * from users where name = $1")
        #expect(bytes.starts(with: [UInt8(ascii: "P")]))
        // The hostile text appears once, as a bound value with its length in
        // front of it, and never next to the statement.
        let valueBytes = i32(Int32(hostile.utf8.count)) + Array(hostile.utf8)
        #expect(bytes.firstRange(of: valueBytes) != nil)
        #expect(bytes.firstRange(of: parse) != nil)
        #expect(bytes.firstRange(of: Array(("$1" + hostile).utf8)) == nil)
    }

    @Test func aBinaryValueDeclaresItsTypeAndTextValuesLeaveTheirsToTheServer() throws {
        let query = PostgresQuery("insert into files (name, data) values ($1, $2)",
                                  [PostgresValue("a.png"), .binary([0, 255], type: PostgresType.bytea)])
        let bytes = try query.messages()
        // Parse: both parameters typed, the text one as 0 (infer).
        let parse = cstr("insert into files (name, data) values ($1, $2)") + i16(2) + i32(0) + i32(17)
        #expect(bytes.firstRange(of: parse) != nil)
        // Bind: a format per parameter, text then binary.
        let formats = i16(2) + i16(0) + i16(1) + i16(2)
        #expect(bytes.firstRange(of: formats) != nil)
    }

    @Test func aStatementOfTextValuesDeclaresNoTypes() throws {
        let query = PostgresQuery("select $1", [PostgresValue("7")])
        #expect(try query.messages().firstRange(of: cstr("select $1") + i16(0)) != nil)
    }

    @Test func theStartupMessageAsksForUTF8AndISODates() throws {
        // Text decodes as Swift strings do only if it is UTF-8, and a
        // timestamp that comes as text is read in one layout only.
        let bytes = try PostgresStartup(user: "garuda", password: "x", database: "app").start()
        #expect(bytes.firstRange(of: cstr("client_encoding") + cstr("UTF8")) != nil)
        #expect(bytes.firstRange(of: cstr("DateStyle") + cstr("ISO")) != nil)
    }
}
