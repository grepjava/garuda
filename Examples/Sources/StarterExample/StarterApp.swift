//===----------------------------------------------------------------------===//
// The application, put together: configuration, state, start-up work,
// middleware, routes, and the two paths a deployment needs.
//
//   swift run starter migrate         apply migrations and exit
//   swift run starter -- --port 8080  serve
//
// The order things happen in, and why:
//
// 1. `StarterConfiguration.fromEnvironment` reads and checks the environment
//    before anything else. A bad environment fails here, with every problem
//    listed, rather than on a request.
// 2. `app.state` builds the pool, the keys, the issuer and the hash a login
//    for an unknown email is checked against, in each shard as it starts.
//    Nothing is shared between shards, and nothing in it changes once built,
//    so the shard's threads share it without a lock.
// 3. `app.onShardStart` migrates the schema and names the administrators,
//    before the shard accepts anything.
// 4. Middleware, then routes. What runs before a handler is registered before
//    it; MIDDLEWARE.md has the order to add things in.
//
// What is a flag and what is an environment variable: the server's own
// concerns (port, shards, TLS, body limits, rate limits) are flags, because
// the server parses them and CONFIG.md documents them. The application's
// concerns (database, signing key, sign-ups) are environment variables,
// because a deployment sets them as secrets.
//===----------------------------------------------------------------------===//

import GarudaPostgres

/// The starter application. Every shard builds its own state from
/// `configuration`.
///
/// With no signing key, one is made up here, which serves one process. A
/// server of several shards needs every shard to sign with the same key, so
/// `starter serve` makes it before this, and hands it on in the environment.
public func starterApp(_ given: StarterConfiguration) -> Application {
    let settled = given.withDevelopmentKey()
    let app = Application()

    // One state value per shard, built as it starts.
    app.state { _ in try await Services.make(settled) } shutdown: { $0.close() }

    // Before this shard serves: the schema, and the administrators the
    // deployment names. Every shard runs it; the first to take the advisory
    // lock migrates and the rest find nothing to do.
    app.onShardStart { start in
        try await start.state(Services.self).prepare()
    }

    // What signs and checks access tokens, so `JWT<AccessClaims>` works in
    // any route.
    // The same key the issuer signs with, so a token this application made
    // verifies in any of its routes.
    app.jwtVerifier { _ in try Services.keys(for: settled) }

    // Housekeeping: a refresh token whose family has ended is of no use to
    // anyone. Hourly, in one shard, a minute after it starts so a deployment
    // is not spent on cleaning up.
    app.every(.seconds(3600), firstAfter: .seconds(60), onShard: 0) { start in
        let store = PostgresRefreshTokenStore(try start.state(Services.self).pool)
        let removed = try await store.deleteExpired()
        if removed > 0 { AppLog.info("cleared expired refresh tokens", ["count": "\(removed)"]) }
    }

    app.securityHeaders()

    // Liveness: no database, so it answers while the database is down and a
    // supervisor does not restart a shard for something it cannot fix.
    app.get("/health") { "ok" }
        .summary("Whether this shard is running")
        .tags("ops")

    // Readiness: takes a connection from the pool, so a load balancer stops
    // sending traffic to a shard whose database has gone.
    app.get("/ready") { (services: State<Services>) async throws -> String in
        struct One: Decodable { let one: Int }
        guard try await services.value.pool.first(One.self, "select 1 as one")?.one == 1 else {
            throw HTTPError(.serviceUnavailable, "the database did not answer")
        }
        return "ready"
    }
        .summary("Whether this shard can reach the database")
        .tags("ops")
        .response(.serviceUnavailable, "The database did not answer")

    // One feature per file. Accounts takes the application, because it needs
    // the configuration; notes is a `Router`, which is a feature as a value:
    // mounted here, and mountable on an application of its own in a test.
    addAccountRoutes(app, settled)
    app.nest("/notes", noteRoutes())
    app.nest("/admin", adminRoutes())

    if let path = settled.documentationPath {
        app.openAPI(OpenAPIInfo(title: "Starter", version: "1.0.0",
                                description: "Accounts and notes: the shape of an application built on Garuda."),
                    path: path + "/openapi.json")
        app.swaggerUI(path: path, openAPIPath: path + "/openapi.json")
    }

    return app
}

extension Services {
    /// The signing keys, from the configuration alone: the issuer and the
    /// verifier both build them, and both must get the same key.
    static func keys(for configuration: StarterConfiguration) throws -> JWTKeys {
        guard let pem = configuration.signingKeyPEM else {
            throw HTTPError(.internalServerError, "no signing key; starterApp makes one for development")
        }
        return try JWTKeys([try JWTKey.pem(pem, algorithm: .ES256, keyID: "access")])
    }
}
