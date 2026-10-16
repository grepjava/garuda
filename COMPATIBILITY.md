# Moving from Garuda 1 to Garuda 2

Garuda 2 is a rewrite of the server underneath the same application API. The
engine is now [Vega](https://github.com/grepjava/vega), a work-stealing
runtime: a shard is a process with many threads, where a Garuda 1 worker was a
process with one. Most route and handler code moves over with small edits;
middleware, lifecycle hooks, custom extractors and deployment scripts need
more. This page lists what changed and what Garuda 2 does not have.

Garuda 1 stays on the `release/1.x` branch and keeps its `1.x` tags. An
application that is not ready to move pins `from: "1.1.0"`, which never
resolves to 2.0.

---

## The short version

1. Depend on `from: "2.0.0"`, and add the database and testing products you
   use: `GarudaPostgres`, `GarudaRedis`, `GarudaSQLite`, `GarudaTesting`.
2. `exit(app.run())` becomes `app.run()`: it returns `Never`.
3. Rewrite middleware in the `use { request, response, next in … }` shape.
4. Make handler captures and `app.state` values `Sendable`: a shard's threads
   run them concurrently.
5. Replace `onWorkerStart`, `prepare` and `onWorkerShutdown` with
   `onShardStart` and `onShardStop`.
6. Turn time values into `Duration`s: `app.deadline(.milliseconds(500))`,
   `app.every(.seconds(3600))`, `HTTPClient.timeout`, database timeouts.
7. Check every command line: `--workers` is now `--shards`, and **`0` means
   one process**, not one per CPU. The ACME flags are gone. Flags keep
   Garuda 1's names and units; a few are accepted but no longer do anything,
   and `--max-connections`, `--blocking-threads` and `--blocking-queue` have
   new defaults.

---

## Packages and modules

| | Garuda 1 | Garuda 2 |
|---|---|---|
| Engine | aviancore 0.7 (`CAvian`, `AvianCore`, `AvianHTTP`, `AvianQUIC`) | Vega 0.4 and vega-db 0.2 |
| Platforms | Linux; macOS 15 | Linux; macOS 26.4 (Vega's floor); Windows experimental, one process only |
| TLS library | vendored BoringSSL for TLS, plus the system's `libcrypto` for JWT, ACME and QUIC | one library for everything, chosen by trait: `BoringSSL` (default, vendored) or `OpenSSL` (the system's OpenSSL 3) |
| System packages | OpenSSL and zlib development files | zlib development files only, by default |

| product | Garuda 1 | Garuda 2 |
|---|---|---|
| `Garuda` | the API, the server, the HTTP client, **and PostgreSQL, Redis and SQLite** | the API, the server, the HTTP client |
| `GarudaPostgres`, `GarudaRedis`, `GarudaSQLite` | -- (internal targets) | new products: vega-db's drivers, re-exported with `Garuda` |
| `GarudaSQL` | `@PostgresRow`; re-exports `Garuda` | `@PostgresRow`; re-exports `GarudaPostgres` |
| `GarudaJSON` | `@JSON` | unchanged |
| `GarudaTesting` | -- (`app.test` was in `Garuda`) | new: `app.test` and the test clients |
| `GarudaUploads` | resumable uploads | the same API, `app.resumableUploads`; bodies are read as they arrive over HTTP/1.1, HTTP/2 and HTTP/3 |

- **Imports.** A file that uses PostgreSQL imports `GarudaPostgres` (which
  brings `Garuda` with it), and so on for Redis and SQLite. Tests import
  `GarudaTesting`. The session and refresh-token stores moved with their
  databases: `RedisSessionStore` is in `GarudaRedis`, `SQLiteSessionStore` in
  `GarudaSQLite`, `PostgresRefreshTokenStore` in `GarudaPostgres`.
- **Vega.** `Garuda` re-exports nothing from Vega. Code that calls
  `Runtime.sleep(for:)` or `Runtime.blocking { }` directly depends on the
  `vega` package and imports `Vega`.

---

## Process model

| | Garuda 1 | Garuda 2 |
|---|---|---|
| unit | worker: a process with one thread and a poller | shard: a process with a work-stealing runtime of several threads |
| default count | `--workers 1` | `--shards auto` on Linux (one per last-level cache domain); `0` on macOS |
| supervisor | always, even for one worker | with one shard or more; `--shards 0` runs in one process with none |
| how processes start | fork | fork on Linux; on macOS, a new run of the executable that runs `main` again |
| balancing | `--balance adaptive`: workers step back and hand idle HTTP/1 connections to each other | work stealing between a shard's threads; across shards, the kernel (`reuseport`) or a shared socket |
| slow handlers | warned about (`--slow-handler-ms`) | the heavy lane bounds them to half a shard's threads (`--heavy-threshold`, `app.heavy`) |
| blocking work | `blocking { }` on a per-worker pool | `app.offload` routes, or Vega's `Runtime.blocking { }` |
| rolling restart (`SIGHUP`) | replacement started before the old worker retired | each shard stopped (with `SIGINT`), then its replacement started |

What this means for application code:

- **Concurrency inside a process.** A Garuda 1 worker ran one handler at a
  time, so state built by `app.state` could be an ordinary class. In Garuda 2
  every thread of a shard shares it, so `app.state` requires `Value: Sendable`
  and handler closures are `@Sendable`. A class with mutable state needs a
  lock (`Synchronization.Mutex`) or another design.
- **Per-shard state.** `app.state`, database pools, the HTTP client's
  connections, and `MemorySessionStore` and `MemoryRefreshTokenStore` are per
  shard. A pool of 8 connections is 8 per shard. The server warns at start-up
  about a memory store under more than one shard.
- **Shared across shards**, as before across workers: the rate limiter, the
  metrics, the response cache, `Topic` broadcast, and now the TLS
  session-ticket key.
- **Deterministic `main`.** On macOS every shard runs `main` again up to
  `app.run()`, so route registration must come out the same each time.
- **No threads before `app.run()`.** With shards, Vega stops the program if
  any other thread exists when it forks: a Vega `Runtime`, a tracer's
  exporter, a library's background thread. Start them in `app.state`,
  `onShardStart` or `app.tracing { shard in … }`.
- **Cancellation is Swift's.** A reset HTTP/2 or HTTP/3 stream cancels its
  handler's task; `Task.isCancelled` and `try Task.checkCancellation()` work.
  On HTTP/1.1 nothing interrupts a handler, but a streamed write to a client
  that went away throws `HandlerWaitError.cancelled`. A streaming-body route
  is the exception: a reset does not cancel its task, and its body throws
  `RequestBodyError.incomplete` instead, once what arrived has been read.

---

## API changes

### Running

| Garuda 1 | Garuda 2 |
|---|---|
| `exit(app.run())` | `app.run()`, which returns `Never` |
| `app.run(arguments: flags)`, without the program name | `app.run(arguments: argv)`: the first element is the program name and is skipped |
| `app.run(configuration: config) -> Int32` | `app.run(config: config) -> Never` |
| `app.runOnce(timeoutMilliseconds:) { … }` | gone: run one-off work on a `Runtime` of your own ([INSTALLATION.md](INSTALLATION.md#an-application-with-commands-of-its-own)) |
| `GarudaCLI.main(argc:argv:)` | gone |

### Handlers

| Garuda 1 | Garuda 2 |
|---|---|
| `Handler = (borrowing Request, inout Response) throws -> Void` | `Handler = @Sendable (borrowing Request, borrowing Response) async throws -> Void` |
| `app.onAsync(.get, "/x") { request, response in … }` | `app.on(.get, "/x") { request, response in … }` or `app.get("/x") { request, response in … }`: every raw handler is async |
| a synchronous and an async overload of each typed route | one async overload; a closure that never awaits converts to it and runs inline |
| `response.sleep(milliseconds:)`, `response.after(milliseconds:then:)` | `try await Runtime.sleep(for:)` (`import Vega`) or `Task.sleep`; `EventSink` and `ResponseBodyWriter` have `sleep(for:)` |
| `response.isCancelled`, `response.isActive`, `response.cancellable { }`, the `Cancellation` extractor | Swift task cancellation |
| `blocking { … }`, `BlockingPoolError` | `app.offload.get(…)` for a whole route, or `Runtime.blocking { … }`; past `--blocking-queue` it throws Vega's `BlockingQueueFull`, a 503 |
| `request.client` | `HTTPClient()`, a `Sendable` value made anywhere |
| `request.scheme` | `request.arrivedOverHTTPS` |
| `request.requestStart: UInt64?` | `request.requestStart: Int?`, microseconds since the epoch, with `--request-start-header` |
| `request.withRemoteAddress { }` | `request.remoteAddress` |
| `response.sendInterim(…)` | the same, now `async` |
| `response.eventStream(status:keepAlive:)`, `keepAlive` in seconds | `await response.eventStream(status:keepAlive:)`, `keepAlive` a `Duration` |
| `EventStream(keepAlive: 30)` | `EventStream(keepAlive: .seconds(30))` |
| `request.withBody`, `withHeader`, `withParameter` … `rethrows` | the same, with typed throws |
| `Digest`, `SHA256Digest` | gone |
| `Cookie.expires: Timestamp?` | `Cookie.expires: Int64?`, seconds since the epoch |

### Streaming request bodies

`app.onStreamingBody` is back, over HTTP/1.1, HTTP/2 and HTTP/3. What
changed:

| Garuda 1 | Garuda 2 |
|---|---|
| `(borrowing Request, inout Response, RequestBodyStream) async throws -> Void` | `@Sendable (borrowing Request, borrowing Response, RequestBody) async throws -> Void` |
| `RequestBodyStream`, a class | `RequestBody`, a `Sendable` struct |
| `read(maxBytes:)`, `readAll(maxBytes:)`, `cancel()`, `bytesRead`, `expectedLength` | the same, and `read(into: &buffer)`, which reads into an `IOBuffer` without a new array per read |
| `onStreamingBody` returns nothing | it returns the route's `OpenAPIOperation`, as other routes do |
| `RequestBodyError.concurrentRead` | gone; read one piece at a time |

`RequestBodyError.incomplete` still answers 400 and `.tooLarge` 413. Every
other route's body is collected whole before dispatch, held to `--max-body`
or `app.maxBodySize`. [HANDLER-API.md](HANDLER-API.md#request-bodies-read-as-they-arrive)
describes the API.

### Middleware

Garuda 1's middleware ran before the handler and returned an answer or `nil`.
Garuda 2's wraps the handler, and calls `next()` to run the rest of the chain:

```swift
// Garuda 1
app.use { request, response async throws -> (any ResponseConvertible)? in
    guard request.header("x-key") != nil else { return HTTPStatus.unauthorized }
    return nil
}

// Garuda 2
app.use { request, response, next in
    guard request.header("x-key") != nil else {
        return response.send(status: .unauthorized)
    }
    try await next()
}
```

A middleware can now change the response after `next()` returns and catch
what the handler threw. `AsyncMiddleware` is gone; a type conforms to the
`Middleware` protocol with `handle(_:_:next:)`. `response.onSend` still works.
The middleware Garuda ships keeps its names (`app.cors`, `app.authenticate`,
`app.sessions` and the rest); [MIDDLEWARE.md](MIDDLEWARE.md) has the details.

### Extractors

| Garuda 1 | Garuda 2 |
|---|---|
| `RequestExtractor.extract(from:parameter:) throws` | `… async throws` |
| `AsyncRequestExtractor`, `awaitsExtraction`, `extractsSynchronously` | gone: there is one protocol, and it may await |
| `ResponseConvertible` | now refines `SendableMetatype` |

A custom extractor adds `async` to its `extract`.

### State, lifecycle and jobs

| Garuda 1 | Garuda 2 |
|---|---|
| `app.state { worker in … }`, synchronous | `app.state { start in … }`, `async`, given a `ShardContext`; `Value: Sendable` |
| `shutdown:` synchronous | `shutdown:` `async` |
| `app.onWorkerStart { worker in … }`, `app.prepare(timeoutMilliseconds:) { … }` | `app.onShardStart { start in … }`, with no timeout |
| `app.onWorkerShutdown { worker in … }` | `app.onShardStop { stop in … }`, run in reverse order |
| `WorkerStartup` | `ShardContext`: `shard` (a `ShardInfo`: `index`, `count`, `threads`) and `state(_:)` |
| `app.every(3600, onWorker: 0) { worker in … }`, seconds as `Double` | `app.every(.seconds(3600), onShard: 0) { shard in … }` |
| `app.tracing { worker in … }` | `app.tracing { shard in … }` |
| `app.jwtVerifier { worker in … }` | `app.jwtVerifier { start in … }`, `async` |
| `app.listen(…, onWorker:, reconnectAfter: Double)` | `app.listen(…, onShard:, reconnectAfter: Duration)` |

A factory or start hook that throws ends the shard's start-up; the supervisor
starts it again with a back-off.

### Time values

Milliseconds as integers and seconds as `Double` are now `Duration`:

| Garuda 1 | Garuda 2 |
|---|---|
| `app.deadline(milliseconds: 500) { }` | `app.deadline(.milliseconds(500)) { }` |
| `client.timeoutMilliseconds`, `client.totalTimeoutMilliseconds` | `client.timeout`, `client.totalTimeout` |
| `JWKSVerifier` `caFile`, `timeoutMilliseconds` (5 s) properties | `JWKSVerifier(…, caFile:, timeout:)` initializer parameters; the timeout default is 10 s |
| `TestClient.timeoutMillis` | `TestClient.timeout` |
| `PostgresConfiguration` / `RedisConfiguration` `timeoutMilliseconds` | `timeout` |
| `acquireTimeoutMilliseconds:` on the pools | `acquireTimeout:` |
| `SQLiteConfiguration.busyTimeoutMilliseconds` | `busyTimeout` |
| `RedisSubscription.next(timeoutMilliseconds:)`, `PostgresListener.next(timeoutMilliseconds:)` | `next(timeout:)` |

`app.deadline` also changes meaning slightly: it bounds I/O waits (sockets,
pipes, databases), and a `Runtime.sleep`, a channel or a child task's wait is
not cut short.

### Databases

The drivers are vega-db's. The type names are the same (`PostgresPool`,
`RedisPool`, `RedisCluster`, `RedisSentinelPool`, `SQLiteDatabase` and the
rest), with these changes besides the timeouts above:

- `caFile`, a **path**, is now `trustedCertificates`, the certificates
  **as PEM text**. Read the file yourself.
- `SQLiteDatabase.migrate` is `async`.
- Pools belong to a shard and are shared by its threads.

[CONNECTORS.md](CONNECTORS.md) has the full list.

### Testing

`app.test` moved to `GarudaTesting`. It now runs requests through the real
HTTP/1.1 connection over an in-memory stream, and adds an HTTP/2 test client
(`app.test.http2()`). `TestClient.request(_:_:headers:json:)` is now
`request(_:_:json:headers:)`.

### `ServerConfig`

Strings are Swift `String`s, not C string pointers, and `ServerConfig.string`
is gone. Durations are `Duration`. The renamed fields:

| Garuda 1 | Garuda 2 |
|---|---|
| `workers` | `shards` (`nil` for automatic) |
| `host: UnsafePointer<CChar>` and other C strings | `String` |
| `balance: BalanceMode` | `balance: ConnectionBalance?` |
| `port: UInt16`, ports with 0 for off | `port: Int`, optional ports `Int?` |
| `keepAliveTimeoutMs`, `requestHeadTimeoutMs`, `gracefulShutdownMs`, `drainDelayMs`, `eventKeepAliveMs` | `keepAliveTimeout`, `requestHeadTimeout`, `gracefulShutdown`, `drainDelay`, `eventKeepAlive` |
| `websocketPingIntervalMs`, `websocketPingTimeoutMs`, `wsCompress` | `websocketPingInterval`, `websocketPingTimeout`, `websocketCompress` |
| `websocketOverHTTP1/2/3` | `websocketProtocols` |
| `healthPath` | `healthCheckPath` |
| `staticRoutes` | `staticDirectories` |
| `tlsCertPath`, `tlsKeyPath`, `tlsExtraCerts` | `tlsCertificates: [TLSCertificateFiles]` |
| `hsts`, `hstsLength` | `hstsMaxAge` |

The fields of removed features are gone with them (below).
[CONFIG.md](CONFIG.md#configuring-from-code) lists every field.

---

## Command line

Flags keep Garuda 1's names and units: `--keep-alive`,
`--request-timeout`, `--graceful-timeout`, `--drain-delay` and the
`--ws-ping-*` flags are milliseconds as before. Most keep their defaults
too; three do not:

| flag | Garuda 1's default | Garuda 2's default |
|---|---|---|
| `--max-connections` | 4096 per worker | no limit |
| `--blocking-threads` | 16 per worker | Vega's, 512 per shard |
| `--blocking-queue` | 1024 per worker | no limit |

A deployment that relied on Garuda 1's bounds passes them. What else
changed:

| flag | Garuda 1 | Garuda 2 |
|---|---|---|
| `--workers N` | N worker processes; `0` one per CPU | accepted as `--shards N`; **`0` now serves in one process** |
| `--balance` | `adaptive` (default), `accept`, `reuseport` | `auto` (default), `shared`, `reuseport`; `adaptive` and `accept` are taken as `auto` and `shared` |
| `--max-connections`, `--blocking-threads`, `--blocking-queue` | per worker | per shard |
| `--port` | 1 to 65535 | 0 to 65535; 0 picks a free port |
| `--ktls`, `--no-ktls`, `--sched-slice`, `--slow-handler-ms` | in effect, or accepted and ignored | accepted; all but `--no-ktls` warn that they have no effect |

`--shards 4` is four processes of several threads each, where `--workers 4`
was four single-threaded ones: a machine that ran `--workers 0` (one per CPU)
runs the default `--shards auto`, which sizes itself from the CPUs' cache
domains.

**New:** `--shards`, `--threads`, `--no-pin`, `--io`, `--acceptors`,
`--heavy-threshold`, `--no-heavy-lane`, `--tls-reload`, `--acme-webroot`.
`SERVER_HOSTNAME` and `SERVER_PORT` in the environment set the host and port.

**Removed:** the ACME flags: `--acme-domain`, `--acme-email`, `--acme-cache`,
`--acme-staging`, `--acme-directory`, `--acme-ca-bundle`. Get the certificate
with an outside ACME client, answer its HTTP-01 challenges with
`--redirect-http 80 --acme-webroot DIR`, and pick up renewals with
`--tls-reload` or `SIGHUP` ([CONFIG.md](CONFIG.md#renewing-certificates)).

[CONFIG.md](CONFIG.md) has every flag.

---

## Behaviour

- **Signals.** `SIGTERM`, `SIGINT` and `SIGQUIT` work as before. The
  supervisor kills shards still running `--drain-delay` + `--graceful-timeout`
  + 5 seconds after the signal (+ 2 seconds in Garuda 1). The same signal sent to
  the supervisor twice kills the shards at once. With `--shards 0`, `SIGHUP`
  is not handled and ends the process. [DEPLOYMENT.md](DEPLOYMENT.md#signals)
  has the details.
- **Reloads.** `SIGHUP` stops a shard before its replacement starts, so the
  server runs one shard short during each step, and the response cache is
  emptied. Garuda 1 started the replacement first.
- **Server log lines** read `garuda info: message`; Garuda 1's read
  `[info]  pid=1234 message`. The access log's JSON and the application log
  (`request.log`, `AppLog`) are unchanged.
- **Metrics.** The per-route series (`garuda_route_*`),
  `garuda_connection_slots`, and the hand-off and deferred-accept counters
  are gone.
- **HTTP/3** runs on Garuda's own QUIC (`GarudaQUIC`), one UDP socket per
  thread, ported from Garuda 1's and using the same TLS library as the rest.
  A client that changes address must pass path validation before the server
  follows it.
- **TLS** has a 10-second handshake timeout, and session tickets resume across
  shards.
- **Request bodies** are collected whole before the handler runs, on every
  protocol, except on an `onStreamingBody` route, which reads its body as it
  arrives.
- **Content-Length.** A `Content-Length` the handler sets is enforced, as in
  Garuda 1, on whole and streamed bodies alike. A longer body is cut to it,
  and a shorter one is never ended as if it were whole: HTTP/1.1 closes the
  connection after either mismatch, and HTTP/2 and HTTP/3 reset the stream of
  a short one. A HEAD states the declared length, a 304 keeps it, and a 204
  states none.

---

## What Garuda 2 does not have

| Garuda 1 feature | status in Garuda 2 |
|---|---|
| Built-in ACME client (tls-alpn-01) | dropped: use certbot or another client with `--acme-webroot` |
| Kernel TLS (`--ktls`) | no; the flag is accepted and has no effect |
| Scheduler slice (`--sched-slice`) and slow-handler warnings (`--slow-handler-ms`) | no; the flags are accepted and have no effect. The heavy lane does the work of both |
| Rolling restart that starts the replacement first | each shard is stopped, then replaced |
| Adaptive balancing (connection hand-off between processes) | work stealing inside a shard instead |
| `app.runOnce` | no |
| `app.prepare` with a timeout | `onShardStart`, without one |
| `response.sleep`, `response.after`, `response.cancellable`, `isCancelled`, the `Cancellation` extractor | Swift's own sleep and cancellation |
| `blocking { }` | `app.offload` and `Runtime.blocking` |
| `Digest`, `SHA256Digest` | no |
| Per-route metrics | no |
| `request.client` | `HTTPClient()` |

---

## Versions from 2.0 on

Garuda 2 follows [semantic versioning](https://semver.org), as Garuda 1 does:

| | |
|---|---|
| `PATCH` (2.0.0 → 2.0.1) | fixes only |
| `MINOR` (2.0.1 → 2.1.0) | additions only; an application keeps building |
| `MAJOR` (2.x → 3.0.0) | may break what is covered |

```swift
.package(url: "https://github.com/grepjava/garuda", from: "2.0.0")
```

**Covered:** the public Swift API of Garuda's products, the command-line flags
and the environment variables the server reads, what goes over the wire (status
codes, the headers the server adds, error bodies, cookie attributes, the
metrics format), and the schemas and Redis keys Garuda's stores write.

**Not covered:** anything `internal` or reached through `@testable import` or
`@_spi`; Vega and vega-db, whose versions each Garuda release names (the API
the database products re-export from vega-db follows vega-db's own releases);
the wording of log lines and error messages; timing and memory use; benchmark
scripts, test suites and examples; anything marked experimental, including
Windows.

Something covered is deprecated with `@available(*, deprecated)` for at least
one release before it is removed. A security fix may break something covered
in a `PATCH` release when there is no other way, and the release notes say so.
Every release's changes are in [RELEASE.md](RELEASE.md).

**Toolchains and platforms:** Swift 6.2 or newer, Swift 6 language mode;
Linux on x86-64 and arm64; macOS 26.4 or newer; Windows experimental.
PostgreSQL with SCRAM-SHA-256 authentication (MD5 is refused), Redis (RESP3 from
Redis 6, RESP2 before it) and Valkey, and the system's SQLite, loaded at run
time ([CONNECTORS.md](CONNECTORS.md)).
