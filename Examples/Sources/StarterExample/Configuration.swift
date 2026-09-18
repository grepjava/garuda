//===----------------------------------------------------------------------===//
// Everything the application reads from its environment, in one type, checked
// once at start-up.
//
// The rule this follows: a value the application needs is read and validated
// before anything is served, and every problem is reported at once rather than
// one per restart. A missing secret should not be discovered by a request.
//
// Garuda's own flags -- port, workers, TLS, rate limits -- stay on the command
// line (CONFIG.md). This is for what the *application* needs: where the
// database is, what signs its tokens, whether sign-ups are open.
//===----------------------------------------------------------------------===//

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda

public struct StarterConfiguration: Sendable {
    public enum Mode: String, Sendable {
        /// Loose defaults, and a signing key made up at start-up.
        case development
        /// Nothing is guessed: every secret must be given.
        case production
    }

    public var mode: Mode
    /// `postgres://user:password@host:port/database?sslmode=require`
    public var databaseURL: String
    /// An ES256 private key in PEM, what access tokens are signed with. Nil in
    /// development means one is made up for this run.
    public var signingKeyPEM: String?
    public var accessTokenSeconds: Int
    public var refreshTokenDays: Int
    public var sessionDays: Int
    public var signUpsOpen: Bool
    public var databasePoolSize: Int
    /// Where the OpenAPI document and Swagger UI are served, or nil for
    /// neither.
    public var documentationPath: String?

    public var isProduction: Bool { mode == .production }

    public init(mode: Mode = .development,
                databaseURL: String = "postgres://garuda:garuda-secret@127.0.0.1:5432/starter?sslmode=disable",
                signingKeyPEM: String? = nil,
                accessTokenSeconds: Int = 15 * 60,
                refreshTokenDays: Int = 14,
                sessionDays: Int = 90,
                signUpsOpen: Bool = true,
                databasePoolSize: Int = 8,
                documentationPath: String? = "/docs") {
        self.mode = mode
        self.databaseURL = databaseURL
        self.signingKeyPEM = signingKeyPEM
        self.accessTokenSeconds = accessTokenSeconds
        self.refreshTokenDays = refreshTokenDays
        self.sessionDays = sessionDays
        self.signUpsOpen = signUpsOpen
        self.databasePoolSize = databasePoolSize
        self.documentationPath = documentationPath
    }
}

/// What was wrong with the environment, all of it at once.
public struct ConfigurationError: Error, CustomStringConvertible {
    public let problems: [String]

    public var description: String {
        "the environment is not usable:\n" + problems.map { "  - " + $0 }.joined(separator: "\n")
    }
}

