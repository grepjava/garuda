<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Releases

What changed in Garuda, newest first, and before it in Peregrine, the Python
ASGI and WSGI server Garuda was forked from at 6200167 on 2026-09-14.

**Garuda has not been released.** No tag or package has been published for it.
The tags `v1.0.0` to `v1.1.5` in this repository are Peregrine's, as is every
version under [Peregrine, before the fork](#peregrine-before-the-fork), and the
`peregrine-server` package on PyPI is Peregrine. Nothing in that section
describes this binary.

**Keeping this file.** A change someone using Garuda would notice gets a line
under [Unreleased](#unreleased) in the commit that makes it. When a version is
cut, that section is renamed to the version and its date, and a new empty
Unreleased section goes above it. There is no release pipeline yet: nothing
builds or publishes a package, and Peregrine's wheel and PyPI steps do not
apply.

**Before cutting a version.** CI (`.github/workflows/ci.yml`) is started by
hand, not on push. It builds `swift build -c release --product garuda` and runs
`swift test` (unit tests and the fuzz corpus) on Ubuntu 24.04 with Swift 6.1.2
and on macOS 15 with the newest installed Xcode, and fuzzes the parsers with
`pgfuzz` for 60 s under AddressSanitizer. The end-to-end scripts are not in
CI. Run them against the release build; each takes the binary's path as its
first argument, defaulting to `.build/release/garuda`
(`.build/release/garuda-conformance` for `handler-test.py`):

```bash
swift build -c release
swift test                             # 659 unit tests
bash scripts/compile-fail-test.sh      # 6, after swift build
bash scripts/static-test.sh            # 42
bash scripts/ratelimit-test.sh         # 18
bash scripts/sni-test.sh               # 11
bash scripts/acme-test.sh              # 12, needs Pebble (PEBBLE_DIR)
bash scripts/redirect-test.sh          # 22
bash scripts/integration-test.sh       # 36
bash scripts/request-id-test.sh        # 12
bash scripts/trace-context-test.sh     # 17
bash scripts/drain-test.sh             # 14
bash scripts/reload-test.sh            # 7
bash scripts/compress-test.sh          # 28
python3 scripts/feature-test.py        # 62
python3 scripts/http2-test.py          # 50
python3 scripts/http3-test.py          # 53
python3 scripts/router-streams-test.py # 41
python3 scripts/handler-test.py        # 107
bash scripts/cache-unit-test.sh
```

The scripts need curl and openssl, and python3 with the client libraries the
Python scripts import (`h2` for HTTP/2, `aioquic` for HTTP/3).

---

## Unreleased

Garuda, forked from Peregrine at 6200167 on 2026-09-14.

### CPython removed

- The engine is renamed Garuda. CPython, ASGI, WSGI and the Python package are
  gone: `Package.swift` has no CPython, and a Garuda binary links OpenSSL, zlib
  and the Swift runtime, not `libpython`. There are no wheels and no
  `pip install`.

### A handler API, first phase

- The library product `Garuda` has a public handler API, early and still
  changing ([HANDLER-API.md](HANDLER-API.md)). An `Application` registers
  handlers by method and pattern (literal, `:param` and trailing `*rest`
  segments, at most 8 parameters), compiled into a byte trie when it first runs
  or is tested; HEAD falls back to GET. A `~Copyable` `Request` gives the
  method, path, query, parameters, version, scheme, authority, headers, the
  whole body, the client with `--forwarded-allow-ips` applied, the request ID
  and the request start. A `~Copyable` `Response` sets a status and headers,
  sends, or waits with `after(milliseconds:then:)`.
- Request bytes are lent, not handed out. `withPath`, `withParameter`,
  `withHeader`, `withBody` and the rest pass a `Span` to a closure, and the
  compiler refuses a handler that stores one, returns it or captures it in a
  continuation. `path`, `parameter(_:)`, `header(_:)`, `body` and the rest make
  owned copies for a handler to keep. The accessors that returned raw
  `ByteSpan`s are gone.
- `request[context: Key.self]` replaces `locals`: typed values for the rest of
  a request, across `after`, tagged with the request so they never reach the
  next one on the connection.
- Each worker keeps a pool of handler tasks on an executor of its own, the
  ground async handlers will be registered on in a later phase. A task is
  reused rather than made per request: after warm-up an async request
  allocates nothing, measured by counting the worker's own heap allocations
  over a thousand requests. Tasks run only on their worker's thread, in the
  same loop turn as the request; closing a connection or resetting a stream
  cancels the handler's wait and returns its task to the pool. A worker that
  serves only synchronous handlers never makes one.
- `JSONCoder.encode` and `JSONCoder.decode` are Garuda's own JSON coder, over the
  standard library's `Encodable` and `Decodable`: `JSONEncoder` and
  `JSONDecoder` are Foundation, which Garuda does not link. The writer streams
  a value out with no tree in between; the reader proves a document is JSON
  once and then reads only the keys the type asks for, so a request body costs
  what the handler takes from it rather than what it contains. Objects and
  arrays may nest 64 deep, a number that does not fit its type is an error
  rather than a silent wrap, and the coder is fuzzed.
- Answers have types. `HTTPStatus` names the statuses and still takes an
  integer literal, so `response.send(status: .created, json: user)` and
  `response.status == .ok` read as themselves while an unnamed code still
  works. `send(json:)`, `send(text:)`, `send(html:)`,
  `send(bytes:contentType:)` and `redirect(to:status:)` each set the content
  type they imply unless the handler set one, and a JSON answer is encoded
  into a buffer the worker keeps rather than a fresh one per request.
- Errors can be answers. An error conforming to `ResponseError` becomes the
  response it describes: `throw HTTPError.notFound` answers 404, and
  `HTTPError(.conflict, "the name is taken")` answers 409 with
  `{"error":"the name is taken"}`, escaped by the coder. `JSONError` conforms,
  so a body that is not what it claimed is a 400 naming the key at fault.
  An error that conforms is an answer rather than a fault and is not logged as
  one; anything else thrown is still a 500 and a log line.
- Handlers can declare what they need and return what they mean:
  `app.get("/person/:id") { (id: Path<Int>) in JSON(person(id.value)) }`.
  Registration is generic over a pack of extractors, so a handler takes none,
  one or several: `Path<Value>` for the next path parameter, percent-decoded;
  `Query<Value>` for the whole query string decoded into a type, where a
  repeated name is a list, an absent one is nil if the type allows it and `+`
  is a space; and `Body<Value>` for a JSON body. What the handler returns
  writes itself — `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an
  `HTTPStatus`, or an Optional whose nil is the ordinary 404. Everything that
  will not decode answers the same way: a 400 whose body says what was wrong.
  The raw `(borrowing Request, inout Response)` handlers register through the
  same names and are unaffected.
- Workers can build typed state. `app.state { worker in try Pool.connect() }`
  runs once in each worker, after the fork and before it reports ready, and a
  handler asks for it by type with `State<Pool>`, alongside the other
  extractors. One value per type. A factory that throws stops that worker's
  start-up with its error — the child exits 1 and the supervisor sees the
  readiness pipe hang up — instead of serving without what it needed, and an
  optional `shutdown:` tears the value down once the worker's loop has ended.
  Asking for state nobody registered answers 500 naming the type. Because each
  worker is a process, what a factory builds belongs to that worker alone; an
  object captured before the fork is copied into each worker, not shared.
- Forms and uploads have types too. `Form<Value>` decodes an
  `application/x-www-form-urlencoded` body — a query string in the body, read
  by the same decoder — and `Multipart` cuts a `multipart/form-data` body into
  parts, each with its name, the client's filename when it sent one, its own
  content type and its bytes: `form.text("title")`, `form.file("avatar")`,
  `form.all("tag")`. The body has already been read whole, up to `--max-body`,
  so this is a parse rather than a stream, bounded by that limit and by a cap
  of 1,000 parts. A body sent as the wrong kind of document answers 415, which
  is not the same as the 400 a malformed one gets.
- `app.run()` parses the usual flags and runs the supervisor, and
  `app.run(configuration:)` serves a `ServerConfig` instead, checked the way
  the command line is. `onWorkerStart` hooks run in each worker before it
  reports ready, and `onWorkerShutdown` hooks after its loop ends. The routes
  and hooks belong to the application, not the process.
- `app.test` serves the application's routes from a worker in the test
  process, over a socket pair and with no port bound: parsing, routing,
  handlers, timers and the response sink run as they do in a server.
  `try app.test.get("/user/42")` returns the status, headers and body.
- Applications write `import Garuda`: the engine's module, formerly
  `GarudaServer`, is named `Garuda`. The executable's sources moved to
  `Sources/garuda-server`; the binary is still `garuda`.
- Garuda can be depended on by version. No target sets unsafe build flags any
  more; `-enforce-exclusivity=unchecked` went from `Package.swift` at a cost of
  0.6% at 64 connections. A CI job builds a package that depends on Garuda by
  version, which SwiftPM refuses while any target sets unsafe flags.
- Every handler response goes through one response sink. It frames 204, 304
  and HEAD, adds the server's own headers unless the handler set its own
  `X-Request-ID`, `Strict-Transport-Security` or `Alt-Svc`, and holds the body
  to a declared `Content-Length`. A handler that throws, or returns without
  answering, gets a 500.
- The `garuda` binary serves the-benchmarker's contract through that API:
  `GET /` → 200, empty body; `GET /user/:id` → 200, the id as the body;
  `POST /user` → 200, empty body; `GET /delay/:ms` → 200 after a timer. HEAD is
  answered wherever GET is; a known path under another method is 405, and any
  other path is 404. The hand-written router (`Router.swift`) is gone.
- `--request-start-header` is read by handlers as `request.requestStart`, and
  `--scheme` is the scheme `request.scheme` falls back to.
- Waiting work runs on a worker-owned async substrate: request continuations
  and pooled operation records, a timer heap and a worker-local ready queue,
  with no scheduling hop before a response that can finish at once. `GET /`
  allocates no operation. Timer deadlines come from the precise clock, so a
  delay never resumes early.
- Routes answer alike over HTTP/1.1, HTTP/2 and HTTP/3: `/user/:id` with
  its body, `/delay/:ms` after its timer. A stream cancelled while it waits
  takes its timer with it.

### A handler API, second phase: handlers that wait

- Handlers can await. A typed route takes an `async throws` closure under the
  same names as a synchronous one — `app.get("/report") { (id: Path<Int>) async
  in … }` — and `app.onAsync(.get, "/report") { request, response in … }` is
  the raw form. An `await` resumes on the worker's own thread, so an async
  handler sees the same request and response a synchronous one does.
- `app.deadline(milliseconds:)` gives every route registered inside it a
  deadline: a request still unanswered that long after dispatch is answered
  504, and a handler waiting on the engine is unwound. It bounds **waiting,
  not computing** — a worker is one thread, so a handler that loops without
  awaiting still stops its worker. Nested calls apply the innermost.
- An answer to a request that has gone is dropped rather than written, so a
  handler that finishes after its connection closed or its stream was reset
  cannot write into the next request that took the slot.

### Connections the server makes

A handler can make an HTTP request, and the database drivers will stand on the
same ground. The connection layer itself is not public: what a handler reaches
is `request.client`.

- A worker opens outbound connections on its own poller, so a handler waiting
  on one waits the way it waits for anything else — one thread, one place
  where a descriptor becoming ready resumes a handler. They live in a slab of
  their own rather than the connection table, because a draining worker
  holding an idle outbound connection there would never look finished.
- Connections are kept for the next caller wanting the same place, and watched
  while they wait, so a peer that hangs up is noticed then rather than by the
  unlucky caller who takes it next. A connection is only ever reused for the
  same destination *and* the same verification identity.
- Outbound TLS verifies the peer: the certificate is checked against the name
  asked for, with SNI sent and the trust store configurable per connection. A
  TLS 1.3 session ticket arriving on an idle pooled connection is recognised
  as a ticket rather than mistaken for the peer going away.
- Names are resolved on the poller rather than through `getaddrinfo`, which
  blocks. Garuda reads the system's nameservers, search list and `ndots` from
  `resolv.conf`, asks over UDP, asks again over TCP when an answer will not
  fit, keeps answers for as long as their TTL allows, and refuses an answer to
  a question it did not ask. Connecting to a name tries every address the
  answer carried, in the order the server gave them.
- `request.client` makes HTTP requests: `try await client.get(url)`, `.head`,
  `.post`, or `.send` for any method, each returning the status, headers and
  body. Read it from the request before the first `await` — a `Request` is a
  view of a connection slot and does not outlive a suspension. `https` verifies
  the peer, names are resolved off the blocking path, and a kept connection is
  reused for the next request to the same place.
- Over `https` the client offers HTTP/2 and HTTP/1.1 and speaks whichever the
  server picks. An HTTP/2 connection is shared: every request to the same place
  runs on it at once, one stream each, and a burst of requests to somewhere new
  opens one connection between them rather than one apiece. A stream the server
  resets, or leaves unanswered past its timeout, fails its own request and no
  other. Plaintext `http` is always HTTP/1.1.
- `https://127.0.0.1/` is checked against the addresses in the certificate, and
  sends no SNI, which may only carry a name.
- Fixed: an HTTPS/1.1 request to a TLS 1.3 server could fail as `closed` when
  the server's session ticket arrived before its response.
- A connection goes back to the pool only when the response was read whole and
  both ends still mean to keep it. Anything else is closed: a connection handed
  back with bytes still on it gives the next caller somebody else's answer, and
  that surfaces far away, looking nothing like a pooling bug.
- What the client refuses, it refuses before opening anything. A response body
  is framed by what was asked and by the status before any field is believed,
  so a response to HEAD and a 204 carry no body whatever they declare. A header
  that could split the request is refused rather than escaped, and Host,
  Content-Length, Transfer-Encoding and Connection belong to the client rather
  than the caller. A URL carrying userinfo is refused outright: `https://a@b/`
  names host `b` and reads as `a`, and that gap is the whole of an attack.

### PostgreSQL

- A native PostgreSQL driver on the worker's poller: no libpq, no thread per
  query. Build a pool per worker with `app.state { _ in PostgresPool(config) }`,
  ask for it with `State<PostgresPool>`, and call `query(User.self, sql, …)`,
  `first(User.self, sql, …)` or `execute(sql, …)`. Rows decode into
  `Decodable` types by column name, a NULL into an `Optional`, and a value is
  bound beside the SQL as `$1`, never written into it. A refused statement's
  SQLSTATE is `error.sqlState`, so a unique violation can be a 409.
- SCRAM-SHA-256 authentication, verifying the server's signature as well as
  proving the client's. A cleartext password request is refused unless allowed,
  and over plaintext always; MD5 is refused outright — both are how a server
  that is not the real one harvests a password. TLS is `.require` by default,
  with no "prefer": falling back to plaintext when a server declines lets
  anyone on the path decline for it.
- Every length a server sends is checked before it is believed, and a result
  has a row limit. An idle pooled connection the server has since closed is
  noticed before a statement is written into it, not after. Tested against
  PostgreSQL 16 and 18.
- `db.transaction { tx in … }` runs its statements on one connection,
  committed if the closure returns and rolled back if it throws. A transaction
  a statement already failed is rolled back and reported rather than
  committed, even if the closure caught the error — PostgreSQL answers COMMIT
  on a failed transaction by quietly rolling back. A connection left inside a
  transaction, by a handler running `begin` itself, is closed rather than
  handed to the next request.

### Changed

- `--reload` watches the executable, not Python sources. Once a rebuild holds
  still and answers `--version`, the supervisor execs it with the listening
  sockets kept open, and the new image replaces the workers one slot at a time,
  so no connection is dropped. A broken build is not exec'd. A changed
  `--tls-cert` or `--tls-key` replaces the workers without an exec. Nothing
  builds for you.
- `--root-path` is the mount routes are matched within. A path outside it is
  matched as it came, as behind a proxy that has already taken the prefix off.
- `--no-websockets` refuses an upgrade with 501 before anything else can answer
  it.
- A path that has a route under some other method is answered 405, with an
  `Allow` header naming every method that would have matched, rather than 404.
  A path no method routes is still 404.

### Not yet

- WebSocket and WebTransport application APIs are stubs. HTTP/3 still
  advertises extended CONNECT and WebTransport; a CONNECT is refused with 501.
- The handler API's later steps: there is no middleware, no router nesting or
  custom fallback, no streaming response, and no WebSocket or WebTransport
  handler.
- PostgreSQL has no binary formats, no `LISTEN`, and does not
  SASLprep-normalise a non-ASCII password. Redis and SQLite drivers are not
  written. The HTTP client does not follow redirects and sends no
  `Accept-Encoding`, since the compression shim encodes and does not decode.
- `--compress` and `--cache-size` act on no handler response; they wait for
  streaming responses.
- TLS is OpenSSL, not Swift.

### Tests

- The end-to-end suites are ported to the router, and the ones that could only
  test a Python application are retired. The 235 checks that went with CPython
  are listed in [GARUDA.md](GARUDA.md), by the handler capability that would
  bring them back.
- `scripts/handler-test.py` covers the handler API end to end: request bodies
  over HTTP/1.1, HTTP/2 and HTTP/3, request headers, client, scheme, request
  IDs and `X-Request-Start`, response framing and server-header merging,
  errors and lifecycle hooks. It runs a second executable,
  `garuda-conformance`, whose routes exist only to make engine behaviour
  observable to the tests.

### Documentation

- [BENCHMARKS.md](BENCHMARKS.md) measures the router against the suite's
  Hummingbird and Vapor entries: 414,234 / 389,445 / 370,945 requests a second
  at 64 / 256 / 512 connections on four workers, against 88,864 / 102,399 /
  99,706 and 60,411 / 58,946 / 60,837. `benchmarks/frameworks.sh` gains
  `FRAMEWORKS=swift` with the `garuda`, `hummingbird` and `vapor` servers.
  Peregrine's figures move to a historical section.
- `benchmarks/frameworks.sh` runs the suite's `rust/axum` entry, copied byte
  for byte into `benchmarks/axum/` and built with `cargo` on first use
  (`FRAMEWORKS="swift rust" SERVERS="garuda axum"`), and gains `WARMUP`
  (default 5s). `benchmarks/vs-axum.sh` compares Garuda with axum in under two
  minutes at 64 connections: the ramp for 15 s, closed loop for 10 s, and
  pinned to one core for 10 s, one run each.

---

## Peregrine, before the fork

Peregrine's release notes as they stood at 6200167, the commit Garuda was
forked from. Package names, commands and options here are Peregrine's
(`peregrine-server`, `peregrine`, ASGI, WSGI), and the guides they link to are
Peregrine's at that version.

### 1.1.5 — 2026-09-14

#### Fixed

- `--cache-size`: a worker that stalled for more than two seconds part way
  through storing a response could have its slot taken over, then finish
  writing over the entry that replaced it: one response's status served with
  another's body. A slot now stays with its writer for as long as that process
  exists.
- `--cache-size`: a response that changed size could be answered with an older
  copy kept in a slot of another size, or have that older copy come back after
  the newer one expired or was evicted, including one that finished being
  written only after the newer copy had gone. Once a newer response has been
  stored, an older one is not served again.
- `--cache-size`: a successful POST, PUT, PATCH or DELETE retires what is cached
  for its URL, as RFC 9111 requires, and a GET that was still being answered
  when the change was made is not stored. Until now a GET was answered with the
  response from before the change until that copy expired.
- `--cache-size`: a response's `Age`, its `Date` and the time the application
  took to produce it count against its lifetime. A response already two minutes
  old with `max-age=60` was kept for a minute and served with `Age: 0`.
- `--cache-size`: a request with `If-Match`, `If-Unmodified-Since` or `If-Range`
  goes to the application, the only one that can evaluate it, instead of being
  answered with a cached 200. One with `If-None-Match` or `If-Modified-Since`
  that the cached copy satisfies is answered `304 Not Modified` from the cache
  instead of 200.
- A 204, or any 1xx, no longer gets `Content-Length: 0`, which RFC 9110 forbids,
  and a 304's `Content-Length` is no longer rewritten to 0: the application's
  is kept, or none is sent. This applies with or without `--cache-size`, to
  ASGI and WSGI over HTTP/1.1, HTTP/2 and HTTP/3.
- A request header sent on more than one line is read as one list, as RFC 9110
  says, where only one line was read before. This covers `X-Forwarded-For`
  behind `--forwarded-allow-ips`, `Accept-Encoding`, and `If-None-Match` for
  `--static-dir` and `--cache-size`. With two `X-Forwarded-For` lines, the
  client could resolve to a trusted proxy's address; with two `If-None-Match`
  lines, a client could be sent a whole response it already had.
- `--static-dir` answers a request whose `If-Match` names no current tag with
  `412 Precondition Failed`, as RFC 9110 requires, instead of sending the file.
- WebSocket: a frame whose length is encoded in more bytes than it needs is
  refused as a protocol error (RFC 6455 section 5.2).
- `--root-path` comes off a request's path only when the path is under it:
  the prefix itself, or the prefix followed by `/`. As many characters as the
  prefix had were cut from every path, so under `--root-path /api` a request
  for `/users` (behind a proxy that had already removed the prefix) reached the
  application as `rs`, and `/apis` as `s`. This applies to ASGI `path` and
  WSGI `PATH_INFO` alike.
- `--compress`: a strong `ETag` on a response the server compresses is sent
  weak (`W/"v1"`), with or without `--cache-size`, over HTTP/1.1, HTTP/2 and
  HTTP/3. The plain and compressed bodies were both sent with the
  application's strong tag, which RFC 9110 says must tell different bytes
  apart. `If-None-Match` still matches the weak tag.
- `--cache-size` with `--compress`: a `304` answered from the cache carries
  the `Vary: Accept-Encoding` its `200` has. The server added that `Vary` when
  sending the `200`, and dropped it from the `304`.
- HTTP/2: a SETTINGS frame that changes `INITIAL_WINDOW_SIZE` more than once
  applies every change to the streams already open, in order. Only the last
  change was applied, so a response could stall with window to spare, or be
  sent past the window the client had set.
- `--free-threaded` with more than one worker no longer hangs at start-up when
  the GIL is enabled (`PYTHON_GIL=1`, or an extension module that turns it back
  on) and the application's lifespan `startup` awaits anything. A worker waiting
  its turn to run `startup` held the GIL, which the worker already inside
  `startup` needed back to finish.

#### Documentation

- `BENCHMARKS.md` is replaced by one session on this build: the suite's raw
  ASGI and WSGI, FastAPI and Django entries on Peregrine, Flask and BlackSheep
  on Peregrine, and Elysia on Bun, with a worker per CPU and the suite's
  current load command, which ramps to 500,000 requests a second.
  `benchmarks/frameworks.sh` gains `SOURCES=upstream`, `AGG=mean`, `RATE` and
  the `asgi`, `wsgi` and `django` frameworks; the suite's sources are in
  `benchmarks/web-frameworks/`.
- The README leads with those results: its headline, chart and Numbers section
  show the suite's entries on Peregrine with a worker per CPU, and FastAPI and
  Django on Peregrine beside uvicorn and gunicorn in the suite's published
  results, in place of the one-worker comparison measured on 1.1.1.

---

### 1.1.4 — 2026-09-14

#### Changed

- Wheels are built for Linux aarch64 as well as x86_64, and tagged
  `manylinux_2_35` rather than `manylinux_2_39`. `pip install` now takes a
  wheel instead of compiling on Debian 12, Ubuntu 22.04, the official
  `python:*-slim` images and ARM machines. Before a release, each wheel is
  installed into `python:*-slim-bookworm` and has to serve a request.

#### Documentation

- The README opens with the results, a chart of them and a table translating
  uvicorn and gunicorn options. Its usage block lists `--ktls`,
  `--acme-directory`, `--acme-ca-bundle`, `--cache-size`,
  `--cache-max-object`, `--cache-ttl-max`, `--trace-context` and `--version`,
  which it had been missing.
- A LICENSE file, for the MIT license `pyproject.toml` already declared, and
  PyPI classifiers, keywords and project links.

---

### 1.1.3 — 2026-09-14

#### Fixed

- An ASGI application's `send` or `receive` used after its request had ended,
  by a task the request started, no longer reaches the next request on the
  same keep-alive connection. A late `send` could deliver its response in
  place of the next request's, and a late `receive` could take that request's
  body. A late `send` now raises `RuntimeError` while the connection is open,
  as it already did before another request had started, and returns quietly
  once the connection has closed. A late `receive` says `http.disconnect`.
  uvicorn behaves the same way.
- An HTTP/2 request that ends with a trailer section is held to its
  `content-length`, as one ending on a DATA frame already was. A body shorter
  or longer than declared reached the application as if it were whole; the
  stream is now reset with `PROTOCOL_ERROR` (RFC 9113 section 8.1.1). HTTP/3
  already checked this. A request whose trailers arrive after its response
  has finished also closes its stream at once, rather than holding it open
  until the request timeout.
- The ETag of a static file changes when the file is rewritten at the same
  size within one second. It was built from the modification time in whole
  seconds, so a client holding the old tag could be told 304 Not Modified for
  content it had never received. It now uses nanoseconds, which also means
  every static ETag changes once on upgrading: clients revalidate each file
  one time.

#### Changed

- `await send()` in an ASGI application finishes without creating a
  `StopIteration` exception. On one worker, a raw ASGI application went from
  116,099 to 118,728 req/s at 2.4 % less server CPU per request (six
  interleaved rounds, `benchmarks/turbo_ab.sh`); FastAPI, whose own code is
  most of each request, was unchanged within noise.

#### Documentation

- `BENCHMARKS.md` adds BlackSheep and a closed-loop capacity run past the
  ramp's ceiling, what a response body costs by size, where a request's server
  CPU goes, how many system calls a request makes (and why an io_uring backend
  was not built), and eager task start, measured twice and not kept.
- New harnesses in `benchmarks/`: `turbo_ab.sh` (two builds A/B, server CPU
  per request), `asgi_overhead.py`, `body_sizes.sh`, `syscalls.sh` and
  `eagercmp.sh` (two builds by connection count). `frameworks.sh` can run a
  closed loop.

---

### 1.1.2 — 2026-09-13

Tagged and released on GitHub only. It never went to PyPI; its changes
reached PyPI in 1.1.3.

#### New options

- `--trace-context`: a request's W3C `traceparent`, its trace ID and parent
  span ID, recorded in the access log. Never generated, and never changed on
  its way to the application.
- `--cache-size`, `--cache-max-object`, `--cache-ttl-max`: a response cache
  shared by every worker, for GET responses the application marks fresh with
  `s-maxage` or `max-age`. Requests with credentials or cookies, and responses
  that set cookies or are private, are never cached.
- `--ktls`: the Linux kernel encrypts TLS, so `--static-dir` files go out with
  sendfile over HTTPS as they do in the clear. On one worker, HTTPS static
  files went from 1485 to 2172 MiB/s (1 MiB) and 1384 to 2206 MiB/s (16 MiB),
  at about a third less CPU per GiB. Needs the kernel's `tls` module.

#### Changed

- `--reload` notices a save within a few tens of milliseconds, woken by
  inotify on Linux and kqueue on macOS instead of waiting for the next scan.
  The scan every `--reload-interval` stays, for filesystems that send no
  notification.

#### Documentation

- `RELEASE.md` records what changed in every version, linked from the README.
- `BENCHMARKS.md` measures this build, with the response cache, Elysia on Bun
  as a reference, and `--ktls` static files. `benchmarks/frameworks.sh` can run
  the suite's `javascript/elysia-bun` entry and take another checkout's
  extension module or extra server flags.

---

### 1.1.1 — 2026-09-13

Tag `v1.1.1` on `e2d49f6`. The server is unchanged from 1.1.0.

#### Fixed

- The links in the project description on PyPI work. The README linked to the
  other guides by paths relative to the repository, which GitHub resolves and
  PyPI does not; they are full URLs now.

#### Changed

- A new logo in the README and every guide.

---

### 1.1.0 — 2026-09-13

Tag `v1.1.0` on `a99b35e`.

#### The server runs inside your Python

- `pip install peregrine-server` installs the server as `peregrine._native`, a
  CPython extension module that the `peregrine` command loads into the
  interpreter it was installed into. Before, it was a standalone executable
  embedding `libpython`. The command and its options are unchanged.
- Framework code runs 10–16 % faster that way, inside a distribution `python3`
  rather than a shared `libpython`.
- Wheels for CPython 3.11, 3.12, 3.13, 3.14 and free-threaded 3.14t on Linux
  (`manylinux_2_39_x86_64`).
- Server processes are named `peregrine`, so `top`, `pgrep` and `pkill` find
  them.
- `PEREGRINE_BUILD=binary` still builds the standalone executable, and
  `swift build` still produces it for development.
- The Docker image builds the extension module: copy its `/usr/local`, or
  `pip install` the wheel it exports.

#### Faster

- Responses leave in batches instead of one write each: FastAPI 1.8× and
  Flask 1.5× on one worker, before the extension module added its share.
- Static files 73 % faster: one kernel walk per path, one write per small
  file.
- HTTP/3 downloads cost half the CPU. The QUIC congestion window is enforced
  (it was sending 17× what it needed), and datagrams go out in runs with UDP
  GSO.
- One worker on a 4-core machine, FastAPI at 64 / 256 / 512 connections:
  24,672 / 24,117 / 24,320 requests a second, against 17,504 / 15,544 / 15,114
  for uvicorn. Method, the other servers, Flask, and why these figures are not
  comparable with the ones the-benchmarker/web-frameworks publishes:
  [BENCHMARKS.md](https://github.com/grepjava/peregrine/blob/v1.1.0/BENCHMARKS.md).

#### New options

- `--compress`, `--compress-static`: br, zstd or gzip, as the client accepts.
- `--rate-limit`, `--rate-limit-burst`: per client, shared by every worker.
- `--static-dir PREFIX=DIR`: files served by the server, with `sendfile`.
- `--acme-domain`: certificates from Let's Encrypt, renewed automatically.
- Several certificates on one listener, chosen by SNI.
- `--redirect-http`, `--hsts`.
- `--drain-delay`: keep serving while a load balancer catches up on SIGTERM.
- `--health-check-path`: a liveness probe answered without the application.
- `--request-id`, `--request-start-header`.
- `--ws-compress`: WebSocket permessage-deflate.
- `peregrine.logging`: Python logging into the server log.

#### Fixed

- A worker could spin at 100 % CPU, ignoring SIGTERM, after a WebTransport or
  WebSocket connection closed under a running session.
- A shutdown signal arriving while a worker was starting was lost.
- A reload hands each worker over to its replacement, waits for the
  replacement to be serving before retiring the old one, and works under every
  execution model, so SIGHUP always reloads.
- `peregrine_workers` reported twice the worker count.
- With every waiting place on the metrics port taken, a new scrape was
  answered before its request had arrived and could lose its response to a
  reset. The one that has waited longest gives up its place instead.
- The rate limiter and the ACME client build on macOS.

#### Documentation

- The guides focus on FastAPI (ASGI) and Flask (WSGI).
- [INSTALLATION.md](https://github.com/grepjava/peregrine/blob/v1.1.0/INSTALLATION.md) covers the extension module, wheels and
  free-threaded builds; [DEPLOY.md](https://github.com/grepjava/peregrine/blob/v1.1.0/DEPLOY.md) covers how a release reaches
  PyPI.

---

### 1.0.0 — 2026-09-11

Tag `v1.0.0` on `38b4fd7`.

- Relocatable Linux wheels: the server executable with the Swift runtime
  vendored beside it, using the `libpython` of the interpreter that installs
  it. Built by the Wheels workflow, one wheel per interpreter.
- PyPI classifier Production/Stable.
- The benchmark figures measured again on the tree as released.
- The documentation uses the cursive logo.

---

### 0.8.0 — 2026-09-11

The first version on PyPI, as an sdist only: `pip install` compiled it, and
needed Swift. No tag.

- A Python ASGI and WSGI server written in Swift, in the same process as
  CPython.
- HTTP/1.1; HTTP/2 over TLS, with ALPN choosing it; HTTP/3 over a QUIC stack of
  its own, advertised with Alt-Svc; WebSocket; WebTransport over HTTP/3.
- WSGI over HTTP/2 and HTTP/3 as well as HTTP/1.1, with response blocks sent
  as the application produces them.
- `--free-threaded`: workers share one interpreter on a GIL-free CPython, with
  the ASGI lifespan run per worker loop.
- Prometheus metrics on a port of their own; access logs in JSON on request.
- Framing enforced rather than trusted: Transfer-Encoding parsed as a coding
  list, a second Host refused, chunked trailers bounded like the head.
- Peers charged for the HTTP/2 and HTTP/3 streams they cancel, and a QUIC
  address believed only once a packet from it decrypts.
- The parsers that read from the network are fuzzed.
- A Dockerfile that builds the server inside the CPython it serves.
