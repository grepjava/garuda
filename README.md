<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/garuda/main/assets/garuda-stylized-lockup.png" alt="Garuda" width="720">
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

**Status: the handler API is early and will change.** Its first phase is in
the tree: routes, a request view with its headers and whole body, one-shot
responses and a timer continuation. Handlers are synchronous, and there is no
typed extraction, JSON, middleware, streaming, WebSocket or WebTransport
handler yet. It is useful for evaluating the engine: its protocols, TLS,
operational behaviour and raw throughput. It is not yet a stable way to serve
your own application. [HANDLER-API.md](HANDLER-API.md) holds the design and
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
- **`JSON.encode` and `JSON.decode`** are Garuda's own coder, over the standard
  library's `Encodable` and `Decodable` — `JSONEncoder` and `JSONDecoder` are
  Foundation, which Garuda does not link. Decoding reads only the keys a type
  asks for, straight from the bytes the request lent it. The typed extraction
  and responses being built on it are [step 2](HANDLER-API.md).
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

The API is not stable. Handlers are synchronous, and suspension is only the
timer continuation. There is no typed extraction, JSON, middleware, 405,
streaming, WebSocket or WebTransport handler yet.
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
- **WebSocket and WebTransport**: the engine has framing and session code but
  no application API, so the `--ws-*` options have no route to apply to.
  `--no-websockets` refuses upgrades with 501. HTTP/3 advertises extended
  CONNECT and WebTransport in its SETTINGS, and a CONNECT is answered 501.

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
swift test                                   # 231 tests
bash scripts/compile-fail-test.sh            # 6   handler code that must not compile
```

The end-to-end suites run against the release binary, `.build/release/garuda`
by default. Each takes another binary path as its first argument. They are
answered by the binary's routes and the server's own features, so no
application is needed. `handler-test.py` runs
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
<venv>/bin/python scripts/handler-test.py    # 107 the handler API: bodies over h1,
                                             #     h2 and h3, headers, client,
                                             #     scheme, request IDs, framing,
                                             #     errors, lifecycle hooks
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

- **A stable handler API.** Asynchronous handlers, typed extraction, JSON,
  middleware, 405, streaming responses, and WebSocket or WebTransport handlers
  are not there yet. See [HANDLER-API.md](HANDLER-API.md) and
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
