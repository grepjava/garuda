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
swift test                             # 561 unit tests
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
python3 scripts/feature-test.py        # 62
python3 scripts/http2-test.py          # 50
python3 scripts/http3-test.py          # 53
python3 scripts/router-streams-test.py # 41
python3 scripts/handler-test.py        # 143, runs garuda-conformance
python3 scripts/websocket-test.py      # 104, runs garuda-conformance
python3 scripts/webtransport-test.py   # 46, runs garuda-conformance
python3 scripts/upload-test.py         # 35, runs garuda-conformance
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
- `Router` holds routes, middleware, groups, deadlines and fallbacks built on
  their own. `app.nest("/users", router)` mounts one under a prefix and
  `app.merge(router)` registers it where the call is, inside the open group,
  whose middleware runs in front of the router's. Routers nest, and one router
  can be mounted twice. Every registration API, typed routes, WebSockets,
  WebTransport and resumable uploads included, works on both.
- `app.fallback { request, response in … }` answers requests no route matches,
  in place of 404, with the middleware of its scope. Inside a group or a
  nested router it answers only under that prefix, and the most specific
  scope wins. A path routed under other methods is still 405.
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
- `try await blocking { … }` runs a call that would block the worker -- a C
  library, disk I/O, a long computation -- on a thread of the worker's blocking
  pool, and resumes the handler on the worker with what it returns or throws.
  Threads start as work arrives, up to `--blocking-threads` (16) per worker;
  work beyond them waits, up to `--blocking-queue` (1024), and past that is
  refused with `BlockingPoolError.full`, a 503. The closure is `@Sendable`, and
  `Path`, `Query` and `Body` are `Sendable` when their values are.

### Middleware

- `app.use` runs middleware before every route in its scope, whether it is
  called before or after the routes. It returns nil to carry on or an answer to
  send instead, and may be async.
- `response.onSend { outgoing in … }` sees the final response, whoever
  answered, and can change its status, headers and body. Hooks run last-added
  first. They do not run for static files, cache hits, or answers given before
  a route is chosen.
- `app.cors(CORSPolicy(origins: […]))` sets the CORS policy of a scope: the
  application, a group or a router, the innermost winning. Origins are any, a
  list, or a closure's decision; methods and request headers are a list or
  what the path is routed for and the preflight asks for; exposed headers,
  credentials and max age are set with it. Any origin with credentials is
  refused when the policy is made.
- The policy answers a preflight 204 whether or not the path has an OPTIONS
  route, so a path routed only for GET no longer answers a preflight 405. It
  runs in front of the scope's middleware, so a preflight skips
  authentication, and a refusal or thrown error from an allowed origin carries
  Access-Control-Allow-Origin. `Vary` names what the answer depends on.
- `app.authenticate(bearer: Key.self) { token in … }` and
  `app.authenticate(basic: Key.self, realm:) { username, password in … }`
  read the Authorization header, keep what the closure returns under `Key` in
  the request's context, and answer 401 with the WWW-Authenticate challenge for
  a missing, malformed or refused one. The closure may be async, and a throw
  answers as a handler's does.
- `BearerToken` and `BasicCredentials` extract the same credentials in a
  handler, and `constantTimeEquals` compares a secret in time that does not
  depend on where it differs.

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

### Streamed request bodies, interim responses and resumable uploads

- `app.onStreamingBody(.post, "/upload", maxBodySize:) { request, response, body in … }`
  runs when the request's head arrives. `body.read(maxBytes:)` returns the next
  piece, or nil at the end, and `readAll(maxBytes:)` the rest. `maxBodySize`
  replaces `--max-body` for that route and is unlimited if left out.
- Reading is flow control. Unread bytes hold back an HTTP/1.1 connection's
  reads, the HTTP/2 stream window and the QUIC stream window, so a handler
  that writes to a slow disk slows only its own client.
- A body that ends short throws `RequestBodyError.incomplete`, but only after
  everything that did arrive has been read. `body.cancel()` ends the request.
  Two reads at once throw `concurrentRead`.
- `response.sendInterim(status:headers:)` sends a 1xx before the answer, such
  as 103 Early Hints, on HTTP/1.1, HTTP/2 and HTTP/3. It does nothing on
  HTTP/1.0 or once the answer has started.
- A new module, `GarudaUploads`, implements resumable uploads
  (draft-ietf-httpbis-resumable-upload-12, interop version 9):
  `app.resumableUploads("/files", store: FileUploadStore(directory:)) { upload in … }`.
  A client that is cut off asks for the offset with HEAD or GET, and appends
  the rest with PATCH. Creation can be POST, PUT or PATCH.
  - Only a client that sends `Upload-Draft-Interop-Version: 9` gets 104
    responses, as the draft requires.
  - `UploadLimits` sets `max-size`, `max-append-size` and `max-age`, advertised
    in `Upload-Limit` and enforced as the body arrives, including bodies with no
    declared length.
  - A wrong offset or inconsistent length is answered with the draft's problem
    documents.
  - Only one request appends to an upload at a time, across worker processes,
    through a file lock. A client that resumes on the same worker while its old
    request is still open ends the old one, keeping what it received.
