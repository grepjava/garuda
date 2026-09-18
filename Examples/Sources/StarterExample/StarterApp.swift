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
// 2. `app.state` builds the pool, the keys and the issuer in each worker,
//    after the fork. Nothing is shared between workers, so nothing is locked.
// 3. `app.prepare` migrates the schema and hashes the timing password, before
//    the worker accepts anything.
// 4. Middleware, then routes. What runs before a handler is registered before
//    it; MIDDLEWARE.md has the order to add things in.
//
// What is a flag and what is an environment variable: the server's own
// concerns (port, workers, TLS, body limits, rate limits) are flags, because
// the server parses them and CONFIG.md documents them. The application's
// concerns (database, signing key, sign-ups) are environment variables,
// because a deployment sets them as secrets.
//===----------------------------------------------------------------------===//

import Garuda

/// The starter application. Every worker builds its own state from
/// `configuration`.
public func starterApp(_ given: StarterConfiguration) -> Application {
    var configuration = given
    if configuration.signingKeyPEM == nil {
        // Development with no key given: one for this run, made here in the
        // parent so every worker signs and checks with the same one. Tokens
        // stop working when the process restarts, which is what a key nobody
        // wrote down means. Production is refused a default by
        // `fromEnvironment`.
        configuration.signingKeyPEM = try? JWTKey.generate(.ES256, keyID: "access").privatePEM
    }
    let settled = configuration
    let app = Application()

    // One state value per worker, built after the fork.
    app.state { _ in try Services(settled) } shutdown: { $0.close() }

    // Before this worker serves: the schema, and the hash a login for an
    // unknown email is checked against. Every worker runs it; the first to
    // take the advisory lock migrates and the rest find nothing to do.
    app.prepare { start in
        try await start.state(Services.self).warmUp()
    }

    // What signs and checks access tokens, so `JWT<AccessClaims>` works in
    // any route.
    // The same key the issuer signs with, so a token this application made
    // verifies in any of its routes.
    app.jwtVerifier { _ in try Services.keys(for: settled) }

    // Housekeeping: a refresh token whose family has ended is of no use to
    // anyone. Hourly, in one worker, a minute after it starts so a deployment
    // is not spent on cleaning up.
    app.every(3600, firstAfter: 60, onWorker: 0) { start in
        let store = PostgresRefreshTokenStore(try start.state(Services.self).pool)
        let removed = try await store.deleteExpired()
        if removed > 0 { AppLog.info("cleared expired refresh tokens", ["count": "\(removed)"]) }
    }

    app.securityHeaders()

    // Liveness: no database, so it answers while the database is down and a
    // supervisor does not restart a worker for something it cannot fix.
    app.get("/health") { "ok" }
        .summary("Whether this worker is running")
        .tags("ops")

    // Readiness: takes a connection from the pool, so a load balancer stops
    // sending traffic to a worker whose database has gone.
    app.get("/ready") { (services: State<Services>) async throws -> String in
        struct One: Decodable { let one: Int }
        guard try await services.value.pool.first(One.self, "select 1 as one")?.one == 1 else {
            throw HTTPError(.serviceUnavailable, "the database did not answer")
        }
        return "ready"
    }
        .summary("Whether this worker can reach the database")
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
