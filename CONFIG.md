<p align="center">
  <img src="assets/garuda-fiery-roaring.png" alt="garuda" width="480">
</p>

# Configuring Garuda

Garuda is configured entirely on the command line. There is no configuration
file, and a running server does not re-read its flags: changing one means a
restart. `garuda --help` prints the list this page explains.

**What answers requests today.** There is no public handler API yet; it is
being designed. Requests that no server feature answers first go to a built-in
synchronous router (`Sources/GarudaServer/Router.swift`):

| request | answer |
|---|---|
| `GET /` | 200, empty body |
| `GET /user/:id` | 200, the id as the body |
| `POST /user` | 200, empty body |
| `GET /delay/:ms` | 200, empty body, after `ms` milliseconds (clamped to 1–5000) |
| `HEAD` on any GET route | the same head, no body |
| anything else | 404, connection kept open |

The router answers the same way over HTTP/1.1, HTTP/2 and HTTP/3. Everything on
this page that sits in front of it — TLS, static files, rate limiting, health
checks, the access log, metrics, reloads — is working and tested end to end. A
few flags are parsed but have nothing to act on until handlers exist; they are
collected under [Flags with no effect yet](#flags-with-no-effect-yet), and
[GARUDA.md](GARUDA.md) tracks that status.

---

## Flag reference

Defaults are what the server uses when a flag is left out.

### Listening and workers

| flag | default | what it does |
|---|---|---|
| `--host HOST` | `127.0.0.1` | interface to bind |
| `--port PORT` | `8000` | TCP port (and HTTP/3's UDP port unless `--quic-port`) |
| `--unix PATH` | — | listen on a unix socket instead of TCP |
| `--workers N` | `1` | worker processes; `0` is one per CPU |
| `--backlog N` | `2048` | listen backlog |
| `--root-path PATH` | — | mount prefix removed from the path before routing |

### Limits and timeouts

| flag | default | what it does |
|---|---|---|
| `--max-connections N` | `4096` | concurrent connections per worker |
| `--max-body BYTES` | 16 MiB | largest request body; larger gets 413 |
| `--max-header-size BYTES` | 32 KiB | largest request head; larger gets 431 (minimum 1024) |
| `--keep-alive MS` | `5000` | idle time allowed between requests |
| `--request-timeout MS` | `30000` | how long a request may stall part-way through |
| `--graceful-timeout MS` | `10000` | time in-flight requests get on shutdown |
| `--drain-delay MS` | `0` | on SIGTERM, keep serving this long with the health check failing |

### Protocols

| flag | default | what it does |
|---|---|---|
| `--no-http2` | off | HTTP/1.1 only |
| `--http2-only` | off | HTTP/2 only (h2c in the clear, `h2` alone in ALPN) |
| `--http3` | off | also serve HTTP/3 over QUIC; needs TLS, not available on `--unix` |
| `--quic-port PORT` | the TCP port | UDP port for HTTP/3 |
| `--no-websockets` | off | refuse WebSocket upgrades with 501 |

### TLS and certificates

| flag | default | what it does |
|---|---|---|
| `--tls-cert PATH` | — | PEM certificate chain; repeatable, paired with `--tls-key` in order |
| `--tls-key PATH` | — | PEM private key for the preceding `--tls-cert` |
| `--tls-ciphers LIST` | OpenSSL's | OpenSSL cipher list for TLS 1.2 (TLS 1.3 suites are not configurable) |
| `--ktls` | off | let the Linux kernel encrypt, so static files use `sendfile` over HTTPS |
| `--acme-domain NAME` | — | get and renew a certificate for NAME (repeatable) |
| `--acme-email ADDR` | — | contact address for the ACME account |
| `--acme-cache DIR` | `./acme` | where the account key and certificate are kept |
| `--acme-staging` | off | use Let's Encrypt's staging CA |
| `--acme-directory URL` | Let's Encrypt | use another ACME CA |
| `--acme-ca-bundle PATH` | system roots | roots to trust for the CA's own HTTPS |
| `--redirect-http PORT` | — | answer plain HTTP on PORT with a redirect to https |
| `--hsts SECONDS` | — | send `Strict-Transport-Security: max-age=SECONDS` on TLS responses |

### Reverse proxy

| flag | default | what it does |
|---|---|---|
| `--forwarded-allow-ips LIST` | nobody | peers whose forwarded headers are believed: addresses, CIDR blocks, `unix`, or `*` |

### Serving and traffic

| flag | default | what it does |
|---|---|---|
| `--static-dir P=DIR` | — | serve URL prefix P from DIR (repeatable) |
| `--compress-static` | off | serve `FILE.br`, `FILE.zst` or `FILE.gz` beside a static file when accepted |
| `--rate-limit RATE` | — | 429 past RATE requests per client, as in `100/s`, `600/m`, `5000/h` |
| `--rate-limit-burst N` | the count in RATE | requests allowed at once before the rate applies |
| `--health-check-path P` | — | answer GET/HEAD for P with 200 in the server |

### Observability

| flag | default | what it does |
|---|---|---|
| `--access-log` | off | one line per request |
| `--access-log-format F` | `text` | `text` or `json`; implies `--access-log` |
| `--request-id` | off | an `X-Request-ID` for every request, on the response and in the access log |
| `--trace-context` | off | record a W3C `traceparent`'s trace and span IDs in the access log |
| `--metrics-port PORT` | — | serve Prometheus metrics on a port of their own |
| `--metrics-host HOST` | `--host` | what the metrics port binds |
| `--log-level LEVEL` | `info` | `debug`, `info`, `warning`, `error` or `silent` |

### Development

| flag | default | what it does |
|---|---|---|
| `--reload` | off | restart on a rebuilt executable; replace workers when a certificate file changes |
| `--reload-interval MS` | `500` | how often `--reload` rescans (minimum 50) |

### Accepted, but with no effect yet

`--compress`, `--compress-min-size`, `--cache-size`, `--cache-max-object`,
`--cache-ttl-max`, `--request-start-header`, `--scheme`, `--ws-max-message`,
`--ws-ping-interval`, `--ws-ping-timeout`, `--ws-max-queue`,
`--ws-max-queue-bytes` and `--ws-compress`. See
[Flags with no effect yet](#flags-with-no-effect-yet).

`--version` prints the version; `-h`/`--help` prints the list. An unknown flag
or a stray argument is an error, and the server exits with status 2.

---

## Protocols

A protocol is a server flag. The router answers the same request the same way
whichever version carried it.

| protocol | flags |
|---|---|
| HTTP/1.1 | *(default)* |
| HTTP/2 in the clear, prior knowledge | *(default)* |
| HTTP/2 over TLS, chosen by ALPN | `--tls-cert --tls-key` |
| HTTP/3 over QUIC | `--http3 --tls-cert --tls-key` |

```bash
garuda --port 8443 --workers 0 --tls-cert cert.pem --tls-key key.pem --http3
```

That serves HTTP/1.1 and HTTP/2 over TCP and HTTP/3 over UDP on the same port
number. Every TCP response carries `Alt-Svc: h3=":8443"; ma=86400` so that
clients can find HTTP/3. There is no other way for them to find it.
`--quic-port` moves HTTP/3 to another UDP port, and the header follows.

`--no-http2` leaves only `http/1.1` in ALPN, and no longer recognises the
cleartext HTTP/2 preface.
`--http2-only` leaves only `h2`. In the clear it treats every connection as
HTTP/2 prior knowledge, which is what an h2c upstream from Envoy or Caddy
expects. HTTP/3 has no cleartext form, so `--http3` without a certificate is a
start-up error, and so is `--http3` with `--unix`.

To check each one:

```bash
curl --http1.1 http://127.0.0.1:8000/user/17            # 17
curl --http2-prior-knowledge http://127.0.0.1:8000/user/17
curl -k --http2 https://127.0.0.1:8443/user/17
curl -k --http3 https://127.0.0.1:8443/user/17          # needs a curl built with HTTP/3
```

The suites do not depend on curl supporting HTTP/3.
[scripts/http2-test.py](scripts/http2-test.py),
[scripts/http3-test.py](scripts/http3-test.py) and
[scripts/router-streams-test.py](scripts/router-streams-test.py) drive the
router over HTTP/2 and HTTP/3 themselves.

---

## A production starting point

```bash
garuda \
    --host 0.0.0.0 --port 8443 \
    --workers 0 \
    --tls-cert /etc/ssl/app/fullchain.pem \
    --tls-key  /etc/ssl/app/privkey.pem \
    --http3 \
    --forwarded-allow-ips 10.0.0.0/8 \
    --static-dir /static=/srv/app/static --compress-static \
    --health-check-path /healthz \
    --max-body 8388608 \
    --drain-delay 10000 \
    --graceful-timeout 30000 \
    --metrics-port 9100 --metrics-host 127.0.0.1 \
    --access-log --access-log-format json --log-level warning
```

A few notes on this command:

- **`--log-level warning` also silences the access log.** Access lines are
  logged at `info`, so this command writes none. Keep `--log-level info` if you
  want them.
- **Leave out `--reload` in production.** It is for development only.
- **`SIGHUP` reloads the certificate** without dropping a connection. See
  [Reloading without a restart](#reloading-without-a-restart).

---

## Workers, sockets and signals

Everything runs under a supervisor process, even with one worker. The
supervisor owns the listening sockets. Each worker gets its own socket in an
`SO_REUSEPORT` group, its own poller and its own connection table, so workers
share no lock. A worker that crashes is restarted in its slot.

### Unix sockets

```bash
garuda --unix /run/app.sock --workers 4 --forwarded-allow-ips unix
```

Every worker accepts on the one socket. A stale socket file left at the path is
removed at start-up, and the socket file is removed again on exit. Peers on a
unix socket have no address. To believe the forwarded headers a proxy sends
over it, list `unix` in `--forwarded-allow-ips`. `--http3` and
`--redirect-http` are refused with `--unix`, because neither has anything to
bind.

### Signals

| signal | effect |
|---|---|
| `SIGTERM` | fail the health check for `--drain-delay`, then stop accepting and drain within `--graceful-timeout` |
| `SIGINT`, `SIGQUIT` | drain at once; a second one cuts short a `--drain-delay` already running |
| `SIGHUP` | replace every worker, one slot at a time, without dropping a connection |

When a worker drains, it stops accepting, closes idle keep-alive connections,
and finishes the requests it already has. The supervisor kills any worker still
running once `--drain-delay` + `--graceful-timeout` + 2 s have passed, so
shutdown always ends. Each worker also runs the drain delay itself. An init
system that signals the whole process group, as systemd does by default, gets
the same behaviour as one that signals only the supervisor.

---

## Behind a reverse proxy

```bash
garuda --forwarded-allow-ips 10.0.0.0/8,127.0.0.1
```

The server reads `X-Forwarded-For`, `X-Forwarded-Proto` and `Forwarded` only
when the connecting peer is on the list. From any other peer it ignores them,
because a client can send them too. The list takes addresses, CIDR blocks,
`unix` and `*`. An entry that does not parse stops start-up. Use `*` only when
nothing but the proxy can reach the server.

Two features use trusted forwarded information today:

- **Rate limiting** keys a client by the address the proxy reports, not by the
  proxy's own address.
- **Request IDs** from a trusted proxy's `X-Request-ID` are kept rather than
  replaced.

Handlers will see the client address and scheme once the handler API exists.

### Mounted under a prefix

```bash
garuda --root-path /api
```

`--root-path` removes a leading path prefix before the router matches, so
`GET /api/user/7` is answered as `GET /user/7`:

- **Whole segments only.** `/apis` is not under `/api`, and a trailing slash on
  the flag (`/api/`) means the same as without it.
- **Paths outside the prefix are routed as they came.** That covers a proxy
  that has already removed the prefix.
- **Router only.** `--static-dir` prefixes and `--health-check-path` match the
  path as the client sent it.

---

## Limits and timeouts

- **`--max-connections`** is per worker. A connection arriving at a full table
  is answered `503 Service Unavailable` and closed rather than queued, and
  counted in `garuda_connections_rejected_total`. HTTP/3 has the same cap. At
  start-up the server raises its descriptor limit, and warns when `ulimit -n`
  is still below `--max-connections`.
- **`--max-body`** is checked against a declared `Content-Length` before
  anything is read, and against the bytes actually received for a chunked
  body, an HTTP/2 body or an HTTP/3 body. Past the limit the answer is 413.
- **`--max-header-size`** bounds the HTTP/1.1 request head and chunked
  trailers. It is also the HTTP/2 header-list limit and the HTTP/3 field
  section limit the server advertises. A head too large gets 431.
- **`--keep-alive`** is how long an HTTP/1.1 connection may sit idle between
  requests. It also closes an HTTP/2 connection idle with no open streams, and
  sets the QUIC idle timeout.
- **`--request-timeout`** is how long a connection may make no progress in the
  middle of a request head, a request body, or a response being written.

---

## The access log

`--access-log` writes one line per request to stderr, at `info`:

```
[info]  pid=8961 GET /user/17?x=1 200 43us
```

`--access-log-format json` writes the same fields as one JSON object per line,
and implies `--access-log`:

```json
{"level":"info","pid":8961,"method":"GET","target":"/user/17?x=1","status":200,"duration_us":43,"proto":"HTTP/2"}
```

The whole line is the object, with no `[info] pid=…` in front of it, so a
collector can parse it as it arrives. `proto` is `HTTP/1.0`, `HTTP/1.1`,
`HTTP/2` or `HTTP/3`.

`duration_us` runs from dispatch to the response head being queued, not to the
last byte of the body. The time to the last byte depends on how fast the client
reads, not on the server.

The request target is whatever bytes the peer sent. `"` and `\` are escaped.
A target that is not valid UTF-8 has its bytes escaped as `\u00XX` rather than
dropped, so the line always parses and the target can be recovered byte for
byte. A line is assembled in a fixed 4 KiB buffer. A target too long for it is
cut on a character boundary, and the object gets `"truncated":true`, so every
line is still a complete object.

The server's own log lines use the same `[level] pid=N` prefix and go to
stderr. `--log-level` filters both, so `--log-level warning` also turns off the
access log.

### Request IDs

```bash
garuda --request-id --access-log
```

`--request-id` gives every request an `X-Request-ID`:

- **In the response.** Router responses and static files carry it on HTTP/1.1,
  HTTP/2 and HTTP/3.
- **In the access log.** A text line ends with ` id=...` and a JSON line gets
  `"request_id"`.

```
[info]  pid=8961 GET /user/17 200 51us id=0b6f1c9e-3c1d-4f7a-9a52-6d2e8f41c7b0
```

A new ID is a version 4 UUID, generated without a system call. When a peer
listed in `--forwarded-allow-ips` sends an `X-Request-ID`, that ID is kept,
because the proxy saw the request first and may already have logged it. The
value must be 1 to 128 characters of letters, digits and `-_.:+/=@~`. Any other
`X-Request-ID` is replaced, including one a client sends directly.

The ID is assigned before any server feature answers, so health probes and 429
refusals are logged with one and carry it back, over every protocol. A
malformed request that never parses gets no ID, and the
`--redirect-http` port assigns none. Handlers will receive the ID when the
handler API exists. The router does not read request headers.
[scripts/request-id-test.sh](scripts/request-id-test.sh) covers this.

### Trace context

```bash
garuda --trace-context --access-log
```

A request sent from inside a distributed trace carries a W3C `traceparent`
header naming the trace and the span that sent it. `--trace-context` records
both IDs on the access line:

```
[info]  pid=8961 GET /user/17 200 51us trace=4bf92f3577b34da6a3ce929d0e0e4736 span=00f067aa0ba902b7
```

A JSON line gets `"trace_id"` and `"parent_id"`. With `--request-id` as well,
the request ID comes first.

The server only records a traceparent. It never generates one and never changes
the header. A value is recorded only when it follows the specification:

- lowercase hex;
- version `00` exactly as `00-<32 hex>-<16 hex>-<2 hex>`, or a later version
  with anything extra after a dash;
- neither ID all zeros, and not version `ff`.

Anything else is ignored.
[scripts/trace-context-test.sh](scripts/trace-context-test.sh) covers this.

### Metrics

`--metrics-port 9100` serves the Prometheus text format:

| metric | type |
|---|---|
| `garuda_requests_total{status="1xx".."5xx"}` | counter |
| `garuda_request_duration_seconds` (`_bucket`, `_sum`, `_count`) | histogram, dispatch to response head queued |
| `garuda_connections_accepted_total`, `_closed_total`, `_rejected_total` | counters |
| `garuda_connections_active`, `garuda_connection_slots` | gauges |
| `garuda_buffer_pool_hits_total`, `garuda_buffer_pool_misses_total` | counters |
| `garuda_requests_rate_limited_total` | counter |
| `garuda_cache_hits_total`, `_misses_total`, `_stores_total` | counters (stay at zero; see [below](#flags-with-no-effect-yet)) |
| `garuda_workers` | gauge |

Metrics get a port of their own rather than a path on the service port.
Nothing on the metrics port goes near the request path: each scrape is
accepted, answered and closed on the worker's loop.

**One scrape answers for every worker.** The counters live in a page mapped
before the workers fork, and each worker writes only its own slot. A scrape
lands on whichever worker `SO_REUSEPORT` picks and reports the sum.
`garuda_workers` says how many workers are summed. During a reload the old
worker and its replacement each keep separate counters, so the totals stay
correct.

**Bind it somewhere private.** `--metrics-host` defaults to `--host`, so a
server on `0.0.0.0` publishes its metrics there too:

```bash
garuda --host 0.0.0.0 --port 8443 --metrics-port 9100 --metrics-host 127.0.0.1
```

Without `--metrics-port` the shared page is never mapped and nothing is
counted.

---

## Reloading without a restart

`SIGHUP` to the supervisor replaces every worker without dropping a connection.
Each worker builds its own TLS context, so the replacements read the
certificate and key from disk again. That makes `SIGHUP` the right certbot
deploy hook:

```ini
# garuda.service
ExecReload=/bin/kill -HUP $MAINPID
```

```bash
certbot renew --deploy-hook 'systemctl reload garuda'
```

Workers are replaced one slot at a time, and no connection is dropped:

1. The replacement is forked and handed the listening socket its predecessor
   had.
2. The replacement reports that it is accepting. Only then is the old worker
   sent `SIGQUIT` to finish what it has.
3. A replacement that dies before it is ready gives the slot back to the old
   worker, and the reload stops there.
4. A replacement that is alive but never reports ready is waited for 60 s. The
   old worker is then retired anyway.

A `SIGHUP` that arrives while a reload is running queues one more pass. A
reload restarts workers; it does not re-read the command line.
[scripts/reload-test.sh](scripts/reload-test.sh) sends reloads under load and
fails on any refused, reset or truncated connection.

### `--reload`, for development

`--reload` watches the running executable. Unless `--acme-domain` manages the
certificates, it also watches every `--tls-cert` and `--tls-key` file.

- **When the executable is rebuilt:**
  1. The change must hold still for about 300 ms, since a linker writes in
     several steps.
  2. The new file must run `garuda --version` successfully, within 5 s.
  3. The supervisor execs the new file in place of itself: same pid, same
     arguments. The listening sockets stay open across the exec. Their
     descriptors and the worker pids are passed in the `GARUDA_REEXEC`
     environment variable.
  4. The new image adopts the old workers and replaces them one slot at a time,
     exactly as `SIGHUP` does. No connection is dropped.

  A build that does not run is not exec'd; the server logs an error and keeps
  running the old one.
- **When only a certificate or key changes:** the workers are replaced, with no
  exec.

The kernel notifies the watcher of changes to the directories holding those
files (inotify on Linux, kqueue on macOS). The watcher also rescans every
`--reload-interval` milliseconds, 500 by default. That catches changes the
kernel never reports: bind mounts, network filesystems, a Windows drive under
WSL.

`--reload` does not build anything. Run `swift build` yourself, in another
terminal. It is a development convenience, not a deployment mechanism.
[scripts/feature-test.py](scripts/feature-test.py) and
[scripts/reload-test.sh](scripts/reload-test.sh) cover rebuilds, broken builds
and certificate changes.

---

## Health checks

`--health-check-path /healthz` answers that path inside the worker, before rate
limiting, static files or the router, with `200` and an empty body:

```yaml
livenessProbe:
  httpGet: { path: /healthz, port: 8000 }
```

Only `GET` and `HEAD` are answered. The match is exact once the query string is
removed, so `/healthz?probe=1` counts too. It works over HTTP/1.1, HTTP/2 and
HTTP/3, and it is never rate limited. It is off unless you ask for it.

### Shutting down behind a load balancer

```bash
garuda --health-check-path /healthz --drain-delay 10000 --graceful-timeout 30000
```

```yaml
readinessProbe:
  httpGet: { path: /healthz, port: 8000 }
  periodSeconds: 2
terminationGracePeriodSeconds: 45
```

Kubernetes sends `SIGTERM` and removes the pod from its Service at the same
moment, and the removal takes a few seconds to reach every node and ingress. A
server that stops accepting as soon as `SIGTERM` arrives refuses traffic that
is still being routed to it.

With `--drain-delay`, the server keeps serving for that many milliseconds after
`SIGTERM`, but:

- the health check answers `503`;
- HTTP/1.1 responses say `Connection: close`, so clients reconnect elsewhere.

When the delay is up, the server stops accepting and drains under
`--graceful-timeout`.

- **Choosing the delay.** Make it a little longer than your readiness probe
  takes to notice: its period multiplied by its failure threshold.
- **Choosing the grace period.** `terminationGracePeriodSeconds` must cover the
  delay plus the graceful timeout.
- **Only `SIGTERM` waits.** `SIGINT` and `SIGQUIT` drain at once, and a
  `SIGHUP` reload never waits.

[scripts/drain-test.sh](scripts/drain-test.sh) covers this.

---

## Serving assets

`--static-dir` answers a URL prefix from a directory, before the router:

```bash
garuda --static-dir /static=/srv/app/static --static-dir /media=/srv/app/media
```

- **Routing.** The prefix must start with `/` and end on a segment boundary, so
  `/staticky` is not under `/static`. When prefixes overlap, the longest
  matches first, in whatever order the flags were given.
- **Fallthrough.** Only `GET` and `HEAD` are served. A path with no regular
  file behind it goes on to the router, and so does any other method; the
  router answers 404 unless one of its routes matches.
- **Containment.** `..`, `%2e%2e`, and a symlink pointing out of the tree are
  refused by where the path lands, not by how it is spelled. The path is
  percent-decoded, resolved, and must still be inside the directory. Only
  regular files are opened.
- **Validators.** The `ETag` is built from the file's size and its modification
  time to the nanosecond, and `If-None-Match` is answered with `304`. There is
  no `Last-Modified`, no byte ranges and no directory index. This is an asset
  route, not a file server.

On a plaintext HTTP/1.1 connection the bytes go from the page cache to the
socket with `sendfile(2)` and never enter the process. Over TLS, HTTP/2 and
HTTP/3 they are read and then encrypted or framed.

`--ktls` removes TLS from that list on Linux. The kernel encrypts instead of
OpenSSL, so an HTTPS/1.1 file response gets `sendfile` too:

```bash
sudo modprobe tls        # once per boot, or list tls in /etc/modules-load.d
garuda --ktls --tls-cert cert.pem --tls-key key.pem --static-dir /static=/srv/app/static
```

OpenSSL still does the handshake and hands the kernel the keys. Where kernel
TLS is not available, OpenSSL encrypts as before, and the server logs a
warning at start-up. That happens when the module is not loaded or OpenSSL was
built without kernel TLS. HTTP/2 still reads its files, because its bytes have
to be framed.

### Pre-compressed files

`--compress-static` serves a copy compressed at build time, `app.js.br`,
`app.js.zst` or `app.js.gz` beside `app.js`, to a client that accepts it:

- **Choice.** The copy comes in the order the client prefers. The original must
  exist as well, and a file with no copy is served as it is.
- **Headers.** The copy gets its own `ETag`, and the response says
  `Vary: Accept-Encoding`.
- **Transfer.** It still goes out with `sendfile` where the original would.

```bash
find static -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' \) \
    -exec brotli -kq 11 {} \; -exec gzip -k9 {} \;
```

A static file reflects nothing from the request, so this carries none of the
BREACH risk of compressing dynamic responses.
[scripts/static-test.sh](scripts/static-test.sh) and
[scripts/compress-test.sh](scripts/compress-test.sh) cover both flags.

---

## Rate limiting

```bash
garuda --rate-limit 100/s --rate-limit-burst 200
```

A client past its allowance gets `429 Too Many Requests` with a `Retry-After`
in whole seconds, rounded up, and the connection stays open. The rate is `N/s`,
`N/m` or `N/h`. The burst is how many requests may arrive at once before the
rate applies; it defaults to `N`. The check runs after the health probe and
before static files and the router.

The count is for the whole server, not for each worker. With `--workers 8` the
kernel spreads a client's connections over eight accept queues, and a limit
kept per worker would let the client through up to eight times over. All
workers share one table mapped before they fork, and they charge a client's
entry with a compare-and-swap.

Who counts as a client:

- **Behind a proxy on `--forwarded-allow-ips`:** the address the proxy
  reports.
- **Otherwise:** the peer address. `X-Forwarded-For` is ignored.
- **IPv6:** grouped by `/64`, which is what one subscriber is normally given.
- **Unix socket peers:** not limited unless a trusted proxy names the client.

The table holds 65,536 clients. An entry whose client has earned its whole
burst back is reused. If a new client finds no entry free, its request is
allowed, so a full table never refuses traffic. Refusals are counted in
`garuda_requests_rate_limited_total`.

This guards against one client overwhelming the server. It is not a quota
system: there are no per-route limits and no key other than the address.
[scripts/ratelimit-test.sh](scripts/ratelimit-test.sh) covers this.

---

## TLS

`--tls-cert` and `--tls-key` turn on TLS for the TCP port, with ALPN choosing
HTTP/2 or HTTP/1.1. TCP TLS is OpenSSL. `--tls-ciphers` sets the TLS 1.2 cipher
list. The certificate and key are loaded and checked once at start-up, so an
unreadable file stops the server before it binds.

### More than one certificate

The flags are repeatable and paired in the order given. The first pair is the
default, and the rest are chosen per connection by SNI:

```bash
garuda --port 443 \
    --tls-cert /etc/ssl/shop/fullchain.pem   --tls-key /etc/ssl/shop/privkey.pem \
    --tls-cert /etc/ssl/admin/fullchain.pem  --tls-key /etc/ssl/admin/privkey.pem
```

An unequal number of certificates and keys is a start-up error.

- **Names.** The names each certificate covers are read from the certificate
  itself: its subject alternative names, or its common name if it has none.
  With more than one certificate, start-up logs what each one covers.
- **Matching.** Matching follows RFC 6125. It is case-insensitive, and a
  wildcard covers exactly one label: `*.example.com` matches `a.example.com`,
  but not `a.b.example.com` or `example.com`.
- **No match.** A name no certificate claims, or no SNI at all, gets the
  default certificate rather than a refused connection.

HTTP/3 serves the default pair whatever the client asks for, because its QUIC
handshake has no SNI selection yet. `SIGHUP` reloads every pair.
[scripts/sni-test.sh](scripts/sni-test.sh) covers this.

### Certificates from Let's Encrypt

```bash
garuda --port 443 --acme-domain example.com --acme-domain www.example.com \
    --acme-email ops@example.com --acme-cache /var/lib/garuda/acme
```

The server gets its own certificate, starting from an empty cache:

1. It starts on a self-signed placeholder.
2. It registers an account and answers the CA's `tls-alpn-01` challenge on the
   port it is already serving.
3. It writes the certificate to the cache directory.
4. It replaces its workers onto the new certificate, the way `SIGHUP` does.

After that it checks every 12 hours and renews when 30 days are left. A restart
finds the certificate in the cache and does not ask again.

The ACME client runs in a helper process forked by the supervisor, so a slow or
unavailable CA holds up no worker. A failed attempt is retried after a minute,
then the wait doubles each time, up to six hours.

- **Staging.** `--acme-staging` uses Let's Encrypt's staging CA, which issues
  untrusted certificates without production rate limits. Try a new setup there
  first.
- **Other CAs.** `--acme-directory URL` uses another ACME CA, and
  `--acme-ca-bundle PATH` trusts a private CA's HTTPS.
- **The cache.** It holds `account.key`, `cert.pem` and `key.pem`, with keys at
  mode 0600. Keep it on persistent storage: losing it means a new account and a
  new certificate, which count against rate limits.
- **Incompatible flags.** `--acme-domain` cannot be combined with `--tls-cert`.
  Names must be plain DNS names, so wildcards (which need `dns-01`) are
  refused.
- **Port 443.** A public CA validates on port 443, and the server warns if
  `--port` is anything else. A proxy that terminates TLS in front of the server
  sees the challenge instead of passing it on.

HTTP/3 uses the same files and picks the new certificate up on the same reload.
[scripts/acme-test.sh](scripts/acme-test.sh) runs the whole flow against
pebble.

### Redirecting HTTP to HTTPS

```bash
garuda --port 443 --acme-domain example.com --redirect-http 80 --hsts 31536000
```

`--redirect-http 80` listens for plain HTTP on port 80 and answers every
request with a redirect to the same host and path on the TLS port:

```
GET /cart?id=7 HTTP/1.1
Host: example.com

HTTP/1.1 301 Moved Permanently
Location: https://example.com/cart?id=7
```

- **Status.** `GET` and `HEAD` get `301`. Every other method gets `308`, which
  keeps the method and the body.
- **Location.** The host comes from `Host`, with its port replaced by the TLS
  port. The port is left out when it is 443.
- **Refusals.** A request with no usable `Host` gets `400`.
- **Nothing else.** These requests never reach the router, and every response
  closes the connection.

It needs TLS and a port of its own, and it is refused with `--unix`.
Certificates from `--acme-domain` do not need port 80. Ports below 1024 need
root or `CAP_NET_BIND_SERVICE`.

### Strict-Transport-Security

`--hsts SECONDS` adds `Strict-Transport-Security: max-age=SECONDS` to every TLS
response: router responses, static files and health checks, over HTTP/1.1,
HTTP/2 and HTTP/3. It needs TLS, and it is never sent over plain HTTP.
`includeSubDomains` and `preload` are not added, because they commit other
host names to https.

Start with a short `max-age`, such as `300`. A browser that has seen a long one
refuses plain HTTP to the site until it expires, even after the certificate is
gone. [scripts/redirect-test.sh](scripts/redirect-test.sh) covers both flags.

---

## Flags with no effect yet

These flags are parsed and accepted, so existing command lines keep starting.
None of them changes what the server does today. The engine code behind most of
them is still in the binary, waiting for the handler API.

- **`--compress`, `--compress-min-size`.** These are meant to compress handler
  responses that are text-like (brotli, zstd or gzip, as the client accepts),
  with `Vary`, weak ETags and a size floor. Router responses carry no content
  type, so nothing is compressed. Static files are served pre-compressed with
  `--compress-static`, or as they are. Once handlers exist, read about BREACH
  before turning `--compress` on. Compressing a TLS response that puts a secret
  next to text the client chose lets an observer of response sizes recover the
  secret.
- **`--cache-size`, `--cache-max-object`, `--cache-ttl-max`.** These are meant
  to be a response cache shared by all workers, for responses marked fresh with
  `Cache-Control: s-maxage` or `max-age`. `--cache-size` still maps the memory
  and logs its size at start-up. Nothing is ever stored, and the `garuda_cache_*`
  metrics stay at zero.
- **`--request-start-header`.** This is meant to give handlers
  `X-Request-Start: t=<microseconds>` for APM queue time. Arrival is timestamped
  when the flag is set, but nothing reads the timestamp.
- **`--scheme`.** This was the scheme reported to the application. Nothing
  reads it today, apart from the unused response cache.
- **`--ws-max-message`, `--ws-ping-interval`, `--ws-ping-timeout`,
  `--ws-max-queue`, `--ws-max-queue-bytes`, `--ws-compress`.** These are
  WebSocket limits and permessage-deflate negotiation, and nothing reads them.
  There is no WebSocket application API, so no upgrade is ever accepted.
  `--no-websockets` does work: it refuses an upgrade with 501 before anything
  else answers.

**WebTransport** has no flag and no application API. HTTP/3 still advertises
extended CONNECT in its SETTINGS, and a CONNECT is refused with 501.

---

Next: [INSTALLATION.md](INSTALLATION.md) covers getting Garuda built and
installed. [TRANSPORT.md](TRANSPORT.md) covers what each protocol does and how
much of it is implemented. [ARCHITECTURE.md](ARCHITECTURE.md) explains how the
server is built, and [GARUDA.md](GARUDA.md) tracks what is not done yet.