extension StarterConfiguration {
    /// Reads the environment, or reports everything that is wrong with it.
    ///
    /// | variable | required | default |
    /// |---|---|---|
    /// | `APP_ENV` | no | `development` |
    /// | `DATABASE_URL` | in production | a local database |
    /// | `JWT_PRIVATE_KEY` | in production | a key made up per run |
    /// | `JWT_PRIVATE_KEY_FILE` | no | read in place of `JWT_PRIVATE_KEY` |
    /// | `ACCESS_TOKEN_SECONDS` | no | 900 |
    /// | `REFRESH_TOKEN_DAYS` | no | 14 |
    /// | `SESSION_DAYS` | no | 90 |
    /// | `SIGNUPS_OPEN` | no | true |
    /// | `DATABASE_POOL_SIZE` | no | 8 |
    /// | `DOCS_PATH` | no | `/docs`, and `off` serves neither |
    public static func fromEnvironment(_ read: (String) -> String? = environment) throws -> StarterConfiguration {
        var problems: [String] = []
        var configuration = StarterConfiguration()

        let modeName = read("APP_ENV") ?? "development"
        if let mode = Mode(rawValue: modeName) {
            configuration.mode = mode
        } else {
            problems.append("APP_ENV is \"\(modeName)\"; it is development or production")
        }
        let production = configuration.mode == .production

        if let url = read("DATABASE_URL"), !url.isEmpty {
            configuration.databaseURL = url
            do {
                let parsed = try PostgresConfiguration(url: url)
                if production, parsed.tls == .disable {
                    problems.append("DATABASE_URL has sslmode=disable, which production should not")
                }
            } catch {
                problems.append("DATABASE_URL cannot be read: \(error)")
            }
        } else if production {
            problems.append("DATABASE_URL is not set; production has no default database")
        }

        if let path = read("JWT_PRIVATE_KEY_FILE"), !path.isEmpty {
            if let pem = contentsOfFile(path) {
                configuration.signingKeyPEM = pem
            } else {
                problems.append("JWT_PRIVATE_KEY_FILE names \"\(path)\", which cannot be read")
            }
        } else if let pem = read("JWT_PRIVATE_KEY"), !pem.isEmpty {
            configuration.signingKeyPEM = pem
        } else if production {
            problems.append("JWT_PRIVATE_KEY is not set; a key made up per run would sign out every "
                                + "user on each deployment, and no two workers would agree")
        }
        if let pem = configuration.signingKeyPEM {
            do {
                _ = try JWTKey.pem(pem, algorithm: .ES256)
            } catch {
                problems.append("the signing key is not an ES256 private key in PEM: \(error)")
            }
        }

        func positive(_ name: String, _ into: inout Int) {
            guard let raw = read(name), !raw.isEmpty else { return }
            guard let value = Int(raw), value > 0 else {
                problems.append("\(name) is \"\(raw)\"; it is a whole number above zero")
                return
            }
            into = value
        }
        positive("ACCESS_TOKEN_SECONDS", &configuration.accessTokenSeconds)
        positive("REFRESH_TOKEN_DAYS", &configuration.refreshTokenDays)
        positive("SESSION_DAYS", &configuration.sessionDays)
        positive("DATABASE_POOL_SIZE", &configuration.databasePoolSize)

        if configuration.accessTokenSeconds >= configuration.refreshTokenDays * 24 * 3600 {
            problems.append("ACCESS_TOKEN_SECONDS is not shorter than REFRESH_TOKEN_DAYS; a short access "
                                + "token is the point of having a refresh token")
        }
        if configuration.refreshTokenDays > configuration.sessionDays {
            problems.append("REFRESH_TOKEN_DAYS is longer than SESSION_DAYS, so a session would end "
                                + "before its refresh token expires")
        }

        if let raw = read("SIGNUPS_OPEN"), !raw.isEmpty {
            switch raw.lowercased() {
            case "1", "true", "yes", "on": configuration.signUpsOpen = true
            case "0", "false", "no", "off": configuration.signUpsOpen = false
            default: problems.append("SIGNUPS_OPEN is \"\(raw)\"; it is true or false")
            }
        }

        if let raw = read("DOCS_PATH"), !raw.isEmpty {
            if raw == "off" {
                configuration.documentationPath = nil
            } else if raw.hasPrefix("/") {
                configuration.documentationPath = raw
            } else {
                problems.append("DOCS_PATH is \"\(raw)\"; it is a path beginning with / , or off")
            }
        }

        guard problems.isEmpty else { throw ConfigurationError(problems: problems) }
        return configuration
    }

    /// One environment variable, or nil when it is unset.
    public static func environment(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        return String(cString: raw)
    }
}

/// A file's contents as text, for a secret mounted as a file.
private func contentsOfFile(_ path: String) -> String? {
    guard let file = fopen(path, "rb") else { return nil }
    defer { fclose(file) }
    var bytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let read = fread(&buffer, 1, buffer.count, file)
        if read <= 0 { break }
        bytes.append(contentsOf: buffer[0..<read])
    }
    guard !bytes.isEmpty else { return nil }
    return String(decoding: bytes, as: UTF8.self)
}
