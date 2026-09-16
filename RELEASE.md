<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Releases

**Garuda has not been released.** No tag or package has been published. The
tags `v1.0.0` to `v1.1.5` in this repository predate Garuda and do not describe
it.

**Keeping this file.** A change someone using Garuda would notice gets a line
under [Unreleased](#unreleased) in the commit that makes it. When a version is
cut, that section is renamed to the version and its date, and a new empty
Unreleased section goes above it.

**Before cutting a version.** CI (`.github/workflows/ci.yml`) is started by
hand. It builds the release binary and runs `swift test` on Ubuntu 24.04 and
macOS 15, and fuzzes the parsers with `pgfuzz` for 60 seconds under
AddressSanitizer. The end-to-end suites are not in CI. Run them against the
release build:

```bash
swift build -c release
swift test                             # 752 unit tests
bash scripts/compile-fail-test.sh      # 6
bash scripts/integration-test.sh       # 36
bash scripts/static-test.sh            # 42
bash scripts/compress-test.sh          # 28
bash scripts/ratelimit-test.sh         # 18
bash scripts/redirect-test.sh          # 22
bash scripts/sni-test.sh               # 11
bash scripts/acme-test.sh              # 12, needs Pebble (PEBBLE_DIR)
bash scripts/request-id-test.sh        # 12
bash scripts/trace-context-test.sh     # 17
bash scripts/drain-test.sh             # 14
bash scripts/reload-test.sh            # 7
bash scripts/cache-unit-test.sh
python3 scripts/feature-test.py        # 62
python3 scripts/http2-test.py          # 50
python3 scripts/http3-test.py          # 53
python3 scripts/router-streams-test.py # 41
python3 scripts/handler-test.py        # 136, runs garuda-conformance
python3 scripts/webtransport-test.py   # 46, runs garuda-conformance
```

The Python suites need `h2` and `aioquic`.

---

## Unreleased

### Applications and routes

- `Application` registers handlers by method and pattern: literal, `:param`
  and trailing `*rest` segments, at most 8 parameters, compiled into a byte
  trie. HEAD falls back to GET. A path routed under other methods is answered
  405 with `Allow`.
- `app.run()` parses the command line and runs the supervisor.
  `app.run(configuration:)` takes a `ServerConfig`, checked the same way.
  `onWorkerStart` and `onWorkerShutdown` hooks run in each worker.
- `app.group("/api") { … }` mounts routes under a prefix, and groups nest.
  `--root-path` is the mount every route is matched within.
- `app.test` serves the application from a worker in the test process over a
  socket pair: `try app.test.get("/user/42")` returns the status, headers and
  body.
- The `garuda` binary serves the-benchmarker's contract through this API.
  `garuda-conformance` holds the routes the end-to-end suites need.

### Requests and responses

- `Request` and `Response` are `~Copyable`. The request lends its bytes to
  closures as `Span`s (`withPath`, `withHeader`, `withBody` and others), and the
  compiler refuses a handler that lets one escape. `path`, `header(_:)`, `body`
  and the rest return owned copies. `request[context: Key.self]` holds typed
  values for the rest of the request.
- Every response goes through one path. It frames 204, 304 and HEAD, adds the
  server's headers unless the handler set its own, and holds the body to a
  declared `Content-Length`. A handler that throws or never answers gets a 500.
- `HTTPStatus` names statuses and still takes an integer literal.
  `send(json:)`, `send(text:)`, `send(html:)`, `send(bytes:contentType:)` and
  `redirect(to:status:)` set the content type they imply.
- `JSONCoder` encodes and decodes `Encodable` and `Decodable` types without
  Foundation. Decoding reads only the keys a type asks for. Nesting is bounded
  at 64, a number that does not fit its type is an error, and the coder is
  fuzzed.

### Typed handlers

- A handler declares extractors and returns an answer:
  `app.get("/person/:id") { (id: Path<Int>) in JSON(person(id.value)) }`.
  `Path<T>`, `Query<T>`, `Body<T>` (JSON), `Form<T>`, `Multipart`, `State<T>`
  and `Context<Key>` are built in, and `RequestExtractor` makes more. A value
  that will not decode is a 400 saying what was wrong. A body of the wrong kind
  is a 415.
- Handlers return `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an
  `HTTPStatus`, or an Optional whose nil is a 404.
- A thrown `ResponseError` is the response: `HTTPError(.conflict, "the name is
  taken")` answers 409 with a JSON body. Other errors are a 500 and a log line.
- `app.state { worker in … }` builds a value once in each worker, after the
  fork and before it reports ready. A factory that throws stops that worker's
  start-up. An optional `shutdown:` tears the value down.
- `Multipart` gives each part's name, filename, content type and bytes, up to
  1,000 parts.

### Async handlers

- A closure that awaits registers as an async handler under the same names.
  `app.onAsync` is the raw form. Handlers run on long-lived tasks reused from a
  pool on each worker's own executor, on the worker's thread. After warm-up an
  async request allocates nothing.
- `app.deadline(milliseconds:)` answers 504 for a request still unanswered at
  its deadline, and unwinds a handler waiting on the engine. It bounds waiting,
  not computing.
- A closed connection or reset stream cancels a handler waiting on the engine.
  An answer to a request that has gone is dropped rather than written into the
  next request on the slot.
- Handlers registered from `main.swift` take `sending` closures, so they run on
  the worker rather than being isolated to the main actor.

### Middleware

- `app.use` runs middleware before every route in its scope, whether it is
  called before or after the routes. It returns nil to carry on or an answer to
  send instead, and may be async.
- `response.onSend { outgoing in … }` sees the final response, whoever
  answered, and can change its status, headers and body. Hooks run last-added
  first. They do not run for static files, cache hits, or answers given before
  a route is chosen.

### Streaming responses and server-sent events

- `response.stream(contentType:)` or a returned `StreamingBody` writes a body as
  it is produced: chunked on HTTP/1.1, close-delimited on HTTP/1.0, DATA frames
  on HTTP/2 and HTTP/3. A `Content-Length` the handler sets is kept and
  enforced.
- A write waits while more than `writeHighWaterMark` (512 KiB) is queued,
  until the backlog is under `writeLowWaterMark` (128 KiB). `queuedBytes` says how far behind the
  client is, including what QUIC holds unacknowledged. A client that stops
  reading is closed after `--request-timeout`.
- Returning or `finish()` ends the body. A throw part-way closes the HTTP/1.1
  connection or resets the stream, so a client never takes half a body for a
  whole one.
- `EventStream` and `response.eventStream()` send server-sent events. Data is
  split into one `data:` line per line, a line break cannot start a field in an
  event name or ID, and `cache-control: no-cache` is set unless the handler set
  its own.

### WebTransport

- `app.webTransport("/room/:id") { (session: WebTransportSession, id: Path<Int>) async throws in … }`
  serves HTTP/3 extended CONNECT. Middleware and extractors can refuse a
  session with an ordinary status. A session accepts and opens streams in both
  directions, sends and receives datagrams, and closes with a code and reason.
- Stream bytes stay in the transport until the handler reads them, and writes
  wait above `writeHighWaterMark`. At most 32 streams are held for a session
  not yet accepted. Datagrams a handler is slow to read are dropped oldest
  first.

### HTTP client

- `request.client` makes HTTP requests from a handler: `get`, `head`, `post`
  and `send`. It speaks HTTP/1.1, and HTTP/2 over TLS when the server offers
  it. An HTTP/2 connection is shared by every request to the same origin.
- Connections are opened on the worker's poller and kept for reuse, only for
  the same destination and verification identity, and only when the previous
  response was read whole.
- Outbound TLS verifies the certificate against the name or address asked for.
- Names are resolved on the poller from `resolv.conf`: UDP with TCP fallback,
  cached for their TTL. Every address in an answer is tried in order.
- Headers that could split a request are refused, and so are URLs with
  userinfo. A response to HEAD and a 204 carry no body whatever they declare.

### PostgreSQL

- A native driver on the worker's poller, with no libpq. A `PostgresPool` per
  worker runs `query`, `first` and `execute`. Rows decode into `Decodable`
  types by column name, values are bound as parameters, and a refused
  statement's SQLSTATE is `error.sqlState`.
- SCRAM-SHA-256, verifying the server's signature. MD5 is refused, and
  cleartext passwords are refused unless allowed and never sent without TLS.
  TLS is required by default.
- `db.transaction { tx in … }` commits when the closure returns and rolls back
  when it throws, or when a statement inside it failed. A connection left
  inside a transaction is closed, not pooled.
- A statement waiting for a connection gives up after
  `acquireTimeoutMilliseconds` with `PostgresClientError.poolTimedOut`.
- Each connection keeps up to `statementCacheCapacity` (256) statements
  prepared. A statement the server dropped is prepared again and retried
  outside a transaction. Repeated statements read booleans, integers, floats
  and bytea in binary.
- `[UInt8]` binds as `bytea`. `UUID` and `Timestamp` bind as `uuid` and
  `timestamptz`, and decode from text or binary, without Foundation.
- Sessions start with `client_encoding` UTF8 and `DateStyle` ISO.

### Server

- `--reload` watches the executable. When a rebuild holds still and answers
  `--version`, the supervisor execs it with its listening sockets open and
  replaces the workers one at a time. A changed `--tls-cert` or `--tls-key`
  replaces the workers without an exec.
- `--no-websockets` refuses an upgrade with 501 before anything else answers
  it.
- `--request-start-header` is read by handlers as `request.requestStart`, and
  `--scheme` is the scheme `request.scheme` falls back to.
- No target sets unsafe build flags, so Garuda can be depended on by version.

### Fixed

- A QUIC stream reset before it had sent anything could be forgotten before its
  RESET_STREAM went out, keeping its stream credit until the connection closed.
  A reset side now counts as finished once the reset is sent.
- An HTTPS/1.1 client request to a TLS 1.3 server could fail as `closed` when
  the server's session ticket arrived before its response.

### Not yet

- WebSocket handlers, streamed request bodies, router values to merge, custom
  fallbacks, and shipped middleware for authentication, CORS and tracing.
  Middleware cannot wrap a handler's run.
- `--compress` and `--cache-size` do not act on handler responses.
- WebTransport is HTTP/3 only.
- PostgreSQL has no `date`, `time`, `interval`, `numeric` or `json` types of
  its own (they read as text), no `LISTEN`, and no SASLprep for non-ASCII
  passwords. No Redis or SQLite driver, and no pool for blocking work.
- The HTTP client does not follow redirects or decompress.
- TLS over TCP is OpenSSL.
