<p align="center">
  <img src="https://raw.githubusercontent.com/grepjava/peregrine/main/assets/peregrine-impact.png" alt="peregrine" width="420">
</p>

<p align="center">
  A Python <b>ASGI and WSGI</b> server written in Swift 6.<br>
  HTTP/1.1, HTTP/2, HTTP/3, WebSocket and WebTransport.
</p>

---

Built around two goals: spend as little time as possible outside the
application, and spend as little memory as possible per connection.

It embeds CPython directly — there is no socket between Swift and Python, no
serialisation step, and no second process. Swift owns the accept loop, the HTTP
parser and the response writer; Python owns the application.

```
pip install peregrine-server                # compiled at install time

peregrine --port 8000 myapp:application     # WSGI, protocol auto-detected
peregrine --port 8000 --workers 0 myapp:app # ASGI, one worker per CPU
peregrine --reload myapp:app                # restart on source changes

peregrine --http3 --tls-cert cert.pem --tls-key key.pem myapp:app
```

**Further reading:** [INSTALLATION.md](INSTALLATION.md) — what to install and
what to do when it goes wrong. [CONFIG.md](CONFIG.md) — configuring FastAPI and
Django for every protocol here. [ARCHITECTURE.md](ARCHITECTURE.md) — how the
server is built, and why. [TRANSPORT.md](TRANSPORT.md) — what each protocol
does and what is implemented of it. [BENCHMARKS.md](BENCHMARKS.md) — hello-world
throughput, processes against `--free-threaded`.

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
which is a large part of [what the server does](ARCHITECTURE.md#minimising-arc).

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

## Numbers

One worker, one core, 64 connections, same application, same load generator
(`oha`), Ubuntu 24.04 on WSL2, CPython 3.12, Swift 6.3.3.
Reproduce with `bash benchmarks/run.sh`.

| WSGI, 1 worker | req/s | p50 | p99 |
|---|---:|---:|---:|
| **peregrine** | **100,603** | 0.49 ms | 3.37 ms |
| gunicorn (sync) | 4,464 | 12.86 ms | 28.93 ms |
| gunicorn (gthread ×8) | 2,041 | 30.74 ms | 45.07 ms |

| ASGI, 1 worker | req/s | p50 | p99 |
|---|---:|---:|---:|
| **peregrine** | **55,526** | 0.98 ms | 4.61 ms |
| uvicorn (uvloop + httptools) | 43,361 | 1.34 ms | 5.08 ms |
| uvicorn (asyncio + h11) | 5,343 | 11.08 ms | 25.60 ms |

Roughly 22× gunicorn on WSGI and 1.3× uvicorn's fastest configuration on ASGI.
Run-to-run variance on this box is around ±10%, so treat the ratios rather than
the absolute figures as the result. Each cell is the median of three runs.

Resident memory for the same application (`bash benchmarks/memory.sh`), summed
over the whole process tree:

| | idle | under 500 connections |
|---|---:|---:|
| peregrine (wsgi) | 31.7 MB | 33.8 MB |
| gunicorn (sync) | 45.4 MB | 45.5 MB |
| peregrine (asgi) | 31.7 MB | 34.8 MB |
| uvicorn (uvloop) | 28.3 MB | 33.3 MB |

Nearly all of that is CPython itself: the server binary is ~1.0 MB of text and
data, and a live connection costs one 16 KiB pooled read buffer plus a
~200-byte slot.

These are trivial-response benchmarks, so they measure server overhead rather
than application throughput — which is the point. A real application doing
database work will be dominated by that work, and the gap will narrow
accordingly.

---

## What is supported

| | HTTP/1.1 | HTTP/2 | HTTP/3 | WebSocket | WebTransport |
| --- | --- | --- | --- | --- | --- |
| ASGI | ✓ | ✓ | ✓ | ✓ | ✓ |
| WSGI | ✓ | ✓ | ✓ | 501 | 501 |

WebSockets and WebTransport are refused for WSGI rather than half-served: both
are streams that outlive their response, and PEP 3333 has no way to express
one. Everything else is the same code for both — see
[one request path](TRANSPORT.md#one-request-path).

**WSGI (PEP 3333):** full environ, `wsgi.input` as a C-level stream (`read`,
`readline`, `readlines`, iteration), `start_response` including `exc_info`
semantics and the legacy `write` callable, `wsgi.file_wrapper`, iterable
`close()`, repeated request headers folded per spec, automatic
`Content-Length`/chunked framing. `start_response` may be called from inside
the first iteration of the returned iterable, as the spec requires a server to
allow, and a `Content-Length` the application declares is
[enforced](TRANSPORT.md#framing-is-enforced-not-trusted) rather than trusted.

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
size limit. [Details.](TRANSPORT.md#websocket)

**WebTransport:** sessions, streams in both directions, unreliable datagrams
and the close capsule, through a documented
[ASGI extension](TRANSPORT.md#the-asgi-extension) — ASGI has no WebTransport
specification, so this one is Peregrine's.

**Free-threaded CPython (PEP 703):** `--free-threaded` runs the workers as
threads of one process rather than as processes, on an interpreter built
without the GIL. Same parallelism, one copy of the application:

```bash
peregrine --workers 0 --free-threaded myapp:app
```

On four cores with a CPU-bound application that is 5,907 req/s in 47 MB against
5,832 req/s in 143 MB for four worker processes — the throughput of processes
at a third of the memory, because Django is imported once instead of four
times. The ASGI lifespan runs once per worker thread, on the event loop that
thread serves requests with, so what an application opens in `startup` is
attached to the loop that will await
it. [Details.](CONFIG.md#free-threaded-python)

---

## Installing

Peregrine embeds CPython rather than talking to it over a socket, so the binary
is built against the interpreter it will run inside:

```bash
pip install peregrine-server
```

```bash
# plus a Swift 6.1+ toolchain from https://swift.org/install
git clone https://github.com/grepjava/peregrine
cd peregrine && swift build -c release
```

Requirements, per-platform packages, certificates and the failure modes worth
recognising: [INSTALLATION.md](INSTALLATION.md).

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
  --wsgi-threads N         WSGI application threads per worker (default 1)
  --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted
  --factory                the target is a factory returning the application
  --venv DIR               virtualenv whose packages the app should import
  --no-auto-venv           ignore VIRTUAL_ENV from the environment
  --python-path DIR        directory to prepend to sys.path (repeatable)
  --python-home DIR        PYTHONHOME for the embedded interpreter
  --reload                 restart workers when source files change
  --no-uvloop              do not use uvloop even when installed
  --no-lifespan            skip the ASGI lifespan protocol
  --lifespan-scope WHICH   with --free-threaded, run the lifespan per worker
                           thread (worker, default) or once for the whole
                           process (process)
  --tls-cert PATH          PEM certificate chain; enables TLS with ALPN
  --tls-key PATH           PEM private key for it
  --tls-ciphers LIST       OpenSSL cipher list for TLS 1.2
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
  --access-log             log one line per request
  --access-log-format F    text (default) or json; implies --access-log
  --metrics-port PORT      serve Prometheus metrics on this port
  --metrics-host HOST      what the metrics port binds (default --host)
  --log-level LEVEL        debug, info, warning, error, silent
```

The protocol is detected by inspecting the callable: a coroutine function, or
one taking three positional parameters, is ASGI; two parameters is WSGI. Force
it with `--protocol` if your application is wrapped in something opaque.

`SIGTERM` or `SIGINT` drains gracefully, with a deadline; `SIGHUP` restarts the
workers without dropping the listening socket. The
[shutdown sequence](ARCHITECTURE.md#shutdown) is more careful than it looks,
and deliberately so.

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

- **FastAPI / Starlette** — routing, middleware, `lifespan` context managers
  including teardown on `SIGTERM`, `StreamingResponse`, WebSocket endpoints
  driven by the `websockets` client, the generated OpenAPI document, and the
  `anyio` worker threads FastAPI uses for synchronous endpoints.
- **Django** — the WSGI handler, `StreamingHttpResponse`, `request.is_secure()`
  and `REMOTE_ADDR` derived from forwarded headers, and blocking views
  overlapping properly on `--wsgi-threads`; and the ASGI handler with Channels
  consumers and WebTransport sessions layered over it.

Both run over HTTP/3 with no integration at all: a request is the same request
whatever carried it. WebTransport is the exception, because a session is not a
request — every ASGI framework asserts on the scope type before it routes — so
`peregrine.contrib` puts a router in front that answers sessions and passes
everything else through:

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

The Django form is the same with `<str:room>` converters and
`get_asgi_application()` underneath, and composes with Channels: Django serves
`http`, Channels serves `websocket`, this serves `webtransport`.
[How to configure both, protocol by protocol.](CONFIG.md)
[What the router does.](TRANSPORT.md#frameworks)

---

## Correctness and hardening

The HTTP/1.1 parser is strict wherever strictness prevents request smuggling —
whitespace before a colon, `Content-Length` with `Transfer-Encoding`,
disagreeing lengths, any `Transfer-Encoding` that is not a bare `chunked`,
`obs-fold`, a missing or repeated `Host`.
Response headers containing CR or LF are refused outright. Request header names
containing underscores are dropped, and a `Proxy:` header is dropped entirely.
[The full list.](TRANSPORT.md#strictness-that-prevents-smuggling)

Every transport is checked against an implementation that shares none of its
code, because a test written against the same understanding as the code proves
only that the understanding is consistent.

```bash
swift test                                      # 127 unit tests: parser,
                                                #   chunking, buffers, writer,
                                                #   websocket framing, HPACK,
                                                #   QUIC packet protection,
                                                #   and the fuzz corpus
bash scripts/integration-test.sh                #  47 end-to-end checks
python3 scripts/feature-test.py                 # 196 checks for the failure
                                                #   modes a plain request never
                                                #   reaches: slow consumers,
                                                #   stuck-request shutdown,
                                                #   lifespan cleanup, worker
                                                #   restarts, reload
bash scripts/framework-test.sh                  #  30 checks against real
                                                #   FastAPI and Django apps,
                                                #   over HTTP/1.1 and HTTP/2
<venv>/bin/python scripts/http2-test.py         # 162 checks against `h2`
<venv>/bin/python scripts/http3-test.py         #  82 checks against `aioquic`
python3 scripts/contrib_test.py                 #  58 Python-only: routing,
                                                #   converters, session helper
<venv>/bin/python scripts/webtransport-test.py  # 117 including the above,
                                                #   plus FastAPI and Django
                                                #   over HTTP/3 and WebTransport
swift run -c release pgfuzz                     # mutation fuzzing of every
                                                #   parser that reads bytes
                                                #   from the network
```

[CI](.github/workflows/ci.yml) runs all of it on every push, against CPython
3.11 through 3.14 and a free-threaded 3.14, on Linux and macOS, plus the
fuzzer under AddressSanitizer. The suites are the ones above — there is no
CI-only test path, so a green run there means what a green run here means.
[More on the fuzzing.](fuzz/README.md)

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
  chunks, but does not yet drop into `sendfile(2)`.
- **QUIC connection migration across workers, and 0-RTT.** A connection
  survives a change of address, but not a change of worker, and every handshake
  is a full one.
- **HTTP/3 server push, and WebSocket over HTTP/2 or HTTP/3.** HTTP/3
  advertises extended `CONNECT` because that is how WebTransport arrives;
  `webtransport` is the only `:protocol` served. HTTP/2 does not advertise it.
- **Windows.** The I/O layer is epoll/kqueue.
- **Tracing.** There are Prometheus metrics on `--metrics-port` and a JSON
  access log, but no OpenTelemetry spans and nothing that follows a request
  into the application. An ASGI middleware is the right place for that, and
  there are good ones.

By default a synchronous WSGI application occupies its worker for the duration
of the call. Scale with `--workers`, and with `--wsgi-threads` when the
application spends its time waiting on I/O rather than on the CPU.
