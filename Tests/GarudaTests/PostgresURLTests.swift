import Testing
import GarudaPostgres
@testable import Garuda

// Reading a `postgres://` URL: the plain form, what may be left out, what is
// percent-encoded, parameters, and what is refused.

@Suite("PostgreSQL connection URLs")
struct PostgresURLTests {
    @Test func theUsualForm() throws {
        let c = try PostgresConfiguration(url: "postgres://app:secret@db.internal:6543/shop")
        #expect(c.host == "db.internal")
        #expect(c.port == 6543)
        #expect(c.user == "app")
        #expect(c.password == "secret")
        #expect(c.database == "shop")
        #expect(c.tls == .require)
    }

    @Test func whatMayBeLeftOut() throws {
        let bare = try PostgresConfiguration(url: "postgresql://db")
        #expect(bare.host == "db" && bare.port == 5432 && bare.user == "postgres")
        #expect(bare.password.isEmpty && bare.database == nil)

        let noPassword = try PostgresConfiguration(url: "postgres://app@db/shop")
        #expect(noPassword.user == "app" && noPassword.password.isEmpty)

        // A trailing slash is no database at all, not a database named "".
        #expect(try PostgresConfiguration(url: "postgres://db/").database == nil)

        // An empty user keeps the default.
        #expect(try PostgresConfiguration(url: "postgres://:secret@db").user == "postgres")
    }

    @Test func percentEncoding() throws {
        // A password with the characters that would otherwise end a field.
        let c = try PostgresConfiguration(url: "postgres://user%40corp:p%40ss%2Fword%3A1@db:5432/my%20app")
        #expect(c.user == "user@corp")
        #expect(c.password == "p@ss/word:1")
        #expect(c.database == "my app")
    }

    @Test func aPasswordHoldingAnAtSign() throws {
        // The credentials end at the last @, not the first.
        let c = try PostgresConfiguration(url: "postgres://app:a@b@db.internal/shop")
        #expect(c.host == "db.internal" && c.password == "a@b")
    }

    @Test func ipv6() throws {
        let withPort = try PostgresConfiguration(url: "postgres://app:s@[2001:db8::1]:5433/shop")
        #expect(withPort.host == "2001:db8::1" && withPort.port == 5433)
        let withoutPort = try PostgresConfiguration(url: "postgres://[::1]/shop")
        #expect(withoutPort.host == "::1" && withoutPort.port == 5432)
    }

    @Test func parameters() throws {
        let disabled = try PostgresConfiguration(url: "postgres://app:s@localhost/shop?sslmode=disable")
        #expect(disabled.tls == .disable)
        for mode in ["require", "verify-ca", "verify-full"] {
            #expect(try PostgresConfiguration(url: "postgres://db/shop?sslmode=\(mode)").tls == .require)
        }
        let full = try PostgresConfiguration(
            url: "postgres://db/shop?sslmode=verify-full&sslrootcert=/etc/ssl/db.pem&connect_timeout=3"
                + "&application_name=starter")
        #expect(full.caFile == "/etc/ssl/db.pem")
        #expect(full.timeoutMilliseconds == 3_000)
        // An unknown parameter is ignored, not refused: a platform's URL
        // carries its own.
        #expect(full.database == "shop")
        // A parameter with a slash in it is not read as the database.
        #expect(try PostgresConfiguration(url: "postgres://db?sslrootcert=/a/b.pem").database == nil)
    }

    @Test func whatIsRefused() throws {
        #expect(throws: PostgresURLError.scheme("mysql")) {
            try PostgresConfiguration(url: "mysql://db/shop")
        }
        #expect(throws: PostgresURLError.scheme("postgres:/db")) {
            try PostgresConfiguration(url: "postgres:/db")
        }
        #expect(throws: PostgresURLError.noHost) {
            try PostgresConfiguration(url: "postgres:///shop")
        }
        #expect(throws: PostgresURLError.port("abc")) {
            try PostgresConfiguration(url: "postgres://db:abc/shop")
        }
        #expect(throws: PostgresURLError.port("99999")) {
            try PostgresConfiguration(url: "postgres://db:99999/shop")
        }
        // Falling back to plaintext when the server declines is not a mode
        // Garuda offers.
        for mode in ["prefer", "allow"] {
            #expect(throws: PostgresURLError.sslMode(mode)) {
                try PostgresConfiguration(url: "postgres://db/shop?sslmode=\(mode)")
            }
        }
    }
}
