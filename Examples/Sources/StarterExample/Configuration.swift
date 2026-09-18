//===----------------------------------------------------------------------===//
// Everything the application reads from its environment, in one type, checked
// once at start-up.
//
// `AppEnvironment` does the reading and collects the problems; this file says
// what the variables are, what they default to, and what combinations make no
// sense. Nothing is served until it all checks out, and every problem is
// reported at once rather than one per restart.
//
// Garuda's own flags -- port, workers, TLS, rate limits -- stay on the command
// line (CONFIG.md). This is for what the *application* needs: where the
// database is, what signs its tokens, whether sign-ups are open.
//===----------------------------------------------------------------------===//

import Garuda

public struct StarterConfiguration: Sendable {
    public var mode: AppEnvironment.Mode
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
    /// What was read, for `starter env`, with secrets held back.
    public var summary: String = ""

    public var isProduction: Bool { mode == .production }

    public init(mode: AppEnvironment.Mode = .development,
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
    public static func fromEnvironment(
        _ read: @escaping (String) -> String? = AppEnvironment.processEnvironment
    ) throws -> StarterConfiguration {
        var env = AppEnvironment(read)
        var configuration = StarterConfiguration()
        configuration.mode = env.mode
        // Development may have defaults; production is told or it fails.
        let production = env.mode == .production

        configuration.databaseURL = env.url("DATABASE_URL",
                                            default: production ? nil : configuration.databaseURL)
        if !configuration.databaseURL.isEmpty {
            do {
                let parsed = try PostgresConfiguration(url: configuration.databaseURL)
                if production, parsed.tls == .disable {
                    env.problem("DATABASE_URL has sslmode=disable, which production should not")
                }
            } catch {
                env.problem("DATABASE_URL cannot be read: \(error)")
            }
        }

        // In development, no key means one made up for the run, which
        // `starterApp` does. In production that would sign out every user on
        // each deployment, and no two workers would agree.
        let key = env.secretOrFile("JWT_PRIVATE_KEY", default: production ? nil : "")
        configuration.signingKeyPEM = key.isEmpty ? nil : key
        if let pem = configuration.signingKeyPEM {
            do {
                _ = try JWTKey.pem(pem, algorithm: .ES256)
            } catch {
                env.problem("the signing key is not an ES256 private key in PEM: \(error)")
            }
        }

        configuration.accessTokenSeconds = env.int("ACCESS_TOKEN_SECONDS", default: 15 * 60, in: 1...86_400)
        configuration.refreshTokenDays = env.int("REFRESH_TOKEN_DAYS", default: 14, in: 1...3_650)
        configuration.sessionDays = env.int("SESSION_DAYS", default: 90, in: 1...3_650)
        configuration.databasePoolSize = env.int("DATABASE_POOL_SIZE", default: 8, in: 1...500)
        configuration.signUpsOpen = env.bool("SIGNUPS_OPEN", default: true)

        // Settings that are each fine and wrong together.
        if configuration.accessTokenSeconds >= configuration.refreshTokenDays * 24 * 3600 {
            env.problem("ACCESS_TOKEN_SECONDS is not shorter than REFRESH_TOKEN_DAYS; a short access "
                            + "token is the point of having a refresh token")
        }
        if configuration.refreshTokenDays > configuration.sessionDays {
            env.problem("REFRESH_TOKEN_DAYS is longer than SESSION_DAYS, so a session would end "
                            + "before its refresh token expires")
        }

        let docs = env.string("DOCS_PATH", default: "/docs")
        if docs == "off" {
            configuration.documentationPath = nil
        } else if docs.hasPrefix("/") {
            configuration.documentationPath = docs
        } else {
            env.problem("DOCS_PATH is \"\(docs)\"; it is a path beginning with / , or off")
        }

        try env.check()
        configuration.summary = env.summary()
        return configuration
    }
}
