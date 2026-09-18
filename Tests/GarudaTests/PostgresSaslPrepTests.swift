import Testing
import CAvian
import GarudaPostgres
@testable import Garuda

// SASLprep's mapping step, and what it is for: a password whose bytes the
// client and the server have to agree on before SCRAM can work.

@Suite("SASLprep")
struct SaslPrepTests {
    @Test func asciiPasswordsAreLeftAlone() throws {
        for password in ["", "secret", "p@ssw0rd!", "a b c", "\t\n"] {
            #expect(SaslPrep.mapped(password) == password)
        }
    }

    @Test func nonAsciiSpacesBecomeOneSpace() throws {
        // The one that costs people an afternoon: a non-breaking space that
        // came in with a paste.
        #expect(SaslPrep.mapped("pa\u{00A0}ss") == "pa ss")
        #expect(SaslPrep.mapped("pa\u{2000}ss") == "pa ss")
        #expect(SaslPrep.mapped("pa\u{3000}ss") == "pa ss")
        #expect(SaslPrep.mapped("pa\u{205F}ss") == "pa ss")
        // A zero-width space is in both tables, and the server maps it to a
        // space before it would map it to nothing.
        #expect(SaslPrep.mapped("pa\u{200B}ss") == "pa ss")
    }

    @Test func whatIsCommonlyMappedToNothingGoes() throws {
        #expect(SaslPrep.mapped("pa\u{00AD}ss") == "pass", "a soft hyphen")
        #expect(SaslPrep.mapped("pa\u{200C}ss") == "pass", "a zero-width non-joiner")
        #expect(SaslPrep.mapped("pa\u{FEFF}ss") == "pass", "a byte-order mark")
        #expect(SaslPrep.mapped("pa\u{FE0F}ss") == "pass", "a variation selector")
    }

    @Test func charactersWithNoRuleAreKept() throws {
        // Accents, other scripts, emoji: SASLprep's mapping does nothing to
        // them, and neither does this.
        for password in ["pässwörd", "пароль", "密碼", "p🔒ss"] {
            #expect(SaslPrep.mapped(password) == password)
        }
    }
}

// MARK: - Against a real server

private let prepTarget: PostgresConfiguration? = {
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

@Suite("SASLprep against a real server", .serialized)
struct SaslPrepIntegrationTests {
    /// A role whose password holds a non-breaking space. The server maps it
    /// when it stores the verifier, so a client that does not map it cannot
    /// authenticate -- and one that does can, with either spelling.
    @Test(.enabled(if: prepTarget != nil, "set GARUDA_POSTGRES to run"))
    func aPasswordWithANonAsciiSpaceAuthenticates() throws {
        let configuration = prepTarget!
        let app = Application()
        app.state { _ in PostgresPool(configuration, maxConnections: 2) }
        app.get("/run") { (db: State<PostgresPool>) async -> String in
            guard let worker = currentWorker else { return "no worker" }
            let pool = db.value
            let role = "garuda_prep_test"
            let withSpace = "pa\u{00A0}ss-\u{00AD}word"
            do {
                // The server SASLpreps this before it stores the verifier.
                try await pool.execute("drop role if exists \"\(role)\"")
                try await pool.execute("create role \"\(role)\" login password '\(withSpace)'")

                func connects(as password: String) async -> String {
                    var settings = configuration
                    settings.user = role
                    settings.password = password
                    do {
                        let connection = try await PostgresConnection.connect(worker, settings)
                        defer { connection.close() }
                        let rows = try await connection.query("select current_user")
                        return rows.text(row: 0, column: 0) == role ? "in" : "wrong user"
                    } catch let error as PostgresClientError {
                        if case .postgres(.server(let fields)) = error { return fields.code }
                        return "\(error)"
                    } catch {
                        return "\(error)"
                    }
                }
                var out: [String] = []
                // As it was written.
                out.append(await connects(as: withSpace))
                // And as SASLprep leaves it, which is the same password: an
                // ordinary space where the non-breaking one was, and the soft
                // hyphen gone.
                out.append(await connects(as: "pa ss-word"))
                // Something else is still refused.
                out.append(await connects(as: "pa ss-word!"))
                try await pool.execute("drop role \"\(role)\"")
                return out.joined(separator: "|")
            } catch {
                _ = try? await pool.execute("drop role if exists \"\(role)\"")
                return "threw \(error)"
            }
        }
        let client = app.test
        client.timeoutMillis = 20_000
        let text = try client.get("/run").text
        #expect(text == "in|in|28P01", "\(text)")
    }
}
