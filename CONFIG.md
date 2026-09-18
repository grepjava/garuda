<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Configuring Garuda

Garuda is configured on the command line. There is no configuration file. A
running server does not re-read its flags, so changing one means a restart.
`garuda --help` prints the list.

`Application.run()` parses the same flags, so an application built on the
handler API takes the same command line as the `garuda` executable.
`Application.run(configuration:)` takes a `ServerConfig` instead; see
[Configuring from code](#configuring-from-code).

A request passes through the server features in this order before a route
sees it:

1. `--request-id` and `--trace-context` are recorded.
2. `--no-websockets` refuses an upgrade with 501.
3. `--health-check-path` answers the probe.
4. `--rate-limit` refuses a client over its allowance with 429.
5. `--static-dir` serves a file, if there is one.
6. The routes.

Everything else on this page applies to every protocol unless it says
otherwise.

`--version` prints the version. `-h` and `--help` print the flag list. An
unknown flag, a stray argument or an invalid value is reported, and the process
exits with status 2.

---

## Listening and workers

| flag | default | what it does |
|---|---|---|
| `--host HOST` | `127.0.0.1` | interface to bind |
| `--port PORT` | `8000` | TCP port, and the HTTP/3 UDP port unless `--quic-port` is given |
| `--unix PATH` | none | listen on a unix socket instead of TCP |
| `--workers N` | `1` | worker processes; `0` means one per CPU |
| `--backlog N` | `2048` | listen backlog |
| `--root-path PATH` | none | prefix removed from the path before routes match |

Every server runs a supervisor process, even with one worker. The supervisor
owns the listening sockets and restarts a worker that crashes. Each worker has
its own `SO_REUSEPORT` socket, poller and connection table. Workers share no
lock.

**Unix sockets.** Every worker accepts on the one socket. A stale socket file
at the path is removed at start-up, and the file is removed on exit. A unix
peer has no address: list `unix` in `--forwarded-allow-ips` to believe a proxy
connecting over it. `--http3` and `--redirect-http` cannot be used with
`--unix`.

```bash
garuda --unix /run/app.sock --workers 4 --forwarded-allow-ips unix
```

**`--root-path`.** `--root-path /api` answers `GET /api/user/7` with the route
for `/user/7`.

- Only a whole segment is removed. `/apis` is not under `/api`. A trailing
  slash on the flag is ignored.
- A path that does not start with the prefix is routed as it came. That covers
  a proxy that already removed it.
- It applies to routes only. `--static-dir` and `--health-check-path` match the
  path as the client sent it.

---

## Limits and timeouts

| flag | default | what it does |
|---|---|---|
| `--max-connections N` | `4096` | concurrent connections per worker |
| `--max-body BYTES` | 16 MiB | largest request body; larger gets 413 |
| `--max-header-size BYTES` | 32 KiB | largest request head; larger gets 431; minimum 1024 |
| `--keep-alive MS` | `5000` | idle time allowed on a connection |
| `--request-timeout MS` | `30000` | how long a request may stall part-way through |
| `--graceful-timeout MS` | `10000` | time in-flight requests get on shutdown |
| `--drain-delay MS` | `0` | on SIGTERM, keep serving this long with the health check failing |
| `--blocking-threads N` | `16` | threads per worker that `blocking` work runs on |
| `--blocking-queue N` | `1024` | `blocking` work waiting for a thread, per worker, before it is refused 503 |
| `--broadcast-size MIB` | `4` | the ring published messages cross workers in; `0` turns `Topic` off |
| `--broadcast-queue N` | `1024` | messages a subscriber may fall behind by before it is told it missed some |
| `--sse-keep-alive S` | `15` | seconds an event stream may be quiet before it is sent a comment; `0` sends none |

- **`--max-connections`** is per worker. A connection that arrives at a full
  table is answered `503` and closed, and counted in
  `garuda_connections_rejected_total`. HTTP/3 has the same cap. At start-up the
  server raises its descriptor limit, and warns if `ulimit -n` is still too low.
- **`--max-body`** is checked against a declared `Content-Length` before the
  body is read, and against the bytes received for a chunked, HTTP/2 or HTTP/3
  body. Routes inside `app.maxBodySize(bytes) { … }` use that limit instead,
  checked the same way.
- **`--max-header-size`** bounds the HTTP/1.1 head and chunked trailers. It is
  also the HTTP/2 header list size and the HTTP/3 field section size the server
  advertises.
- **`--keep-alive`** is the HTTP/1.1 idle time between requests. It also closes
  an idle HTTP/2 connection and sets the QUIC idle timeout.
- **`--request-timeout`** covers a request head, a request body, or a response
  being written, when the connection makes no progress.
- **`--blocking-threads`** threads start only as `blocking` work arrives, so a
  worker that never calls it starts none. Work that finds them all busy waits,
  up to **`--blocking-queue`** pieces, and past that `blocking` throws
  `BlockingPoolError.full`, answered 503. Each worker has its own pool, so the
  process count multiplies both.
- **`--broadcast-size`** is memory every worker maps before the fork. A message
  published on a `Topic` goes into it and every worker reads it from there, so
  it reaches subscribers on all of them. It also holds the recent past: a
  client that reconnects with `Last-Event-ID` is sent what it missed as long as
  newer messages have not written over it. A message may be up to a quarter of
  the ring. With `0`, publishing and subscribing throw
  `BroadcastError.unavailable`, answered 503.
- **`--broadcast-queue`** is per subscriber. One that falls further behind --
  a client reading slowly, a handler busy elsewhere -- is given `.missed` in
  place of what it could not keep, rather than holding the rest in memory.
- **`--sse-keep-alive`** is kept by the worker, whatever the handler is waiting
  on, so a proxy that closes idle connections sees traffic and a client that has
  gone is found when the write fails. `EventStream(keepAlive:)` sets it for one
  stream.

`--drain-delay` and `--graceful-timeout` are described under
[Reload and signals](#reload-and-signals).

---

## TLS and ACME

| flag | default | what it does |
|---|---|---|
| `--tls-cert PATH` | none | PEM certificate chain; repeatable, paired with `--tls-key` in order |
| `--tls-key PATH` | none | PEM private key for the matching `--tls-cert` |
| `--tls-ciphers LIST` | OpenSSL's | OpenSSL cipher list for TLS 1.2; TLS 1.3 suites are not configurable |
| `--ktls` | off | let the Linux kernel encrypt, so static files use `sendfile` over HTTPS |
| `--acme-domain NAME` | none | get and renew a certificate for NAME; repeatable |
| `--acme-email ADDR` | none | contact address for the ACME account |
| `--acme-cache DIR` | `./acme` | where the account key and certificate are kept |
| `--acme-staging` | off | use Let's Encrypt's staging CA |
| `--acme-directory URL` | Let's Encrypt production | use another ACME CA |
| `--acme-ca-bundle PATH` | system roots | roots to trust for the CA's own HTTPS |
| `--redirect-http PORT` | none | answer plain HTTP on PORT with a redirect to https |
| `--hsts SECONDS` | none | send `Strict-Transport-Security: max-age=SECONDS` on TLS responses |

`--tls-cert` and `--tls-key` turn on TLS for the TCP port. ALPN chooses HTTP/2
or HTTP/1.1. The files are loaded and checked at start-up, so an unreadable
file stops the server before it binds.

### Several certificates

Repeat the pair. The first pair is the default. The others are chosen per
connection by SNI:

```bash
garuda --port 443 \
    --tls-cert /etc/ssl/shop/fullchain.pem  --tls-key /etc/ssl/shop/privkey.pem \
    --tls-cert /etc/ssl/admin/fullchain.pem --tls-key /etc/ssl/admin/privkey.pem
```

- The names each certificate covers are read from the certificate: its subject
  alternative names, or its common name if it has none.
- Matching follows RFC 6125. It is case-insensitive, and a wildcard covers one
  label: `*.example.com` matches `a.example.com`, not `a.b.example.com` or
  `example.com`.
- A name no certificate covers, or no SNI, gets the default certificate.
- An unequal number of certificates and keys is a start-up error.
- HTTP/3 always serves the default pair. Its handshake has no SNI selection.

### ACME

```bash
garuda --port 443 --acme-domain example.com --acme-domain www.example.com \
    --acme-email ops@example.com --acme-cache /var/lib/garuda/acme
```

With an empty cache, the server starts on a self-signed placeholder. A helper
process forked by the supervisor registers an account, answers the CA's
`tls-alpn-01` challenge on the port being served, and writes the certificate
to the cache. The workers are then replaced, as on `SIGHUP`. The helper checks
every 12 hours and renews when fewer than 30 days are left. A failed attempt is
retried after a minute, and the wait doubles up to six hours.

- The cache holds `account.key`, `cert.pem` and `key.pem`, with keys at mode
  0600. Keep it on persistent storage. Losing it means a new account and a new
  certificate, which count against the CA's rate limits.
- `--acme-domain` cannot be combined with `--tls-cert`. Names must be plain DNS
  names. Wildcards are refused, since they need `dns-01`.
- A public CA validates on port 443. The server warns when `--port` is
  anything else. A proxy that terminates TLS in front of Garuda breaks the
  challenge.
- Try a new setup with `--acme-staging` first. `--acme-directory` and
  `--acme-ca-bundle` point at another CA, such as a private one.
- HTTP/3 serves the same certificate and picks up a new one on the same reload.

### Redirecting HTTP

```bash
garuda --port 443 --acme-domain example.com --redirect-http 80 --hsts 31536000
```

`--redirect-http 80` answers every plain HTTP request on port 80 with the same
host and path on the TLS port.

- `GET` and `HEAD` get `301`. Other methods get `308`, which keeps the method
  and body.
- The host comes from `Host`, with its port replaced by the TLS port. The port
  is left out when it is 443.
- A request with no usable `Host` gets `400`.
- The request never reaches a handler, and the connection is closed.

It needs TLS (`--tls-cert` or `--acme-domain`), a port other than `--port`, and
TCP rather than `--unix`. Ports below 1024 need root or
`CAP_NET_BIND_SERVICE`.

### HSTS

`--hsts SECONDS` adds `Strict-Transport-Security: max-age=SECONDS` to every
response on the TLS port, over every protocol. A handler that sets its own
header has its value sent instead. It needs TLS. `includeSubDomains` and
`preload` are not added.

Start with a short value such as `300`. A browser that has seen a long
`max-age` refuses plain HTTP to the site until it expires.

### Kernel TLS

`--ktls` has the Linux kernel encrypt after OpenSSL completes the handshake. A
`--static-dir` file sent over HTTPS/1.1 then goes out with `sendfile`, as it
does in the clear. It needs the `tls` kernel module and an OpenSSL built with
kernel TLS. Without either, the server logs a warning and OpenSSL encrypts as
usual. HTTP/2 and HTTP/3 still read files, because their bytes are framed.

```bash
sudo modprobe tls
garuda --ktls --tls-cert cert.pem --tls-key key.pem --static-dir /static=/srv/app/static
```

---

## Protocols

| flag | default | what it does |
|---|---|---|
| `--no-http2` | off | HTTP/1.1 only |
| `--http2-only` | off | HTTP/2 only: `h2` alone in ALPN, prior knowledge in the clear |
| `--http3` | off | also serve HTTP/3 over QUIC; needs TLS; not with `--unix` |
| `--quic-port PORT` | `--port` | UDP port for HTTP/3 |
| `--no-websockets` | off | refuse WebSocket upgrade requests with 501 |
| `--websocket-protocols L` | `http1,http2,http3` | which protocols carry WebSockets; the others refuse them |
| `--ws-max-message BYTES` | 16 MiB | largest message accepted, joined or inflated; a larger one is closed with 1009 |
| `--ws-ping-interval MS` | `20000` | ping a WebSocket quiet this long; `0` sends none |
| `--ws-ping-timeout MS` | `20000` | close one whose ping, or whose close, has gone unanswered this long |
| `--ws-max-queue N` | `32` | messages held for a handler that is not reading, before the socket stops being read |
| `--ws-max-queue-bytes N` | 4 MiB | the same, in bytes; one message always fits |
| `--ws-compress` | off | agree permessage-deflate with a client that offers it |

With no flags, the TCP port serves HTTP/1.1 and HTTP/2 prior knowledge in the
clear. With a certificate, ALPN offers `h2` and `http/1.1`.

- `--no-http2` leaves only `http/1.1` in ALPN and does not recognise the
  cleartext HTTP/2 preface.
- `--http2-only` treats every cleartext connection as HTTP/2, which is what an
  h2c upstream from Envoy or Caddy expects.
- `--http3` serves HTTP/3 on UDP. Every TCP response carries
  `Alt-Svc: h3=":PORT"; ma=86400`, which is how clients find it. The UDP port
  must be open in the firewall as well as the TCP one.

```bash
garuda --port 8443 --workers 0 --tls-cert cert.pem --tls-key key.pem --http3

curl --http2-prior-knowledge http://127.0.0.1:8000/
curl -k --http2 https://127.0.0.1:8443/
curl -k --http3 https://127.0.0.1:8443/     # needs a curl built with HTTP/3
```

**WebSocket.** An upgrade is routed like any other request, and a route
registered with `app.webSocket` accepts it. `--no-websockets` refuses every
upgrade with 501 before anything else answers. The `--ws-*` flags bound what a
WebSocket may send and how long it may go quiet.

WebSockets are served over all three protocols: HTTP/1.1 by upgrade, HTTP/2 by
extended CONNECT (RFC 8441) and HTTP/3 the same way (RFC 9220). The same route
and handler serve all three. `--websocket-protocols` narrows the list:

- Leaving out `http1` answers an upgrade with 501.
- Leaving out `http2` stops sending `SETTINGS_ENABLE_CONNECT_PROTOCOL`, so a
  client asking anyway gets `RST_STREAM(PROTOCOL_ERROR)`.
- Leaving out `http3` answers the CONNECT with 501.

A browser that has negotiated HTTP/2 or HTTP/3 opens a WebSocket on that
connection only if the server offers it, and otherwise opens a separate
HTTP/1.1 connection. It does not retry one that was refused. So
`--websocket-protocols http3` alone breaks browsers that reach the server over
HTTP/2 or HTTP/1.1. Leave `http1` in unless every client is known.

**WebTransport** has no flag. It needs `--http3`, and a route registered with
`app.webTransport` takes the session. Any other extended CONNECT is refused
with 501.

---

## Static files and compression

| flag | default | what it does |
|---|---|---|
| `--static-dir P=DIR` | none | serve URL prefix P from DIR; repeatable |
| `--spa-fallback P=FILE` | none | answer a browser navigation under P that nothing else answers with FILE; repeatable |
| `--compress-static` | off | serve `FILE.br`, `FILE.zst` or `FILE.gz` beside a static file when accepted |
| `--compress` | off | compress handler responses with brotli, zstd or gzip, as the client accepts |
| `--compress-min-size N` | `1024` | leave a body declared smaller than this uncompressed |

### `--spa-fallback`

A single-page application routes in the browser, so a reload or a shared link
asks the server for a path like `/settings/profile` that only the page knows.

```bash
garuda --static-dir /assets=/srv/app/dist/assets --spa-fallback /=/srv/app/dist/index.html
```

- The file is sent, 200 with its ETag, for a `GET` or `HEAD` under the prefix
  that no `--static-dir` file, route, 405 or scope fallback answered.
- Only when the request's `Accept` names `text/html` or
  `application/xhtml+xml`, as a browser's navigation does. A missing script, an
  image or an API call sends `*/*` or a type of its own and keeps its 404, so a
  broken asset link is not answered with a page that fails to parse as
  JavaScript.
- The prefix matches whole segments, and the longest wins. The file must be
  readable when the server starts.

### `--static-dir`

```bash
garuda --static-dir /static=/srv/app/static --static-dir /media=/srv/app/media
```

- The prefix must start with `/` and matches whole segments. The longest prefix
  matches first, whatever the flag order.
- Only `GET` and `HEAD` are served. Any other method, or a path with no regular
  file behind it, goes on to the routes.
- The path is percent-decoded and resolved, and must stay inside the directory.
  `..`, `%2e%2e` and symlinks that leave the tree are refused.
- The `ETag` comes from the file's size and modification time.
  `If-None-Match` gets `304` and `If-Match` gets `412`. There is no
  `Last-Modified`, no byte ranges and no directory index.
- On plaintext HTTP/1.1 the file goes out with `sendfile(2)`. Over TLS (without
  `--ktls`), HTTP/2 and HTTP/3 it is read and then encrypted or framed.

### `--compress-static`

The server looks for a copy compressed at build time beside the file, such as
`app.js.br`, `app.js.zst` or `app.js.gz`, in the order the client prefers. The
original must also exist. The copy gets its own `ETag`, the response carries
`Vary: Accept-Encoding`, and it still uses `sendfile` where the original would.

```bash
find static -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' \) \
    -exec brotli -kq 11 {} \; -exec gzip -k9 {} \;
```

A static file reflects nothing from the request, so this carries no BREACH
risk.

### `--compress`

`--compress` compresses what handlers answer with, whoever answered: the
handler, a middleware, an error. The coding is the one the client rates highest
of brotli, zstd and gzip, brotli first when it rates them equally. brotli and
zstd are loaded at run time from `libbrotlienc` and `libzstd` when present; gzip
uses zlib.

- Only text and the formats that are text in all but name are compressed:
  `text/*` except `text/event-stream`, JSON, JavaScript, XML, SVG, WebAssembly
  and a few fonts. An image, an event stream, a body the handler encoded
  itself, `Cache-Control: no-transform`, a partial response and a body
  declared shorter than `--compress-min-size` go out as they are.
- A body sent whole is compressed whole and states its compressed
  `Content-Length`. A streamed body is compressed as it is written, each write
  flushed through so the client can read it at once, and is chunked on
  HTTP/1.1. A declared `Content-Length` is still held to the bytes the handler
  writes.
- Any response that could be compressed for some client says
  `Vary: Accept-Encoding`, unless the handler's own `Vary` covers it. A strong
  `ETag` on a compressed response is sent weak. HEAD is not encoded.

Before turning it on, read about BREACH: a compressed TLS response that puts a
secret next to text the client controls lets an observer of response sizes
recover the secret.

---

## Caching

| flag | default | what it does |
|---|---|---|
| `--cache-size MIB` | `0` (off) | a response cache shared by every worker |
| `--cache-max-object KIB` | `1024` | largest body the cache keeps; 1 to 65536 |
| `--cache-ttl-max SECONDS` | `300` | longest a response is kept |

The cache answers a GET or HEAD from a copy of an earlier handler response to
the same URL, without calling the handler. The memory is mapped before the
workers fork, so a copy one worker stores, every worker serves.

- **What is kept:** a response marked fresh with `Cache-Control: s-maxage` or
  `max-age`, for no longer than it has left or `--cache-ttl-max`. A 200, 204,
  404 and the other statuses RFC 9110 calls cacheable by default are kept; a
  body streamed in pieces is kept whole.
- **What is not:** `private`, `no-store`, `Set-Cookie`, a `Vary` on anything
  but `Accept-Encoding`, a response already past its lifetime by its own
  `Age` or `Date`, a body larger than `--cache-max-object`, and a body that
  disagrees with its `Content-Length`. Nor is a response to a request with
  `Authorization` or a cookie, and such a request is never answered from a
  copy. `Cache-Control: no-cache` or `max-age=0` on a request goes to the
  handler.
- **Serving:** a copy carries `Age` and `Cache-Status: garuda; hit; ttl=N`,
  gets its own request ID, and is compressed afresh for each client when
  `--compress` is on. `If-None-Match` and `If-Modified-Since` are answered 304
  from the copy; `If-Match`, `If-Unmodified-Since` and `If-Range` go to the
  handler.
- **Retiring:** a POST, PUT, PATCH or DELETE to a URL that succeeds retires its
  copies, including a GET still being answered at the time. A refused one
  retires nothing. A reload starts with an empty cache.

---

## Rate limiting

| flag | default | what it does |
|---|---|---|
| `--rate-limit RATE` | none | 429 past RATE requests per client: `N/s`, `N/m` or `N/h` |
| `--rate-limit-burst N` | N from RATE | requests allowed at once before the rate applies |

```bash
garuda --rate-limit 100/s --rate-limit-burst 200
```

A client over its allowance gets `429` with `Retry-After` in whole seconds, and
the connection stays open. The health check is never limited.

- **Shared across workers.** All workers use one table mapped before they fork.
  A limit per worker would let a client through once per worker.
- **Client key.** The peer address, or the address a trusted proxy reports.
  `X-Forwarded-For` from an untrusted peer is ignored. IPv6 clients are keyed
  by `/64`. Unix socket peers are not limited unless a trusted proxy names the
  client.
- **Full table.** The table holds 65,536 clients. An entry whose client has
  earned back its whole burst is reused. A new client that finds no free entry
  is allowed, so a full table never refuses traffic.

Refusals are counted in `garuda_requests_rate_limited_total`. There are no
per-route limits and no key other than the address.

---

## Proxies and request identity

| flag | default | what it does |
|---|---|---|
| `--forwarded-allow-ips LIST` | nobody | peers whose forwarded headers are believed |
| `--scheme http\|https` | `https` with TLS, else `http` | fallback for `request.scheme` |
| `--request-id` | off | give every request an `X-Request-ID` |
| `--trace-context` | off | record a W3C `traceparent` in the access log |
| `--request-start-header` | off | make the arrival time available as `request.requestStart` |

### `--forwarded-allow-ips`

```bash
garuda --forwarded-allow-ips 10.0.0.0/8,127.0.0.1
```

`X-Forwarded-For`, `X-Forwarded-Proto` and `Forwarded` are read only when the
connecting peer is on the list. From any other peer they are ignored, because
a client can send them too. The list is comma-separated addresses, CIDR
blocks, `unix`, or `*`. An entry that does not parse stops start-up. Use `*`
only when nothing but the proxy can reach the server.

Trusted forwarded information is used for:

- rate limiting, which keys on the reported client address;
- `--request-id`, which keeps a trusted proxy's `X-Request-ID`;
- handlers, through `request.remoteAddress`, `request.remotePort` and
  `request.scheme`.

### `--scheme`

`request.scheme` is `https` on a TLS connection, on an HTTP/2 or HTTP/3
request whose `:scheme` says so, or when a trusted proxy says so. Otherwise it
is `--scheme`. Set `--scheme https` behind a proxy that terminates TLS and
does not send forwarded headers.

### `--request-id`

- Every response carries `X-Request-ID`, on every protocol. A handler that sets
  its own has its value sent instead.
- A handler reads it as `request.requestID`.
- A text access line ends with ` id=...`. A JSON line gets `"request_id"`.

A new ID is a version 4 UUID. An `X-Request-ID` from a peer in
`--forwarded-allow-ips` is kept if it is 1 to 128 characters of letters,
digits and `-_.:+/=@~`. Any other `X-Request-ID`, including one sent directly
by a client, is replaced. The ID is assigned before the health check and the
rate limiter, so their responses carry one too. The `--redirect-http` port
assigns none.

### `--trace-context`

The server records the trace ID and parent span ID of a valid `traceparent`
header in the access log: ` trace=... span=...` on a text line, `"trace_id"`
and `"parent_id"` in JSON. It never generates or changes the header. A value
that does not follow the W3C format is ignored.

### `--request-start-header`

`request.requestStart` is the time the request arrived, in microseconds since
the epoch, using the kernel's receive timestamp where available. It is `nil`
without the flag. APM agents use it to report queue time. The server does not
add an `X-Request-Start` header; a proxy's own header is still among the
request headers.

---

## Observability

| flag | default | what it does |
|---|---|---|
| `--access-log` | off | one line per request to stderr |
| `--access-log-format F` | `text` | `text` or `json`; implies `--access-log` |
| `--log-format F` | `text` | `text` or `json` for `request.log` and `AppLog`, and the access log unless `--access-log-format` is given |
| `--log-level LEVEL` | `info` | `debug`, `info`, `warning`, `error` or `silent` |
| `--health-check-path P` | none | answer GET and HEAD for P with 200 |
| `--metrics-port PORT` | none | serve Prometheus metrics on a separate port |
| `--metrics-host HOST` | `--host` | interface the metrics port binds |

### Access log

```
[info]  pid=8961 GET /user/17?x=1 200 43us
```

```json
{"level":"info","pid":8961,"method":"GET","target":"/user/17?x=1","status":200,"duration_us":43,"proto":"HTTP/2"}
```

- Access lines are logged at `info`. `--log-level warning` or higher turns them
  off.
- The duration runs from dispatch to the response head being queued, not to
  the last body byte.
- `proto` is `HTTP/1.0`, `HTTP/1.1`, `HTTP/2` or `HTTP/3`.
- In JSON, a target that is not valid UTF-8 has its bytes escaped as `\u00XX`.
  A target too long for the line is cut and the object gets
  `"truncated":true`. Every line is a complete object.

`--log-level` also accepts `warn` and `none`.

### Application log

`request.log` and `AppLog` write to the same stderr, at the same levels:

```
[info]  pid=8961 order placed order=42 cents=1250 method=POST path=/orders request_id=5f0c…
```

```json
{"level":"info","pid":8961,"msg":"order placed","method":"POST","path":"/orders","request_id":"5f0c…","order":"42","cents":1250}
```

- A request's lines carry `method` and `path`, `request_id` with
  `--request-id`, and `trace_id` and `parent_id` with `--trace-context`: the
  fields the access log has, under the JSON access log's names.
- In text, a value with a space, quote, `=` or control character is quoted,
  and newlines are escaped in both formats.
- A line is one write of at most 4096 bytes, so workers sharing a pipe do not
  interleave. A longer one is cut and ends `truncated=true`, or
  `"truncated":true` in JSON.
- The server's own messages, such as a handler that threw, stay text.

### Health check

`--health-check-path /healthz` answers `GET` and `HEAD` for that path with
`200` and an empty body, before rate limiting, static files and routes. The
query string is ignored. The path must start with `/`. During a
`--drain-delay` it answers `503`.

### Metrics

`--metrics-port 9100` serves the Prometheus text format on its own port. A
scrape is answered by whichever worker accepts it, and reports the sum over
all workers.

| metric | type |
|---|---|
| `garuda_requests_total{status="1xx".."5xx"}` | counter |
| `garuda_request_duration_seconds` | histogram |
| `garuda_connections_accepted_total`, `_closed_total`, `_rejected_total` | counters |
| `garuda_connections_active`, `garuda_connection_slots` | gauges |
| `garuda_buffer_pool_hits_total`, `garuda_buffer_pool_misses_total` | counters |
| `garuda_requests_rate_limited_total` | counter |
| `garuda_cache_hits_total`, `_misses_total`, `_stores_total` | counters, with `--cache-size` |
| `garuda_workers` | gauge |
| `garuda_route_requests_total{method, route, status}` | counter |
| `garuda_route_request_duration_seconds{method, route}` | histogram |

The `route` label is the pattern a route was registered with, such as
`/users/:id`, never the path a client sent, so there is one series per route
however many URLs it serves. A request no route matched is `route="unmatched"`
and one a fallback answered is `route="fallback"`. A route appears once it has
answered something. HEAD requests a GET route answers count under `GET`.

`--metrics-host` defaults to `--host`, so a server on `0.0.0.0` publishes its
metrics there too. Bind it privately:

```bash
garuda --host 0.0.0.0 --port 8443 --metrics-port 9100 --metrics-host 127.0.0.1
```

Without `--metrics-port`, nothing is counted.

---

## Reload and signals

| flag | default | what it does |
|---|---|---|
| `--reload` | off | development: restart on a rebuilt executable; replace workers when a certificate file changes |
| `--reload-interval MS` | `500` | how often `--reload` rescans; minimum 50 |

### Signals

| signal | effect |
|---|---|
| `SIGTERM` | fail the health check for `--drain-delay`, then stop accepting and drain within `--graceful-timeout` |
| `SIGINT`, `SIGQUIT` | drain at once; a second one cuts short a running `--drain-delay` |
| `SIGHUP` | replace every worker, one at a time, without dropping a connection |

A draining worker stops accepting, closes idle keep-alive connections and
finishes its requests. The supervisor kills any worker still running after
`--drain-delay` + `--graceful-timeout` + 2 seconds. Workers apply the drain
delay themselves, so an init system that signals the whole process group
behaves the same as one that signals only the supervisor.

### `--drain-delay` behind a load balancer

```bash
garuda --health-check-path /healthz --drain-delay 10000 --graceful-timeout 30000
```

A load balancer or Kubernetes Service keeps routing to a server for a few
seconds after it is told to stop. During `--drain-delay`, the server keeps
serving, the health check answers `503`, and HTTP/1.1 responses carry
`Connection: close`. Then the drain starts.

- Make the delay longer than the readiness probe takes to fail: its period
  times its failure threshold.
- Kubernetes' `terminationGracePeriodSeconds` must cover the delay plus
  `--graceful-timeout`.
- Only `SIGTERM` waits. `SIGINT`, `SIGQUIT` and `SIGHUP` do not.

### `SIGHUP`

Each replacement worker is forked with its predecessor's listening socket. The
old worker gets `SIGQUIT` only after the replacement reports it is accepting.
A replacement that dies before it is ready gives the slot back and stops the
reload. One that never reports ready is given 60 seconds, then the old worker
is retired anyway. A `SIGHUP` during a reload queues one more pass.

Replacement workers read the certificates and keys from disk again, so
`SIGHUP` reloads certificates. It does not re-read the command line.

```bash
certbot renew --deploy-hook 'systemctl reload garuda'
```

### `--reload`

`--reload` watches the running executable, and every `--tls-cert` and
`--tls-key` file unless `--acme-domain` is in use.

- **Executable rebuilt.** The file must stop changing for 300 ms and run
  `--version` successfully within 5 seconds. The supervisor then execs it with
  the same pid and arguments, keeping the listening sockets open, and replaces
  the workers as `SIGHUP` does. A build that does not run is logged and
  ignored.
- **Certificate or key changed.** The workers are replaced without an exec.

Changes are picked up through inotify on Linux or kqueue on macOS, plus a
rescan every `--reload-interval` for file systems that send no notification,
such as network mounts or a Windows drive under WSL. `--reload` does not build
anything. Do not use it in production.

---

## A production starting point

```bash
garuda \
    --host 0.0.0.0 --port 443 --workers 0 \
    --tls-cert /etc/ssl/app/fullchain.pem --tls-key /etc/ssl/app/privkey.pem \
    --http3 --redirect-http 80 --hsts 300 \
    --forwarded-allow-ips 10.0.0.0/8 \
    --static-dir /static=/srv/app/static --compress-static \
    --health-check-path /healthz --drain-delay 10000 --graceful-timeout 30000 \
    --max-body 8388608 \
    --metrics-port 9100 --metrics-host 127.0.0.1 \
    --access-log --access-log-format json
```

---

## Configuring from code

`Application.run(configuration:)` takes a `ServerConfig`. It is checked the
same way as the command line, and a mistake is logged and returns status 2.
String fields are C string pointers that must outlive the server.
`ServerConfig.string(_:)` makes one.

```swift
var config = ServerConfig()
config.host = ServerConfig.string("0.0.0.0")
config.port = 8443
config.workers = 0
config.tlsCertPath = ServerConfig.string("/etc/ssl/app/fullchain.pem")
config.tlsKeyPath = ServerConfig.string("/etc/ssl/app/privkey.pem")
config.http3Enabled = true
_ = config.trust.parse(ServerConfig.string("10.0.0.0/8"))
exit(app.run(configuration: config))
```

Most fields share the flag's name. These do not:

| flag | `ServerConfig` field |
|---|---|
| `--unix` | `unixPath` |
| `--max-body` | `maxBodySize` |
| `--max-header-size` | `maxHeadSize` |
| `--keep-alive` | `keepAliveTimeoutMs` |
| `--request-timeout` | `requestHeadTimeoutMs` |
| `--graceful-timeout` | `gracefulShutdownMs` |
| `--drain-delay` | `drainDelayMs` |
| `--tls-cert`, `--tls-key` | `tlsCertPath`, `tlsKeyPath` for the default pair; `tlsExtraCerts` for the rest |
| `--acme-domain` | `acmeDomains` |
| `--acme-cache` | `acmeCacheDir` |
| `--acme-staging` | `acmeDirectory` set to the staging URL |
| `--acme-ca-bundle` | `acmeCABundle` |
| `--redirect-http` | `redirectHTTPPort` |
| `--hsts` | `hsts` and `hstsLength`: the header value bytes, such as `max-age=300`; not checked against TLS |
| `--no-http2` | `http2Enabled = false` |
| `--http2-only` | `http2Only` |
| `--http3` | `http3Enabled` |
| `--no-websockets` | `websocketsEnabled = false` |
| `--websocket-protocols` | `websocketOverHTTP1`, `websocketOverHTTP2`, `websocketOverHTTP3` |
| `--ws-max-message` | `maxWebsocketMessageSize` |
| `--ws-ping-interval`, `--ws-ping-timeout` | `websocketPingIntervalMs`, `websocketPingTimeoutMs` |
| `--ws-max-queue`, `--ws-max-queue-bytes` | `maxWebsocketQueue`, `maxWebsocketQueueBytes` |
| `--static-dir` | `staticRoutes` |
| `--compress-min-size` | `compressMinimumLength` |
| `--cache-size` | `cacheSizeMiB` |
| `--cache-max-object` | `cacheMaxObject`, in bytes |
| `--cache-ttl-max` | `cacheTTLMaxSeconds` |
| `--rate-limit` | `rateLimitCount` and `rateLimitPeriodMs` |
| `--rate-limit-burst` | `rateLimitBurst` (0 means the count) |
| `--forwarded-allow-ips` | `trust`, filled with `trust.parse(_:)` |
| `--health-check-path` | `healthPath` |
| `--access-log-format json` | `accessLog = true` and `accessLogJSON = true` |
| `--log-format json` | `logJSON = true`, and `accessLogJSON = true` unless `--access-log-format` is given |
| `--reload-interval` | `reloadIntervalMs` |

The command line clamps some values (the `--max-header-size` minimum, the
`--reload-interval` minimum). Fields set from code are not clamped.

---

Next: [INSTALLATION.md](INSTALLATION.md) covers building, certificates and
running as a service. [README.md](README.md) describes the handler API and
current status. [TRANSPORT.md](TRANSPORT.md) covers each protocol, and
[ARCHITECTURE.md](ARCHITECTURE.md) explains how the server is built.

---

## Your application's own settings

The flags above are the server's. What your application needs -- a database
URL, a signing key, which features are on -- belongs in the environment, where
a deployment sets it as a secret, and `AppEnvironment` reads it:

```swift
struct Settings {
    let databaseURL: String
    let signingKey: String
    let poolSize: Int
    let signUpsOpen: Bool
}

func settings() throws -> Settings {
    var env = AppEnvironment()
    let production = env.mode == .production      // APP_ENV
    let settings = Settings(
        // A default in development; required in production.
        databaseURL: env.url("DATABASE_URL", default: production ? nil : "postgres://localhost/dev"),
        // JWT_PRIVATE_KEY, or the contents of the file JWT_PRIVATE_KEY_FILE names.
        signingKey: env.secretOrFile("JWT_PRIVATE_KEY", default: production ? nil : ""),
        poolSize: env.int("DATABASE_POOL_SIZE", default: 8, in: 1...500),
        signUpsOpen: env.bool("SIGNUPS_OPEN", default: true))
    if settings.signUpsOpen && production && settings.databaseURL.isEmpty {
        env.problem("SIGNUPS_OPEN cannot be on with no database")
    }
    try env.check()        // throws once, listing every problem
    return settings
}
```

| Reader | Reads |
|---|---|
| `string(_:default:)` | text; `default: nil` makes it required |
| `int(_:default:in:)` | a whole number, refused outside the range |
| `bool(_:default:)` | `true`/`yes`/`on`/`1` and their opposites, any case |
| `choice(_:default:)` | one case of a `RawRepresentable & CaseIterable` |
| `secret(_:default:)` | text that `summary()` only says is set |
| `secretOrFile(_:default:)` | the same, or the contents of the file `<NAME>_FILE` names |
| `url(_:default:)` | a URL whose password `summary()` takes out |

- **Every problem at once.** A reader always returns a usable value and records
  what was wrong, so reading goes on and `check()` reports the lot. A missing
  secret and a mistyped number are one restart, not two.
- **`mode`** is `APP_ENV`: `development`, `test`, `staging` or `production`,
  and `development` when it is unset.
- **`summary()`** is what a `myapp env` command prints: every variable that was
  read, secrets held back, passwords taken out of URLs.
- **Where to call it:** before the application is built, so nothing is served
  until the environment checks out.
  [Examples/STARTER.md](Examples/STARTER.md) does exactly this, and
  `Examples/Sources/StarterExample/Configuration.swift` is the whole file.
