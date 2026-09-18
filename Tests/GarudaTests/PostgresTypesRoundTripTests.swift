import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// The new types against a real server: bound as parameters, read back from
// binary, and compared with what the server itself says they are.
//
// Opt-in through GARUDA_POSTGRES, like the driver's other integration tests.

private let roundTripTarget: PostgresConfiguration? = {
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

private struct Metadata: Codable, Equatable, Sendable {
    let source: String
    let tags: [String]
}

private struct Row: Decodable {
    let day: PostgresDate
    let clock: PostgresTime
    let span: PostgresInterval
    let total: PostgresNumeric
    let small: PostgresNumeric
    let document: PostgresJSON<Metadata>
    let binaryDocument: PostgresJSON<Metadata>
    let absent: PostgresDate?
}

@Suite("PostgreSQL types round trip", .serialized)
struct PostgresTypesRoundTripTests {
    @Test(.enabled(if: roundTripTarget != nil, "set GARUDA_POSTGRES to run"))
    func everyTypeSurvivesTheServer() throws {
        let configuration = roundTripTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            do {
                let pool = db.value
                let day = PostgresDate(2026, 9, 18)!
                let clock = PostgresTime(14, 30, 5, microsecond: 250_000)!
                let span = PostgresInterval(years: 1, months: 2, days: 3, hours: 4, minutes: 5, seconds: 6)
                let total = PostgresNumeric("1234.56")!
                let small = PostgresNumeric("-0.00005")!
                let document = PostgresJSON(Metadata(source: "import", tags: ["a", "b"]))

                // Bound as parameters, read back in whatever form the driver
                // asked for.
                let row = try await pool.first(
                    Row.self,
                    """
                    select $1::date as day, $2::time as clock, $3::interval as span,
                           $4::numeric as total, $5::numeric as small,
                           $6::json as document, $6::jsonb as "binaryDocument",
                           null::date as absent
                    """,
                    day, clock, span, total, small, document)
                guard let row else { return "no row" }
                var out: [String] = []
                out.append("\(row.day == day)")
                out.append("\(row.clock == clock)")
                out.append("\(row.span == span)")
                out.append("\(row.total == total)")
                out.append("\(row.total.description == "1234.56")")
                out.append("\(row.small == small)")
                out.append("\(row.document.value == document.value)")
                out.append("\(row.binaryDocument.value == document.value)")
                out.append("\(row.absent == nil)")

                // What the server itself says these values are, so a wrong
                // reading cannot agree with a wrong writing.
                struct Text: Decodable { let text: String }
                let said = try await pool.query(
                    Text.self,
                    """
                    select $1::date::text as text union all
                    select $2::time::text union all
                    select $3::interval::text union all
                    select $4::numeric::text union all
                    select $5::numeric::text
                    """,
                    day, clock, span, total, small)
                out.append("\(said.count == 5)")
                out.append("\(said.map(\.text).joined(separator: "|"))")

                // A column PostgreSQL computes, rather than one it echoes.
                struct Computed: Decodable {
                    let later: PostgresDate
                    let age: PostgresInterval
                    let sum: PostgresNumeric
                }
                let computed = try await pool.first(
                    Computed.self,
                    """
                    select ($1::date + 45) as later,
                           ('2026-09-18'::date - '2025-08-17'::date) * interval '1 day' as age,
                           ($2::numeric * 3) as sum
                    """,
                    day, total)
                out.append("\(computed?.later.description ?? "-")")
                out.append("\(computed?.age.description ?? "-")")
                out.append("\(computed?.sum.description ?? "-")")
                return out.joined(separator: " ")
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let text = try client.get("/run").text
        #expect(text == "true true true true true true true true true true "
                    + "2026-09-18|14:30:05.25|1 year 2 mons 3 days 04:05:06|1234.56|-0.00005 "
                    + "2026-11-02 P397D 3703.68",
                "\(text)")
    }

    /// Values PostgreSQL itself generates, read back and compared with its own
    /// text: numeric at the edges, and dates far from today.
    @Test(.enabled(if: roundTripTarget != nil, "set GARUDA_POSTGRES to run"))
    func edgesAgreeWithTheServersOwnText() throws {
        let configuration = roundTripTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            do {
                struct Pair: Decodable {
                    let value: PostgresNumeric
                    let text: String
                }
                let numbers = ["0", "-0.1", "1e-8", "0.00000001", "12345678901234567890.123456789",
                               "99999999999999999999999999999999999999", "-9999.0001", "NaN"]
                var wrong: [String] = []
                for number in numbers {
                    guard let pair = try await db.value.first(
                        Pair.self, "select $1::numeric as value, $1::numeric::text as text",
                        PostgresNumeric(number)!) else {
                        wrong.append("\(number): no row")
                        continue
                    }
                    let expected = PostgresNumeric(pair.text)!
                    if pair.value != expected || (pair.value.isNaN != expected.isNaN) {
                        wrong.append("\(number): read \(pair.value) for \(pair.text)")
                    }
                }
                struct DatePair: Decodable {
                    let value: PostgresDate
                    let text: String
                }
                for date in ["0001-01-01", "1000-02-28", "1900-03-01", "2000-01-01", "2026-09-18",
                             "4713-12-31", "9999-12-31"] {
                    guard let pair = try await db.value.first(
                        DatePair.self, "select $1::date as value, $1::date::text as text",
                        PostgresDate(date)!) else {
                        wrong.append("\(date): no row")
                        continue
                    }
                    if pair.value.description != pair.text {
                        wrong.append("\(date): read \(pair.value) for \(pair.text)")
                    }
                }
                return wrong.isEmpty ? "all agree" : wrong.joined(separator: "; ")
            } catch {
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let text = try client.get("/run").text
        #expect(text == "all agree", "\(text)")
    }
}
