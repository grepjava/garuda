<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/garuda/main/assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="720">
</p>

<p align="center">
  <b>A Swift web framework with its own HTTP engine.</b><br>
  HTTP/1.1, HTTP/2 and HTTP/3, TLS and ACME, typed handlers, PostgreSQL, streaming, WebTransport.<br>
  No Foundation, no SwiftNIO.
</p>

<p align="center">
  <a href="https://github.com/grepjava/garuda/blob/main/LICENSE"><img src="https://img.shields.io/github/license/grepjava/garuda" alt="MIT license"></a>
</p>

---

Garuda is a web framework and the server under it, written together in Swift.
The goal is a server that stands with the best in any language: correct and
strict on every protocol it speaks, safe by construction, pleasant to build an
API in, and fast. Handlers run on the worker thread that read the request, with
no scheduling hop before a response that can be sent at once.

**Status: early, and the API will change.** Routes, groups and middleware,
synchronous and async handlers, typed extraction and answers, per-worker state,
deadlines, an HTTP client, a PostgreSQL driver, streamed responses and request
bodies, server-sent events, WebSockets, resumable uploads and WebTransport all
work and are tested. Nothing has been released.
[HANDLER-API.md](HANDLER-API.md) has the roadmap, and [Status](#status) below
lists what is tested and what is missing.

## Quick start

```bash
swift build -c release
.build/release/garuda --port 8000 --workers 0
curl -i http://127.0.0.1:8000/user/42
```

The `garuda` binary serves a small benchmark application. Your own application
depends on the `Garuda` library:

```swift
// Package.swift
dependencies: [.package(url: "https://github.com/grepjava/garuda", branch: "main")],
targets: [.executableTarget(name: "app", dependencies: [.product(name: "Garuda", package: "garuda")])]
```

```swift
// Sources/app/main.swift
import Glibc   // Darwin on macOS
import Garuda

struct Person: Codable { let id: Int; let name: String }

let app = Application()
app.get("/person/:id") { (id: Path<Int>) in
    JSON(Person(id: id.value, name: "Ada"))
}
exit(app.run())
```

`app.run()` reads the same command-line flags as the `garuda` binary. Swift 6.1
or newer, on Linux or macOS 15. [INSTALLATION.md](INSTALLATION.md) lists the
system packages, certificates and running as a service.

## Writing handlers

### Routes and typed handlers

Routes are registered with `get`, `head`, `post`, `put`, `delete`, `patch`,
`options` or `on`. A path segment is a literal, a `:param` or a trailing
`*rest`. HEAD falls back to GET, and a known path under the wrong method is 405
with `Allow`.

A handler declares what it needs and returns what it means:

```swift
app.get("/search") { (query: Query<Search>) in JSON(results(for: query.value)) }
app.post("/people") { (body: Body<NewPerson>) in JSON(create(body.value), status: .created) }
app.post("/login") { (form: Form<Credentials>) in Redirect(to: "/") }
```

- **Extractors:** `Path<T>` (the next path parameter, percent-decoded),
  `Query<T>`, `Body<T>` (JSON), `Form<T>`, `Multipart`, `State<T>`,
  `Context<Key>`, or your own `RequestExtractor`. A value that will not decode
  is a 400 that says what was wrong.
- **Answers:** `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an
  `HTTPStatus`, or an Optional whose `nil` is a 404.
- **Errors:** a thrown `ResponseError` is the response.
  `throw HTTPError(.conflict, "the name is taken")` answers 409 with
  `{"error":"the name is taken"}`. Anything else thrown is a 500 and a log line.

JSON goes through Garuda's own coder over `Encodable` and `Decodable`, which
reads only the keys a type asks for, straight from the request bytes.

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

### Async handlers, deadlines and the HTTP client

A closure that awaits is an async handler. It runs on a task reused from the
worker's pool, on the worker's own thread, and allocates nothing per request
once warm.

```swift
app.deadline(milliseconds: 500) {
    app.onAsync(.get, "/weather/:city") { request, response in
        let client = request.client              // read before the first await
        let city = request.parameter(0)
        let answer = try await client.get("https://api.example.com/\(city)")
        response.send(bytes: answer.body, contentType: "application/json")
    }
}
```

A request still unanswered at its deadline is answered 504. A closed connection
or reset stream cancels a handler waiting on the engine. `request.client`
speaks HTTP/1.1, and HTTP/2 over TLS when the server offers it. It resolves
names on the worker's poller and keeps connections for reuse. It asks for
gzip, deflate, brotli and zstd and decodes what comes back, and it follows
redirects only when `client.redirects` says to: `.sameOrigin()`, `.any()` or
`.matching { url in … }`.

### State, groups and middleware

```swift
app.state { _ in PostgresPool(PostgresConfiguration(host: "db", user: "app", password: secret)) }

app.group("/api") {
    app.cors(CORSPolicy(origins: ["https://app.example.com"], allowCredentials: true))
    app.authenticate(bearer: CurrentUser.self) { token in try await sessions.user(token) }
    app.use { request, response in
        response.onSend { outgoing in outgoing.addHeader("cache-control", "no-store") }
        return nil
    }
    app.get("/user/:id") { (id: Path<Int>, db: State<PostgresPool>) async throws in
        try await db.value.first(User.self, "select id, name from users where id = $1", id.value).map { JSON($0) }
    }
}
```

- `app.state` builds a value once in each worker process, after the fork.
- `app.use` runs before every route in its scope, whether it is called before
  or after the routes. It returns `nil` to carry on or an answer to send
  instead, and can be async. `response.onSend` sees and changes the final
  response, whoever answered.
- `request[context: Key.self]` carries values from middleware to the handler,
  which reads them with `Context<Key>`.
- `app.cors` sets the scope's CORS policy. It answers preflights, including to
  paths routed only for other methods, and runs ahead of the scope's
  middleware, so a preflight never meets authentication and a 401 still
  reaches the page.
- `app.authenticate(bearer:)` and `app.authenticate(basic:)` read the
  Authorization header and keep who it belongs to in the context, or answer
  401 with the challenge. `BearerToken` and `BasicCredentials` are the same as
  extractors, and `constantTimeEquals` compares secrets.

### PostgreSQL

A native driver runs on the worker's poller. It supports SCRAM-SHA-256, TLS
(required by default) and a pool per worker with an acquire timeout. Rows decode
into `Decodable` types by column name. `db.transaction { tx in … }` commits or
rolls back. Statements stay prepared on each connection, and values are read in
binary after the first run. `UUID` and `Timestamp` come without Foundation.

### Streaming, server-sent events, WebSockets and WebTransport

```swift
app.get("/export") { () async in
    StreamingBody(contentType: "text/csv") { body in
        for row in rows { try await body.write(row.csv) }   // waits while the client is behind
    }
}

app.get("/ticks") { () async in
    EventStream { events in
        for i in 0... { try await events.send("tick \(i)"); try await events.sleep(milliseconds: 1000) }
    }
}

app.webSocket("/chat/:room") { (ws: WebSocket, room: Path<String>) async throws in
    for try await message in ws { try await ws.send(message) }   // whole messages
}

app.webTransport("/room/:id") { (session: WebTransportSession, id: Path<Int>) async throws in
    while let stream = try await session.acceptStream() { /* read and write */ }
}
```

A streamed body is chunked on HTTP/1.1 and DATA frames on HTTP/2 and HTTP/3.
A write waits while more than 512 KiB is queued (`writeHighWaterMark`), and a throw part-way resets the
stream rather than ending it cleanly. A WebSocket handler sees whole messages:
the engine joins fragments, checks UTF-8, answers pings, sends keepalive pings,
runs the close handshake and, with `--ws-compress`, permessage-deflate. Messages
the handler has not read wait in a bounded queue, and past it the socket is not
read, so a fast sender is slowed by TCP. WebTransport runs over HTTP/3 on the same
port and routes, with bidirectional and unidirectional streams, datagrams and
close codes.

### Streamed request bodies and resumable uploads

```swift
app.onStreamingBody(.put, "/files/:name", maxBodySize: 10 << 30) { request, response, body in
    while let bytes = try await body.read() { try file.write(bytes) }   // as it arrives
    response.send(status: .created)
}

import GarudaUploads

app.resumableUploads("/uploads", store: try FileUploadStore(directory: "/var/lib/app/uploads"),
                     limits: UploadLimits(maxSize: 10 << 30)) { upload in
    try moveIntoPlace(upload.path)
    try upload.remove()
    return HTTPStatus.created
}
```

A route registered with `onStreamingBody` runs as soon as the request's head
arrives, and reads the body as it comes, with its own size limit. Reading is
flow control: bytes the handler has not read hold back the client over
HTTP/1.1, HTTP/2 and HTTP/3, so a slow disk slows only its own upload. If the
client goes away part-way, the handler still reads everything that arrived and
then gets `RequestBodyError.incomplete`.

`GarudaUploads` implements the IETF resumable upload protocol
(draft-ietf-httpbis-resumable-upload, interop version 9). A client cut off
mid-upload asks how much arrived and sends the rest, over any protocol and on
any worker. `response.sendInterim` sends 1xx responses such as 103 Early Hints.

### Testing

```swift
@Test func personIsFound() throws {
    let response = try app.test.get("/person/1")
    #expect(response.status == .ok)
    #expect(try response.json(Person.self).name == "Ada")
}
```

`app.test` runs the real engine in the test process over a socket pair, with no
port: parsing, routing, middleware, handlers, timers and the response path.

## Garuda and axum

[axum](https://github.com/tokio-rs/axum) is a mature, widely used framework, so
it is a useful reference for what a production web framework is expected to
offer. This is where Garuda stands, area by area.

| Area | axum (Tokio) | Garuda | Status |
|---|---|---|---|
| Route dispatch | Every handler is a future the runtime polls | A synchronous handler is a direct call on the worker thread | Done |
| Async handlers | `async fn` on a work-stealing pool | Reused tasks on the worker's own executor, no allocation per request | Done |
| Typed extraction | `Path`, `Query`, `Json`, `Form`, `Multipart` | `Path`, `Query`, `Body`, `Form`, `Multipart` | Done |
| Custom extractors | `FromRequestParts`, `FromRequest` | `RequestExtractor` | Done |
| State | `State<T>`, one `Arc` shared by every thread | `State<T>`, built in each worker process | Done, [differs](#one-process-per-worker) |
| Request-scoped values | `Extension<T>` | `request[context:]`, `Context<Key>` | Done |
| Errors as responses | `IntoResponse` | `ResponseError`, `HTTPError` | Done |
| Protocols | HTTP/1.1 and HTTP/2 through hyper | HTTP/1.1, HTTP/2 and HTTP/3 | Done |
| TLS | rustls or OpenSSL via `axum-server`; ACME from another crate | Built in, with ACME | Done |
| Nesting and 405 | `nest`, `merge`, `fallback`, 405 with `Allow` | `group`, `Router` with `nest` and `merge`, `fallback` per scope, 405 with `Allow` | Done |
| Middleware | Tower layers that wrap the handler | `use` before the handler; `onSend` on the response | Done, [differs](#middleware-does-not-wrap-the-handler) |
| Ready-made middleware | tower-http | Server flags for compression, rate limits, request IDs, trace context, access log; `app.deadline`, `app.cors`, `app.authenticate` | Partial: no tracing API or request limits in code |
| Streaming responses | `Body::from_stream` | `response.stream()`, `StreamingBody`, with backpressure | Done |
| Server-sent events | `Sse` | `EventStream` | Done |
| Streaming request bodies | `Body::into_data_stream` | `onStreamingBody`, with a limit per route and flow control back to the client | Done |
| Resumable uploads | None built in; tus through other crates | `GarudaUploads`: the IETF resumable upload protocol | Done |
| Interim responses | None: hyper sends only 100 Continue | `response.sendInterim`, such as 103 Early Hints | Done |
| WebSockets | `WebSocketUpgrade` | `app.webSocket`, whole messages, pings and permessage-deflate by the engine | Done, HTTP/1.1 only |
| WebTransport | None in hyper | `app.webTransport` | Done |
| HTTP client | reqwest | `request.client`, HTTP/1.1 and HTTP/2, redirects by policy, decompression | Done |
| PostgreSQL | sqlx, tokio-postgres | Native driver on the poller | Done |
| Redis, SQLite | redis-rs, sqlx | None | Planned |
| Blocking work | `spawn_blocking` | `blocking { … }` on a bounded pool of threads per worker | Done |
| Testing | `tower::ServiceExt::oneshot` | `app.test`, the real engine | Done |

For performance, [BENCHMARKS.md](BENCHMARKS.md) has the method and every run,
including hello-world comparisons with axum that measure what the server adds to
a request.

### Where Garuda differs, and why

#### Middleware does not wrap the handler

A Tower layer awaits the handler and gets its response back as a value. A
Garuda handler writes its answer straight into the connection's buffer, so
there is no response value to hand back without building and copying one on
every request. Middleware runs **before** the handler, and `response.onSend`
lets it see and change the response just before the head is written. The hook
runs for every way a request is answered: the handler, a thrown error, a
middleware's refusal and a deadline's 504. Hooks run last-added first, so they
nest the way layers do.

What that rules out: retrying the handler from middleware, or holding a scope
open around its run. Retry inside the handler or around `pool.transaction`, and
use `app.deadline` for timeouts. Hooks do not run for static files, cache hits,
or the 404 before any route matches.

#### Middleware covers its whole scope

An axum `layer` applies only to routes added before it. Garuda's `use` covers
every route in its group or application wherever the call is, so moving a line
cannot leave a route unguarded. A route that must skip a middleware goes outside
the group.

#### One process per worker

A worker is a process with one thread. Nothing is shared, so nothing is locked,
a crash takes only that worker's connections, and `SIGHUP` replaces workers one
at a time. The cost: in-memory state is per worker, and a pool of 8 database
connections is 8 per worker. Keep shared state in a database, and size pools as
the total divided by `--workers`.

#### A handler that computes without awaiting holds its worker

A worker is one thread, and staying on it is what removes the scheduling hop. A
loop that never awaits holds the worker until it ends. A deadline bounds
waiting, not computing. Run more workers than busy cores, and hand a call that
blocks or computes for long to `try await blocking { … }`, which runs it on the
worker's blocking pool while the worker serves other requests.

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
  QUIC, TLS 1.3 key schedule and QPACK are Swift, over OpenSSL's crypto
  primitives.
- **TLS** through OpenSSL, with several certificates chosen by SNI, and kernel
  TLS (`--ktls`) so static files use `sendfile` over HTTPS.
- **ACME** certificates (`--acme-domain`), obtained and renewed with tls-alpn-01
  on the port already served.
- **Static files** (`--static-dir`) with `sendfile` and `ETag`, and
  pre-compressed copies (`--compress-static`).
- **Rate limiting** (`--rate-limit`) counted across workers.
- **HTTPS redirects** (`--redirect-http`), **HSTS**, **request IDs**, **W3C
  trace context**, an **access log**, **Prometheus metrics** and a **health
  check**.
- **Graceful shutdown** with `--drain-delay`, and **zero-downtime reload** on
  `SIGHUP` or when the executable is rebuilt (`--reload`).
- **Unix sockets**, multiple **workers**, and **trusted proxy headers**
  (`--forwarded-allow-ips`).

`--compress` and `--cache-size` exist but do not act on handler responses yet.
`garuda --help` lists every
flag, and [CONFIG.md](CONFIG.md) explains them.

### Signals

| Signal | Effect |
|---|---|
| `SIGTERM` | Stop accepting, finish in-flight requests within `--graceful-timeout`. With `--drain-delay`, keep serving first while the health check answers 503. |
| `SIGINT`, `SIGQUIT` | Shut down without the drain delay. |
| `SIGHUP` | Replace every worker one at a time, rereading certificates, without refusing a connection. |

## Tests

```bash
swift test                                   # 561 unit tests, and the fuzz corpus
bash scripts/compile-fail-test.sh            # 6   handler code that must not compile
```

The end-to-end suites run against a release build. Each takes a binary path as
its first argument. Most use `.build/release/garuda`; `handler-test.py`,
`websocket-test.py`, `webtransport-test.py` and `upload-test.py` use
`.build/release/garuda-conformance`, whose routes exist only for the tests.

```bash
bash scripts/integration-test.sh             # 36  HTTP/1.1 framing and smuggling defences
bash scripts/static-test.sh                  # 42  --static-dir
bash scripts/compress-test.sh                # 28  --compress-static
bash scripts/ratelimit-test.sh               # 18  --rate-limit
bash scripts/redirect-test.sh                # 22  --redirect-http, --hsts
bash scripts/sni-test.sh                     # 11  certificates by SNI
bash scripts/acme-test.sh                    # 12  --acme-domain, needs Pebble
bash scripts/request-id-test.sh              # 12  --request-id
bash scripts/trace-context-test.sh           # 17  --trace-context
bash scripts/drain-test.sh                   # 14  --drain-delay
bash scripts/reload-test.sh                  #  7  SIGHUP under load
python3 scripts/feature-test.py              # 62  shutdown, supervision, unix sockets, slow clients
python3 scripts/http2-test.py                # 50  against the h2 library
python3 scripts/http3-test.py                # 53  against aioquic
python3 scripts/router-streams-test.py       # 41  routes over HTTP/2 and HTTP/3
python3 scripts/handler-test.py              # 143 the handler API over all three protocols
python3 scripts/websocket-test.py            # 104 handshake, framing violations, closing, pings, deflate
python3 scripts/webtransport-test.py         # 46  sessions, streams, datagrams
python3 scripts/upload-test.py               # 35  streamed request bodies, 1xx, resumable uploads
```

The shell suites need `curl` and `openssl`. The Python suites are clients only,
using `h2` and `aioquic`, which share no code with the server. Every parser that
reads network bytes is fuzzed with `swift run -c release pgfuzz`
([fuzz/README.md](fuzz/README.md)). CI (`.github/workflows/ci.yml`) is started
by hand. It builds and runs the unit tests on Ubuntu 24.04 and macOS 15, and
fuzzes for 60 seconds under AddressSanitizer.

## Status

### Engine code with nothing to act on yet

Some engine features are built but not yet reachable from handlers, so their
end-to-end tests wait on the handler API step that connects them:

| Waiting for | Engine feature and the checks it brings back |
|---|---|
| Compression in the response path | `--compress`: codec choice, `Content-Length` removal, `Vary`, weak `ETag`, `no-transform`, event streams, the small-body exemption |
| Caching in the response path | `--cache-size`: storing, HEAD from GET, 304 revalidation, retirement on unsafe methods, `Age` and TTL, credentials kept out, flush on reload |
| A logging API | Levels applied to handler log records |

A handler waiting on something other than the engine (its own continuation,
say) is not unwound when its request is cancelled. It resumes to find
`response.isCancelled` set, and anything it sends is dropped.

### Not supported


- A stable API, WebSocket over HTTP/2 and HTTP/3, Redis and SQLite.
- Resumable uploads have no `min-size` or `min-append-size` limits and no
  digests, and a completed upload is not replayed to a client that asks again.
- A body over its limit is answered 413 on HTTP/1.1 and HTTP/3, and refused
  with a stream reset (ENHANCE_YOUR_CALM) on HTTP/2.
- Byte ranges and directory listings for static files.
- QUIC session resumption and 0-RTT.
- TLS over TCP in Swift: it is OpenSSL.
- Windows, except through WSL 2.

## Documentation

| File | What it covers |
|---|---|
| [HANDLER-API.md](HANDLER-API.md) | The handler API's design, decisions and roadmap |
| [INSTALLATION.md](INSTALLATION.md) | Building, dependencies, certificates, deployment |
| [CONFIG.md](CONFIG.md) | Every command-line flag |
| [ARCHITECTURE.md](ARCHITECTURE.md) | How the engine is built |
| [TRANSPORT.md](TRANSPORT.md) | What each protocol implementation does |
| [BENCHMARKS.md](BENCHMARKS.md) | Benchmark method and results |
| [RELEASE.md](RELEASE.md) | Changes |