- `scripts/upload-test.py` (35 checks) covers streamed bodies, flow control,
  per-route limits, interim responses and uploads over HTTP/1.1, HTTP/2 and
  HTTP/3, including resuming after a dropped connection and a reset QUIC
  stream.

### WebSockets

- `app.webSocket("/chat/:room", subprotocols: ["chat.v2"]) { (ws: WebSocket, room: Path<String>) async throws in … }`
  serves RFC 6455 over HTTP/1.1, cleartext or TLS. Middleware and extractors
  run before the upgrade and can refuse it with an ordinary status; headers
  middleware adds go out with the 101. A plain request to the route is 426.
- The handler sees whole messages: `receive()`, or `for try await message in ws`,
  and `send` of text or bytes, which waits while the peer reads slowly.
  `close(code:reason:)` starts the close handshake, `closeCode` and
  `closeReason` say how the peer ended it, and `sleep(milliseconds:)` waits on
  the worker between sends.
- The engine joins fragments, checks UTF-8 as frames arrive, answers pings and
  closes, sends keepalive pings, and refuses protocol violations with the close
  code RFC 6455 gives them, whether or not the handler is reading. With
  `--ws-compress`, permessage-deflate is agreed and a message that inflates past
  `--ws-max-message` is refused.
- Messages a handler has not read wait in a queue bounded by `--ws-max-queue`
  and `--ws-max-queue-bytes`; past that the socket is not read.
- A handler that returns closes with 1000, one that throws with 1011, and a
  draining worker closes its WebSockets with 1001.
- Each WebSocket's handler runs on a task of its own, so open WebSockets do not
  take tasks from the pool ordinary requests use.
- The Autobahn testsuite's 517 cases pass: none fail, and the three marked
  non-strict (6.4.2 to 6.4.4) check UTF-8 inside a frame, which the engine
  checks once the frame has arrived.
- `app.test.webSocket("/path")` opens a WebSocket in a test: `send`, `receive`,
  `ping` and `close`, with the 101 or the refusal in `response` and the
  server's close in `closeCode` and `closeReason`.

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
- The client sends Accept-Encoding with the codings it can decode (gzip and
  deflate, brotli and zstd when their libraries load) and decodes the body,
  removing Content-Encoding and Content-Length. The decoded body is held to
  `maxBodyBytes` as it grows, and a corrupt one is `undecodableBody`. A coding
  it cannot decode is returned as it came. With `decompress = false` the caller
  may send its own Accept-Encoding.
- `client.redirects` follows redirects: `.none` (the default), `.sameOrigin()`,
  `.any()` or `.matching { url in … }`, each with a limit (10), past which is
  `tooManyRedirects`. 303, and 301 or 302 after a POST, become a GET without
  the body; 307 and 308 repeat the request. Leaving the origin drops
  Authorization, Cookie and Proxy-Authorization, and https is never left for
  http. A redirect the policy does not follow is the response.
  `ClientResponse.url` is where the request ended up.

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
- The protocol and systems layers moved to
  [aviancore](https://github.com/grepjava/aviancore), a package of their own:
  `CAvian`, `AvianCore`, `AvianHTTP` and `AvianQUIC`, in place of `CGaruda`,
  `GarudaCore`, `GarudaHTTP` and `GarudaQUIC`. Code that imported those modules
  imports the Avian ones, and the C functions are named `av_` instead of `pg_`.
  Their unit tests run in aviancore.
- `GARUDA_UDP_GSO` and `GARUDA_NO_OPENAT2` are now `AVIAN_UDP_GSO` and
  `AVIAN_NO_OPENAT2`.

### Fixed

- A QUIC stream reset before it had sent anything could be forgotten before its
  RESET_STREAM went out, keeping its stream credit until the connection closed.
  A reset side now counts as finished once the reset is sent.
- An HTTPS/1.1 client request to a TLS 1.3 server could fail as `closed` when
  the server's session ticket arrived before its response.

### Not yet

- WebSocket over HTTP/2 and HTTP/3, and shipped middleware for tracing.
  Middleware cannot wrap a handler's run.
- `--compress` and `--cache-size` do not act on handler responses.
- WebTransport is HTTP/3 only.
- Resumable uploads have no `min-size` or `min-append-size` and no digests,
  and a completed upload is not replayed. A request still appending on
  another worker is waited for briefly, then the new request gets 409 with
  Retry-After. Expired uploads are removed when uploads are created.
- A body over its limit is refused with a stream reset on HTTP/2, where
  HTTP/1.1 and HTTP/3 answer 413.
- PostgreSQL has no `date`, `time`, `interval`, `numeric` or `json` types of
  its own (they read as text), no `LISTEN`, and no SASLprep for non-ASCII
  passwords. No Redis or SQLite driver.
- TLS over TCP is OpenSSL.
