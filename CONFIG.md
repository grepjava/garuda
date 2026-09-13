<p align="center">
  <img src="assets/peregrine-cursive-segoe.png" alt="peregrine" width="480">
</p>

# Configuring FastAPI and Flask

The governing rule is that **the protocol is a server flag, not an application
change.** A view is the same view whether HTTP/1.1, HTTP/2 or HTTP/3 carried
the request to it. Nothing about the request changes except the version it
reports, so there is nothing for the framework to do differently and nothing
to configure.

There are exactly two exceptions, and they are exceptions for the same reason:
a **WebSocket** and a **WebTransport session** are not requests. They outlive a
response. FastAPI is ASGI, and its router (Starlette's) admits `http`,
`websocket` and `lifespan` scopes and nothing else, so a WebTransport session
has to be answered in front of it. Flask is WSGI, and PEP 3333 has no way to
express either one, so both are refused with a 501.

| | FastAPI (ASGI) | Flask (WSGI) | Server flags |
|---|---|---|---|
| **HTTP/1.1** | nothing to do | nothing to do | *(default)* |
| **HTTP/2**, cleartext | nothing to do | nothing to do | *(default; prior knowledge)* |
| **HTTP/2**, TLS | nothing to do | nothing to do | `--tls-cert --tls-key` |
| **HTTP/3 / QUIC** | nothing to do | nothing to do | `--http3 --tls-cert --tls-key` |
| **WebSocket** | native `@app.websocket` | 501 | *(default)* |
| **WebTransport** | `contrib.fastapi.WebTransportRouter` | 501 | `--http3 …` |

Working code is in [examples/fastapi_app.py](examples/fastapi_app.py) and
[examples/flask_app.py](examples/flask_app.py).
[scripts/framework-test.sh](scripts/framework-test.sh) runs both over HTTP/1.1
and HTTP/2, [scripts/webtransport-test.py](scripts/webtransport-test.py) runs
FastAPI over HTTP/3 and WebTransport, and
[scripts/http3-test.py](scripts/http3-test.py) runs WSGI over HTTP/3, inline and
on a thread pool.

---

## FastAPI and Starlette

### One command, everything on

```bash
peregrine --port 8443 --workers 0 \
          --tls-cert cert.pem --tls-key key.pem --http3 \
          myapp:app
```

That serves HTTP/1.1 and HTTP/2 over TCP (chosen by ALPN), HTTP/3 over UDP on
the same port number, WebSockets, and — once a router is in front — WebTransport
sessions. `--workers 0` is one worker per CPU.

### The application object

FastAPI needs no adapter. Serve `app` directly, and only wrap it when you want
WebTransport:

```python
from fastapi import FastAPI
from peregrine.contrib.fastapi import WebTransportRouter

app = FastAPI(lifespan=lifespan)      # ordinary FastAPI, all HTTP versions

wt = WebTransportRouter(app)          # serve *this* when you want sessions too
```

`WebTransportRouter` is an ASGI application that answers `webtransport` scopes
itself and passes everything else — HTTP, WebSocket, lifespan — through to
`app` untouched. Wrapping costs one `dict.get` per request.

* **Lifespan** works, including teardown on `SIGTERM`
  ([lifespan](examples/fastapi_app.py#L14), and the shutdown check in
  `framework-test.sh`). `--no-lifespan` skips the protocol for applications
  that do not implement it; peregrine detects those anyway.
* **`StreamingResponse`** streams with real backpressure — the application is
  not run further ahead than the socket has drained
  ([/stream](examples/fastapi_app.py#L47)).
* **Synchronous endpoints** run in the `anyio` thread pool FastAPI manages;
  nothing here interferes with it.
* **uvloop** is used automatically when importable. `--no-uvloop` opts out.

### Knowing what carried the request

```python
from peregrine.contrib.fastapi import http_version, is_http3, supports_webtransport

@app.get("/proto")
def proto(request: Request):
    return {"http_version": http_version(request),      # "1.1", "2" or "3"
            "webtransport": supports_webtransport(request)}  # True on HTTP/3
```

[examples/fastapi_app.py:72](examples/fastapi_app.py#L72). This is for feature
detection and logging — routing on it is almost always a mistake.

### WebSocket

Native, and nothing to configure on the framework side
([/ws](examples/fastapi_app.py#L61)):

```python
@app.websocket("/ws")
async def ws(socket: WebSocket):
    await socket.accept()
    while True:
        await socket.send_text("echo:" + await socket.receive_text())
```

Server-side limits, all with usable defaults: `--ws-max-message` (16 MiB),
`--ws-ping-interval` / `--ws-ping-timeout` (20 s each, for detecting a peer
that has gone away silently), `--ws-max-queue` and `--ws-max-queue-bytes` for
how much a slow application may buffer. `--no-websockets` refuses upgrades
with 501.

`--ws-compress` negotiates permessage-deflate (RFC 7692) with any client that
offers it, which every browser does. Messages are compressed and decompressed
in the server, and the application still sends and receives plain `str` and
`bytes`. Chat, tickers and dashboards send many small messages that look alike,
and they compress well because the compression context carries from one
message to the next.

- **What it costs:** memory for each connection that actually uses it. The
  server compresses with a 4 KiB window and a small zlib memory level, about
  40 KiB per connection. It also asks the browser to use a 4 KiB window for the
  messages it sends. Nothing is allocated until the first compressed message.
  Messages under 64 bytes are sent as they are.
- **What it refuses:** a message is decompressed only up to `--ws-max-message`.
  A few kilobytes that would inflate past it close the connection with 1009,
  and data that is not deflate at all closes it with 1007. A client may still
  send uncompressed messages, and those work as before.
- **What to watch for:** as with `--compress` for HTTP, compressing over TLS a
  message that mixes a secret with text the other side controls lets an
  attacker who can watch message sizes learn the secret. It is off by default
  for that reason, and because it costs CPU.

WebSocket runs over HTTP/1.1 here. It is not carried over HTTP/2 or HTTP/3 —
see [what is not](README.md#what-is-not).

### WebTransport

Two forms. The function, for a session you drive yourself
([/wt/echo](examples/fastapi_app.py#L94)):

```python
@wt.route("/wt/echo")
async def echo(session):
    await session.accept()
    async for stream in session.incoming_streams():
        await stream.send(b"echo:" + await stream.read(), end=True)
```

and the class, mirroring Starlette's `WebSocketEndpoint`
([WTChat](examples/fastapi_app.py#L125)), which dispatches streams and
datagrams concurrently so neither waits on the other:

```python
class Chat(WebTransportEndpoint):
    async def on_connect(self):     await self.session.accept()
    async def on_stream(self, s):
        body = await s.read()
        if s.bidirectional:
            await s.send(b"chat:" + body, end=True)
        else:
            reply = await self.session.create_stream(bidirectional=False)
            await reply.send(b"chat:" + body, end=True)
    async def on_datagram(self, d): await self.session.send_datagram(b"chat:" + d)

wt.add_route("/wt/chat", Chat)
```

`{name}` in a path is a single-segment parameter, in Starlette's spelling;
`{name:int}`, `{name:uuid}`, `{name:path}` and `{name:slug}` convert the same
way Starlette's HTTP router does. They arrive as `session.path_params["name"]`
([/wt/room/{name}](examples/fastapi_app.py#L106),
[/wt/n/{count:int}](examples/fastapi_app.py#L116)). A missing or extra trailing
slash is tried the other way — a session cannot be HTTP-redirected. Closing
without accepting refuses the session with an HTTP status
([/wt/reject](examples/fastapi_app.py#L143)); an unrouted path gets a 404.

---

## Flask

### Serving it

```bash
peregrine --port 8000 --workers 0 myapp:app
```

A Flask `app` is a WSGI application and is detected as one: no adapter, no
`--protocol`, and no change to the application. The same command with
`--tls-cert`, `--tls-key` and `--http3` serves it over HTTP/2 and HTTP/3 as
well.

`app.run()` starts Werkzeug's development server, not this one. Keep it under
`if __name__ == "__main__":`, point peregrine at `app`, and use `--reload` for
the edit-and-refresh loop it was giving you.

### Inline or on a thread pool

By default a worker calls the view itself, and concurrency comes from
`--workers`. That is the fastest arrangement for views that are busy on the
CPU, and it is what the benchmarks measure.

Views that wait — on a database, on another service — want a pool:

```bash
peregrine --port 8000 --workers 4 --wsgi-threads 8 myapp:app
```

`--wsgi-threads` is what lets eight views that are waiting on a database
overlap instead of queueing ([the pool](ARCHITECTURE.md#the-wsgi-thread-pool)). It
does not help views that are busy on the CPU; `--workers` does. Flask's request
context is local to the thread, so ordinary Flask code needs nothing for this;
module-level state an application mutates does.

It also changes what a streamed response costs. PEP 3333 requires each yielded
block to be transmitted before the next one is asked for, so the inline path
makes one write syscall per block — on a view streaming hundreds of small rows,
that dominates. A pool thread instead hands each block to the loop, which
writes it while the view produces the next one; the spec allows that, and it
costs a mutex rather than a syscall. Measured on a view yielding two hundred
100-byte rows (`/rows` in [examples/flask_app.py](examples/flask_app.py)):
**1,430 req/s inline against 5,123 req/s with `--wsgi-threads 4`**, one
worker and 64 connections. A view that returns a string or a list is unaffected
either way: its response is in hand when the view returns, and it goes out in
one write.

### Knowing what carried the request

```python
@app.get("/proto")
def proto():
    # "HTTP/1.1", "HTTP/2" or "HTTP/3"
    return {"http_version": request.environ["SERVER_PROTOCOL"].partition("/")[2]}
```

The same view answers on every version
([/proto](examples/flask_app.py)). This is for logging and feature detection —
routing on it is almost always a mistake.

### What a WSGI application cannot have

WebSocket and WebTransport are refused with a 501. Both are streams that outlive
a response, and PEP 3333 has no way to hand one to the application. The
WebSocket support in `flask-sock` and Flask-SocketIO depends on a server that
gives the application the raw socket, which this one does not. Real-time
traffic belongs in an ASGI application — FastAPI, above — served next to the
Flask one.

### Settings worth knowing about

* **`request.scheme`, `request.is_secure` and `request.remote_addr`** are right
  over TLS and over HTTP/3 with nothing configured. Behind a terminating proxy,
  use `--forwarded-allow-ips` (below) rather than Werkzeug's `ProxyFix`: the
  server resolves the scheme and `REMOTE_ADDR` before Flask sees them, and only
  for peers you have named. `url_for(..., _external=True)` then builds `https`
  URLs from what the server resolved.
* **The `Host` header** reaches Flask unchanged, so `SERVER_NAME` and
  host-matched routes behave as they do anywhere else.
* **Static files** go through the application unless something is in front.
  `--static-dir /static=/srv/app/static` serves Flask's `static` folder with
  `sendfile(2)` instead, and a path with no file behind it still reaches Flask
  ([Serving assets](#serving-assets)).
* **Streamed responses** — a generator, `stream_with_context` — go out block by
  block as they are yielded, chunked on HTTP/1.1.
* **`DEBUG`** and the interactive debugger are as unsuitable here as anywhere
  else in production.

---

## Proving each protocol

With the example applications running, from a checkout:

```bash
# HTTP/1.1
curl --http1.1 http://127.0.0.1:8000/proto
# {"http_version":"1.1", …}

# HTTP/2, cleartext, prior knowledge. Same application, same view.
curl --http2-prior-knowledge http://127.0.0.1:8000/proto
# {"http_version":"2", …}

# HTTP/2 over TLS: ALPN chooses it, so an ordinary request is enough.
curl -k --http2 https://127.0.0.1:8443/proto

# HTTP/3. Few curl builds have it; `curl -V` lists HTTP3 when yours does.
curl -k --http3 https://127.0.0.1:8443/proto
```

The suites do not rely on curl having HTTP/3, and drive the server with
`aioquic` instead:

```bash
bash scripts/framework-test.sh                  # FastAPI and Flask over
                                                #   HTTP/1.1 and HTTP/2, and
                                                #   Starlette websockets
python3 scripts/contrib_test.py                 # 58 Python-only: routing
<venv>/bin/python scripts/webtransport-test.py  # FastAPI over HTTP/3 and
                                                #   WebTransport
<venv>/bin/python scripts/http3-test.py         # 114, WSGI and ASGI over
                                                #   HTTP/3
```

The HTTP/3 checks there include fetching `/proto` from the FastAPI example over
QUIC and reading `"http_version": "3"` back out of the view — the same view
that answers `1.1` on the line above, with nothing changed in between.

---

## Behind a reverse proxy

```bash
peregrine --forwarded-allow-ips 10.0.0.0/8,127.0.0.1 myapp:app
```

`X-Forwarded-For`, `X-Forwarded-Proto` and `Forwarded` are honoured **only**
from a peer on that list; from anyone else they are ignored rather than
trusted, because a client can send them too. The list takes addresses, CIDR
blocks, `unix`, or `*`. This is what makes `request.client`, `request.scheme`,
`request.is_secure()` and `REMOTE_ADDR` correct behind a proxy, in both
frameworks.

If HTTP/3 lives somewhere the server cannot know about — a terminating proxy in
front, or a different host or port — advertise it yourself:

```python
from peregrine.contrib.asgi import AltSvcMiddleware
app = AltSvcMiddleware(app, port=443)
```

Peregrine already sends `alt-svc` for its own HTTP/3 listener, so this is only
for the case where the answer is not its own port.

---

## A production starting point

```bash
peregrine \
    --host 0.0.0.0 --port 8443 \
    --workers 0 \
    --tls-cert /etc/ssl/app/fullchain.pem \
    --tls-key  /etc/ssl/app/privkey.pem \
    --http3 \
    --forwarded-allow-ips 10.0.0.0/8 \
    --static-dir /static=/srv/app/static \
    --health-check-path /healthz \
    --max-body 8388608 \
    --drain-delay 10000 \
    --graceful-timeout 30000 \
    --access-log --log-level warning \
    myapp:app
```

Add `--wsgi-threads 8` for a WSGI application that waits on I/O. Leave
`--reload` for development only — it polls the source tree.

`SIGHUP` reloads the certificate without dropping a connection, so this wants a
certbot deploy hook rather than a restart; see
[Reloading without a restart](#reloading-without-a-restart).

### The access log

`--access-log` gives one line per request:

```
GET /orders/17?expand=items 200 431us
```

`--access-log-format json` gives the same information as one JSON object per
line, which is what to use when something is collecting these rather than
someone reading them. It implies `--access-log`:

```json
{"level":"info","pid":8961,"method":"GET","target":"/orders/17","status":200,"duration_us":431,"proto":"HTTP/1.1"}
```

The whole line is the object — there is no `[info] pid=…` in front of it to
strip — so a collector can parse it without being told where the JSON starts.

`duration_us` is measured from the request being dispatched to the response
head being settled and queued, not to the last byte of the body: for a
streaming response that last byte is the client's pace rather than the
application's, and a number that mixes the two says nothing about either.

A request target is whatever bytes the peer sent. `"` and `\` are escaped, and
a target that is not valid UTF-8 has its bytes escaped as `\u00XX` rather than
being dropped or truncated — so the line is always parseable and the target is
always recoverable, byte for byte.

That is true up to the length of the line, which is assembled in a fixed
buffer. Rather than let a very long target run off the end — leaving a string
unterminated, an object unclosed, and no newline to separate it from whatever
is logged next — the target is cut short and the object carries
`"truncated":true` alongside the fields that follow it. The cut lands on a
character boundary rather than in the middle of one, so the line is still
valid UTF-8 and a parser reading the raw bytes will take it. Every line is a
complete object, whatever the peer asked for.

`--access-log` costs a clock read per request; without it there is none.

### Request IDs

```bash
peregrine --request-id --access-log myapp:app
```

`--request-id` gives every request an `X-Request-ID`, and puts that one value
in three places:

- **The application** sees it as a request header: `X-Request-ID` in the ASGI
  scope's headers, `HTTP_X_REQUEST_ID` in the WSGI environ. Log it, or pass it
  on to the services the request calls.
- **The response** carries it, so a client or a support ticket can quote it
  back. An application that sets its own `X-Request-ID` response header keeps
  its value.
- **The access log** records it: ` id=...` at the end of a text line, and
  `"request_id"` in a JSON one.

```
GET /cart 200 1843us id=0b6f1c9e-3c1d-4f7a-9a52-6d2e8f41c7b0
```

A new ID is a random version 4 UUID. When a proxy listed in
`--forwarded-allow-ips` sends its own `X-Request-ID`, that ID is kept, because
the proxy saw the request first and may already have logged it. The value must
be 1 to 128 characters of letters, digits and `-_.:+/=@~`. Any other
`X-Request-ID`, including one a client sends directly, is replaced before the
application sees it. A value that anyone can set is not an identifier anyone
else can rely on.

The server answers a few requests itself, without the application, and logs
their IDs as well. Static files also carry the ID in a response header. Health
probes, rate-limit refusals and malformed requests do not, and the
`--redirect-http` port assigns no IDs.

### Metrics

`--metrics-port 9100` serves the Prometheus text exposition format:

```
peregrine_requests_total{status="2xx"} 10241
peregrine_connections_accepted_total 812
peregrine_connections_active 37
peregrine_connection_slots 8192
peregrine_buffer_pool_hits_total 774
peregrine_buffer_pool_misses_total 38
peregrine_workers 4
peregrine_request_duration_seconds_bucket{le="0.001000"} 9987
peregrine_request_duration_seconds_sum 4.271038
peregrine_request_duration_seconds_count 10241
```

A port of its own, not a route. The application owns every path on the service
port, and monitoring that can be reached through the application — or an
application that can be reached through monitoring — is a configuration
accident waiting for a bad day. Nothing on the metrics port goes anywhere near
the request path; it is accepted, answered and closed on the loop thread.

**One scrape answers for every worker.** Workers are separate processes under
`--workers` and threads under `--free-threaded`; in both cases the counters
live in a page mapped before anything forked, each worker writing only its own
slot. A scrape lands on whichever worker `SO_REUSEPORT` gives it and reports
the sum, so the numbers do not jump about between scrapes. `peregrine_workers`
says how many are being summed.

**Bind it somewhere private.** `--metrics-host` defaults to `--host`, so a
server on `0.0.0.0` publishes its metrics there too. They contain no request
data — counts, durations and connection totals — but they are still nobody
else's business:

```bash
peregrine --host 0.0.0.0 --port 8443 \
          --metrics-port 9100 --metrics-host 127.0.0.1 \
          myapp:app
```

`peregrine_buffer_pool_hits_total` against `_misses_total` is worth watching:
misses that keep climbing mean connections are outliving the pool's free list,
or that `--read-buffer` is smaller than what requests actually need.

Counting costs one load, one add and one store per event, on a cache line no
other worker touches. With no `--metrics-port` there is no page and the
counters do nothing at all.


### Queue time

```bash
peregrine --request-start-header myapp:app
```

A tracer inside the application measures from the moment the application is
called. What happened before that — the worker finishing the request ahead of
this one, a WSGI thread pool with every thread taken, the event loop behind on
its callbacks — is invisible to it, and it is usually the first thing to grow
when a server is short of capacity.

`--request-start-header` hands the application `X-Request-Start:
t=<microseconds since the epoch>` for when the request arrived, which is what
New Relic, Datadog and Scout read to report queue time. On a plaintext
connection the time is the kernel's receive timestamp, so a request that sat in
the accept queue behind a busy worker is stamped when it arrived, not when it
was read. Over TLS it is when the decrypted request reached the worker, and on
HTTP/2 and HTTP/3 when the stream opened.

A proxy that already sends the header is left alone: it saw the request first.

---

## Reloading without a restart

`SIGHUP` replaces every worker without dropping a connection. The TLS context
is built per worker, so the replacements read the certificate and key off disk
again — which makes this the certbot hook:

```bash
certbot renew --deploy-hook 'kill -HUP $(cat /run/peregrine.pid)'
```

Workers are replaced one at a time, and each replacement is spawned, given the
listening socket its predecessor had, and allowed to report that it is
accepting *before* the worker it replaces is asked to stop. Both serve the same
socket in the meantime. Nothing is refused, nothing is reset, and the worst
case a client sees is the ordinary latency of the request it was making.

The listening sockets belong to the supervisor rather than to the workers,
which is what makes that possible. A worker that opened its own socket would
take the socket's accept queue with it when it exited, along with every
connection still completing its handshake on it — the kernel picks which socket
in an `SO_REUSEPORT` group a connection belongs to when the SYN arrives, not
when `accept` is called, so no amount of draining on the worker side rescues
them.

`--reload` uses the same mechanism when it sees a source file change, so a save
during development costs no more than a certificate renewal does in production.

A reload restarts workers; it does not re-read the command line. Changing a
flag still means restarting the server.

---

## Serving assets

`--static-dir` answers a URL prefix from a directory, without the application
being called:

```bash
peregrine --static-dir /static=/srv/app/static \
          --static-dir /media=/srv/app/media \
          myapp:app
```

On a plaintext HTTP/1.1 connection the bytes never enter the process: the file
descriptor goes to `sendfile(2)` and the kernel moves them from the page cache
to the socket. Over TLS, and on an HTTP/2 or HTTP/3 stream, they are read and
framed like any other response — the bytes have to be encrypted or multiplexed,
and the kernel cannot do either — which is still an interpreter, a `dict` of CGI
variables and a list of byte strings per asset less than serving them from
Python.

**A path with no file behind it reaches the application.** So does a `POST`, a
path that is a prefix of the route rather than under it, and a directory. A
route that answered 404 for everything under its prefix would take those URLs
away from an application that already serves them; this is meant to go in front
of Flask's own `static` route or FastAPI's `StaticFiles` mount, not to compete
with them for URLs.

`..`, `%2e%2e` and a symlink pointing out of the tree are all refused by where
the path lands rather than by how it is spelled: both the root and the result
are resolved with `realpath(3)` and the result has to still be inside. Only
regular files are opened — not a directory, not a fifo, not a device.

An `ETag` is built from the file's size and modification time, and
`If-None-Match` is answered with `304`. There is no `Last-Modified`: a date has
one-second resolution and says nothing about a file that changed twice within a
second, and emitting only the strong validator means a client can only ask the
question that can be answered exactly. There are no byte ranges and no
directory indexes — this is an asset route, not a file server. Put a CDN in
front of it for anything that needs either.

---

## Compression

Two flags, because they carry different risks.

```bash
peregrine --compress --compress-static \
          --static-dir /static=/srv/app/static \
          myapp:app
```

`--compress-static` serves a copy compressed at build time — `app.js.br`,
`app.js.zst` or `app.js.gz` beside `app.js` — to a client that accepts it. The
bytes still go out with `sendfile(2)` on a plaintext connection, the copy gets
its own `ETag`, and a file with no copy is served as it is. The compressing is
done once, at whatever level the build can afford:

```bash
find static -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' \) \
    -exec brotli -kq 11 {} \; -exec gzip -k9 {} \;
```

`--compress` compresses what the application sends, as it sends it: brotli,
zstd or gzip, whichever the client rates highest, brotli first on a tie. Only
text-like responses are touched — `text/*` apart from `text/event-stream`,
JSON, JavaScript, XML, SVG, WebAssembly. Nothing is compressed that already has
a `Content-Encoding`, says `Cache-Control: no-transform`, is a `206`, answers
a `HEAD`, or declares a `Content-Length` below `--compress-min-size` (1024 by
default). A response that could have been compressed says
`Vary: Accept-Encoding` whether it was or not, so that a cache in front does
not hand one client's copy to the next.

A compressed response has no `Content-Length`; it is chunked on HTTP/1.1 and
ended by the stream on HTTP/2 and HTTP/3. The length the application declared
is still held against what it sends. Each body message is flushed through the
compressor as it arrives, so a response streamed in pieces reaches the client
in pieces.

gzip is always available. brotli and zstd are used when `libbrotlienc` and
`libzstd` are installed, and silently left out when they are not.

**Read this before turning `--compress` on.** Compression over TLS leaks
through length. A page that puts a secret — a CSRF token, a session-bound
value — in the same response as text an attacker can choose, such as a search
term echoed back, lets an attacker who can watch the size of the traffic recover
the secret a byte at a time (BREACH). Whether an application has pages like
that is its own knowledge, which is why this is off by default and not
something the server can decide. The usual answers are to keep secrets out of
responses that reflect input, to mask tokens so they differ in every response,
or to leave `--compress` off and use only `--compress-static`, which reflects
nothing.

---

## Rate limiting

```bash
peregrine --rate-limit 100/s --rate-limit-burst 200 myapp:app
```

A client past its allowance gets `429 Too Many Requests` with a `Retry-After`
in whole seconds, before the application is called. The rate is `N/s`, `N/m`
or `N/h`; the burst is how many requests may arrive at once before the rate
applies, and defaults to `N`.

The count is the server's, not each worker's. With `--workers 8` a client's
connections are spread over eight accept queues by the kernel, and a limit kept
per worker would let it through up to eight times over, unevenly. The state
lives in a table mapped before the workers start, and every worker charges the
same entry for the same client with a compare-and-swap, so two workers
admitting the same client at the same moment cannot both spend its last
request.

Who counts as a client:

- **Behind a proxy on `--forwarded-allow-ips`**, the address the proxy
  reports. Keying by the peer there would put every user in one bucket.
- **Otherwise the peer address**, and `X-Forwarded-For` is ignored — believing
  it would give any client a fresh allowance per request.
- **IPv6 by `/64`**, which is what one subscriber is normally given. Keyed by
  the full address, each of them would have 2⁶⁴ allowances.
- **Unix socket peers** are not limited unless a trusted proxy names the
  client.

The health probe on `--health-check-path` is never refused, and refusals are
counted in `peregrine_requests_rate_limited_total` on the metrics port.

The table holds 65,536 clients. An entry whose client has gone quiet long
enough to have its whole burst back is reused, so the limit covers the clients
active *now*, not everyone ever seen. If a new client finds no entry to take,
its request is allowed: a limiter that refuses traffic because its own table is
full is a denial of service against everyone.

This is a guard against a single client overwhelming the server, not a quota
system. There is no per-route limit and no key other than the address; an
application that needs either wants a limiter that knows its users.

---

## Health checks

`--health-check-path /healthz` answers that path in the server, with `200` and
an empty body, before anything reaches Python:

```yaml
livenessProbe:
  httpGet: { path: /healthz, port: 8000 }
```

A liveness probe that runs through the application measures the application.
That sounds like the point and is close to the opposite of it: the probe goes
unanswered exactly when every worker is busy, and an orchestrator reads an
unanswered liveness probe as a process to kill — so the busiest moment is the
one where it shoots the server. This answers from the accept loop, which is
what liveness actually is.

Readiness is a different question and still the application's: whether the
database is reachable, whether migrations have run. Give that one a route of
its own.

The match is exact once the query string is split off, and only `GET` and
`HEAD` are answered, so a `POST` to the same path is still the application's.
It is off unless asked for — the server has no business assuming `/healthz` is
free.

### Shutting down behind a load balancer

```bash
peregrine --health-check-path /healthz --drain-delay 10000 --graceful-timeout 30000 myapp:app
```

```yaml
readinessProbe:
  httpGet: { path: /healthz, port: 8000 }
  periodSeconds: 2
terminationGracePeriodSeconds: 45
```

Kubernetes sends `SIGTERM` and removes the pod from its Service at the same
moment, and the removal takes a few seconds to reach every node and every
ingress. Anything that stops accepting connections as soon as `SIGTERM`
arrives spends those seconds refusing traffic that was still routed to it.

`--drain-delay` fills that gap. When `SIGTERM` arrives, the server keeps
serving for that many milliseconds, but the health check answers `503`. HTTP/1.1
responses also say `Connection: close`, so clients that hold a connection open
reconnect somewhere else. Only after the delay does it stop accepting and start
the usual drain under `--graceful-timeout`. Set the delay a little longer than
your readiness probe takes to notice: its period multiplied by its failure
threshold. Set `terminationGracePeriodSeconds` to cover the delay plus the
graceful timeout.

The delay is only for `SIGTERM`:
- `SIGINT` (Ctrl-C) and `SIGQUIT` drain at once. `SIGQUIT` also cuts short a
  delay that is already running.
- A `SIGHUP` reload never waits, because each replacement worker is serving
  before the worker it replaces is retired.
- Each worker keeps the delay itself, so an init system that signals the whole
  process group, as systemd does by default, gets the same behaviour as one
  that signals only the supervisor.

---

## More than one certificate

`--tls-cert` and `--tls-key` are repeatable and paired in the order given. The
first pair is the default; the rest are chosen per connection by SNI:

```bash
peregrine --port 443 \
    --tls-cert /etc/ssl/shop/fullchain.pem   --tls-key /etc/ssl/shop/privkey.pem \
    --tls-cert /etc/ssl/admin/fullchain.pem  --tls-key /etc/ssl/admin/privkey.pem \
    myapp:app
```

Which names each certificate covers is read out of the certificate — its
subject alternative names, or its common name if it has none — rather than
declared alongside it. The certificate already carries that list, and a second
copy of it on a command line is a second copy to get wrong, in the direction
where the mistake surfaces as a browser warning rather than as an error at
start-up. Start-up logs what each certificate is good for when there is more
than one.

Matching follows RFC 6125: case-insensitive, and a wildcard covers exactly one
label, so `*.example.com` matches `a.example.com` but neither
`a.b.example.com` nor `example.com`.

A name no certificate claims, and a client that sends no SNI at all, get the
default certificate rather than a refused connection. That is the kinder
failure: a name mismatch is something a browser can explain to the person
reading it, where a dropped handshake is not.

`SIGHUP` reloads all of them.

### Certificates from Let's Encrypt

```bash
peregrine --port 443 --acme-domain example.com --acme-domain www.example.com \
          --acme-email ops@example.com --acme-cache /var/lib/peregrine/acme \
          myapp:app
```

The server gets its own certificate. With nothing cached it starts on a
self-signed placeholder, registers an account, answers the CA's `tls-alpn-01`
challenge on the port it is already serving, installs the certificate in the
cache directory, and reloads its workers onto it the way `SIGHUP` does — no
connection is dropped. It checks twice a day and renews with thirty days left.
A restart finds the certificate in the cache and does not ask again.

`tls-alpn-01` rather than `http-01`, because it needs nothing but the port
being served: no port 80, no web root, no route kept free for the CA. The CA
connects offering only the `acme-tls/1` protocol; whichever worker accepts the
connection serves the challenge certificate and closes it.

The client runs in a helper process the supervisor forks, not in a worker. A CA
that is slow or down costs one waiting process and nothing that serves
requests. A failed attempt is retried after a minute, then two, doubling up to
six hours, which stays well inside Let's Encrypt's rate limits.

- `--acme-staging` uses Let's Encrypt's staging CA, which issues untrusted
  certificates without production rate limits. Try a new setup there first.
- `--acme-directory URL` uses another ACME CA, and `--acme-ca-bundle PATH`
  trusts a private one's HTTPS.
- The cache holds `account.key`, `cert.pem` and `key.pem`, keys at mode 0600.
  Keep it on persistent storage: a server that loses it registers a new account
  and asks for a new certificate, which counts against the rate limits.

A public CA validates on port 443, so the server has to be reachable there,
directly or through a TCP forward. A proxy that terminates TLS in front of it
sees the challenge instead of passing it on, and needs to do ACME itself.

Wildcards are not possible here: a wildcard certificate needs `dns-01`, which
needs credentials for a DNS provider. HTTP/3 serves the certificate from the
same files and picks it up on the same reload.

HTTP/3 serves the default pair whatever the client asks for. The QUIC handshake
here is built from the primitives rather than driven by OpenSSL, and it has no
SNI selection of its own yet.

---

## Redirecting HTTP to HTTPS

```bash
peregrine --port 443 --acme-domain example.com \
    --redirect-http 80 --hsts 31536000 myapp:app
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
  keeps the method and the body; a `301` would let the client repeat a `POST`
  as a `GET`.
- **Location.** The host comes from `Host`, or from the request target when a
  client sends an absolute URL. Its port is replaced with the TLS port, which
  is left out when it is 443.
- **Refusals.** A request with no `Host`, or with a `Host` that is not a host
  name or address, gets `400`. The redirect target comes from the client, so
  it is checked before it goes into a header.
- **Nothing else.** The application never sees these requests, and every
  response closes the connection.

Certificates from `--acme-domain` do not need port 80: they are validated on
the TLS port with tls-alpn-01. Behind a proxy that terminates TLS, redirect at
the proxy instead. Ports below 1024 need the same privilege as port 443, root
or `CAP_NET_BIND_SERVICE`.

### Strict-Transport-Security

`--hsts SECONDS` adds `Strict-Transport-Security: max-age=SECONDS` to every
TLS response: application responses and static files, over HTTP/1.1, HTTP/2
and HTTP/3. A browser that has seen it goes straight to https for that long,
so its first request no longer travels as plain HTTP where it could be
intercepted before the redirect. The header is never sent over plain HTTP,
because browsers ignore it there.

An application that sets the header itself keeps its own value, and the server
adds no second one. `includeSubDomains` and `preload` are not added. They
commit other host names to https, which is for whoever owns those names to
decide; an application that wants them sets the header itself.

Start with a short `max-age`, such as `300`. A browser that has seen a long one
refuses plain HTTP to the site until it expires, even after the certificate is
gone.

---

## Application logging

Peregrine writes its own lines with a level and a pid. Python's `logging`
writes whatever it was last configured with. On one file descriptor that is two
log formats interleaved, and neither half can be filtered by level without
filtering both.

```python
from peregrine.logging import configure

configure()
```

after which `logging.getLogger("shop").info("checkout complete")` comes out as

```
[info]  pid=29404 shop: checkout complete
```

next to the server's own lines, behind the server's own `--log-level`. Taking
the level from the server rather than from a second setting is the point:
`--log-level warning` quiets the application to match, with nothing to keep in
step.

`configure()` replaces the handlers already on the logger, because the case it
is for is an application where something has already called `basicConfig` — a
library, a settings module, the application's own start-up — and adding to
those would duplicate every line. Pass `replace=False` to sit alongside them
instead.

In a Flask application, call `configure()` before anything first uses
`app.logger`. Flask gives that logger a handler of its own, writing to stderr,
the first time it is used, unless a handler already sees its records. Configured
first, the server's log is where `app.logger.info(...)` goes. Configured after,
every line from `app.logger` is written twice.

For an application that builds its logging configuration by hand, the handler
is an ordinary one:

```python
LOGGING = {
    "version": 1,
    "handlers": {
        "peregrine": {"class": "peregrine.logging.PeregrineHandler"},
    },
    "root": {"handlers": ["peregrine"], "level": "INFO"},
}
```

Outside a peregrine process — under pytest, or under another server — the
handler falls back to `stderr` and `server_level()` reports `DEBUG`, so a
configuration naming it does not have to be conditional on what is running it.

A record containing newlines, which in practice means a traceback, arrives as
one line with `" | "` where the breaks were. A traceback that stayed multi-line
would read to a line-oriented collector as several records of unknown level.

`sys.stdout` is left alone. Taking over a stream the application may be writing
to itself is a surprise, and `print` is not logging.

---

## Free-threaded Python

On a CPython built without the GIL (PEP 703 — `python3.13t`, `python3.14t`),
`--free-threaded` turns the workers into threads of one process instead of
processes:

```bash
peregrine --workers 0 --free-threaded myapp:app
```

`--workers` still means the same thing; only what a worker *is* changes. Each
one keeps its own poller, its own connection table and its own event loop, so
nothing about request handling is different — they simply share an address
space.

What that buys, measured on a four-core machine with a CPU-bound application:

| | throughput | resident memory |
|---|---|---|
| 1 worker | 1,695 req/s | — |
| 4 workers, processes | 5,832 req/s | 143 MB |
| 4 workers, threads | 5,907 req/s | 47 MB |

The same parallelism for a third of the memory, because the application is
imported once rather than four times. The larger the application, the wider
that gap gets — it is the application and everything it imports, not the
server, that was being copied.

Hello-world `GET /` is the other way around: with four workers, threads reach
81–94 % of what four processes do on FastAPI and 71–82 % on Flask. That table
is in [BENCHMARKS.md](BENCHMARKS.md#processes-or-free-threaded). `--free-threaded` is the
memory and shared-state option, not a request-rate upgrade on an empty view.

Sharing one process also changes three things it is worth knowing about:

- **The ASGI lifespan runs once per worker thread**, on the event loop that
  thread will serve requests with, and each worker gets its own `state` mapping.
  It is tempting to run it once for the process, since there is one application
  — and that is what this used to do. It is wrong: `startup` is where an
  application builds asyncio objects, and an asyncio object belongs to the loop
  that was running when it was created. A pool built on the supervising thread's
  loop and awaited from a worker's loop raises `got Future attached to a
  different loop`, when it fails loudly at all. Each worker shuts its own
  lifespan down on its own loop, after its own requests have drained.

  The consequence to plan for is that `startup` runs N times against one
  application object. The startups are serialised, so they do not race each
  other, but an application that stores its pool in a module global or on
  `app.state` keeps only the last one and puts every other worker back to
  reaching across loops. Put per-worker resources in the `state` mapping the
  lifespan scope hands you:

  ```python
  async def lifespan(app):
      async with asyncpg.create_pool(DSN) as pool:
          yield {"pool": pool}          # per worker thread, on its own loop

  # in a handler: scope["state"]["pool"], or request.state.pool in Starlette
  ```

  `--lifespan-scope process` restores the single startup for applications whose
  start-up opens nothing loop-bound — reading configuration, building
  synchronous objects, warming a cache. There the lifespan lives on the
  supervising thread's loop, all workers share its `state`, and shutdown waits
  for every worker to be joined first.
- **`wsgi.multithread` is `True` and `wsgi.multiprocess` is `False`**, which is
  the opposite of what `--workers` reports. An application that is not
  thread-safe will notice. This is the same requirement `--wsgi-threads`
  already makes, applied to the whole application rather than to one pool.
- **A crash takes every worker with it.** With processes the supervisor
  restarts the one that died. Keep a process supervisor in front in production —
  systemd, or peregrine's own, by combining `--free-threaded` with `--reload`
  in development.

The option is refused, with an error, on an interpreter that has the GIL:
running it there would silently be slower than `--workers`, not faster.
`peregrine --version` says which kind of interpreter is embedded:

```
peregrine 1.0.0 (CPython 3.14.6 free-threaded)
```

One caveat that is not peregrine's to fix: importing an extension module that
has not declared itself free-threading-safe switches the GIL back on for the
whole process, and so does `PYTHON_GIL=1`. The server checks after loading the
application and warns when that has happened, because the symptom otherwise is
just "it is not any faster".

`SIGTERM` and `SIGINT` drain gracefully within `--graceful-timeout`; `SIGHUP`
restarts the workers without dropping the listening socket, which is how to
pick up new code without dropping a connection.

---

Next: [INSTALLATION.md](INSTALLATION.md) — getting it built and installed.
[TRANSPORT.md](TRANSPORT.md) — what each protocol does and what is implemented
of it. [ARCHITECTURE.md](ARCHITECTURE.md) — how the server is built, and why.
