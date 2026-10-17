<p align="center">
  <img src="assets/garuda.png" alt="Garuda, a Swift server framework" width="720">
</p>

# Garuda

Garuda is a Swift web framework and the HTTP server underneath it. It is my attempt to create a spiritual successor to [Kitura](https://github.com/Kitura/Kitura): a server written in Swift, with its own HTTP engine, for the protocols and the application features a production service needs today.

The application API is modelled after [axum](https://github.com/tokio-rs/axum). Routes, typed extractors, and the set of features a production framework is expected to offer follow axum's shape. [Garuda and axum](#garuda-and-axum) compares the two area by area. The HTTP engine is Garuda's own.

The same route in each. axum names the parameter in braces; Garuda uses a colon. Both take it as a typed `Path` and answer JSON.

```rust
// axum
async fn person(Path(id): Path<i32>) -> Json<Person> {
    Json(Person { id, name: "Ada".into() })
}

let app = Router::new().route("/person/{id}", get(person));
```

```swift
// Garuda
app.get("/person/:id") { (id: Path<Int>) async in
    JSON(Person(id: id.value, name: "Ada"))
}
```

This is Garuda 2. It runs on [Vega](https://github.com/grepjava/vega), a
work-stealing runtime for Swift in the shape of Tokio and an alternative to
SwiftNIO ([how they compare](https://github.com/grepjava/vega#vega-swiftnio-and-tokio)): an idle thread takes a
waiting task from a busy one, at any `await`. Every handler is async, and a
handler that does not suspend runs inline in the task that read its request,
with no hop onto another executor and nothing allocated. The engine parses
HTTP/1.1, HTTP/2 and HTTP/3 itself, the last on Garuda's own QUIC.

A supervisor starts **shards**. A shard is a process with its own Vega runtime
over several threads, so work is stolen between the threads of a shard and
never between shards. That boundary matters more in Swift than in Rust: a
force-unwrapped `nil` ends the process, where Tokio catches a panic inside the
task that raised it. Here a crash takes only that shard's connections, and the
supervisor starts the shard again. [Shards are processes](#shards-are-processes)
has the rest, and [ARCHITECTURE.md](ARCHITECTURE.md) the design.

Swift 6.2 or newer. No Foundation, no SwiftNIO.

This project is an independent effort. It is not an IBM product, and it is not a continuation maintained by the Kitura project.

<p align="center">
  <a href="https://github.com/grepjava/garuda/blob/main/LICENSE"><img src="https://img.shields.io/github/license/grepjava/garuda" alt="MIT license"></a>
</p>

**Garuda 2.0.0 is released** (2026-10-16; [RELEASE.md](RELEASE.md) has what
changed). Garuda 1 (1.1) stays on the `release/1.x` branch.
[COMPATIBILITY.md](COMPATIBILITY.md) is the guide to moving from Garuda 1 to
Garuda 2, and [Status](#status) below lists what Garuda 2 does not have yet.

## Features

| Area | What Garuda provides |
| --- | --- |
| HTTP | HTTP/1.1 with a parser strict where that prevents request smuggling, HTTP/2 over TLS and in cleartext, and HTTP/3 over QUIC |
| TLS and certificates | TLS 1.2 and 1.3 on BoringSSL (the default) or the system's OpenSSL 3, several certificates chosen by SNI, and certificates reloaded from disk without a restart |
| Handlers | Routes, groups, and middleware that wraps the handler. One async handler API on Vega's work-stealing shards; a route that holds its thread for long runs in the heavy lane, and a blocking one can be offloaded |
| Typed API | Extractors for path, query, JSON body, form, and multipart. Answers as JSON, HTML, text, bytes, or a redirect. A type can validate its values; every broken rule is returned together as 422 |
| OpenAPI | An OpenAPI 3.1 document generated from the routes, and Swagger UI |
| Application middleware | Deadlines, CORS, bearer and basic authentication, authorization policies, CSRF protection, security headers, signed and encrypted cookies, and sessions in memory, Redis, or SQLite |
| Identity | JWT (HS, RS, PS, ES, and EdDSA), JWKS verification, rotating refresh tokens, and PBKDF2-HMAC-SHA256 password hashing |
| HTTP client | HTTP/1.1 and HTTP/2, redirects by policy, decompression, streamed response bodies, and server-sent events |
| Data | PostgreSQL, Redis (including Redis Cluster and Sentinel) and SQLite, from [vega-db](https://github.com/grepjava/vega-db) through `GarudaPostgres`, `GarudaRedis` and `GarudaSQLite` |
| Streaming | Streamed responses, request bodies read as they arrive, server-sent events, broadcast across shards, and interim 1xx responses such as 103 Early Hints |
| Uploads | Resumable uploads (draft-ietf-httpbis-resumable-upload) through `GarudaUploads`: the body goes to disk as it arrives, and a client whose connection drops asks how much arrived and sends the rest |
| WebSockets | WebSockets over HTTP/1.1, HTTP/2, and HTTP/3. The engine joins fragments, checks UTF-8, answers pings, and supports permessage-deflate |
| WebTransport | WebTransport over HTTP/3 on the same port and routes, with bidirectional and unidirectional streams and datagrams |
| Files and compression | Static files with ETag and byte ranges, including precompressed copies. Response and request compression with brotli, zstd, and gzip |
| Request limits | A body limit and a concurrency limit on a group of routes. Rate limiting counted across shards |
| Edge policy | HTTPS redirect, HSTS, trusted proxy headers, allowed hosts, and client address allow and deny lists |
| Operations | Prometheus metrics, health checks, request IDs, W3C trace context, an access log, a response cache shared by the shards, graceful shutdown with a drain delay, and a rolling restart on SIGHUP. Unix sockets and more than one shard |
| Tracing | Spans through swift-distributed-tracing for the request, outbound HTTP, PostgreSQL, and Redis |
| Tests | `app.test`, from `GarudaTesting`, runs requests through the real HTTP/1 connection over an in-memory stream, and has an HTTP/2 client too. The parsers that read the network are fuzzed (`pgfuzz`) |
| Process model | A supervisor starts shard processes, each a work-stealing runtime over several threads. In-memory state is per shard |
| Platforms | Linux, and macOS 26.4 or newer, on Swift 6.2 or newer. Windows is experimental, and serves in one process only |

Not in Garuda 2: a built-in ACME client, QUIC 0-RTT and session resumption,
kernel TLS, `multipart/byteranges`, and reads from Redis replicas.
[What Garuda 2 does not have](COMPATIBILITY.md#what-garuda-2-does-not-have)
lists what Garuda 1 had.

[BENCHMARKS.md](BENCHMARKS.md) has the benchmark method and
[Garuda 2 against Garuda 1 and axum](BENCHMARKS.md#garuda-2-against-garuda-1-and-axum),
measured on the same clock-capped machine, with links to the code each server
runs.

## Quick start

```bash
swift build -c release
.build/release/garuda --port 8000
curl -i http://127.0.0.1:8000/user/42
```

The `garuda` binary serves a small benchmark application. Your own application
depends on the `Garuda` library:

```swift
// Package.swift
platforms: [.macOS("26.4")],
dependencies: [.package(url: "https://github.com/grepjava/garuda", from: "2.0.0")],
targets: [.executableTarget(name: "app", dependencies: [.product(name: "Garuda", package: "garuda")])]
```

```swift
// Sources/app/main.swift
import Garuda

struct Person: Codable { let id: Int; let name: String }

let app = Application()
app.get("/person/:id") { (id: Path<Int>) async in
    JSON(Person(id: id.value, name: "Ada"))
}
app.run()
```

`app.run()` reads the same command-line flags as the `garuda` binary, and does
not return. Swift 6.2 or newer, on Linux or macOS 26.4 -- 6.2 because a
borrowed body is a `Span`, macOS 26.4 because Vega's executor needs that
release's runtime. [INSTALLATION.md](INSTALLATION.md) lists the system
packages, the TLS library traits and certificates.

The databases, resumable uploads and the test client are products of their
own: `GarudaPostgres`, `GarudaRedis`, `GarudaSQLite`, `GarudaUploads` and
`GarudaTesting`.

[Examples/](Examples/README.md) has eight complete applications to run and
copy from, all on Garuda 2: a todo API, sign-in, streaming, chat,
WebTransport, a file service, per-user uploads, and a starter.

## Writing handlers

### Routes and typed handlers

Routes are registered with `get`, `head`, `post`, `put`, `delete`, `patch`, `options`, or `on`. A path segment is a literal, a parameter (`:param`), or a trailing rest segment (`*rest`). HEAD falls back to GET, and a known path under the wrong method is 405 with `Allow`.

A handler declares what it needs and returns what it means:

```swift
app.get("/search") { (query: Query<Search>) async in JSON(results(for: query.value)) }
app.post("/people") { (body: Body<NewPerson>) async in JSON(create(body.value), status: .created) }
app.post("/login") { (form: Form<Credentials>) async in Redirect(to: "/") }
```

- **Extractors:** `Path<T>` (the next path parameter, percent-decoded),
  `Query<T>`, `Body<T>` (JSON), `Form<T>`, `Multipart`, `State<T>`,
  `Context<Key>`, or your own `RequestExtractor`, whose `extract` may await --
  to load the signed-in user from a database, say. `E?` is nil where `E`
  would refuse, and `Result<E, any Error>` hands the handler the refusal. A
  value that will not decode is a 400 that says what was wrong.
- **Answers:** `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an
  `HTTPStatus`, or an Optional whose `nil` is a 404.
- **Errors:** a thrown `ResponseError` is the response.
  `throw HTTPError(.conflict, "the name is taken")` answers 409 with
  `{"error":"the name is taken"}`. Anything else thrown is a 500 and a log line.
- **Rules:** a type saying what its values have to be, beyond their shape, conforms to `Validated`, and whatever is decoded from a request is held to them before the handler runs.

```swift
struct NewOrder: Decodable, Validated {
    let quantity: Int
    let email: String

    func validate(_ check: inout Validation) {
        check.range("quantity", quantity, atLeast: 1, atMost: 100)
        check.email("email", email)
    }
}
```

Every broken rule is answered at once, as 422 with the fields named: `{"error":"quantity must be at least 1","fields":[{"field":"quantity","message":"must be at least 1"}]}`. A decoding failure fills `fields` the same way, from the path it already reports, so one answer tells a form where each message goes whichever of the two refused the request.

Handler closures are `@Sendable`: the threads of a shard run them at once, so
what they capture must be safe to share.

JSON goes through Garuda's own coder over `Encodable` and `Decodable`, which
reads only the keys a type asks for, straight from the request bytes. `@JSON`
takes a type off `Codable` altogether:

```swift
import GarudaJSON

@JSON struct Order: Codable {
    let id: Int
    let name: String
    let tags: [String]
}
```

Nothing at the call site changes -- the same `Body<Order>`, the same
`JSON(order)` -- and the type keeps `Codable` for everything else.
`@PostgresRow`, from `GarudaSQL`, does the same for a database row: a
property is read from the column of its own name. The macro writes the
reading and the writing out longhand, and the bytes are the same ones Codable
sent; on the JSON workload it takes about a fifth off the time a request
takes. It lives in its own module because it is the only part of Garuda that
needs swift-syntax.

### The raw layer

Under the typed API, a handler can take the request and response directly:

```swift
app.get("/user/:id") { request, response in
    request.withParameter(0) { response.send($0) }   // lent bytes, no copy
}
```

`Request` and `Response` are `~Copyable`. The request lends its bytes to a
closure as a `Span`, which the compiler keeps from escaping (`withPath`,
`withHeader`, `withBody` and others). `path`, `header(_:)`, `body` and the rest
return owned copies.

### Deadlines and the HTTP client

```swift
app.deadline(.milliseconds(500)) {
    app.get("/weather/:city") { request, response in
        let city = request.parameter(0)
        let answer = try await HTTPClient().get("https://api.example.com/\(city)")
        response.send(bytes: answer.body, contentType: "application/json")
    }
}
```

A request still unanswered at its deadline is answered 504. A deadline bounds
waits on I/O -- sockets, pipes, databases -- and not computing, a
`Runtime.sleep` or a child task's wait. On HTTP/2 and HTTP/3 a reset stream
cancels its handler's task, and `Task.isCancelled` sees it.

`HTTPClient` is a value, made wherever it is needed. It speaks HTTP/1.1, and
HTTP/2 over TLS when the server offers it, and keeps connections for reuse in
the shard. It asks for gzip, deflate, brotli and zstd and decodes what comes
back, and it follows redirects only when `client.redirects` says to:
`.sameOrigin()`, `.any()` or `.matching { url in … }`. `client.timeout` bounds
each wait; `client.totalTimeout` bounds the whole exchange, redirects
included.

`client.stream` returns once the response head is in, and the body is read as
it arrives -- a large file relayed on, an upstream's server-sent events, a
model's tokens -- rather than held whole:

```swift
app.get("/relay") { request, response in
    let upstream = try await HTTPClient().stream(.get, "https://llm.example/v1/stream")
    let body = response.stream(contentType: "text/event-stream")
    while let event = try await upstream.nextEvent() {
        try await body.write("data: \(event.data)\n\n")
    }
}
```

A streamed response is not held to `maxBodyBytes`. A caller that stops reading
stops the upstream: over HTTP/1.1 by TCP's window, over HTTP/2 because the
stream's window opens only as the caller reads.

### State, groups and middleware

```swift
import GarudaPostgres

struct User: Codable, Sendable { let id: Int; let name: String }
enum CurrentUser: RequestContextKey { typealias Value = User }

app.state { _ in PostgresPool(PostgresConfiguration(host: "db", user: "app", password: secret)) }

app.group("/api") {
    app.cors(CORSPolicy(origins: ["https://app.example.com"], allowCredentials: true))
    app.authenticate(bearer: CurrentUser.self, state: PostgresPool.self) { token, db in
        try await db.first(User.self, "select id, name from users where token = $1", token)
    }
    app.use { request, response, next in
        try await next()
        response.addHeader("cache-control", "no-store")
    }
    app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws in
        try await db.value.first(User.self, "select id, name from users where id = $1", id.value).map { JSON($0) }
    }
}
```

- `app.state` builds a value once in each shard, before it accepts a
  connection, and every thread of the shard shares it, so it is `Sendable`.
  One value per type; registering a type twice is refused. `onShardStart` and
  `onShardStop` run hooks as a shard starts and stops.
- `app.problems()` is what the routes cannot do, found before serving: a
  handler taking more `Path` extractors than its pattern has parameters, or
  asking for a `State<T>` nothing registered. `run()` logs them and exits 2
  instead of starting, and a test can assert `app.problems().isEmpty`.
- `app.use` wraps every route in its scope, whether it is called before or
  after the routes. It calls `next()` to run the rest of the chain, or answers
  without calling it; after `next()` it can change the status and headers, or
  catch what the handler threw. `response.onSend` sees and changes the final
  response, whoever answered.
- `request[context: Key.self]` carries values from middleware to the handler,
  which reads them with `Context<Key>`.
- `app.cors` sets the scope's CORS policy. It answers preflights, including to
  paths routed only for other methods, and runs ahead of the scope's
  middleware, so a preflight never meets authentication and a 401 still
  reaches the page.
- `app.authenticate(bearer:)` and `app.authenticate(basic:)` read the
  Authorization header and keep who it belongs to in the context, or answer
  401 with the challenge. With `state:`, the check is handed what `app.state`
  built, such as the database sessions live in. `BearerToken` and
  `BasicCredentials` are the same as extractors, and `constantTimeEquals`
  compares secrets.
- `app.authorize(CurrentUser.self, .admin)` requires a named rule of every
  route in the scope, once `authenticate` has said whose request it is. A
  `Policy` is `(Value) -> Bool` with a name, combined with `and`, `or` and
  `about`, and callable in a test without a request. A rule that does not hold
  is 403 saying what would have been enough; nobody under the key is 401.
  `authorize(jwt:)` reads the claims a scope verified, and
  `Policy.scope("orders:write")` an OAuth 2.0 scope in them. Both
  `authenticate` and `authorize` add what they can answer, and the security
  scheme, to every route of the scope in the OpenAPI document.
- `JWT<Claims>` takes a verified JSON Web Token (HS, RS, PS, ES or EdDSA),
  keys from PEM, JWK or a secret, with `exp`, `nbf`, `iss` and `aud` checked;
  `keys.sign(claims)` issues one and `keys.publicJWKS` publishes the key set.
  `JWKSVerifier` checks tokens from an identity provider against its JWK Set.
  `TokenIssuer` pairs short-lived access tokens with refresh tokens that rotate
  on every use and revoke their whole chain when a spent one is reused.
- `Passwords.hash` and `Passwords.verify` use PBKDF2-HMAC-SHA256 on Vega's
  blocking pool. `Tokens.random()` makes a session token and `Tokens.digest`
  what to store in its place.
- `request.log.info("order placed", ["order": "\(id)"])` writes to the
  application log with the request's method, path, request ID and trace
  context on the line. `AppLog` is the same log outside a request.
  `--log-format json` makes every line one JSON object.
- `app.onResponse { done in … }` sees every request once it is answered: the
  matched route's pattern, status, duration, request ID and trace, and why a
  route failed. This is what per-route metrics or error reporting hang from.
- `app.maxBodySize(64 << 20) { … }` gives a scope's routes a body limit of
  their own in place of `--max-body`, applied before the body is read.
  `app.concurrencyLimit(8) { … }` lets that many of a scope's handlers run at
  once in each shard, and answers the next 503.
- `request.cookie("theme")` and `response.setCookie(Cookie("theme", "dark"))`
  read and set cookies. A cookie is `Path=/`, `HttpOnly` and `SameSite=Lax`
  unless it says otherwise, and `Secure` over HTTPS. With a `CookieKey`, a
  cookie is signed (HMAC-SHA256) or encrypted (AES-256-GCM), and one that was
  tampered with reads as absent. The key takes previous secrets for rotation.
- `app.sessions(store: …)` gives a scope's routes a `Session`: a map of strings
  kept in memory, Redis or SQLite, found by a random ID in a cookie.
  `try await session.set("user", id)` writes it to the store before it returns.
  `session.renew()` moves it to a new ID at login, and `session.destroy()`
  deletes it and its cookie. A `MemorySessionStore` belongs to one shard.
- `app.csrfProtection()` refuses, with 403, a POST, PUT, PATCH or DELETE that
  the browser says another site's page started, from Sec-Fetch-Site or else
  Origin against Host. It needs no tokens in forms. `trustedOrigins` lets a
  front end on another origin through.
- `app.securityHeaders()` puts nosniff, frame, referrer and cross-origin
  policies on every answer in its scope, and Strict-Transport-Security on
  those over HTTPS. A Content-Security-Policy is one field away, and a header a
  route sets itself is kept.
- `app.trailingSlash(.redirect)` answers `/users/` with a 308 to `/users` when
  only that is routed, and `.ignore` serves it from `/users` directly. Routes
  match exactly by default.
- `app.requestDecompression()` decodes a gzip, deflate, br or zstd request body
  before the handler reads it, held to the route's body limit as it inflates.
- `app.allowedHosts(["example.com", "*.example.com"])` answers 400 to a request
  for any other Host, and `app.addressFilter(allow: ["10.0.0.0/8"])` answers
  403 to a client address outside the list or on a `deny` list.

[MIDDLEWARE.md](MIDDLEWARE.md) has every piece in detail, and how to write
your own.

### Slow and blocking handlers

A route whose handler holds its thread for longer than `--heavy-threshold`
(500 microseconds by default) on average, without suspending, becomes
**heavy**: it runs only once it holds one of the shard's heavy-lane permits,
of which there are half as many as threads. Quick requests always have
threads left. A route that computes between awaits, which the average does
not see, is registered heavy from the start:

```swift
app.heavy.get("/report/:id") { (id: Path<Int>) in render(report: id.value) }
```

A handler that blocks its thread without computing -- a synchronous file read,
a C library that waits -- is offloaded instead. Its synchronous handler runs
on Vega's blocking pool, and the answer is written back on the shard's
threads:

```swift
app.offload.get("/thumbnail/:name") { (name: Path<String>) -> Bytes in
    Bytes(try makeThumbnail(name.value), contentType: "image/png")
}
```

### Tracing

`app.tracing()` traces through
[swift-distributed-tracing](https://github.com/apple/swift-distributed-tracing),
so any tracer written for it records the spans, the OpenTelemetry exporters
among them:

```swift
import Tracing

app.onShardStart { _ in
    InstrumentationSystem.bootstrap(makeTracer())   // any Tracer
}
app.tracing()
```

Each request is a server span named for its route, `GET /users/:id`,
continuing the trace its headers carry. Under it are child spans for every
call `HTTPClient` makes, which passes the trace on in its headers, and for
every PostgreSQL statement and Redis round trip. Spans a handler starts with
`withSpan` go under it too. The attributes follow OpenTelemetry's HTTP and
database conventions. SQL is recorded as written; bound values, Redis keys and
values, and query-string values in URLs are not. A streamed response's span
ends with its last byte, not its head.

Shards are processes, and an exporter's threads do not survive the fork, so
the tracer is made in each shard: bootstrap it in `onShardStart`, or pass
`app.tracing { shard in … }` a closure that returns one. With tracing off,
each request pays one check.

### OpenAPI

`app.openAPI(OpenAPIInfo(title: "Shop", version: "1.0.0"))` serves an OpenAPI
3.1 document at `/openapi.json`, and `app.swaggerUI()` serves Swagger UI at
`/docs`. The document comes from the routes: a typed route's extractors and
return type give its parameters, request body, security and response, with
JSON Schemas read from the `Decodable` types, so nothing needs annotating.
Every route method returns an `OpenAPIOperation` for what types cannot say:

```swift
app.get("/orders/:id") { (id: Path<Int>) async throws in JSON(try await order(id.value)) }
    .summary("An order by its number")
    .tags("orders")
    .response(.notFound, "No order has that number")
```

### Databases

The drivers are vega-db's, on Vega's sockets and TLS, so a query is an await
like any other on the shard's threads. Each product re-exports its driver
with `Garuda`, and joins it to Garuda's `UUID`, `Timestamp` and JSON coder. A
pool is made in `app.state`, so each shard has its own: a pool of 8
connections is 8 per shard.

**PostgreSQL** (`GarudaPostgres`) supports SCRAM-SHA-256, TLS (required by
default) and a pool with an acquire timeout. Rows decode into `Decodable`
types by column name. `db.transaction { tx in … }` commits or rolls back.
Statements stay prepared on each connection, and values are read in binary.
`UUID`, `Timestamp`, `PostgresDate`, `PostgresTime`, `PostgresInterval`,
`PostgresNumeric` (exact, kept as its digits) and `PostgresJSON<T>` come
without Foundation. An array column is a Swift list, and a list binds as one.
`app.listen` hears `NOTIFY` in each shard, on a connection of its own,
reconnecting with its channels when the server restarts. `copyIn` and
`copyOut` are `COPY` in both directions, and `pool.migrate` brings a schema up
to date.

**Redis** (`GarudaRedis`):

```swift
import GarudaRedis

app.state { _ in RedisPool(RedisConfiguration(host: "cache", password: secret)) }

app.get("/visits/:page") { (page: Path<String>, redis: State<RedisPool>) async throws in
    String(try await redis.value.incr("visits:\(page.value)"))
}
```

RESP3 through HELLO, and RESP2 for servers older than Redis 6; Valkey works
the same. TLS is required by default, and ACL users, databases and unix
sockets are supported. Commands come with typed replies, and `send` takes any
other. `pipeline` and `transaction` go in one round trip, `session` holds one
connection for WATCH, and `subscribe` listens to channels and patterns on a
connection of its own. `RedisCluster` is the same API across a cluster,
following `MOVED` and `ASK`, and `RedisSentinelPool` finds the master through
a set of sentinels. Garuda's session and refresh-token stores work on either.

**SQLite** (`GarudaSQLite`):

```swift
import GarudaSQLite

app.state { _ in
    let db = try SQLiteDatabase(SQLiteConfiguration(path: "/var/lib/app/app.db"))
    try await db.migrate(["create table notes (id integer primary key, text text not null)"])
    return db
}

app.get("/note/:id") { (id: Path<Int>, db: State<SQLiteDatabase>) async throws in
    try await db.value.first(Note.self, "select id, text from notes where id = ?", id.value).map { JSON($0) }
}
```

The system's libsqlite3 is loaded at run time, and every statement runs on
Vega's blocking pool, so the shard keeps serving while SQLite reads the disk
or waits for another process's lock. Each database has one connection that
writes and up to four that read, in write-ahead-log mode. Transactions begin
IMMEDIATE, and `migrate` brings the schema up to date by `user_version`.

[CONNECTORS.md](CONNECTORS.md) has the HTTP client and every driver in detail,
with their limits.

### Streaming, server-sent events, WebSockets and WebTransport

```swift
app.get("/export") { () async -> StreamingBody in
    StreamingBody(contentType: "text/csv") { body in
        for row in rows { try await body.write(row.csv) }   // waits while the client is behind
    }
}

app.get("/ticks") { () async -> EventStream in
    EventStream { events in
        for i in 0... { try await events.send("tick \(i)"); try await events.sleep(for: .seconds(1)) }
    }
}

app.webSocket("/chat/:room") { (ws: WebSocket, room: Path<String>) async throws in
    for try await message in ws { try await ws.send(message) }   // whole messages
}

struct Said: Codable { var text: String }
let lobby = Topic("lobby")
app.post("/say") { (said: Body<Said>) async throws in
    try lobby.publish(said.value.text, event: "said")   // heard by subscribers on every shard
    return HTTPStatus.noContent
}
app.get("/lobby") { (last: LastEventID) async -> EventStream in
    EventStream { events in try await events.forward(lobby, after: last) }   // replays what a reconnect missed
}

app.webTransport("/room/:id") { (session: WebTransportSession, id: Path<Int>) async throws in
    while let stream = try await session.acceptStream() { /* read and write */ }
}
```

A streamed body is chunked on HTTP/1.1 and DATA frames on HTTP/2 and HTTP/3.
A write waits while more than 512 KiB is queued (`writeHighWaterMark`), and a
throw part-way resets the stream rather than ending it cleanly. A WebSocket
handler sees whole messages: the engine joins fragments, checks UTF-8, answers
pings, sends keepalive pings, runs the close handshake and, with
`--ws-compress`, permessage-deflate. Messages the handler has not read wait in
a bounded queue, and past it the socket is not read, so a fast sender is
slowed. A send on a socket whose connection has ended throws
`WebSocketError.closed`, so a room holding sockets learns who has gone rather
than writing to them. The same route serves WebSockets over HTTP/1.1, HTTP/2
and HTTP/3; on the last two, flow control slows just that stream. WebTransport
runs over HTTP/3 on the same port and routes, with bidirectional and
unidirectional streams, datagrams and close codes.

A `Topic`'s messages cross shards through a ring in shared memory
(`--broadcast-size`), which also keeps recent messages for `Last-Event-ID`.
`response.sendInterim` sends 1xx responses such as 103 Early Hints.

A route's request body is collected whole before the handler runs, held to
`--max-body` or the scope's `maxBodySize`, unless the route reads it as it
arrives:

```swift
app.onStreamingBody(.put, "/uploads/:name", maxBodySize: 10 << 30) { request, response, body in
    var buffer = IOBuffer(capacity: 256 * 1024)   // Vega's
    while try await body.read(into: &buffer) > 0 {
        try await file.write(buffer)              // a VegaFS File
        buffer.clear()
    }
    response.send(status: .created)
}
```

This works over HTTP/1.1, HTTP/2 and HTTP/3. Reading is what lets more in: the
HTTP/2 or HTTP/3 window is given back as the handler reads, so a slow disk
slows its own upload and nothing else. `body.read(maxBytes:)` and
`body.readAll(maxBytes:)` hand over `[UInt8]`; `bytesRead`, `expectedLength`
and `cancel()` are there too. A body that passes `maxBodySize` throws
`RequestBodyError.tooLarge`, answered 413. A request that ends before its body
did hands over every byte that arrived and then throws `.incomplete`, answered
400; a reset HTTP/2 or HTTP/3 stream ends a streaming handler this way rather
than cancelling it. [HANDLER-API.md](HANDLER-API.md#request-bodies-read-as-they-arrive)
has the details.

### Resumable uploads

```swift
import GarudaUploads

let store = try FileUploadStore(directory: "/var/lib/app/uploads")
app.resumableUploads("/files", store: store,
                     limits: UploadLimits(maxSize: 10 << 30)) { upload in
    try await FileSystem.rename(upload.path, to: "/srv/files/\(upload.info.id)")   // VegaFS
    return JSON(["size": upload.length], status: .created)
}
```

`GarudaUploads` implements the IETF's resumable uploads
(draft-ietf-httpbis-resumable-upload, interop version 9) over HTTP/1.1,
HTTP/2 and HTTP/3. A client that speaks it learns where its upload lives (in
a 104 before a byte of the body is read, when it sends interop version 9),
and if the connection drops, it asks that URL how much arrived (`HEAD`) and
sends the rest (`PATCH`) as many times as it takes. A client that does not
speak it sends an ordinary `POST`. Either way the handler is called once,
with the whole file on disk, and its answer is the response to the request
that finished the upload. A `GET` of the upload's URL
replays that answer to a client that lost it.

`UploadLimits` sets the largest and smallest upload and append, and how long
an upload is kept. `onCreate` records what the application knows on the
request that creates an upload, such as whose it is, for the completion
handler to read as `upload.metadata`. A client's `Repr-Digest` is checked
before the handler runs, and `await upload.digest()` gives the SHA-256.

A client that comes back while its old request is still appending supersedes
it: on the same shard the old request is ended and what it received kept; on
another shard the new request waits a moment, then is answered 409 with
`Retry-After`. Over HTTP/1.1, ending the old request closes its connection,
and bytes it had read from the socket but not yet stored are dropped. The
client resumes from the offset that was stored, so nothing is lost but those
bytes' transfer.

The [files and uploads examples](Examples/README.md) are whole applications
built on it.

### Testing

```swift
import GarudaTesting
import Testing

@Test func personIsFound() throws {
    let response = try app.test.get("/person/1")
    #expect(response.status == .ok)
    #expect(try response.json(Person.self).name == "Ada")
}
```

`app.test` runs requests through the real HTTP/1 connection over an
in-memory stream, with no port: parsing, routing, middleware, handlers and the
response path. `app.test.http2()` does the same over HTTP/2.

## Garuda and axum

The application API is modelled after [axum](https://github.com/tokio-rs/axum).
axum is a mature, widely used framework, so this is where Garuda stands against
it, area by area.

| Area | axum (Tokio) | Garuda |
|---|---|---|
| Async handlers | `async fn` on a work-stealing pool | async closures on Vega's work-stealing threads; a handler that does not suspend runs inline in the task that read the request, allocating nothing |
| Spreading load over cores | Idle threads steal tasks from busy ones | The same inside a shard. Shards are processes and do not steal from each other; the kernel spreads connections across them ([differs](#shards-are-processes)) |
| Slow handlers | Share the pool with everything else | A route that holds its thread for long runs in the heavy lane, on at most half a shard's threads |
| Typed extraction | `Path`, `Query`, `Json`, `Form`, `Multipart` | `Path`, `Query`, `Body`, `Form`, `Multipart` |
| Custom extractors | `FromRequestParts`, `FromRequest`, `Option<T>`, `Result<T, E>` | `RequestExtractor`, whose `extract` may await; `E?`, `Result<E, any Error>` |
| OpenAPI | utoipa or aide, with derive macros | `app.openAPI`, `app.swaggerUI`; schemas read from `Decodable` types |
| State | `State<T>`, one `Arc` shared by every thread | `State<T>`, built in each shard and shared by its threads ([differs](#shards-are-processes)) |
| Request-scoped values | `Extension<T>` | `request[context:]`, `Context<Key>` |
| Errors as responses | `IntoResponse` | `ResponseError`, `HTTPError` |
| Protocols | HTTP/1.1 and HTTP/2 through hyper | HTTP/1.1, HTTP/2 and HTTP/3 |
| TLS | rustls or OpenSSL via `axum-server`; ACME from another crate | Built in, on BoringSSL or OpenSSL; certificates from an outside ACME client, reloaded without a restart |
| Nesting and 405 | `nest`, `merge`, `fallback`, 405 with `Allow` | `group`, `Router` with `nest` and `merge`, `fallback` per scope, 405 with `Allow` |
| Middleware | Tower layers that wrap the handler | `use { request, response, next in … }`, which wraps the handler; `onSend` on the final response |
| Ready-made middleware | tower-http, tower-sessions, axum-extra | Server flags for compression, rate limits, request IDs, trace context, access log; `app.deadline`, `app.cors`, `app.authenticate`, `JWT<Claims>`, `request.log`, `app.onResponse`, `app.maxBodySize`, `app.concurrencyLimit`, cookies, `app.sessions`, `app.csrfProtection`, `app.securityHeaders`, `app.trailingSlash`, `app.requestDecompression`, `app.allowedHosts`, `app.addressFilter` |
| Streaming responses | `Body::from_stream` | `response.stream()`, `StreamingBody`, with backpressure |
| Server-sent events | `Sse`, with keep-alive | `EventStream`, with keep-alive comments and `Last-Event-ID` |
| Broadcast | `tokio::sync::broadcast`, within one process | `Topic`, across shard processes, to event streams, WebSockets and long polls, with replay |
| Streaming request bodies | `Body::into_data_stream` | `app.onStreamingBody`, read with flow control over HTTP/1.1, HTTP/2 and HTTP/3 |
| Resumable uploads | None built in; tus through other crates | `app.resumableUploads` (`GarudaUploads`), the IETF draft over every protocol |
| Interim responses | None: hyper sends only 100 Continue | `response.sendInterim`, such as 103 Early Hints |
| WebSockets | `WebSocketUpgrade` | `app.webSocket`, whole messages, pings and permessage-deflate by the engine (over HTTP/1.1, HTTP/2 and HTTP/3) |
| WebTransport | None in hyper | `app.webTransport` |
| HTTP client | reqwest | `HTTPClient`, HTTP/1.1 and HTTP/2, redirects by policy, decompression, streamed responses and server-sent events, a whole-exchange budget |
| PostgreSQL | sqlx, tokio-postgres | vega-db's driver on Vega's I/O |
| Redis | redis-rs, fred | vega-db's driver on Vega's I/O: RESP3 and RESP2, TLS, ACL, pipelines, transactions, pub/sub, Cluster and Sentinel |
| SQLite | sqlx, rusqlite | The system's libsqlite3 on Vega's blocking pool: a writer and readers per shard, WAL, migrations |
| Blocking work | `spawn_blocking` | a whole route with `app.offload`, or `Runtime.blocking { … }` from Vega |
| Testing | `tower::ServiceExt::oneshot` | `app.test`, the real HTTP/1 connection; `app.test.http2()` |

Every row is implemented and tested.

[BENCHMARKS.md](BENCHMARKS.md) has the benchmark method, including
hello-world comparisons with axum that measure what the server adds to a
request.

### Where Garuda differs, and why

#### Middleware covers its whole scope

An axum `layer` applies only to routes added before it. Garuda's `use` covers
every route in its group or application wherever the call is, so moving a line
cannot leave a route unguarded. A route that must skip a middleware goes
outside the group. Global middleware is outermost, then each group's, from
the outside in.

#### Shards are processes

A shard is a process with several threads, and work is stolen between them,
not across shards. A crash takes only that shard's connections, and `SIGHUP`
restarts the shards one at a time. The cost: in-memory state is per shard,
and a pool of 8 database connections is 8 per shard. Keep state every shard
must see in a database, and size pools as the total divided by the number of
shards. The rate limiter, the metrics, the response cache and `Topic` are
shared by the shards through shared memory.

A crash staying in one shard matters more in Swift than in Rust: a
force-unwrapped `nil` or an index out of range ends a Swift process on the
spot, where Tokio catches a Rust panic in the task that raised it.

With `--shards 0`, the default on macOS, the server is one process with no
supervisor. On Linux the default, `--shards auto`, is one shard per
last-level cache domain. Shards are forked on Linux; on macOS each runs the
executable again, so `main` must register the same routes every time. With
shards, no thread may be started before `app.run()`: start runtimes and
tracers in `app.state` or `onShardStart`. [DEPLOYMENT.md](DEPLOYMENT.md) has
the details.

#### A handler that computes without awaiting holds its thread

Nothing preempts a handler between awaits. A loop that never awaits holds its
thread until it ends, and a deadline bounds waiting, not computing. The heavy
lane keeps such routes to half a shard's threads, so quick requests still run;
hand a call that blocks to `app.offload` or `Runtime.blocking`.

#### Cancellation on HTTP/1.1

A reset HTTP/2 or HTTP/3 stream cancels its handler's task. On HTTP/1.1
nothing interrupts a handler whose client has gone; a streamed write to it
throws `HandlerWaitError.cancelled`, and any other answer goes nowhere.

#### No Foundation

Garuda brings its own JSON coder, `UUID` and `Timestamp`. If your code imports
Foundation too, write `Garuda.UUID` where both are in scope.

#### PostgreSQL prepares statements on its own

Every connection keeps up to 256 statements prepared, with no opt-in per query.
Behind PgBouncer in transaction pooling mode, set `statementCacheCapacity = 0`.

## The server

These work without any handler code, set by flags:

- **HTTP/1.1** with a parser strict where it prevents request smuggling,
  **HTTP/2** over TLS and cleartext, and **HTTP/3** over QUIC (`--http3`).
  QUIC and QPACK are Swift, from Vega (`VegaQUIC`, `VegaHTTP3`), over
  the same TLS library as the rest.
- **TLS** through Vega's `VegaTLS`, on BoringSSL by default or the system's
  OpenSSL 3, with several certificates chosen by SNI on both TCP and QUIC, and
  certificates reloaded from disk (`--tls-reload`, or `SIGHUP`). There is no
  kernel TLS: `--ktls` is accepted with a warning that it has no effect.
- **Certificates from an ACME client** such as certbot: `--redirect-http 80
  --acme-webroot DIR` answers its HTTP-01 challenges. There is no built-in
  ACME client.
- **Static files** (`--static-dir`) with `ETag` and byte ranges,
  pre-compressed copies (`--compress-static`), and directories answered by
  their `index.html` (`--static-index`) or listed (`--static-listing`).
- **Rate limiting** (`--rate-limit`) counted across shards.
- **HTTPS redirects** (`--redirect-http`), **HSTS**, **request IDs**, **W3C
  trace context**, an **access log**, **Prometheus metrics** and a **health
  check**.
- **Graceful shutdown** with `--drain-delay` and `--graceful-timeout`, a
  **rolling restart** on `SIGHUP`, and in development a restart when the
  executable is rebuilt (`--reload`).
- **Unix sockets** (`--unix`), several **shards** (`--shards`), and **trusted
  proxy headers** (`--forwarded-allow-ips`).
- **Compression** of handler responses (`--compress`) and a **response cache**
  shared by the shards (`--cache-size`).

`garuda --help` lists every flag, and [CONFIG.md](CONFIG.md) explains them.
Flags keep Garuda 1's names and units: `--keep-alive`, `--request-timeout`,
`--graceful-timeout` and `--drain-delay` are milliseconds.

### Signals

| Signal | Effect |
|---|---|
| `SIGTERM` | Fail the health check for `--drain-delay`, then stop accepting and finish what is in progress within `--graceful-timeout`. |
| `SIGINT`, `SIGQUIT` | The same without the drain delay; one sent during a drain delay cuts it short. |
| `SIGHUP` | Restart the shards one at a time, rereading certificates. With shards only. |

On Windows, Ctrl-C and Ctrl-Break stop it as `SIGINT` does, and closing the console as `SIGTERM` does. [DEPLOYMENT.md](DEPLOYMENT.md#signals) has
the details.

## Tests

```bash
swift test                                   # unit tests
bash scripts/compile-fail-test.sh            # handler code that must not compile
```

The database tests skip themselves unless a database is reachable. The
end-to-end suites run against a release build. Each takes a binary path as
its first argument. Most use `.build/release/garuda`; the handler, WebSocket,
WebTransport, broadcast and upload suites use `.build/release/garuda-conformance`,
whose routes exist only for the tests.

```bash
bash scripts/integration-test.sh             # HTTP/1.1 framing and smuggling defences
bash scripts/static-test.sh                  # --static-dir
bash scripts/compress-test.sh                # --compress, --compress-static
bash scripts/cache-test.sh                   # --cache-size
bash scripts/ratelimit-test.sh               # --rate-limit
bash scripts/redirect-test.sh                # --redirect-http, --hsts
bash scripts/sni-test.sh                     # certificates by SNI
bash scripts/resumption-test.sh              # session tickets resume, TLS 1.3 and 1.2
bash scripts/request-id-test.sh              # --request-id
bash scripts/trace-context-test.sh           # --trace-context
bash scripts/drain-test.sh                   # --drain-delay
bash scripts/reload-test.sh                  # SIGHUP under load
python3 scripts/feature-test.py              # shutdown, supervision, unix sockets, slow clients
python3 scripts/http2-test.py                # against the h2 library
python3 scripts/http3-test.py                # against aioquic
python3 scripts/router-streams-test.py       # routes over HTTP/2 and HTTP/3
python3 scripts/handler-test.py              # the handler API over all three protocols
python3 scripts/websocket-test.py            # handshake, framing violations, closing, pings, deflate
python3 scripts/websocket-streams-test.py    # WebSocket over HTTP/2 and HTTP/3
python3 scripts/webtransport-test.py         # sessions, streams, datagrams
python3 scripts/broadcast-test.py            # topics across shards, Last-Event-ID, keep-alive
python3 scripts/upload-test.py               # streamed request bodies, resumable uploads
```

The shell suites need `curl` and `openssl`. The Python suites are clients only,
using `h2` and `aioquic`, which share no code with the server.

The parsers that read bytes from the network, and whole HTTP/2, HTTP/3 and
QUIC connections, are fuzzed with `pgfuzz`, a mutation fuzzer in the package,
against 14 targets (`GarudaFuzzTargets`). `swift test` replays every seed and
everything in `fuzz/corpus` through them (`GarudaFuzzTests`).

```bash
swift run -c release pgfuzz                  # every target, 5 seconds each
swift run -c release pgfuzz h2 --seconds 300
```

[fuzz/README.md](fuzz/README.md) lists the targets, the invariants each
checks, and how to run them under AddressSanitizer.

## Status

Garuda 2.0.0 is the current release. Garuda 1 stays on `release/1.x`; an
application not ready to move pins `from: "1.1.0"`. From 2.0 on, Garuda
follows semantic versioning, and
[COMPATIBILITY.md](COMPATIBILITY.md#versions-from-20-on) says what that
covers.

### Not supported yet

- A built-in ACME client. Use certbot or another client with
  `--acme-webroot`.
- Kernel TLS: `--ktls` is accepted and has no effect.
- Reads from Redis replicas: every command goes to the master, or to the node
  that owns the slot. [CONNECTORS.md](CONNECTORS.md) has the rest of the
  drivers' limits.
- `multipart/byteranges`: a request for several ranges at once is answered
  with the whole file.
- QUIC session resumption and 0-RTT.
- Windows beyond one process: it is experimental, with no shards, no `SIGHUP`
  and no response compression yet.

## Documentation

| File | What it covers |
|---|---|
| [INSTALLATION.md](INSTALLATION.md) | Requirements, the TLS library traits, building, using Garuda in an application, certificates |
| [CONFIG.md](CONFIG.md) | Every command-line flag, with its unit and default, and `ServerConfig` |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Running in production: the supervisor and shards, signals, draining, reloads, systemd, proxies |
| [HANDLER-API.md](HANDLER-API.md) | The handler API's design and the decisions behind it |
| [MIDDLEWARE.md](MIDDLEWARE.md) | How middleware runs, every piece Garuda ships, and writing your own |
| [CONNECTORS.md](CONNECTORS.md) | The HTTP client, and PostgreSQL, Redis and SQLite from vega-db: limits and future work |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How Garuda 2 is built: shards, the work-stealing runtime, the protocols, the heavy lane, shared memory |
| [TRANSPORT.md](TRANSPORT.md) | What each protocol implementation does |
| [COMPATIBILITY.md](COMPATIBILITY.md) | Moving from Garuda 1 to Garuda 2, and what a release may change |
| [EXAMPLES.md](EXAMPLES.md) | The eight runnable applications, and recipes (still being ported from Garuda 1) |
| [Examples/README.md](Examples/README.md) | The example applications and how they are laid out |
| [BENCHMARKS.md](BENCHMARKS.md) | Benchmark method and results |
| [RELEASE.md](RELEASE.md) | Changes |
