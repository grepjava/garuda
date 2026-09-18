#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Testing
import CAvian
@testable import Garuda

// `AppEnvironment`: reading an application's settings, collecting every
// problem, and reporting what was read.

private enum Colour: String, CaseIterable {
    case red, green
}

@Suite("Application environment")
struct AppEnvironmentTests {
    private func reading(_ values: [String: String]) -> (String) -> String? {
        { values[$0].flatMap { $0.isEmpty ? nil : $0 } }
    }

    @Test func defaultsWhenNothingIsSet() throws {
        var env = AppEnvironment(reading([:]))
        #expect(env.mode == .development)
        let url = env.string("DATABASE_URL", default: "postgres://localhost/dev")
        let pool = env.int("POOL", default: 8)
        let signUps = env.bool("SIGNUPS", default: true)
        let colour = env.choice("COLOUR", default: Colour.red)
        #expect(url == "postgres://localhost/dev")
        #expect(pool == 8)
        #expect(signUps)
        #expect(colour == .red)
        try env.check()
    }

    @Test func valuesThatAreSet() throws {
        var env = AppEnvironment(reading([
            "APP_ENV": "production",
            "DATABASE_URL": "postgres://app:secret@db/shop",
            "POOL": "24",
            "SIGNUPS": "off",
            "COLOUR": "GREEN",
        ]))
        #expect(env.mode == .production)
        let url = env.url("DATABASE_URL")
        let pool = env.int("POOL", in: 1...100)
        let signUps = env.bool("SIGNUPS")
        let colour = env.choice("COLOUR", default: Colour.red)
        #expect(url == "postgres://app:secret@db/shop")
        #expect(pool == 24)
        #expect(signUps == false)
        #expect(colour == .green)
        try env.check()
    }

    @Test func everyProblemIsReportedAtOnce() throws {
        var env = AppEnvironment(reading([
            "APP_ENV": "prod",
            "POOL": "many",
            "WORKERS": "0",
            "SIGNUPS": "maybe",
            "COLOUR": "blue",
        ]))
        // A reader still answers, so reading goes on and the report is whole.
        #expect(env.mode == .development, "an unusable APP_ENV falls back")
        let url = env.string("DATABASE_URL")
        let pool = env.int("POOL", default: 8)
        let workers = env.int("WORKERS", default: 4, in: 1...64)
        let signUps = env.bool("SIGNUPS", default: true)
        let colour = env.choice("COLOUR", default: Colour.red)
        #expect(url == "")
        #expect(pool == 8)
        #expect(workers == 4)
        #expect(signUps)
        #expect(colour == .red)
        env.problem("SIGNUPS cannot be on with no database")

        // Six from the readers, and the application's own.
        #expect(env.problems.count == 7, "\(env.problems)")
        do {
            try env.check()
            Issue.record("check should have thrown")
        } catch let error as AppEnvironmentError {
            #expect(error.problems.count == 7)
            #expect(error.description.contains("APP_ENV is \"prod\""))
            #expect(error.description.contains("DATABASE_URL is not set"))
            #expect(error.description.contains("POOL is \"many\""))
            #expect(error.description.contains("WORKERS is 0; it is 1 to 64"))
            #expect(error.description.contains("SIGNUPS is \"maybe\""))
            #expect(error.description.contains("COLOUR is \"blue\"; it is one of red, green"))
        }
    }

    @Test func productionCanBeRefusedADefault() throws {
        // The convention: `default: production ? nil : something`.
        for mode in ["development", "production"] {
            var env = AppEnvironment(reading(["APP_ENV": mode]))
            let production = env.mode == .production
            _ = env.string("DATABASE_URL", default: production ? nil : "postgres://localhost/dev")
            // Development has a default; production is told or it fails.
            #expect(env.problems.isEmpty == !production, "\(mode): \(env.problems)")
            if production {
                #expect(env.problems[0].contains("no default for it in production"))
            }
        }
    }

    @Test func aSecretCanComeFromAFile() throws {
        let path = "/tmp/garuda-env-\(av_getpid()).txt"
        let wrote = "a long secret".withCString { text -> Bool in
            guard let file = fopen(path, "wb") else { return false }
            let written = fwrite(text, 1, strlen(text), file)
            fclose(file)
            return written > 0
        }
        try #require(wrote)
        defer { _ = path.withCString { av_unlink($0) } }

        var fromFile = AppEnvironment(reading(["JWT_KEY_FILE": path]))
        let read = fromFile.secretOrFile("JWT_KEY")
        #expect(read == "a long secret")
        try fromFile.check()
        // The file wins over the variable: that is what a mounted secret is.
        var both = AppEnvironment(reading(["JWT_KEY": "inline", "JWT_KEY_FILE": path]))
        let preferred = both.secretOrFile("JWT_KEY")
        #expect(preferred == "a long secret")
        var inline = AppEnvironment(reading(["JWT_KEY": "inline"]))
        let plain = inline.secretOrFile("JWT_KEY")
        #expect(plain == "inline")

        var missing = AppEnvironment(reading(["JWT_KEY_FILE": "/tmp/garuda-nothing-here.txt"]))
        let nothing = missing.secretOrFile("JWT_KEY")
        #expect(nothing == "")
        #expect(missing.problems.count == 1)
        #expect(missing.problems[0].contains("cannot be read"))
    }

    @Test func aSummaryHoldsSecretsBack() throws {
        var env = AppEnvironment(reading([
            "APP_ENV": "production",
            "DATABASE_URL": "postgres://app:secret@db:5432/shop?sslmode=require",
            "JWT_KEY": "the signing key",
            "POOL": "16",
        ]))
        _ = env.url("DATABASE_URL")
        _ = env.secretOrFile("JWT_KEY")
        _ = env.int("POOL", default: 8)
        _ = env.bool("SIGNUPS", default: true)
        // Read above, printed below.
        let summary = env.summary()
        #expect(summary.contains("APP_ENV       production"))
        #expect(summary.contains("postgres://app:***@db:5432/shop?sslmode=require"))
        #expect(!summary.contains("secret@"))
        #expect(summary.contains("JWT_KEY       set"))
        #expect(!summary.contains("the signing key"))
        #expect(summary.contains("POOL          16"))
        #expect(summary.contains("SIGNUPS       true"))
    }

    @Test func redactingAURL() throws {
        #expect(AppEnvironment.redacting("postgres://app:secret@db/shop") == "postgres://app:***@db/shop")
        // Nothing to hide, nothing changed.
        #expect(AppEnvironment.redacting("postgres://app@db/shop") == "postgres://app@db/shop")
        #expect(AppEnvironment.redacting("postgres://db/shop") == "postgres://db/shop")
        #expect(AppEnvironment.redacting("not a url") == "not a url")
        // A password holding an @: the credentials end at the last one.
        #expect(AppEnvironment.redacting("redis://user:pa@ss@host:6379") == "redis://user:***@host:6379")
    }

    @Test func theProcessEnvironmentIsTheDefaultSource() throws {
        setenv("GARUDA_ENV_TEST", "from the process", 1)
        var env = AppEnvironment()
        let set = env.string("GARUDA_ENV_TEST", default: "unset")
        let unset = env.string("GARUDA_ENV_TEST_UNSET", default: "unset")
        #expect(set == "from the process")
        #expect(unset == "unset")
        try env.check()
    }
}
