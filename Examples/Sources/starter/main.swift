// A production-shaped application: accounts, notes, PostgreSQL, migrations,
// configuration from the environment, and a deployment recipe
// (Examples/STARTER.md).
//
//   createdb starter
//   swift run starter migrate                 apply migrations and exit
//   swift run starter serve -- --port 8080    serve
//
//   curl -s localhost:8080/auth/signup -d '{"email":"ada@example.com","password":"correct horse"}'
//   TOKENS=$(curl -s localhost:8080/auth/login -d '{"email":"ada@example.com","password":"correct horse"}')
//   ACCESS=$(printf '%s' "$TOKENS" | sed 's/.*"access_token":"\([^"]*\)".*/\1/')
//   curl -s localhost:8080/notes -H "authorization: Bearer $ACCESS" -d '{"title":"First"}'
//   curl -s localhost:8080/notes -H "authorization: Bearer $ACCESS"
//   open localhost:8080/docs
//
// DATABASE_URL, JWT_PRIVATE_KEY and the rest are in
// Sources/StarterExample/Configuration.swift; `starter env` prints them.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Garuda
import StarterExample

/// The environment is read before anything else, and every problem with it is
/// printed at once.
let configuration: StarterConfiguration
do {
    configuration = try StarterConfiguration.fromEnvironment()
} catch {
    StandardError.put("starter: \(error)\n")
    exit(78)  // EX_CONFIG
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "serve" {
case "migrate":
    // The schema, without serving anything. Shards migrate for themselves
    // too, so this is for a deployment that migrates before it rolls out.
    do {
        let applied = try withServices(configuration) { services in
            try await services.pool.migrate(starterMigrations)
        }
        print(applied == 0 ? "starter: the schema is already up to date"
                           : "starter: applied \(applied) migration\(applied == 1 ? "" : "s")")
        exit(0)
    } catch {
        StandardError.put("starter: migrations failed: \(error)\n")
        exit(1)
    }

case "env":
    // What the environment said, as the application read it: secrets held
    // back and the database password taken out.
    print(configuration.summary)
    exit(0)

case "serve":
    // A development key, made up for this run when none was given, goes into
    // the environment as well. On Linux each shard is a fork of this process
    // and has the key already; on macOS a shard is this program started
    // again, and reads the key from the environment like any other setting.
    // Either way every shard signs with the same key.
    let serving = configuration.withDevelopmentKey()
    if configuration.signingKeyPEM == nil, let pem = serving.signingKeyPEM {
        setenv("JWT_PRIVATE_KEY", pem, 1)
    }
    // Everything after `serve` is Garuda's own: --port, --shards, --tls-*,
    // --rate-limit, --access-log (CONFIG.md). A leading `--` is what
    // `swift run starter serve -- --port 8080` leaves behind. `run` reads
    // the flags after the program's name, as it does CommandLine.arguments.
    var flags = Array(CommandLine.arguments.dropFirst(2))
    if flags.first == "--" { flags.removeFirst() }
    starterApp(serving).run(arguments: [CommandLine.arguments[0]] + flags)

case let unknown:
    StandardError.put("starter: unknown command \"\(unknown)\"; try serve, migrate or env\n")
    exit(64)  // EX_USAGE
}

/// Standard error, without Foundation.
enum StandardError {
    static func put(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { raw in
            raw.baseAddress.map { write(2, $0, raw.count) } ?? 0
        }
    }
}
