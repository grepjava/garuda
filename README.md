<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/peregrine/main/assets/peregrine-fiery-roaring.png" alt="peregrine" width="560">
</p>

<p align="center">
  <b>A drop-in ASGI and WSGI server for Python, written in Swift.</b><br>
  FastAPI at 1.4–1.6× and Flask at 2.3–2.5× the throughput of uvicorn, on one worker.<br>
  HTTP/1.1, HTTP/2, HTTP/3, WebSocket and WebTransport.
</p>

<p align="center">
  <a href="https://pypi.org/project/peregrine-server/"><img src="https://img.shields.io/pypi/v/peregrine-server" alt="PyPI version"></a>
  <a href="https://pypi.org/project/peregrine-server/"><img src="https://img.shields.io/pypi/pyversions/peregrine-server" alt="Python versions"></a>
  <a href="https://github.com/grepjava/peregrine/blob/main/LICENSE"><img src="https://img.shields.io/pypi/l/peregrine-server" alt="MIT license"></a>
</p>

---

```bash
pip install peregrine-server
peregrine --host 0.0.0.0 --workers 0 main:app    # where you ran: uvicorn main:app
```

<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/peregrine/main/assets/benchmark-256.png" alt="Requests per second on one worker at 256 connections. FastAPI: peregrine 24,117, granian 15,574, uvicorn 15,544, fastpysgi 10,843. Flask: peregrine 14,992, fastpysgi 10,202, uvicorn 6,545, granian 6,152." width="760">
</p>

