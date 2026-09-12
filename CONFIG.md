<p align="center">
  <img src="assets/peregrine-cursive-segoe.png" alt="peregrine" width="480">
</p>

# Configuring FastAPI and Django

The governing rule is that **the protocol is a server flag, not an application
change.** A view is the same view whether HTTP/1.1, HTTP/2 or HTTP/3 carried
the request to it; none of them alter the scope beyond `http_version`, so there
is nothing for the framework to do differently and nothing to configure.

There are exactly two exceptions, and they are exceptions for the same reason:
a **WebSocket** and a **WebTransport session** are not requests. They outlive a
response, and every ASGI framework asserts on `scope["type"]` before it looks at
a path — Starlette allows `http`, `websocket` and `lifespan`; Django's handler
allows `http` alone. Anything a framework will not admit to its router has to be
answered in front of it.

| | FastAPI / Starlette | Django | Server flags |
|---|---|---|---|
| **HTTP/1.1** | nothing to do | nothing to do | *(default)* |
| **HTTP/2**, cleartext | nothing to do | nothing to do | *(default; prior knowledge)* |
| **HTTP/2**, TLS | nothing to do | nothing to do | `--tls-cert --tls-key` |
| **HTTP/3 / QUIC** | nothing to do | nothing to do | `--http3 --tls-cert --tls-key` |
| **WebSocket** | native `@app.websocket` | Channels | *(default)* |
| **WebTransport** | `contrib.fastapi.WebTransportRouter` | `contrib.django.WebTransportRouter` | `--http3 …` |

Django over **WSGI** serves the first four and refuses the last two with a 501,
which is PEP 3333's doing rather than a shortcut — see
[the support matrix](README.md#what-is-supported). Everything below the WSGI
section assumes Django on ASGI.

Working code for every row is in [examples/fastapi_app.py](examples/fastapi_app.py)
and [examples/django_app.py](examples/django_app.py), and every row is checked
by [scripts/framework-test.sh](scripts/framework-test.sh) and
[scripts/webtransport-test.py](scripts/webtransport-test.py).

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

## Django

### WSGI or ASGI

Django gives you two entry points and they are not equivalent here:

```python
application = WSGIHandler()                  # HTTP/1.1, HTTP/2, HTTP/3
asgi_application = WebTransportRouter(...)   # …and WebSocket, and WebTransport
```

WSGI is the right answer for an ordinary Django site — it is the path Django is
most heavily used on, it serves every HTTP version, and blocking views overlap
properly on a thread pool:

```bash
peregrine --port 8000 --workers 4 --wsgi-threads 8 myproject.wsgi:application
```

`--wsgi-threads` is what lets eight views that are waiting on a database
overlap instead of queueing ([the pool](ARCHITECTURE.md#the-wsgi-thread-pool)). It
does not help views that are busy on the CPU; `--workers` does.

It also changes what a streaming response costs. PEP 3333 requires each yielded
block to be transmitted before the next one is asked for, so the inline path
makes one write syscall per block — on a `StreamingHttpResponse` yielding
hundreds of small rows, that dominates. A pool thread instead hands each block
to the loop, which writes it while the application produces the next one; the
spec allows that, and it costs a mutex rather than a syscall. Measured on a view
yielding two hundred 100-byte rows: **1,516 req/s inline against 9,632 req/s
with `--wsgi-threads 4`**. Responses that return a list are unaffected either
way — they are written in one call, and hello-world throughput does not move.

Choose ASGI when you want WebSockets or WebTransport, and compose the entry
point like this ([examples/django_app.py:85-128](examples/django_app.py#L85-L128)):

```python
# asgi.py
import os
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "myproject.settings")

from django.core.asgi import get_asgi_application
from channels.routing import ProtocolTypeRouter, URLRouter
from peregrine.contrib.django import WebTransportRouter

from . import consumers

application = WebTransportRouter(ProtocolTypeRouter({
    "http": get_asgi_application(),
    "websocket": URLRouter([path("ws", consumers.Echo.as_asgi())]),
}))
```

Read outward: Django serves `http`, Channels serves `websocket`, and the
peregrine router serves `webtransport` and forwards everything else to the pair
of them. Each layer owns exactly the scope types the one beneath it refuses.

```bash
peregrine --port 8443 --tls-cert cert.pem --tls-key key.pem --http3 \
          --python-path . myproject.asgi:application
```

### WebSocket, through Channels

Django itself has no WebSocket support; Channels is the framework's own answer
and works unmodified ([EchoConsumer](examples/django_app.py#L111)):

```python
class Echo(AsyncWebsocketConsumer):
    async def connect(self):
        await self.accept()

    async def receive(self, text_data=None, bytes_data=None):
        await self.send(text_data="echo:" + text_data)
```

`pip install channels`. A channel layer is only needed if consumers talk to
each other; an echo like this needs none. Nothing about running under peregrine
changes how Channels is configured.

### WebTransport

Routes are written the way `urlpatterns` are, converters included
([examples/django_app.py:131-160](examples/django_app.py#L131-L160)):

```python
@application.route("wt/room/<str:name>/")
async def room(session):
    await session.accept()
    name = session.path_params["name"]              # a str
    ...

@application.route("wt/n/<int:count>/")
async def count(session):
    count = session.path_params["count"]            # an int, converted
```

`<str:>`, `<int:>`, `<slug:>`, `<uuid:>` and `<path:>` are understood, the
leading slash is optional, `<int:>` and `<uuid:>` convert rather than handing
you a string, and a missing trailing slash is still matched.

### Settings worth knowing about

* **`ALLOWED_HOSTS`** applies as usual; peregrine passes the `Host` header
  through unchanged.
* **`request.is_secure()`** is true over TLS and over HTTP/3 with no
  `SECURE_PROXY_SSL_HEADER` needed. Behind a terminating proxy, use
  `--forwarded-allow-ips` (below) rather than the Django setting — the server
  resolves the scheme and `REMOTE_ADDR` before Django sees them, and it will
  only do so for peers you have named.
* **Static files** are not served by the application server. Use a CDN or a
  proxy in front, or `whitenoise` in the middleware stack if you want Django to
  do it.
* **`DEBUG = True`** is as unsuitable here as anywhere else in production, and
  its stack-trace pages are unaffected by any of this.

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

The suites do not rely on curl having HTTP/3, and drive both frameworks with
`aioquic` instead:

```bash
bash scripts/framework-test.sh                  # 30 checks: HTTP/1.1 and
                                                #   HTTP/2 against both,
                                                #   Starlette and Channels
                                                #   websockets
python3 scripts/contrib_test.py                 # 58 Python-only: routing
<venv>/bin/python scripts/webtransport-test.py  # 115 checks, of which 22 drive
                                                #   FastAPI and Django over
                                                #   HTTP/3 and WebTransport
```

The HTTP/3 checks there include fetching `/proto` from each framework over
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
of `whitenoise` or Django's `staticfiles`, not to compete with them for URLs.

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

HTTP/3 serves the default pair whatever the client asks for. The QUIC handshake
here is built from the primitives rather than driven by OpenSSL, and it has no
SNI selection of its own yet.

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
is for is an application whose framework has already called `basicConfig` —
Django does — and adding to those would duplicate every line. Pass
`replace=False` to sit alongside them instead.

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
that gap gets — it is the whole of Django, not the server, that was being
copied.

Hello-world `GET /` is the other way around: four processes still win on
FastAPI, Django, Sanic and BlackSheep, and threads only tie on raw ASGI.
That table is in [BENCHMARKS.md](BENCHMARKS.md). `--free-threaded` is the
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
