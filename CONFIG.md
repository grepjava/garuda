# Configuring Garuda

Garuda is configured on the command line. There is no configuration file. A
running server does not re-read its flags, so changing one means a restart.
`garuda --help` prints the list.

`Application.run()` parses the same flags, so an application built on the
handler API takes the same command line as the `garuda` executable.
`Application.run(config:)` takes a `ServerConfig` instead; see
[Configuring from code](#configuring-from-code). Neither returns: the process
exits when the server stops.

Before the flags are read, `SERVER_HOSTNAME` and `SERVER_PORT` in the
environment set the host and port. The command line wins over them.

A request passes through the server features in this order before a route
sees it:

1. `--request-id` and `--trace-context` are recorded as the head is read.
2. `--health-check-path` answers the probe.
3. `--rate-limit` refuses a client over its allowance with 429.
4. `--static-dir` serves a file, if there is one.
5. `--cache-size` answers from a stored copy, if there is one.
6. The routes, then scope fallbacks, then `--spa-fallback`, then 404 or 405.

Everything else on this page applies to every protocol unless it says
otherwise.

`--version` prints the version. `-h` and `--help` print the flag list. An
unknown flag, a stray argument or an invalid value is reported, and the process
exits with status 2. So does a route table with problems, and a certificate
that cannot be loaded.

**Units.** Each flag takes the unit its name in `--help` says, and they are not
all the same: `--keep-alive`, `--request-timeout`, `--graceful-timeout`,
`--drain-delay` and the `--ws-ping-*` flags are milliseconds, while
`--sse-keep-alive`, `--cache-ttl-max`, `--hsts` and `--tls-reload` are seconds.
The units are Garuda 1's. [COMPATIBILITY.md](COMPATIBILITY.md) lists what
changed between the two.

---

## Shards, threads and listening

| flag | default | what it does |
|---|---|---|
| `--host HOST` | `127.0.0.1` | interface to bind |
| `--port PORT` | `8000` | TCP port, and the HTTP/3 UDP port unless `--quic-port` is given; `0` picks a free one |
| `--unix PATH` | none | listen on a unix socket instead of TCP |
| `--backlog N` | `2048` | listen backlog |
| `--root-path PATH` | none | prefix removed from the path before routes match |
| `--shards N\|auto` | `auto` on Linux, `0` elsewhere | shard processes; `0` serves in this process |
| `--balance MODE` | `auto` | how shards share the port: `reuseport`, `shared` or `auto` |
| `--threads N` | the shard's CPUs | worker threads per shard |
| `--no-pin` | pinned | do not pin each shard's threads to its CPUs |
| `--acceptors N` | one per thread | accept loops per shard |
| `--io uring\|epoll` | io_uring where the kernel has it | the I/O driver (Linux) |
| `--heavy-threshold US` | `500` | microseconds a route may hold a thread, on average, before it runs in the heavy lane |
| `--no-heavy-lane` | lane on | let every route use every thread |
| `--sched-slice US` | -- | Garuda 1's scheduler slice; accepted (0, or 100 to 100000), with a warning that it has no effect |

**Shards.** A shard is a process with its own work-stealing runtime on its
own CPUs. With one shard or more, the process that was started becomes a
supervisor: it binds the ports, starts the shards, starts again one that
crashes, and passes signals on to them. A crash takes down only the
connections of that one shard. [ARCHITECTURE.md](ARCHITECTURE.md#shards)
has how this works.

- `auto` lets Vega choose: one shard per last-level cache domain on Linux
  (an L3, read from sysfs), within the CPUs the process may run on. The
  environment variable `VEGA_SHARDS`, when set, overrides the flag.
- `0` serves in this one process with no supervisor. It is the default on
  macOS, where a developer usually wants one process to attach a debugger to,
  and the only mode on Windows. Nothing restarts a crashed server, and there
  is no reload: `SIGHUP` is not handled, so the system's default for it ends
  the process.
- `--workers N` is accepted as Garuda 1's name for `--shards N`.

**`--balance`.** How the shards share the listening port:

- `reuseport`: each shard binds its own `SO_REUSEPORT` socket and the kernel
  hashes connections across them. On Linux that spreads them evenly. On macOS
  the kernel sends every connection to the newest socket, so do not use it
  there.
- `shared`: one socket, bound by the supervisor, that every shard accepts
  on. A connection goes to a shard that is waiting in accept.
- `auto` (the default): `reuseport` on Linux, `shared` elsewhere.

`accept` and `adaptive` are accepted as Garuda 1's names for `shared` and
`auto`. Garuda 2 does not move connections between shards; there is no
equivalent of Garuda 1's adaptive hand-off.

**`--threads`** is per shard. Without it a shard has one worker per CPU it was
given, or, with `--shards 0`, one per CPU. **`--no-pin`** leaves the threads
unpinned, which matters where the machine's CPUs are shared with something
else.

**Unix sockets.** Every shard accepts on the one socket, which the
supervisor binds. A stale socket file at the path is removed at start-up. A
unix peer has no address: list `unix` in `--forwarded-allow-ips` to believe a
proxy connecting over it. `--http3` and `--redirect-http` cannot be used with
`--unix`.

```bash
garuda --unix /run/app.sock --forwarded-allow-ips unix
```

**`--root-path`.** `--root-path /api` answers `GET /api/user/7` with the route
for `/user/7`. Only a whole segment is removed, and a path that does not start
with the prefix is routed as it came. It applies to routes only:
`--static-dir` and `--health-check-path` match the path as the client sent it.

**`--acceptors`** sets how many accept loops each shard runs. One per thread
means a new connection usually starts on the thread that accepted it rather
than on a thread woken to steal it.

**`--io`** chooses Vega's I/O driver on Linux: `uring` (completion-based
io_uring, one ring per worker, Linux 6.7 or later) or `epoll`. io_uring is used
by default where the kernel can run it, and Vega falls back to epoll where it
cannot (an older kernel, or io_uring blocked by seccomp or
`kernel.io_uring_disabled`). macOS always uses kqueue, and the flag changes
nothing there.

**The heavy lane.** Each route keeps an average of how long its handler holds
a thread without awaiting. A route whose average passes `--heavy-threshold`,
or one registered through `app.heavy`, runs only while it holds one of the
shard's heavy-lane permits, of which there are half as many as threads,
rounded up. Quick requests always have the other threads.
[ARCHITECTURE.md](ARCHITECTURE.md#the-heavy-lane) explains it.

**Routes must be deterministic.** On macOS each shard of a sharded server is
started as a new run of the executable (Linux forks instead), and runs `main`
again up to `app.run()`. The routes an application registers must therefore
come out the same every time: no clock, no random numbers, no reading of files
that may change in between.

---

## Limits and timeouts

| flag | default | what it does |
|---|---|---|
| `--max-connections N` | no limit | connections a shard has open at once; more wait in the backlog |
| `--max-body BYTES` | 16 MiB | largest request body; larger gets 413 |
| `--max-header-size BYTES` | 32 KiB | largest request head; larger gets 431; minimum 1024 |
| `--keep-alive MS` | `5000` | idle time allowed on a connection between requests |
| `--request-timeout MS` | `30000` | how long a request may stall part-way through |
| `--graceful-timeout MS` | `10000` | time requests, streams and WebSockets in progress get at shutdown |
| `--drain-delay MS` | `0` | on `SIGTERM`, keep serving this long with the health check failing |
| `--blocking-threads N` | Vega's, `512` | threads per shard that blocking work (`app.offload`) runs on |
| `--blocking-queue N` | no limit | blocking work waiting for a thread, per shard, before it is refused 503 |
| `--sse-keep-alive SECS` | `15` | an event stream quiet this long is sent a comment; `0` sends none |
| `--broadcast-size MIB` | `4` | the ring a `Topic`'s messages cross shards in; `0` turns topics off |
| `--broadcast-queue N` | `1024` | messages a subscriber may fall behind by before it is told it missed some |

- **`--max-connections`** is per shard. A connection that arrives at a full
  shard is not accepted until one closes; it waits in the listen backlog.
- **`--max-body`** is checked against a declared `Content-Length` before the
  body is read, and against the bytes received for a chunked, HTTP/2 or HTTP/3
  body. Routes inside `app.maxBodySize(bytes) { … }` use that limit instead.
- **`--max-header-size`** bounds the HTTP/1.1 head. It is also the HTTP/2
  header list size and the HTTP/3 field section size.
- **`--keep-alive`** is the HTTP/1.1 idle time between requests. It also closes
  an idle HTTP/2 connection and is the QUIC idle timeout.
- **`--request-timeout`** covers a request head or body that stops arriving.
- **`--sse-keep-alive`** is kept by the server whatever the handler is waiting
  on, so a proxy that closes idle connections sees traffic and a client that
  has gone is found when the write fails. `EventStream(keepAlive:)` sets it
  for one stream.
- **`--broadcast-size`** is memory every shard maps before it starts. A
  message published on a `Topic` goes into it and every shard reads it from
  there, so it reaches subscribers on all of them. It also holds the recent
  past: a client that reconnects with `Last-Event-ID` is sent what it missed
  as long as newer messages have not written over it. A message may be up to
  a quarter of the ring. With `0`, publishing and subscribing throw
  `BroadcastError.unavailable`, answered 503.
- **`--broadcast-queue`** is per subscriber. One that falls further behind is
  given `.missed` in place of what it could not keep, rather than holding the
  rest in memory.

`--drain-delay` and `--graceful-timeout` are described under
[Signals](#signals) and in [DEPLOYMENT.md](DEPLOYMENT.md).

The limits below have no flag; set them on a `ServerConfig` and call
`app.run(config:)`:

| `ServerConfig` field | default | what it does |
|---|---|---|
| `readBufferSize` | 16 KiB | per-connection read buffer (at least 1024) |
| `maxHeaders` | `100` | most header fields in a request |
| `maxRequestsPerConnection` | `0` | requests before a polite close; `0` is unlimited |
| `pipelineDepth` | `16` | pipelined HTTP/1.1 responses written as one batch |
| `bodyTimeout` | 30 s | how long each read of a request body may wait |
| `writeTimeout` | 30 s | how long one write of a streamed body may wait on an HTTP/1.1 client that is not reading |
| `writeHighWaterMark`, `writeLowWaterMark` | 512 KiB, 128 KiB | a streamed body's writes wait above the first until it is down to the second |
| `tlsHandshakeTimeout` | 10 s | time to finish the TLS handshake |
| `h2MaxConcurrentStreams` | `128` | HTTP/2 streams a client may have open at once |
| `h2MaxFrameSize` | 16 KiB | largest HTTP/2 frame payload a client may send |
| `h2InitialWindowSize` | 256 KiB | request body a client may send before the window is given back |
| `maxQUICConnections` | `4096` | QUIC connections per UDP socket; a shard has one socket per thread |

---

## TLS

| flag | default | what it does |
|---|---|---|
| `--tls-cert PATH` | none | PEM certificate chain; repeatable, paired with `--tls-key` in order |
| `--tls-key PATH` | none | PEM private key for the `--tls-cert` before it |
| `--tls-reload SECS` | off | look at the certificate files every SECS and serve them again when they change |
| `--redirect-http PORT` | none | answer plain HTTP on PORT with a redirect to https |
| `--acme-webroot DIR` | none | on the `--redirect-http` port, serve ACME HTTP-01 challenges from DIR |
| `--hsts SECS` | none | send `Strict-Transport-Security: max-age=SECS` on TLS responses |
| `--tls-ciphers LIST` | the library's | cipher list for TLS 1.2; TLS 1.3 suites are not configurable |
| `--ktls`, `--no-ktls` | -- | Garuda 1's; accepted. `--ktls` warns that it has no effect, and `--no-ktls` asks for what is already so |

`--tls-cert` and `--tls-key` turn on TLS for the TCP port. ALPN chooses HTTP/2
or HTTP/1.1. The files are loaded and checked before any shard starts, so an
unreadable file or a key that does not match its certificate stops the server
with status 2.

TLS is Vega's, on BoringSSL by default or on the system's OpenSSL 3 when built
with the `OpenSSL` trait ([INSTALLATION.md](INSTALLATION.md#the-tls-library)).
There is no kernel TLS.

Session tickets let a returning client skip the full handshake. The ticket key
lives in memory every shard shares, so a client whose next connection lands
on another shard, or on a restarted one, still resumes.

### Several certificates

Repeat the pair:

```bash
garuda --port 443 \
    --tls-cert /etc/ssl/shop/fullchain.pem  --tls-key /etc/ssl/shop/privkey.pem \
    --tls-cert /etc/ssl/admin/fullchain.pem --tls-key /etc/ssl/admin/privkey.pem
```

- The names each certificate covers are read from the certificate.
- The client's SNI picks the first certificate that covers the name. A
  wildcard covers one label: `*.example.com` matches `a.example.com`, not
  `a.b.example.com`.
- A name no certificate covers, or no SNI, gets the first certificate.
- An unequal number of certificates and keys is a start-up error.
- HTTP/3 chooses among the same certificates the same way.

### Renewing certificates

Garuda 2 does not get certificates itself: there is no built-in ACME client.
Whatever issues them -- certbot, a proxy, an operator -- writes the files, and
the server picks them up:

- **`--tls-reload SECS`** checks the files' modification times every SECS
  seconds and loads them again when one has changed. New handshakes get the
  new certificate; open connections keep theirs. A set that does not load is
  logged and the old one stays in service.
- **`SIGHUP`** restarts the shards one at a time, and each loads the files
  as it starts ([DEPLOYMENT.md](DEPLOYMENT.md#reloads)).

For certbot's HTTP-01 challenge, run the redirect port with a webroot:

```bash
garuda --host 0.0.0.0 --port 443 --tls-cert … --tls-key … \
    --redirect-http 80 --acme-webroot /var/www/acme --tls-reload 3600

certbot certonly --webroot -w /var/www/acme -d example.com
```

`--acme-webroot DIR` answers `GET /.well-known/acme-challenge/TOKEN` on the
`--redirect-http` port with the file `DIR/.well-known/acme-challenge/TOKEN`,
which is where `certbot --webroot -w DIR` writes it. A token that is not
base64url, or a file larger than a challenge would be, is a 404. It needs
`--redirect-http`.

### Redirecting HTTP

```bash
garuda --port 443 --tls-cert … --tls-key … --redirect-http 80 --hsts 31536000
```

`--redirect-http 80` answers every plain HTTP request on port 80 with the same
host and path on the TLS port.

- `GET` and `HEAD` get `301`. Other methods get `308`, which keeps the method
  and body.
- The host comes from the request, with its port replaced by the TLS port. The
  port is left out when it is 443.
- A request with no usable host gets `400`.

It needs `--tls-cert` and a port other than `--port`. Ports below 1024 need
root or `CAP_NET_BIND_SERVICE`.

### HSTS

`--hsts SECS` adds `Strict-Transport-Security: max-age=SECS` to every response
over TLS, HTTP/3 included. A handler that sets its own header has its value
sent instead. It needs `--tls-cert`. `includeSubDomains` and `preload` are not
added.

Start with a short value such as `300`. A browser that has seen a long
`max-age` refuses plain HTTP to the site until it expires.

---

## Protocols

| flag | default | what it does |
|---|---|---|
| `--no-http2` | off | HTTP/1.1 only |
| `--http2-only` | off | HTTP/2 only: `h2` alone in ALPN, prior knowledge in the clear |
| `--http3` | off | also serve HTTP/3 over QUIC; needs `--tls-cert` |
| `--quic-port PORT` | `--port` | UDP port for HTTP/3; needs `--http3` |
| `--no-websockets` | off | refuse WebSocket requests with 501 |
| `--websocket-protocols LIST` | `http1,http2,http3` | which protocols carry WebSockets |
| `--ws-max-message BYTES` | 16 MiB | largest message taken, after inflating; at least 125 |
| `--ws-ping-interval MS` | `20000` | ping a WebSocket quiet this long; `0` sends none |
| `--ws-ping-timeout MS` | `20000` | close one whose ping, or whose close, has gone unanswered this long |
| `--ws-max-queue N` | `32` | messages held for a handler that is not reading, before the socket stops being read |
| `--ws-max-queue-bytes BYTES` | 4 MiB | the same, in bytes |
| `--ws-compress` | off | agree permessage-deflate with a client that offers it |

With no flags, the TCP port serves HTTP/1.1, and HTTP/2 to a cleartext client
that opens with the HTTP/2 preface (prior knowledge). With a certificate, ALPN
offers `h2` and `http/1.1`.

- `--no-http2` leaves only `http/1.1` in ALPN and does not recognise the
  cleartext preface.
- `--http2-only` treats every cleartext connection as HTTP/2, which is what an
  h2c upstream from Envoy or Caddy, or a gRPC client, expects.
- `--http3` serves HTTP/3 on UDP, on Garuda's own QUIC implementation. Every
  TCP response carries `Alt-Svc: h3=":PORT"; ma=86400`, which is how clients
  find it. Each shard opens one UDP socket per thread on the port. Open the
  UDP port in the firewall as well as the TCP one.

```bash
garuda --port 8443 --tls-cert cert.pem --tls-key key.pem --http3

curl --http2-prior-knowledge http://127.0.0.1:8000/   # a server without TLS
curl -k --http2 https://127.0.0.1:8443/
curl -k --http3 https://127.0.0.1:8443/     # needs a curl built with HTTP/3
```

**WebSocket.** WebSockets are served over all three protocols: HTTP/1.1 by
upgrade, HTTP/2 by extended CONNECT (RFC 8441) and HTTP/3 the same way
(RFC 9220). The same `app.webSocket` route serves all three.
`--websocket-protocols` takes a comma-separated list of `http1`, `http2` and
`http3` (`h1`, `h2`, `h3` also work) and narrows it:

- Leaving out `http1` answers an upgrade with 501.
- Leaving out `http2` stops the server offering extended CONNECT
  (`SETTINGS_ENABLE_CONNECT_PROTOCOL`) at all.
- Leaving out `http3` answers the CONNECT with 501.

A browser that has negotiated HTTP/2 or HTTP/3 opens a WebSocket on that
connection only if the server offers it, and otherwise opens a separate
HTTP/1.1 connection. So leave `http1` in unless every client is known.

`--no-websockets` turns WebSockets off on every protocol: a WebSocket route
answers 501.

**WebTransport** has no flag. It needs `--http3`, and a route registered with
`app.webTransport` takes the session. [TRANSPORT.md](TRANSPORT.md) has the
details of every protocol.

---

## Static files and compression

| flag | default | what it does |
|---|---|---|
| `--static-dir PREFIX=DIR` | none | serve URL prefix PREFIX from DIR; a path naming no file falls through; repeatable |
| `--static-index` | off | answer a `--static-dir` directory with its `index.html` |
| `--static-listing` | off | list a `--static-dir` directory that has no `index.html` |
| `--static-listing-limit N` | `10000` | list at most N entries; `0` for no limit |
| `--spa-fallback PREFIX=FILE` | none | answer a browser navigation under PREFIX that nothing else answers with FILE; repeatable |
| `--compress-static` | off | serve `FILE.br`, `FILE.zst` or `FILE.gz` beside a static file when accepted |
| `--compress` | off | compress handler responses with brotli, zstd or gzip, as the client accepts |
| `--compress-min-size BYTES` | `1024` | leave a body declared smaller than this uncompressed |

### `--static-dir`

```bash
garuda --static-dir /static=/srv/app/static --static-dir /media=/srv/app/media
```

- The prefix must start with `/` and matches whole segments. The longest prefix
  matches first, whatever the flag order.
- Only `GET` and `HEAD` are served. Any other method, or a path with no regular
  file behind it, goes on to the routes.
- The path is percent-decoded, and the file is opened beneath the directory,
  by the kernel where it can, so `..`, `%2e%2e` and symbolic links cannot
  reach outside it.
- The `ETag` is strong, made from the file's size and modification time.
  `If-None-Match` gets `304`. There is no `Last-Modified`.
- `Range` is served: `206` with `Content-Range`, `416` with the file's size
  when it asks for what is not there, and `Accept-Ranges: bytes`. One range per
  request; a request for several gets the whole file, as RFC 9110 allows.
  `If-Range` sends the range only while the client's copy is current.
- A file of up to 16 KiB goes out with its head in one write. A larger one
  over plain HTTP/1.1 goes with `sendfile(2)`. Over TLS, HTTP/2 and HTTP/3 it
  is read in blocks and encrypted or framed, waiting for a slow client.
- A directory is not served unless asked for, as below. Otherwise it falls
  through to the routes like any unserved path.

### `--static-index` and `--static-listing`

```bash
garuda --static-dir /files=/srv/files --static-listing
```

- `--static-index` answers a request for a directory with its `index.html`,
  through the same path as any other file.
- `--static-listing` also lists a directory that has no `index.html`. It
  implies `--static-index`.
- Both are off by default. A listing tells whoever asks every name in the
  directory, which is a different decision from serving the files.
- A directory asked for without its trailing slash is a `301` to the slash,
  so relative links resolve inside it.
- A listing carries `Cache-Control: no-store`. It shows at most
  `--static-listing-limit` entries and says when there are more.
- A listing is refused for a path with a `.` or `..` segment or a symbolic
  link anywhere along it, even one that stays inside the tree.

### `--spa-fallback`

A single-page application routes in the browser, so a reload or a shared link
asks the server for a path like `/settings/profile` that only the page knows.

```bash
garuda --static-dir /assets=/srv/app/dist/assets --spa-fallback /=/srv/app/dist/index.html
```

- The file is sent for a `GET` or `HEAD` under the prefix that no
  `--static-dir` file, route, 405 or scope fallback answered.
- Only when the request's `Accept` names `text/html` or
  `application/xhtml+xml`, as a browser's navigation does. A missing script,
  an image or an API call keeps its 404.
- The prefix matches whole segments, and the longest wins. The file must be
  readable when the server starts.

### `--compress-static`

The server looks for a copy compressed at build time beside the file, such as
`app.js.br`, `app.js.zst` or `app.js.gz`, in the order the client prefers. The
original must also exist. The response carries `Vary: Accept-Encoding`.

```bash
find static -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' \) \
    -exec brotli -kq 11 {} \; -exec gzip -k9 {} \;
```

A static file reflects nothing from the request, so this carries no BREACH
risk.

### `--compress`

`--compress` compresses what handlers answer with: the coding the client rates
highest among brotli, zstd and gzip. gzip comes from zlib. brotli and zstd are
loaded at run time from `libbrotlienc` and `libzstd` where the system has
them, and are not offered where it does not.

- Only text and its kin are compressed: `text/*` except `text/event-stream`,
  JSON, JavaScript, XML, SVG and the like. An image, an event stream, a body
  the handler encoded itself, `Cache-Control: no-transform`, a partial
  response and a body declared shorter than `--compress-min-size` go out as
  they are.
- A whole body is compressed whole and states its compressed `Content-Length`.
  A streamed body is compressed as it is written, each write flushed through,
  and is chunked on HTTP/1.1.
- Any response that could be compressed for some client says
  `Vary: Accept-Encoding`. A strong `ETag` on a compressed response is sent
  weak.

Before turning it on, read about BREACH: a compressed TLS response that puts a
secret next to text the client controls lets an observer of response sizes
recover the secret.

Compression is not available on Windows yet.

---

## Caching

| flag | default | what it does |
|---|---|---|
| `--cache-size MIB` | `0` (off) | a response cache shared by every shard |
| `--cache-max-object KIB` | `1024` | largest body the cache keeps; 1 to 65536 |
| `--cache-ttl-max SECS` | `300` | longest a response is kept |

The cache answers a GET or HEAD from a copy of an earlier handler response to
the same URL, without calling the handler. The memory is shared by every
shard, so a copy one shard stores, every shard serves, over any protocol.

- **What is kept:** a response marked fresh with `Cache-Control: s-maxage` or
  `max-age`, for no longer than it has left or `--cache-ttl-max`. A 200, 203,
  204, 300, 301, 308, 404, 405, 410, 414 or 501 is kept.
- **What is not:** `private`, `no-store`, `no-cache`, `Set-Cookie`, a `Vary`
  on anything but `Accept-Encoding`, a body the application encoded itself, a
  response already past its lifetime, and a body larger than
  `--cache-max-object`. Nor is the response to a request with
  `Authorization`, a cookie or `Range`, and such a request is never answered
  from a copy. `Cache-Control: no-cache` or `max-age=0` on a request goes to
  the handler, as do `If-Match`, `If-Unmodified-Since` and `If-Range`.
- **Serving:** a copy carries `Age` and `Cache-Status: garuda; hit; ttl=N`,
  and is compressed afresh for each client when `--compress` is on.
  `If-None-Match` and `If-Modified-Since` are answered 304 from the copy.
- **The key** is the scheme, the host and the whole request target, plus the
  forwarding headers when the peer is a trusted proxy.
- **Retiring:** a POST, PUT, PATCH or DELETE to a URL that is answered 2xx or
  3xx retires its copies, including a GET still being answered at the time.
  A refused one retires nothing. A shard that starts again, after a crash or
  during a reload, empties the cache.

---

## Rate limiting

| flag | default | what it does |
|---|---|---|
| `--rate-limit N/s\|m\|h` | none | 429 past N requests per client a second, minute or hour, counted across every shard |
| `--rate-limit-burst N` | the rate's count | requests allowed at once before the rate applies |

```bash
garuda --rate-limit 100/s --rate-limit-burst 200
```

A client over its allowance gets `429` with `Retry-After` in whole seconds, and
the connection stays open. The health check is never limited.

- **Shared across shards.** Every shard uses one table in shared memory. A
  client that came through four shards spent four requests of one allowance.
- **Client key.** The peer address, or the address a trusted proxy reports.
  `X-Forwarded-For` from an untrusted peer is ignored. IPv6 clients are keyed
  by `/64`, and an IPv4-mapped IPv6 address counts as the IPv4 one.
- **Full table.** The table holds 65,536 entries. An entry whose client has
  earned back its whole burst is reused. A new client that finds no free entry
  is allowed, so a full table never refuses traffic.

Refusals are counted in `garuda_requests_rate_limited_total`. There are no
per-route limits and no key other than the address. `app.concurrencyLimit`
bounds how many requests a group of routes runs at once in one shard
([MIDDLEWARE.md](MIDDLEWARE.md)).

---

## Proxies and request identity

| flag | default | what it does |
|---|---|---|
| `--forwarded-allow-ips LIST` | nobody | peers whose forwarded headers are believed |
| `--request-id` | off | give every request an `X-Request-ID` |
| `--trace-context` | off | record a W3C `traceparent` in the logs |
| `--scheme http\|https` | `http` | the scheme a request without TLS arrived by, behind a proxy that terminates TLS and does not say so; a request over TLS is always `https` |
| `--request-start-header` | off | make the arrival time available as `request.requestStart` |

### `--forwarded-allow-ips`

```bash
garuda --forwarded-allow-ips 10.0.0.0/8,127.0.0.1
```

`X-Forwarded-For`, `X-Forwarded-Proto` and `Forwarded` are read only when the
connecting peer is on the list. From any other peer they are ignored, because
a client can send them too. The list is comma-separated addresses, CIDR
blocks, `unix`, or `*`. An entry that does not parse stops start-up. Use `*` only when
nothing but the proxy can reach the server.

Trusted forwarded information is used for:

- rate limiting, which keys on the reported client address;
- `--request-id`, which keeps a trusted proxy's `X-Request-ID`;
- the response cache's key;
- handlers, through `request.remoteAddress`, `request.remotePort` and
  `request.arrivedOverHTTPS`.

### `--scheme`

A request arrived over HTTPS when it came over TLS, when an HTTP/2 or HTTP/3
request's `:scheme` says so, or when a trusted proxy says so. Otherwise
`--scheme` decides. Set `--scheme https` behind a proxy that terminates TLS
and does not send forwarded headers.

### `--request-start-header`

`request.requestStart` is the time the request arrived, in microseconds since
the epoch. It is `nil` without the flag. APM agents use it to report queue
time.

### `--request-id`

- Every response carries `X-Request-ID`, on every protocol. A handler that sets
  its own has its value sent instead.
- A handler reads it as `request.requestID`, and `request.log` puts it on
  every line.
- A text access line ends with ` id=...`. A JSON line gets `"request_id"`.

A new ID is a version 4 UUID. An `X-Request-ID` from a peer in
`--forwarded-allow-ips` is kept if it is 1 to 128 characters of letters,
digits and `-_.:+/=@~`. Any other, including one sent directly by a client, is
replaced, and the client's header is taken out of what the application sees.
The ID is assigned before the health check and the rate limiter, so their
responses carry one too.

### `--trace-context`

The server records the trace ID and parent span ID of a valid `traceparent`
header: ` trace=... span=...` on a text access line, `"trace_id"` and
`"parent_id"` in JSON, the same on `request.log` lines, and
`request.traceContext` for a handler. It never generates or changes the
header. A value that does not follow the W3C format is ignored. For spans of
the server's own, see `app.tracing` in [MIDDLEWARE.md](MIDDLEWARE.md).

---

## Observability

| flag | default | what it does |
|---|---|---|
| `--access-log` | off | one line per request to stderr |
| `--access-log-format F` | `text` | `text` or `json`; implies `--access-log` |
| `--log-format F` | `text` | `text` or `json` for `request.log` and `AppLog`, and the access log unless `--access-log-format` is given |
| `--log-level LEVEL` | `info` | `debug`, `info`, `warning`, `error` or `silent` (`warn` and `none` also work) |
| `--health-check-path P` | none | answer `GET` and `HEAD` for P with 200 |
| `--metrics-port PORT` | none | serve Prometheus metrics on a separate port |
| `--metrics-host HOST` | `--host` | interface the metrics port binds |
| `--slow-handler-ms MS` | -- | Garuda 1's slow-handler warning; accepted, with a warning that it has no effect |

`--slow-handler-ms` is accepted, with a warning that it has no effect in
Garuda 2. The heavy lane measures what it measured and acts on it;
`--log-level debug` logs each route that enters or leaves the lane, with its
average.

### Access log

```
garuda info: GET /user/17?x=1 200 43us
```

```json
{"level":"info","pid":8961,"method":"GET","target":"/user/17?x=1","status":200,"duration_us":43,"proto":"HTTP/2"}
```

- Access lines are logged at `info`. `--log-level warning` or higher turns them
  off.
- The duration runs from dispatch to the response head being written, not to
  the last body byte.
- `proto` is `HTTP/1.0`, `HTTP/1.1`, `HTTP/2` or `HTTP/3`.
- A JSON line carries the process ID, so shards sharing one output can be told
  apart. A target too long for the line is cut and the line says
  `truncated`. Every JSON line is a complete object.

### Application log

`request.log` and `AppLog` write to the same stderr, at the same levels:

```
[info]  pid=8961 order placed order=42 cents=1250 method=POST path=/orders request_id=5f0c…
```

```json
{"level":"info","pid":8961,"msg":"order placed","method":"POST","path":"/orders","request_id":"5f0c…","order":"42","cents":1250}
```

- A request's lines carry `method` and `path`, `request_id` with
  `--request-id`, and `trace_id` and `parent_id` with `--trace-context`.
- In text, a value with a space, quote, `=` or control character is quoted,
  and newlines are escaped in both formats.
- A line is one write of at most 4096 bytes, so shards sharing a pipe do not
  interleave. A longer one is cut and ends `truncated=true`, or
  `"truncated":true` in JSON.
- The server's own messages (`garuda info: serving http on …`, a handler that
  threw) stay text.

### Health check

`--health-check-path /healthz` answers `GET` and `HEAD` for exactly that path
with `200` and an empty body, before rate limiting, static files and routes.
The path must start with `/`. From the moment a shard is told to stop -- and
for the whole of a `--drain-delay` -- it answers `503`.

### Metrics

`--metrics-port 9100` serves the Prometheus text format at `/metrics` on its
own port, by a server of its own that never reaches the application's routes.
A scrape is answered by whichever shard accepts it, and reports the sum over
all shards.

| metric | type |
|---|---|
| `garuda_requests_total{status="1xx".."5xx"}` | counter |
| `garuda_request_duration_seconds` | histogram, 0.5 ms to 10 s |
| `garuda_connections_accepted_total`, `garuda_connections_closed_total` | counters |
| `garuda_connections_active` | gauge |
| `garuda_buffer_pool_hits_total`, `garuda_buffer_pool_misses_total` | counters |
| `garuda_requests_rate_limited_total` | counter |
| `garuda_cache_hits_total`, `_misses_total`, `_stores_total` | counters, with `--cache-size` |
| `garuda_workers` | gauge: worker threads sharing the counters |

Garuda 2 has no per-route metrics.

`--metrics-host` defaults to `--host`, so a server on `0.0.0.0` publishes its
metrics there too. Bind it privately:

```bash
garuda --host 0.0.0.0 --port 8443 --metrics-port 9100 --metrics-host 127.0.0.1
```

Without `--metrics-port`, nothing is counted.

---

## Signals

| signal | effect |
|---|---|
| `SIGTERM` | fail the health check for `--drain-delay`, then stop accepting and drain within `--graceful-timeout` |
| `SIGINT`, `SIGQUIT` | drain at once; one during a `--drain-delay` cuts it short |
| `SIGHUP` | with shards: restart them one at a time |

When a shard drains it stops accepting, sends WebSockets a 1001 close and
HTTP/2 connections a GOAWAY, and gives what is in progress
`--graceful-timeout` milliseconds. The supervisor kills any shard still running
after `--drain-delay` + `--graceful-timeout` + 5 seconds.
[DEPLOYMENT.md](DEPLOYMENT.md) covers signals, draining behind a load
balancer, and reloads. On Windows no signal is handled.

| flag | default | what it does |
|---|---|---|
| `--reload` | off | development: restart on a rebuilt executable; replace the shards when a certificate file changes |
| `--reload-interval MS` | `500` | how often `--reload` rescans; minimum 50 |

`--reload` is for development. Do not use it in production.

---

## A production starting point

```bash
garuda \
    --host 0.0.0.0 --port 443 \
    --tls-cert /etc/ssl/app/fullchain.pem --tls-key /etc/ssl/app/privkey.pem \
    --tls-reload 3600 \
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

`Application.run(config:)` takes a `ServerConfig`:

```swift
var config = ServerConfig()
config.host = "0.0.0.0"
config.port = 8443
config.tlsCertificates = [TLSCertificateFiles(chain: "/etc/ssl/app/fullchain.pem",
                                              key: "/etc/ssl/app/privkey.pem")]
config.http3Enabled = true
config.drainDelay = .seconds(10)
_ = "10.0.0.0/8".withCString { config.trust.parse($0) }
app.run(config: config)
```

`run(config:)` checks the routes and loads the certificates, as `run()` does,
but not the combinations the command line refuses (`--http3` with no
certificate, `--redirect-http` on the TLS port, and so on). Durations are
`Duration` values.

`app.run(arguments:)` parses a command line of its own. It is an `argv`: the
first element is the program name and is skipped.

Most fields share the flag's name. These do not:

| flag | `ServerConfig` field |
|---|---|
| `--shards` | `shards` (`nil` for `auto`) |
| `--balance` | `balance`: `.reusePort`, `.shared`, or `nil` for `auto` |
| `--no-pin` | `pinThreads = false` |
| `--heavy-threshold` | `heavyThreshold`, a `Duration` |
| `--no-heavy-lane` | `heavyLane = false` |
| `--unix` | `unixPath` |
| `--max-body` | `maxBodySize` |
| `--max-header-size` | `maxHeadSize` |
| `--keep-alive` | `keepAliveTimeout` |
| `--request-timeout` | `requestHeadTimeout` |
| `--sse-keep-alive` | `eventKeepAlive` |
| `--graceful-timeout` | `gracefulShutdown` |
| `--drain-delay` | `drainDelay` |
| `--broadcast-size` | `broadcastSizeMiB` |
| `--tls-cert`, `--tls-key` | `tlsCertificates`, an array of `TLSCertificateFiles(chain:key:)` |
| `--tls-reload` | `tlsReloadInterval` |
| `--redirect-http` | `redirectHTTPPort` |
| `--hsts` | `hstsMaxAge`, in seconds |
| `--no-http2` | `http2Enabled = false` |
| `--http2-only` | `http2Only` |
| `--http3` | `http3Enabled` |
| `--no-websockets` | `websocketsEnabled = false` |
| `--websocket-protocols` | `websocketProtocols`, such as `[.http1, .http2]` |
| `--ws-max-message` | `maxWebsocketMessageSize` |
| `--ws-ping-interval`, `--ws-ping-timeout` | `websocketPingInterval`, `websocketPingTimeout` |
| `--ws-max-queue`, `--ws-max-queue-bytes` | `maxWebsocketQueue`, `maxWebsocketQueueBytes` |
| `--ws-compress` | `websocketCompress` |
| `--static-dir` | `staticDirectories`, `(prefix, directory)` pairs |
| `--spa-fallback` | `spaFallbacks`, `(prefix, directory, file)` triples |
| `--compress-min-size` | `compressMinimumLength` |
| `--cache-size` | `cacheSizeMiB` |
| `--cache-max-object` | `cacheMaxObject`, in bytes |
| `--cache-ttl-max` | `cacheTTLMaxSeconds` |
| `--rate-limit` | `rateLimitCount` and `rateLimitPeriodMs` |
| `--rate-limit-burst` | `rateLimitBurst` (0 means the count) |
| `--forwarded-allow-ips` | `trust`, filled with `trust.parse(_:)` |
| `--access-log-format json` | `accessLog = true` and `accessLogJSON = true` |
| `--log-format json` | `logJSON = true`; the command line also sets `accessLogJSON` unless `--access-log-format` is given |

---

Next: [INSTALLATION.md](INSTALLATION.md) covers building and certificates,
[DEPLOYMENT.md](DEPLOYMENT.md) running in production,
[TRANSPORT.md](TRANSPORT.md) each protocol, and
[ARCHITECTURE.md](ARCHITECTURE.md) how the server is built.

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
- **Work on a timer** belongs to the application too:
  `app.every(.hours(1)) { shard in … }` runs in each shard between start-up and
  shutdown, and `onShard: 0` runs it in one shard only.
- **Where to call it:** before the application is built, so nothing is served
  until the environment checks out.