- **Faster with the framework you already use.** The same FastAPI application
  answers 24,100 requests a second on one worker against uvicorn's 15,500, and
  the same Flask application 15,000 against 6,500.
  [How that was measured.](https://github.com/grepjava/peregrine#numbers)
- **Nothing to change in the application.** ASGI 3 and PEP 3333 in full, for
  FastAPI, Starlette, Django and Flask, with lifespan and WebSockets. The
  protocol is detected, and the options are the ones you know:
  [coming from uvicorn or gunicorn](https://github.com/grepjava/peregrine#coming-from-uvicorn-or-gunicorn).
- **What usually needs a proxy in front, built in.** HTTP/2 and HTTP/3, TLS
  with Let's Encrypt certificates, static files with `sendfile`, compression,
  rate limiting, a response cache, Prometheus metrics, and a `SIGHUP` that
  replaces every worker without refusing a connection.
- **Free-threaded Python.** On CPython 3.14t, `--free-threaded` runs the
  workers as threads of one process: the throughput of processes at a third
  of the memory.
- **Wheels for Linux x86_64 and aarch64**, CPython 3.11 to 3.14 and 3.14t,
  including the official `python:*-slim` images. No Swift toolchain needed.

---

Built around two goals: spend as little time as possible outside the
application, and spend as little memory as possible per connection.

It runs in the same process as CPython — there is no socket between Swift and
Python, no serialisation step, and no second process. Swift owns the accept
loop, the HTTP parser and the response writer; Python owns the application. A
wheel installs the server as `peregrine._native`, an extension module the
`peregrine` command loads into your own interpreter, so applications run in
exactly the `python3` they were installed for.

```
pip install peregrine-server                # wheel if one matches; else compiled

peregrine --port 8000 myapp:application     # WSGI, protocol auto-detected
peregrine --port 8000 --workers 0 myapp:app # ASGI, one worker per CPU
peregrine --reload myapp:app                # restart on source changes

peregrine --http3 --tls-cert cert.pem --tls-key key.pem myapp:app
```

**Further reading:** [INSTALLATION.md](https://github.com/grepjava/peregrine/blob/main/INSTALLATION.md) — what to install and
what to do when it goes wrong. [CONFIG.md](https://github.com/grepjava/peregrine/blob/main/CONFIG.md) — configuring FastAPI and
Flask for every protocol here. [ARCHITECTURE.md](https://github.com/grepjava/peregrine/blob/main/ARCHITECTURE.md) — how the
server is built, and why. [TRANSPORT.md](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md) — what each protocol
does and what is implemented of it. [BENCHMARKS.md](https://github.com/grepjava/peregrine/blob/main/BENCHMARKS.md) — the
raw ASGI and WSGI, FastAPI, Django, Flask and BlackSheep entries on Peregrine,
and Elysia on Bun, with the load command, applications and worker count of
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/),
and how that differs from what the site publishes. [DEPLOY.md](https://github.com/grepjava/peregrine/blob/main/DEPLOY.md) — how a release reaches PyPI.
[RELEASE.md](https://github.com/grepjava/peregrine/blob/main/RELEASE.md) — what changed in each version.

---

## Numbers

FastAPI and Flask, one worker each, on Peregrine, uvicorn, granian and
fastpysgi, with the applications and load command of
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/)
at a pinned revision (zrk, an open-loop ramp to 100,000 requests a second, 15 s
per level). Requests per second at 64 / 256 / 512 connections, median of three
runs, all in one session, WSL2 on 4 cores, CPython 3.12:

| FastAPI (ASGI) | 64 | 256 | 512 |
|---|---:|---:|---:|
| **peregrine** | **24,672** | **24,117** | **24,320** |
| peregrine, executable | 21,696 | 21,841 | 21,504 |
| uvicorn | 17,504 | 15,544 | 15,114 |
| granian | 15,647 | 15,574 | 15,209 |
| fastpysgi, running FastAPI | 11,337 | 10,843 | 10,264 |

| Flask (WSGI) | 64 | 256 | 512 |
|---|---:|---:|---:|
| **peregrine** | **14,768** | **14,992** | **14,458** |
| peregrine, executable | 13,084 | 13,029 | 12,488 |
| fastpysgi, running Flask | 10,419 | 10,202 | 9,978 |
| uvicorn (`--interface wsgi`) | 6,554 | 6,545 | 5,722 |
| granian | 6,427 | 6,152 | 6,257 |

`peregrine` is what a wheel installs: the extension module, running inside
`python3.12`. The executable is the same server embedding `libpython3.12.so`,
and a shared libpython runs the framework 10–16 % slower than the statically
linked interpreter every other server here runs in.

These are not the site's figures and cannot be set beside them. The site runs
every server with a worker per CPU on 16 CPUs, under Python 3.14, with gunicorn
for Flask and fastpysgi on a raw application with no framework. Peregrine was
[added to that suite](https://github.com/the-benchmarker/web-frameworks/pull/9776)
in September 2026, and its figures there come from that hardware and those
settings, not these. What these tables show is how the servers compare with each
other on one worker of this machine.

These tables were measured on 1.1.1 on 2026-09-13, with the suite's earlier
ramp. [benchmarks/frameworks.sh](https://github.com/grepjava/peregrine/blob/main/benchmarks/frameworks.sh) repeats them with
`WORKERS=1 RATE=1000:100000`. Run-to-run variance on this box is around ±10 %,
so read the ratios rather than the absolute figures.
[BENCHMARKS.md](https://github.com/grepjava/peregrine/blob/main/BENCHMARKS.md) has the suite's own entries under its current
command, a worker per CPU: raw WSGI up to 302,417 requests a second, BlackSheep
up to 202,141, FastAPI up to 76,818, Flask about 50,000 and Django about
46,000.

These are hello-world routes, so they measure what a server adds to a request
rather than what an application can do. A real application doing database work
will be dominated by that work, and the gaps will narrow accordingly.

The server is about 1.7 MB of text and data as the extension module (1.3 MB as
the executable, which needs no position-independent code), and a live connection costs
one 16 KiB pooled read buffer plus a slot of about 200 bytes. Nearly all of a
worker's resident memory is CPython and the application.

---

## Coming from uvicorn or gunicorn

Point Peregrine at the same application object. The protocol is detected, so
there is no worker class to name, and most options keep their names. What
differs is mostly units, because Peregrine's timeouts are in milliseconds:

| uvicorn | gunicorn | peregrine |
|---|---|---|
| `uvicorn main:app` | `gunicorn -k uvicorn.workers.UvicornWorker main:app` | `peregrine main:app` |
| | `gunicorn myproject.wsgi` | `peregrine myproject.wsgi:application` |
| `--host 0.0.0.0 --port 8000` | `-b 0.0.0.0:8000` | `--host 0.0.0.0 --port 8000` |
| `--uds /run/app.sock` | `-b unix:/run/app.sock` | `--unix /run/app.sock` |
| `--workers 4` | `-w 4` | `--workers 4`, or `0` for one per CPU |
| | `--threads 8` | `--wsgi-threads 8` |
| `--reload` | `--reload` | `--reload` |
| `--ssl-certfile c.pem --ssl-keyfile k.pem` | `--certfile c.pem --keyfile k.pem` | `--tls-cert c.pem --tls-key k.pem` |
| `--forwarded-allow-ips '*'` | `--forwarded-allow-ips '*'` | `--forwarded-allow-ips '*'` |
| `--root-path /api` | | `--root-path /api` |
| `--timeout-keep-alive 5` | `--keep-alive 5` | `--keep-alive 5000` |
| `--timeout-graceful-shutdown 30` | `--graceful-timeout 30` | `--graceful-timeout 30000` |
| `--lifespan off` | | `--no-lifespan` |
| `--ws-max-size 16777216` | | `--ws-max-message 16777216` |
| `--ws-ping-interval 20` | | `--ws-ping-interval 20000` |
| `--factory` | | `--factory` |
| access log on by default | `--access-logfile -` | `--access-log` |
| `--log-level info` | `--log-level info` | `--log-level info` |

uvloop is used when it is installed (`pip install "peregrine-server[uvloop]"`),
as with uvicorn. `SIGTERM` drains the workers, and `SIGHUP` replaces them one
at a time without refusing a connection.

---

## What is supported

| | HTTP/1.1 | HTTP/2 | HTTP/3 | WebSocket | WebTransport |
| --- | --- | --- | --- | --- | --- |
| ASGI | ✓ | ✓ | ✓ | ✓ | ✓ |
| WSGI | ✓ | ✓ | ✓ | 501 | 501 |

WebSockets and WebTransport are refused for WSGI rather than half-served: both
are streams that outlive their response, and PEP 3333 has no way to express
one. Everything else is the same code for both — see
[one request path](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#one-request-path).

**WSGI (PEP 3333):** full environ, `wsgi.input` as a C-level stream (`read`,
`readline`, `readlines`, iteration), `start_response` including `exc_info`
semantics and the legacy `write` callable, `wsgi.file_wrapper`, iterable
`close()`, repeated request headers folded per spec, automatic
`Content-Length`/chunked framing. `start_response` may be called from inside
the first iteration of the returned iterable, as the spec requires a server to
allow, and a `Content-Length` the application declares is
[enforced](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#framing-is-enforced-not-trusted) rather than trusted.

Output is unbuffered in the sense PEP 3333 means. A block yielded by an
iterator goes to the socket before the next one is asked for, and a block
handed to `write()` goes out before the call returns — taking the response head
with it, if it is the first. A generator that yields a progress line and then
works for a second is therefore seen to do so. A list or tuple return value is
still written in one go, because every part of it is already in hand and
nothing is waiting.

**ASGI 3.0 (HTTP):** full scope including `client`, `server`, `raw_path` and
`state`, streaming request bodies, streaming responses with genuine write
backpressure, `http.disconnect`, and the lifespan protocol with state shared
into request scopes. Applications that do not implement lifespan are detected
and skipped. Response headers are accepted in any shape the specification
allows — tuples or lists, `bytes`, `bytearray` or `str`.

An ASGI application is started as soon as the request head is parsed, not once
the body has finished arriving. That is what lets one reject an upload at byte
one — unauthorised, too large, wrong content type — instead of paying to
receive all of it first, and it is the only way `receive()` can mean anything on
a request that is still being sent. Body bytes are read no further ahead than
the application has asked for.

Answering early leaves the rest of that body on the wire, and it is not a
request. If what remains is small and already here it is swallowed and the
connection is reused; otherwise that response is the last one on the
connection.

A `receive()` made after the response is complete is answered with
`http.disconnect` rather than parked. The request is over at that point, and a
task waiting on a body nobody will read holds the connection with it.

**ASGI 3.0 (WebSocket):** the full connect / accept / receive / send / close
cycle, subprotocol negotiation, extra handshake headers, fragmented messages,
text and binary, keepalive ping/pong with a dead-peer timeout, and a message
size limit. [Details.](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#websocket)

**WebTransport:** sessions, streams in both directions, unreliable datagrams
and the close capsule, through a documented
[ASGI extension](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#the-asgi-extension) — ASGI has no WebTransport
specification, so this one is Peregrine's.

**Free-threaded CPython (PEP 703):** `--free-threaded` runs the workers as
threads of one process rather than as processes, on an interpreter built
without the GIL. Same parallelism, one copy of the application:

```bash
peregrine --workers 0 --free-threaded myapp:app
```

On four cores with a CPU-bound application that is 5,907 req/s in 47 MB against
5,832 req/s in 143 MB for four worker processes — the throughput of processes
at a third of the memory, because the application is imported once instead of
four times. The ASGI lifespan runs once per worker thread, on the event loop that
thread serves requests with, so what an application opens in `startup` is
attached to the loop that will await
it. [Details.](https://github.com/grepjava/peregrine/blob/main/CONFIG.md#free-threaded-python)

---

## Installing

A wheel is tagged for one CPython and one platform. PyPI has them for CPython
3.11 to 3.14 and free-threaded 3.14t, on Linux x86_64 and aarch64 with glibc
2.35 or newer: Debian 12, Ubuntu 22.04, what came after them, and the official
`python:*-slim` images. When one matches, `pip` installs it and Swift is not
required. When none does, as on macOS, Alpine or an older distribution, `pip`
compiles the sdist against the interpreter you are installing into:

```bash
pip install peregrine-server
```

In a container nothing else is needed:

```dockerfile
FROM python:3.13-slim
RUN pip install --no-cache-dir "peregrine-server[uvloop]" fastapi
COPY main.py .
CMD ["peregrine", "--host", "0.0.0.0", "--workers", "0", "main:app"]
```

```bash
# plus a Swift 6.1+ toolchain from https://swift.org/install
git clone https://github.com/grepjava/peregrine
cd peregrine && bash scripts/build-extension.sh    # peregrine._native
PYTHONPATH=python python3 -m peregrine --port 8000 myapp:app
```

The extension module is the default wherever Peregrine is installed or built
from source. `swift build -c release` builds the standalone executable, which
embeds `libpython` and takes the same options; it is for working on Peregrine
itself.

Requirements, per-platform packages, certificates and the failure modes worth
recognising: [INSTALLATION.md](https://github.com/grepjava/peregrine/blob/main/INSTALLATION.md).

---

## Usage

```
peregrine [options] MODULE:ATTRIBUTE

  --host HOST              interface to bind (default 127.0.0.1)
  --port PORT              port to bind (default 8000)
  --unix PATH              listen on a unix socket instead
  --workers N              worker processes, 0 = one per CPU (default 1)
  --free-threaded          run the workers as threads of one process
                           instead of as processes; needs a free-threaded
                           CPython (python3.13t or newer)
  --protocol wsgi|asgi     force the application protocol (default: detect)
  --root-path PATH         SCRIPT_NAME / ASGI root_path prefix
  --scheme http|https      scheme reported to the application
  --backlog N              listen backlog (default 2048)
  --max-connections N      concurrent connections per worker (default 4096)
  --max-body BYTES         largest accepted request body (default 16 MiB)
  --max-header-size BYTES  largest accepted request head (default 32 KiB)
  --keep-alive MS          idle keep-alive timeout (default 5000)
  --request-timeout MS     how long a request may stall mid-message (30000)
  --graceful-timeout MS    time in-flight requests get on shutdown (10000)
  --drain-delay MS         on SIGTERM, fail the health check and keep serving
                           for MS before draining, for load balancers
  --wsgi-threads N         WSGI application threads per worker (default 1)
  --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted
  --factory                the target is a factory returning the application
  --venv DIR               virtualenv whose packages the app should import
  --no-auto-venv           ignore VIRTUAL_ENV from the environment
  --python-path DIR        directory to prepend to sys.path (repeatable)
  --python-home DIR        PYTHONHOME, for the standalone executable only
  --reload                 restart workers when source files change
  --no-uvloop              do not use uvloop even when installed
  --no-lifespan            skip the ASGI lifespan protocol
  --lifespan-scope WHICH   with --free-threaded, run the lifespan per worker
                           thread (worker, default) or once for the whole
                           process (process)
  --tls-cert PATH          PEM certificate chain; enables TLS with ALPN.
                           Repeatable, with a --tls-key each: the first pair
                           is the default and the rest are chosen by SNI
  --tls-key PATH           PEM private key for the preceding --tls-cert
  --tls-ciphers LIST       OpenSSL cipher list for TLS 1.2
  --ktls                   let the kernel encrypt TLS, so --static-dir files
                           go out with sendfile over HTTPS too
  --no-http2               refuse HTTP/2 and answer HTTP/1.1 only
  --http2-only             serve only HTTP/2 (h2c), with no HTTP/1 fallback
  --http3                  also serve HTTP/3 over QUIC (needs TLS)
  --quic-port PORT         UDP port for HTTP/3 (default: the TCP port)
  --no-websockets          reject WebSocket upgrades with 501
  --ws-max-message BYTES   largest accepted WebSocket message (16 MiB)
  --ws-ping-interval MS    keepalive ping period, 0 to disable (20000)
  --ws-ping-timeout MS     how long an unanswered ping may go (20000)
  --ws-max-queue N         messages buffered for a slow app (default 32)
  --ws-max-queue-bytes N   bytes buffered for a slow app (default 4 MiB)
  --ws-compress            permessage-deflate for clients that offer it
  --static-dir P=DIR       serve URL prefix P from DIR with sendfile,
                           without calling the application (repeatable)
  --acme-domain NAME       get and renew a certificate from Let's Encrypt,
                           answering tls-alpn-01 on this port (repeatable)
  --acme-email ADDR        contact address for the ACME account
  --acme-cache DIR         account key and certificate (default ./acme)
  --acme-staging           use Let's Encrypt's staging CA
  --acme-directory URL     use another ACME CA
  --acme-ca-bundle PATH    roots to trust for the CA's own HTTPS
  --redirect-http PORT     answer plain HTTP on PORT with a redirect to https
  --hsts SECONDS           Strict-Transport-Security on every TLS response
  --rate-limit RATE        429 past RATE requests per client (100/s, 600/m),
                           counted across all workers
  --rate-limit-burst N     requests allowed at once before RATE applies
  --cache-size MIB         answer repeated GETs from a cache shared by every
                           worker, for responses the application marks fresh
                           (read CONFIG.md first)
  --cache-max-object KIB   largest body the cache keeps (default 1024)
  --cache-ttl-max SECONDS  longest a response is kept (default 300)
  --compress               compress text-like application responses with
                           br, zstd or gzip (see CONFIG.md about BREACH)
  --compress-min-size N    leave bodies declared smaller than N alone (1024)
  --compress-static        serve FILE.br / FILE.zst / FILE.gz beside a
                           --static-dir file to clients that accept it
  --request-start-header   hand the app X-Request-Start for queue-time APMs
  --request-id             an X-Request-ID per request, for the app, the
                           response and the access log
  --trace-context          log a request's W3C trace and parent span IDs
  --health-check-path P    answer P with 200 in the server, without calling
                           the application (e.g. /healthz)
  --access-log             log one line per request
  --access-log-format F    text (default) or json; implies --access-log
  --metrics-port PORT      serve Prometheus metrics on this port
  --metrics-host HOST      what the metrics port binds (default --host)
  --log-level LEVEL        debug, info, warning, error, silent
  --version                print the version and exit
```

The protocol is detected by inspecting the callable: a coroutine function, or
one taking three positional parameters, is ASGI; two parameters is WSGI. Force
it with `--protocol` if your application is wrapped in something opaque.

`SIGTERM` or `SIGINT` drains gracefully, with a deadline. `SIGHUP` replaces
every worker one at a time, each replacement accepting on the socket its
predecessor had before that one is asked to stop, so nothing is refused and
nothing is reset -- which also makes it the certbot deploy hook, because the
replacements read the certificate off disk again. See
[reloading without a restart](https://github.com/grepjava/peregrine/blob/main/CONFIG.md#reloading-without-a-restart), and the
[shutdown sequence](https://github.com/grepjava/peregrine/blob/main/ARCHITECTURE.md#shutdown), which is more careful than it
looks and deliberately so.

### Behind a reverse proxy

`--forwarded-allow-ips` takes a comma-separated list of addresses or CIDR
blocks, `unix`, or `*` for every peer. Only headers arriving from a peer on
that list are honoured; from anyone else `X-Forwarded-For`, `X-Forwarded-Proto`
and `Forwarded` are ignored rather than trusted, because a client can send them
too.

---

## Frameworks

Checked against real applications rather than only the specifications
(`bash scripts/framework-test.sh`):

- **FastAPI** (ASGI) — routing, middleware, `lifespan` context managers
  including teardown on `SIGTERM`, `StreamingResponse`, WebSocket endpoints
  driven by the `websockets` client, the generated OpenAPI document, and the
  `anyio` worker threads FastAPI uses for synchronous endpoints.
- **Flask** (WSGI) — routing, request bodies, streamed responses,
  `request.is_secure` and `request.remote_addr` derived from forwarded headers,
  and blocking views overlapping properly on `--wsgi-threads`.

Both run over HTTP/3 with no integration at all: a request is the same request
whatever carried it. WebTransport is the exception for FastAPI, because a
session is not a request — Starlette's router asserts on the scope type before
it routes — so `peregrine.contrib` puts a router in front that answers sessions
and passes everything else through:

```python
from fastapi import FastAPI
from peregrine.contrib.fastapi import WebTransportRouter

api = FastAPI()
app = WebTransportRouter(api)            # serve this one

@app.route("/chat/{room}")
async def chat(session):
    await session.accept()
    async for stream in session.incoming_streams():
        await stream.send(b"hello " + await stream.read(), end=True)
```

Flask needs nothing at all: as a WSGI application it is served over HTTP/1.1,
HTTP/2 and HTTP/3, and WebSocket and WebTransport, which PEP 3333 cannot
express, are refused with a 501.
[How to configure both, protocol by protocol.](https://github.com/grepjava/peregrine/blob/main/CONFIG.md)
[What the router does.](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#frameworks)

---

## Why Swift

The interesting question is not "why not C" but "why not Python, or Rust, or
Go", since all four can host an application server and three of them are more
usual choices for one.

**It compiles to a native binary with no runtime to schedule around.** A server
is a loop over a poller; anything that inserts its own scheduler between the
loop and the syscall — a garbage collector that stops the world, a green-thread
runtime that decides when a read happens — buys concurrency this design does
not need and costs latency it cannot recover. Swift has neither. Reference
counting is deterministic, and where it would cost anything it can be removed,
which is a large part of [what the server does](https://github.com/grepjava/peregrine/blob/main/ARCHITECTURE.md#minimising-arc).

**It talks to C without a binding layer.** Embedding CPython means calling a C
API constantly: `PyDict_SetItem`, `PyObject_Vectorcall`, `Py_DECREF`, a few
hundred times per request. In Swift those are direct calls through a thin shim
for the parts that are macros. There is no FFI marshalling, no
`unsafe` boundary to justify per call site, and no second object model to keep
in step with CPython's — a `PyObject *` is an `OpaquePointer`, and a
`~Copyable` struct makes the compiler prove the decref happens exactly once.
The same is true of OpenSSL, epoll and `recvmmsg`.

**It is memory-safe by default and unsafe on request.** Almost all of this
server is ordinary safe Swift: bounds-checked, ownership-checked, no null. The
hot path opts out deliberately and locally — raw pointers into a read buffer, a
slab of connection structs — and those opt-outs are visible in the source
because they have to be spelled `Unsafe`. That is a better default for a
network-facing parser than a language where everything is unsafe and discipline
is the only guard, and a better ceiling than one where the escape hatch is
awkward enough that you write the slow thing instead.

**Generics and value types make the fast version the readable one.** `ByteBuffer`
is a struct passed in registers; the HTTP parser returns offsets into it; the
QUIC packet builder writes through a `~Copyable` writer that cannot be aliased.
None of that needs a comment explaining what the pointer arithmetic is for,
because there is no pointer arithmetic in it.

The honest costs: the ecosystem for this kind of work is small, so the QUIC
stack, the TLS 1.3 handshake, HPACK and QPACK are all written here rather than
pulled in; Linux tooling is thinner than C's; and Foundation is avoided
entirely because it would bring back the allocation behaviour the design exists
to remove.

---

## Correctness and hardening

The HTTP/1.1 parser is strict wherever strictness prevents request smuggling —
whitespace before a colon, `Content-Length` with `Transfer-Encoding`,
disagreeing lengths, any `Transfer-Encoding` that is not a bare `chunked`,
`obs-fold`, a missing or repeated `Host`.
Response headers containing CR or LF are refused outright. Request header names
containing underscores are dropped, and a `Proxy:` header is dropped entirely.
[The full list.](https://github.com/grepjava/peregrine/blob/main/TRANSPORT.md#strictness-that-prevents-smuggling)

Every transport is checked against an implementation that shares none of its
code, because a test written against the same understanding as the code proves
only that the understanding is consistent.

```bash
swift test                                      # 150 unit tests: parser,
                                                #   chunking, buffers, writer,
                                                #   websocket framing, HPACK,
                                                #   QUIC packet protection,
                                                #   and the fuzz corpus
bash scripts/integration-test.sh                #  56 end-to-end checks
python3 scripts/feature-test.py                 # 196 checks for the failure
                                                #   modes a plain request never
                                                #   reaches: slow consumers,
                                                #   stuck-request shutdown,
                                                #   lifespan cleanup, worker
                                                #   restarts, reload
bash scripts/framework-test.sh                  # checks against real FastAPI
                                                #   and Flask applications,
                                                #   over HTTP/1.1 and HTTP/2
<venv>/bin/python scripts/http2-test.py         # 162 checks against `h2`
<venv>/bin/python scripts/http3-test.py         # 114 checks against `aioquic`
python3 scripts/contrib_test.py                 #  58 Python-only: routing,
                                                #   converters, session helper
<venv>/bin/python scripts/webtransport-test.py  # sessions, streams, datagrams,
                                                #   plus FastAPI over HTTP/3
                                                #   and WebTransport
swift run -c release pgfuzz                     # mutation fuzzing of every
                                                #   parser that reads bytes
                                                #   from the network
```

[CI](https://github.com/grepjava/peregrine/blob/main/.github/workflows/ci.yml) runs all of it on every push, against CPython
3.11 through 3.14 and a free-threaded 3.14, on Linux and macOS, plus the
fuzzer under AddressSanitizer. The suites are the ones above — there is no
CI-only test path, so a green run there means what a green run here means.
[More on the fuzzing.](https://github.com/grepjava/peregrine/blob/main/fuzz/README.md)

HTTP/2 conformance is checked with
[h2spec](https://github.com/summerwind/h2spec), which is not vendored here:

```bash
peregrine --port 8443 --tls-cert cert.pem --tls-key key.pem examples.asgi_app:app &
h2spec -h 127.0.0.1 -p 8443 -t -k    # 146 tests, 146 passed
```

QUIC packet protection is checked against RFC 9001 appendix A directly: the key
schedule, the header protection and the sample packets are the RFC's own bytes.

---

## What is not

- **`sendfile` for `wsgi.file_wrapper`.** The wrapper works and streams in
  chunks, but does not yet drop into `sendfile(2)` the way `--static-dir`
  does.
- **Byte ranges and directory indexes for `--static-dir`.** It serves assets
  with an `ETag` and answers `If-None-Match`; it is not a file server.
- **Compressing `--static-dir` files on the fly.** `--compress-static` serves
  copies compressed at build time; a file with no copy is sent as it is, which
  keeps `sendfile(2)` and keeps the CPU for requests.
- **SNI for HTTP/3.** Several certificates are chosen by name over TCP;
  HTTP/3 serves the first pair whatever the client asks for, because the QUIC
  handshake here is built from the primitives rather than driven by OpenSSL.
- **QUIC connection migration across workers, and 0-RTT.** A connection
  survives a change of address, but not a change of worker, and every handshake
  is a full one.
- **HTTP/3 server push, and WebSocket over HTTP/2 or HTTP/3.** HTTP/3
  advertises extended `CONNECT` because that is how WebTransport arrives;
  `webtransport` is the only `:protocol` served. HTTP/2 does not advertise it.
- **Windows.** The I/O layer is epoll/kqueue.
- **Spans.** `--trace-context` puts an incoming W3C trace on the access-log
  line and hands the header to the application untouched, and there are
  Prometheus metrics on `--metrics-port`, but the server records no
  OpenTelemetry spans of its own. The application's instrumentation is the
  right place for those, and there are good ones.

By default a synchronous WSGI application occupies its worker for the duration
of the call. Scale with `--workers`, and with `--wsgi-threads` when the
application spends its time waiting on I/O rather than on the CPU.
