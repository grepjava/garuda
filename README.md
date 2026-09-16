<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/garuda/main/assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="720">
</p>

<p align="center">
  <b>A pure-Swift HTTP server.</b><br>
  HTTP/1.1, HTTP/2 and HTTP/3, TLS and ACME, static files, rate limiting, zero-downtime reload.<br>
  No Foundation, no CPython.
</p>

<p align="center">
  <a href="https://github.com/grepjava/garuda/blob/main/LICENSE"><img src="https://img.shields.io/github/license/grepjava/garuda" alt="MIT license"></a>
</p>

---

Garuda was forked from Peregrine, a Python ASGI/WSGI server. The engine was
kept. CPython, ASGI, WSGI and the Python package were removed.

**Status: the handler API is early and will change.** In the tree: routes and
groups, synchronous and async handlers, middleware before a handler and hooks on
its response, typed extraction and answers, per-worker state, deadlines, an HTTP
client, a native PostgreSQL driver on the worker's poller, streamed responses,
server-sent events and WebTransport. There is no WebSocket handler or streamed
request body yet. [Garuda and
axum](#garuda-and-axum) compares it feature by feature with the framework it
aims to beat. It is not yet a stable way to serve your own application. [HANDLER-API.md](HANDLER-API.md) holds the design and
roadmap, and [GARUDA.md](GARUDA.md) is the authoritative status document.

```bash
swift build -c release
.build/release/garuda --host 0.0.0.0 --port 8000 --workers 0
curl -i http://127.0.0.1:8000/user/42
```

Requirements, per-platform packages, TLS certificates and running it as a
service are in [INSTALLATION.md](INSTALLATION.md).

---

## The handler API

The library product `Garuda` (the `Garuda` module) serves an `Application`
with the same command-line flags as the `garuda` binary:

```swift
import Glibc                // Darwin on macOS, for exit
import Garuda

let app = Application()
app.get("/user/:id") { request, response in
    request.withParameter(0) { response.send($0) }   // lent, not copied
}
exit(app.run())
```

- **Routes** are registered on the application with `get`, `head`, `post`,
  `put`, `delete`, `patch`, `options` or `on`. A pattern segment is a literal, a
  `:param`, or a trailing `*rest`, with at most 8 parameters. The table is
  compiled into a byte trie when the application first runs or is tested.
  HEAD falls back to GET.
- **`Request`** is a `~Copyable` view of the request. Bytes it already holds
  are lent to a closure as a `Span`, which the compiler keeps inside it:
  `withPath`, `withQuery`, `withParameter(i)`, `withHeader(_:)`,
  `forEachHeader`, `withBody`, `withRemoteAddress` and `withRequestID`. A
  handler that wants to keep a value asks for an owned copy: `path`, `query`,
  `parameter(i)`, `header(_:)`, `authority`, `remoteAddress` and `requestID` as
  `String`, `body` as `[UInt8]`. Also `method`, `version`, `scheme`,
  `remotePort` (with `--forwarded-allow-ips` applied) and `requestStart`.
- **`request[context: Key.self]`** holds typed values for the rest of the
  request, across a wait, and never for the next request on the connection.
- **`Response`** is `~Copyable` too: `status`, `addHeader`, `send(status:)`,
  `send(status:_:)` (a lent `Span` is sent without a copy), and
  `after(milliseconds:then:)`, which calls a handler again after a timer.
- **Typed answers**: `send(json:)`, `send(text:)`, `send(html:)`,
  `send(bytes:contentType:)` and `redirect(to:status:)`. Each sets the content
  type it implies unless the handler set one. Statuses are named —
  `send(status: .created, json: user)` — and an integer literal still works
  for one that has no name.
- **Errors that are answers.** A thrown error conforming to `ResponseError`
  becomes the response: `throw HTTPError.notFound`, or
  `HTTPError(.conflict, "the name is taken")` for 409 and
  `{"error":"the name is taken"}`. `JSONError` conforms, so a malformed body
  is a 400 that says which key. Anything else thrown is a 500 and a log line.
- **Typed handlers** declare what they need and return what they mean:

  ```swift
  app.get("/person/:id") { (id: Path<Int>) in JSON(Person(id: id.value, name: "Ada")) }
  app.get("/search")     { (query: Query<Search>) in JSON(query.value) }
  app.post("/people")    { (body: Body<NewPerson>) in JSON(body.value, status: .created) }
  ```

  `Path` takes the next path parameter percent-decoded, `Query` decodes the
  whole query string into a type (a repeated name is a list, `+` is a space),
  and `Body` decodes the JSON body. A handler may take none, one or several.
  Returning `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, a status —
  or an Optional whose `nil` is a 404 — writes the response. Anything that
  will not decode is one consistent 400 saying what was wrong.
- **Typed state per worker.** `app.state { worker in try Pool.connect() }` runs
  once in each worker after the fork, and `State<Pool>` hands it to any handler
  that asks:

  ```swift
  app.get("/user/:id") { (id: Path<Int>, pool: State<Pool>) in JSON(pool.value.user(id.value)) }
  ```

  A factory that throws stops that worker starting rather than letting it serve
  without what it needed, and `shutdown:` tears the value down when the
  worker's loop ends. Each worker is a process, so what it builds is its own:
  state every worker must see belongs outside the process.
- **Forms and uploads.** `Form<Credentials>` decodes an
  `application/x-www-form-urlencoded` body into a type, the way `Query` does.
  `Multipart` cuts a `multipart/form-data` body into parts —
  `form.text("title")`, `form.file("avatar")?.filename`, `form.all("tag")` —
  each with its bytes, filename and content type. A body sent as the wrong kind
  of document is a 415. Uploads are read whole, up to `--max-body`; streaming
  them is a later step.
- **`JSONCoder.encode` and `JSONCoder.decode`** are Garuda's own coder, over the standard
  library's `Encodable` and `Decodable` — `JSONEncoder` and `JSONDecoder` are
  Foundation, which Garuda does not link. Decoding reads only the keys a type
  asks for, straight from the bytes the request lent it. The typed extraction
  and answers above are built on it.
- **`app.run()`** parses the flags and runs the supervisor;
  `app.run(configuration:)` serves a `ServerConfig` instead. `onWorkerStart`
  hooks run in each worker before it reports ready, and `onWorkerShutdown`
  hooks after its loop ends.
- **`app.test`** serves the routes from a worker in the test process, over a
  socket pair with no port bound: `try app.test.get("/user/42")` returns the
  status, headers and body.

Every handler response goes through one response path. It frames 204, 304 and
HEAD responses, adds the server's headers unless the handler set its own
`X-Request-ID`, `Strict-Transport-Security` or `Alt-Svc`, and holds the body to
a declared `Content-Length`. A handler that throws, or returns without
answering or waiting, gets a 500.

The API is not stable. There is no WebSocket handler or streamed request body
yet, and [Garuda and axum](#garuda-and-axum) lists what else is still to come.
[HANDLER-API.md](HANDLER-API.md) has the roadmap.

### What the binary serves

`Sources/garuda-server/main.swift` serves the-benchmarker's contract through the
handler API:

| request | response |
|---|---|
| `GET /` | 200, empty body |
| `GET /user/:id` | 200, the id as the body |
| `POST /user` | 200, empty body |
| `GET /delay/:ms` | 200, empty body, after `ms` milliseconds (clamped to 1..5000) |
| `HEAD` on any GET route | the same head, no body |
| anything else | 404, connection kept alive |

The answers are the same over HTTP/1.1, HTTP/2 and HTTP/3. A stream cancelled
while `/delay/:ms` waits takes its timer with it. With `--root-path`, the
prefix is taken off the path before routing.

Server features that act before dispatch still apply in front of the routes:
`--health-check-path`, `--rate-limit`, `--static-dir`, `--redirect-http`,
`--hsts`, `--request-id`, `--trace-context`, the access log and metrics.

## Garuda and axum

Garuda's target is [axum](https://github.com/tokio-rs/axum): as quick to write
an API in, and faster serving it. This is where it stands against axum on
Tokio, feature by feature.

| Feature area | axum (Tokio, Rust) | Garuda today | Status |
|---|---|---|---|
| Route dispatch | Every handler is a future the runtime polls | A synchronous handler is a direct call on the worker thread, no allocation | Delivered |
| Async handlers | `async fn` on a work-stealing pool | `async` closures on the worker's own reused tasks; none allocated per request once warm | Delivered |
| Typed extraction | `Path<T>`, `Query<T>`, `Json<T>` | `Path<T>`, `Query<T>`, `Body<T>` | Delivered |
| Forms and uploads | `Form<T>`, `Multipart` | `Form<T>`, `Multipart`, read whole up to `--max-body` | Delivered; streaming uploads in step 5 |
| Custom extractors | `FromRequestParts`, `FromRequest` | `RequestExtractor` | Delivered |
| Application state | `State<T>`, one `Arc` shared by every thread | `State<T>`, built once in each worker process | Delivered, [differs](#one-process-per-worker) |
| Request-scoped values | `Extension<T>` | `request[context: Key.self]`, `Context<Key>` | Delivered |
| Errors as responses | `IntoResponse` on the error | `ResponseError`, `HTTPError` | Delivered |
| Protocols | HTTP/1.1 and HTTP/2 through hyper | HTTP/1.1, HTTP/2 and HTTP/3 over QUIC | Delivered |
| TLS and certificates | rustls or OpenSSL through `axum-server`; ACME from another crate | Built in, with ACME | Delivered |
| Nesting and 405 | `nest`, `merge`, 405 with `Allow` | `group(prefix)`, nested; 405 with `Allow` | Partial: no router values to merge, no custom fallback (step 4) |
| Middleware | Tower layers that wrap the handler | `use` before the handler, sync or async; `response.onSend` to change the response | Delivered, [differs](#middleware-does-not-wrap-the-handler) |
| Ready-made middleware | tower-http: CORS, compression, tracing, timeouts, limits | Server flags: compression, rate limits, request IDs, trace context, access log, body limits; `app.deadline` for timeouts. No CORS or auth middleware yet | Partial (step 4) |
| Streaming responses | `Body::from_stream` | `response.stream()` or `StreamingBody`, with a write that waits above `--write-high-water` | Delivered |
| Server-sent events | `Sse`, with `KeepAlive` | `EventStream` / `response.eventStream()`; heartbeats are the handler's `comment()` | Delivered |
| Streaming request bodies | `Body::into_data_stream` | Read whole, up to `--max-body` | Step 5 |
| WebSockets | `WebSocketUpgrade` | Engine stubs, answered 501 | Step 5 |
| WebTransport | None: hyper has no HTTP/3, so a separate stack such as `wtransport` | `app.webTransport`: sessions, streams both ways, datagrams, close codes, on the same port and routes as everything else | Delivered |
| Outbound DNS | Tokio's resolver or hickory | A resolver on the worker's poller: UDP with TCP fallback, TTL cache | Delivered |
| HTTP client | reqwest | `request.client` on the worker's poller: HTTP/1.1, and HTTP/2 shared per origin when TLS negotiates it | Delivered; no redirects or decompression |
| PostgreSQL | sqlx, tokio-postgres | A native driver: SCRAM, TLS, a pool per worker with an acquire deadline, rows into `Decodable` types, transactions, prepared statements kept per connection, binary values | Delivered |
| UUIDs and timestamps | `uuid`, `chrono` or `time` | `UUID`, `Timestamp`, no Foundation | Delivered |
| Redis, SQLite | redis-rs, sqlx | None yet | Step 3 |
| Blocking work | `spawn_blocking` | None yet | Step 3 |
| Testing | `tower::ServiceExt::oneshot` | `app.test`, the real engine over a socket pair | Delivered |

Speed, on the benchmark machine at the end of step 3 (`benchmarks/vs-axum.sh`,
64 connections): Garuda served 1.71× axum's requests a second on the suite's
ramp, 1.22× closed-loop and 1.21× pinned to one core, at under half axum's p99
closed-loop. [BENCHMARKS.md](BENCHMARKS.md#against-axum-quick-comparison) has the
method.

### Where Garuda differs, and why

Each of these is a decision, not an omission. Each says what it costs you and
what to do instead.

#### Middleware does not wrap the handler

In axum, a Tower layer receives the request and a `next`, awaits the handler,
and gets its response back as a value to inspect or replace. Garuda's
middleware runs **before** the handler, and sees the response through a hook:

```swift
app.use { request, response in                      // before: refuse, or carry on
    guard request.header("authorization") != nil else { return HTTPStatus.unauthorized }
    response.onSend { outgoing in                   // after: see and change the answer
        outgoing.addHeader("access-control-allow-origin", "*")
        if outgoing.status.code >= 500 { try? outgoing.replaceBody(json: ["error": "internal"]) }
    }
    return nil
}
```

**Why.** A Garuda handler does not return a response value. It writes its
answer into the engine's response path, straight into the connection's buffer,
and an async handler does so whenever it finishes. For a `next` to hand a
response back to the middleware, every response would first have to be built
as an owned value and copied out later. That copy on every request is what
Garuda's lead over axum is made of, so the hook runs instead at the one point
every answer passes through. It runs before a byte of the head is written, and
it sees the status, headers and body there. Routes that register no hook pay
one pointer check.

**What you get.** The hook runs for every way a request is answered: the
handler, an async handler seconds later, a middleware's refusal, a thrown
error, the 500 for a handler that said nothing, and a deadline's 504. That is
what CORS, security headers, timing, access logs and a uniform error body need.
Hooks run once, the last added first, so the middleware that ran first sees the
response last, as layers nest.

**What it costs.** A middleware cannot run the handler itself. That rules out:

- retrying the handler;
- holding a scope open around the handler's run;
- using Tower's ecosystem, which does not exist in Swift anyway.

**Instead:**

- Retry inside the handler, or in the database layer. `pool.transaction` is
  where a serialization failure should be retried, and the driver already
  re-prepares a statement the server dropped.
- For a timeout, use `app.deadline(milliseconds:)`, which answers 504 and
  unwinds a waiting handler.
- For request-scoped data, have the middleware store it with
  `request[context: Key.self]` and the handler ask for `Context<Key>`.
- Hooks do not run for static files, `--cache-size` hits or the 404 before any
  route matches. Those are served by the engine, not by a route.

#### Middleware covers its whole scope, wherever `use` is called

In axum, a `layer` applies only to the routes added before it. Moving one line
leaves a route unguarded, and nothing warns you. In Garuda, `use` covers every
route in its group or the application, whether it is called before or after
them. The order of `use` calls within a scope is the order they run.
**Instead:** a route that must skip a middleware goes outside the group that
uses it.

#### One process per worker

axum runs one process with threads that share memory, so `State<T>` is one
value behind an `Arc`. A Garuda worker is a process with one thread. `app.state`
builds a value in each worker after the fork, so a pool, a client or a cache
belongs to that worker alone.

**Why.** Nothing is shared, so nothing is locked, and a request never waits on
another worker's lock. A worker that crashes takes only its own connections with
it. The supervisor can replace workers one at a time for a zero-downtime reload.

**What it costs.** A counter or cache in memory is per worker, not global. A
database pool of 8 is 8 connections a worker.

**Instead:** keep state every worker must see where it belongs anyway, in
PostgreSQL or another store. Size `maxConnections` as the total you want
divided by `--workers`.

#### A handler that computes without awaiting holds its worker

Tokio moves tasks between threads, so one busy task delays others less. A
Garuda worker is one thread. An async handler yields at every `await`, but a
loop that never awaits holds the worker until it ends. A deadline bounds
*waiting*, not computing.

**Why.** Staying on one thread is what lets a request run inline with no
scheduling hop and no cross-thread handoff.

**Instead:** run more workers than cores are busy, and keep CPU-heavy work
short. A bounded pool for blocking work, like `spawn_blocking`, is on the
roadmap (step 3).

#### Request bytes are lent, not owned

axum hands a handler an owned `Request`. Garuda's `Request` is `~Copyable` and
lends its bytes to a closure as a `Span`, which the compiler keeps from being
stored. Reading a path, header or body this way copies nothing.

**Instead:** when you need to keep a value, ask for the owned copy: `path`,
`header(_:)`, `body`. Typed extractors already produce owned values.

#### No Foundation

Garuda links the Swift standard library, not Foundation, so it brings its own
JSON coder (`JSONCoder`), `UUID` and `Timestamp`. JSON decoding reads only the
keys a type asks for, straight from the request's bytes.

**Instead:** if your code imports Foundation too, write `Garuda.UUID` where both
types are in scope.

#### PostgreSQL prepares statements on its own

Like sqlx, each connection keeps the statements it has run prepared, up to
`statementCacheCapacity` (256). Unlike sqlx, you don't opt in per query. A
statement's second run skips parsing and planning and reads bools, integers,
floats, bytea, UUIDs and timestamps in binary. The first run is text.
**Instead:** behind PgBouncer in transaction pooling mode, set
`statementCacheCapacity = 0`.

---

## What the engine does

These features are built in and covered by the end-to-end suites listed
[below](#tests):

- **HTTP/1.1**, with a parser that is strict where strictness prevents request
  smuggling. It rejects `Content-Length` together with `Transfer-Encoding`,
  disagreeing lengths, any `Transfer-Encoding` other than a bare `chunked`, and
  `obs-fold`. See [TRANSPORT.md](TRANSPORT.md).
- **HTTP/2**, over TLS by ALPN and in cleartext (h2c). `--no-http2` turns it
  off; `--http2-only` serves h2c alone.
- **HTTP/3 over QUIC** (`--http3`). QUIC, TLS 1.3 and QPACK are implemented
  here in Swift, using OpenSSL only for crypto primitives. Alt-Svc is
  advertised to TCP clients.
- **TLS** through OpenSSL. You can pass several certificates, chosen by SNI.
  `--ktls` hands encryption to the Linux kernel, so static files go out with
  `sendfile` over HTTPS too.
- **ACME certificates** (`--acme-domain`): obtained and renewed from Let's
  Encrypt or another ACME CA, answering tls-alpn-01 on the port already being
  served.
- **Static files** (`--static-dir`), sent with `sendfile`, with `ETag` and
  `If-None-Match`. With `--compress-static`, a pre-compressed `.br`, `.zst` or
  `.gz` copy is served to clients that accept it.
- **Rate limiting** (`--rate-limit`), counted across all workers, by forwarded
  address behind a trusted proxy and by /64 for IPv6.
- **HTTP to HTTPS redirects** (`--redirect-http`) and **HSTS** (`--hsts`).
- **Request IDs** (`--request-id`) and **W3C trace context** in the access log
  (`--trace-context`).
- **Graceful shutdown**, with `--drain-delay` for load balancers.
  **Zero-downtime reload** on `SIGHUP`.
- **Prometheus metrics** on a separate port (`--metrics-port`), and a
  **health check** answered inside the server (`--health-check-path`).
- **Unix sockets** (`--unix`), multi-process workers (`--workers`), and trusted
  proxy headers (`--forwarded-allow-ips`).

### Present, but nothing to act on yet

These flags are parsed and the engine code behind them exists, but nothing
reaches that code until a later step of the handler API:

- **`--compress`**: handler responses are not compressed yet. That arrives
  with streaming responses. `--compress-static` does work.
- **`--cache-size`** (and `--cache-max-object`, `--cache-ttl-max`): the cache
  never stores a handler response. That also arrives with streaming responses.
- **WebSocket**: the engine has framing code but no application API, so the
  `--ws-*` options have no route to apply to. `--no-websockets` refuses
  upgrades with 501.

[GARUDA.md](GARUDA.md) lists the end-to-end coverage that returns as the
handler API grows.

---

## Numbers

These figures come from GARUDA.md step 2, measured 2026-09-15. The load was the
suite zrk from [the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/)
(`-c N -d 15s -R1000:500000`, `GET /`), the mean of three runs. Garuda ran with
4 workers. The machine was WSL2 with 4 CPUs, shared with the load generator.
There were zero errors. Requests per second:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda router | **414,234** | **389,445** | **370,945** |
| Hummingbird | 88,864 | 102,399 | 99,706 |
| Vapor | 60,411 | 58,946 | 60,837 |

Hummingbird and Vapor are the suite's own `swift/*-framework` entries.
This is a hello-world route, measured on the built-in router that the handler
API has since replaced, so it measures what the server adds to a request, not
what an application built on it will do. Figures from different sessions on
this machine move by tens of percent. Compare rows within one table.

`benchmarks/frameworks.sh` also runs the suite's `rust/axum` entry
(`FRAMEWORKS="swift rust" SERVERS="garuda axum"`), the framework Garuda aims to
beat; the first run builds it with `cargo`. `benchmarks/vs-axum.sh` is a quick
Garuda-against-axum read at 64 connections, under two minutes, for use between
changes. Its first run, through the handler API, one run per pass, had Garuda
at 1.95× axum on the suite's ramp (390,324 against 200,048 requests a second)
and 1.72× on one pinned core (200,890 against 116,799);
[BENCHMARKS.md](BENCHMARKS.md#against-axum-quick-comparison) has every pass and
why single runs need care.

The versions, build flags, reproduction command and caveats are in
[GARUDA.md](GARUDA.md). Method and history are in [BENCHMARKS.md](BENCHMARKS.md).

---

## Signals and reload

- **`SIGTERM`** drains. Workers stop accepting and finish in-flight requests
  within `--graceful-timeout`. With `--drain-delay MS`, they first keep serving
  for `MS` with the health check answering 503, so a load balancer stops
  sending traffic before connections are refused.
- **`SIGINT` / `SIGQUIT`** shut down without the drain delay. Sent after
  `SIGTERM`, either one cuts the delay short.
- **`SIGHUP`** replaces every worker, one slot at a time. Each replacement is
  accepting before its predecessor is told to stop, so no connection is refused
  or reset. Replacements read the certificate off disk again, so this also works
  as a certificate deploy hook. ACME renewals use the same path. Everything runs
  under a supervisor, including `--workers 1`, so `SIGHUP` always works.
- **`--reload`** watches the executable, not your sources. After a rebuild
  (`swift build -c release` in another terminal), the supervisor execs the new
  file with its listening sockets kept open, then replaces the workers one slot
  at a time without dropping connections. A changed `--tls-cert` or `--tls-key`
  replaces the workers without an exec. It does not build for you.

---

## Usage

Output of `garuda --help`:

```
garuda -- a Swift web server

usage: garuda [options]

  --host HOST              interface to bind (default 127.0.0.1)
  --port PORT              port to bind (default 8000)
  --unix PATH              listen on a unix socket instead
  --workers N              worker processes, 0 = one per CPU (default 1)
  --root-path PATH         mount prefix, taken off paths before routing
  --scheme http|https      scheme taken as the request's, behind a proxy
                           that terminates TLS (keys --cache-size)
  --backlog N              listen backlog (default 2048)
  --max-connections N      concurrent connections per worker (default 4096)
  --max-body BYTES         largest accepted request body (default 16 MiB)
  --max-header-size BYTES  largest accepted request head (default 32 KiB)
  --keep-alive MS          idle keep-alive timeout (default 5000)
  --request-timeout MS     how long a request may stall mid-message (30000)
  --graceful-timeout MS    time in-flight requests get on shutdown (10000)
  --drain-delay MS         on SIGTERM, keep serving for MS with the health
                           check answering 503, so a load balancer stops
                           routing here before connections are refused
                           (default 0; SIGINT and SIGQUIT do not wait)
  --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted:
                           a comma-separated list of addresses or CIDR
                           blocks, "unix", or "*" for every peer
  --reload                 when the executable is rebuilt, restart on it
                           without dropping a connection; when a
                           --tls-cert or --tls-key file changes, replace
                           the workers
  --reload-interval MS     how often --reload looks, where the kernel
                           sends no notification (default 500)
  --tls-cert PATH          PEM certificate chain; enables TLS with ALPN.
                           Repeatable, with a --tls-key each: the first
                           pair is the default and the rest are picked by
                           SNI, using the names inside each certificate
  --tls-key PATH           PEM private key for the preceding --tls-cert
  --tls-ciphers LIST       OpenSSL cipher list for TLS 1.2
  --ktls                   let the Linux kernel encrypt TLS, so --static-dir
                           files go out with sendfile over HTTPS too
                           (needs the tls module: modprobe tls)
  --acme-domain NAME       get and renew a certificate for NAME from an
                           ACME CA (Let's Encrypt by default), answering
                           tls-alpn-01 on this port (repeatable)
  --acme-email ADDR        contact address for the ACME account
  --acme-cache DIR         where the account key and certificate live
                           (default ./acme)
  --acme-staging           use Let's Encrypt's staging CA
  --acme-directory URL     use another ACME CA
  --acme-ca-bundle PATH    roots to trust for the CA's own HTTPS
  --redirect-http PORT     answer plain HTTP on PORT with a redirect to
                           https on the TLS port (301, or 308 for methods
                           other than GET and HEAD)
  --hsts SECONDS           send Strict-Transport-Security: max-age=SECONDS
                           on every TLS response
  --no-http2               refuse HTTP/2 and answer HTTP/1.1 only
  --http2-only             serve only HTTP/2 (h2c), with no HTTP/1 fallback
  --http3                  also serve HTTP/3 over QUIC (needs TLS)
  --quic-port PORT         UDP port for HTTP/3 (default: the TCP port)
  --no-websockets          reject WebSocket upgrades with 501
  --ws-max-message BYTES   largest accepted WebSocket message (16 MiB)
  --ws-ping-interval MS    keepalive ping period, 0 to disable (20000)
  --ws-ping-timeout MS     how long an unanswered ping may go (20000)
  --ws-max-queue N         messages buffered for a slow handler (default 32)
  --ws-max-queue-bytes N   bytes buffered for a slow handler (4 MiB)
  --ws-compress            negotiate permessage-deflate with WebSocket
                           clients that offer it
                           (the --ws-* settings have no effect until
                           WebSocket handlers exist)
  --static-dir P=DIR       serve URL prefix P from DIR with sendfile,
                           before routing (repeatable). A path with no
                           file behind it still reaches the routes
  --rate-limit RATE        refuse a client with 429 past RATE requests, as
                           in 100/s, 600/m or 5000/h; counted across all
                           workers, by the forwarded address behind a
                           trusted proxy and by /64 for IPv6
  --rate-limit-burst N     requests allowed at once before the rate
                           applies (default: the count in RATE)
  --cache-size MIB         answer repeated GETs from a cache shared by
                           every worker, for responses a handler marks
                           fresh with Cache-Control s-maxage or max-age;
                           read CONFIG.md first (nothing is stored yet)
  --cache-max-object KIB   largest body the cache keeps (default 1024)
  --cache-ttl-max SECONDS  longest a response is kept (default 300)
  --compress               compress handler responses (br, zstd or gzip,
                           as the client accepts) when their type is
                           text-like; read CONFIG.md about BREACH first
                           (handler responses are not compressed yet)
  --compress-min-size N    leave bodies declared smaller than this as they
                           are (default 1024)
  --compress-static        serve FILE.br, FILE.zst or FILE.gz beside a
                           --static-dir file to clients that accept it
  --request-start-header   give handlers X-Request-Start: t=<usec> for
                           when the request arrived, for APM agents that
                           report queue time
  --request-id             give every request an X-Request-ID, echoed on
                           the response and in the access log; one from a
                           --forwarded-allow-ips proxy is kept
  --trace-context          record a request's W3C traceparent, its trace
                           and parent span IDs, in the access log
  --health-check-path P    answer P with 200 before routing (e.g.
                           /healthz)
  --access-log             log one line per request
  --access-log-format F    text (default) or json; implies --access-log
  --metrics-port PORT      serve Prometheus metrics on this port
  --metrics-host HOST      what the metrics port binds (default --host)
  --log-level LEVEL        debug, info, warning, error, silent
  --version                print the version and exit
  -h, --help               print this message

examples:
  garuda --port 8080
  garuda --workers 0 --host 0.0.0.0
  garuda --unix /run/app.sock --workers 4 \
            --forwarded-allow-ips 10.0.0.0/8
```

Flags the help marks as having no effect yet configure engine code that later
steps of the handler API will reach ([HANDLER-API.md](HANDLER-API.md#roadmap)).
Timeouts are in milliseconds.
[CONFIG.md](CONFIG.md) covers the flags in depth.

### Behind a reverse proxy

`--forwarded-allow-ips` controls trust. `X-Forwarded-*` and `Forwarded` headers
are honoured only from a peer on that list and ignored from anyone else, since a
client can send them too. The forwarded client address is what `--rate-limit`
counts. A request ID from a trusted proxy is kept by `--request-id`. A handler
reads the forwarded client and scheme as `request.remoteAddress`,
`request.remotePort` and `request.scheme`.

---

## Tests

Unit tests, including the fuzz corpus:

```bash
swift test                                   # 288 tests
bash scripts/compile-fail-test.sh            # 6   handler code that must not compile
```

The end-to-end suites run against the release binary, `.build/release/garuda`
by default. Each takes another binary path as its first argument. They are
answered by the binary's routes and the server's own features, so no
application is needed. `handler-test.py` and `webtransport-test.py` run
`.build/release/garuda-conformance` instead
(`swift build -c release --product garuda-conformance`), whose routes exist
only to make engine behaviour observable to the tests; it is not benchmarked
or meant as an example:

```bash
bash scripts/integration-test.sh             # 36  HTTP/1.1 framing, keep-alive,
                                             #     pipelining, smuggling defences
bash scripts/static-test.sh                  # 42  --static-dir
bash scripts/compress-test.sh                # 28  --compress-static
bash scripts/ratelimit-test.sh               # 18  --rate-limit
bash scripts/redirect-test.sh                # 22  --redirect-http, --hsts
bash scripts/sni-test.sh                     # 11  several certificates by SNI
bash scripts/acme-test.sh                    # 12  --acme-domain (needs local Pebble)
bash scripts/request-id-test.sh              # 12  --request-id
bash scripts/trace-context-test.sh           # 17  --trace-context
bash scripts/drain-test.sh                   # 14  --drain-delay
bash scripts/reload-test.sh                  #  7  SIGHUP under load
python3 scripts/feature-test.py              # 62  shutdown, supervision, unix
                                             #     sockets, slow clients
<venv>/bin/python scripts/http2-test.py      # 50  against `h2`
<venv>/bin/python scripts/http3-test.py      # 53  against `aioquic`
<venv>/bin/python scripts/router-streams-test.py  # 41  routes over h2 and h3
<venv>/bin/python scripts/handler-test.py    # 136 the handler API: bodies over h1,
                                             #     h2 and h3, headers, client,
                                             #     scheme, request IDs, framing,
                                             #     streamed responses and events,
                                             #     errors, lifecycle hooks
<venv>/bin/python scripts/webtransport-test.py # 46 sessions, streams, datagrams,
                                             #     closing, against `aioquic`
```

The shell suites need `curl`, and some need `openssl`, `nc` or `python3`; each
script's header says which. Python appears only as a test client: `h2` and
`aioquic` are independent implementations that share no code with the server.
`feature-test.py` uses only the standard library.

Fuzzing covers every parser that reads bytes from the network:

```bash
swift run -c release pgfuzz
```

See [fuzz/README.md](fuzz/README.md).

**What CI runs.** [`.github/workflows/ci.yml`](.github/workflows/ci.yml) is
started by hand (`workflow_dispatch`). It builds the release binary and runs
`swift test` on Linux (Swift 6.1.2, Ubuntu 24.04) and macOS 15. It also runs
`pgfuzz` for 60 seconds under AddressSanitizer. The end-to-end suites above are
not run in CI.

---

## Not supported

- **A stable handler API.** Streamed request bodies, WebSocket handlers, router values to merge, custom fallbacks, ready-made CORS and auth
  middleware, Redis, SQLite and a blocking pool are not there yet. See [HANDLER-API.md](HANDLER-API.md) and
  [GARUDA.md](GARUDA.md).
- **Byte ranges, directory indexes and `Last-Modified` for `--static-dir`.** It
  serves assets with an `ETag`; it is not a file server.
- **Compressing static files on the fly.** `--compress-static` serves copies
  compressed ahead of time. A file with no copy is sent as it is.
- **QUIC session resumption and 0-RTT.** Every HTTP/3 handshake is a full one.
- **Pure-Swift TLS over TCP.** It is OpenSSL (`Sources/CGaruda/garuda_tls.c`).
- **Windows.** The I/O layer is epoll and kqueue. WSL 2 works.

---

**Further reading:** [GARUDA.md](GARUDA.md) is the status, plan and
measurements. [HANDLER-API.md](HANDLER-API.md) is the handler API and its
roadmap. [INSTALLATION.md](INSTALLATION.md) covers building, certificates
and deployment. [CONFIG.md](CONFIG.md) covers the flags.
[ARCHITECTURE.md](ARCHITECTURE.md) explains how the engine is built.
[TRANSPORT.md](TRANSPORT.md) describes what each protocol does.
[BENCHMARKS.md](BENCHMARKS.md) has the benchmark method.
