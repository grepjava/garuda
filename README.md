# peregrine

A Python **ASGI and WSGI** server written in Swift 6, built around two goals:
spend as little time as possible outside the application, and spend as little
memory as possible per connection.

It embeds CPython directly — there is no socket between Swift and Python, no
serialisation step, and no second process. Swift owns the accept loop, the HTTP
parser and the response writer; Python owns the application.

```
pip install peregrine-server                # compiled at install time

peregrine --port 8000 myapp:application     # WSGI, protocol auto-detected
peregrine --port 8000 --workers 0 myapp:app # ASGI, one worker per CPU
peregrine --reload myapp:app                # restart on source changes
```

---

## Numbers

One worker, one core, 64 connections, same application, same load generator
(`oha`), Ubuntu 24.04 on WSL2, CPython 3.12, Swift 6.3.3.
Reproduce with `bash benchmarks/run.sh`.

| WSGI, 1 worker | req/s | p50 | p99 |
|---|---:|---:|---:|
| **peregrine** | **103,376** | 0.46 ms | 3.65 ms |
| gunicorn (sync) | 4,750 | 12.07 ms | 26.14 ms |
| gunicorn (gthread ×8) | 2,115 | 29.35 ms | 43.43 ms |

| ASGI, 1 worker | req/s | p50 | p99 |
|---|---:|---:|---:|
| **peregrine** | **57,039** | 0.94 ms | 4.69 ms |
| uvicorn (uvloop + httptools) | 44,293 | 1.33 ms | 5.10 ms |
| uvicorn (asyncio + h11) | 5,293 | 10.95 ms | 25.73 ms |

Roughly 22× gunicorn on WSGI and 1.3× uvicorn's fastest configuration on ASGI.
Run-to-run variance on this box is around ±10%, so treat the ratios rather than
the absolute figures as the result.

Resident memory for the same application (`bash benchmarks/memory.sh`), summed
over the whole process tree:

| | idle | under 500 connections |
|---|---:|---:|
| peregrine (wsgi) | 29.9 MB | 32.2 MB |
| gunicorn (sync) | 46.6 MB | 46.6 MB |
| peregrine (asgi) | 29.9 MB | 33.2 MB |
| uvicorn (uvloop) | 28.9 MB | 33.9 MB |

Nearly all of that is CPython itself: the server binary is ~1.2 MB and a live
connection costs one 16 KiB pooled read buffer plus a ~200-byte slot.

These are trivial-response benchmarks, so they measure server overhead rather
than application throughput — which is the point. A real application doing
database work will be dominated by that work, and the gap will narrow
accordingly.

---

## How it is built

```
Sources/
  CPeregrine/        C shim: epoll/kqueue, sockets, signals, CPython macros
  PeregrineCore/     buffers, buffer pool, poller, logging, date cache
  PeregrineHTTP/     HTTP/1.1 parser, chunked decoder, response writer
  PeregrinePython/   PyRef, interned constants, custom Python types
  PeregrineWSGI/     environ building, wsgi.input, start_response
  PeregrineASGI/     scope and message building
  PeregrineServer/   connection table, worker loop, both dispatchers, supervisor
  peregrine/         command line entry point
```

### One process per worker

Each worker is a separate process with its own interpreter and its own poller.
How the listening socket is shared depends on the address family, because the
two have opposite constraints:

- **TCP:** every worker opens its own socket with `SO_REUSEPORT`, so each gets
  an independent accept queue in the kernel. No shared accept lock, no
  thundering herd; the kernel spreads connections by hashing the four-tuple.
- **Unix:** a path can only be bound once, so the supervisor creates the
  listener and the workers inherit it across `fork`. (Letting each worker bind
  for itself would have every worker unlink and replace the socket the previous
  one had just published, leaving only the last one reachable.)

The ASGI path uses no threads at all: with an event loop and a GIL there is
nothing for a second thread to do.

WSGI is different, and `--wsgi-threads N` turns on a bounded pool. A
synchronous application spends most of its wall clock *waiting* — on a
database, a cache, another service — and CPython releases the GIL around every
blocking syscall, so those waits can overlap. The GIL is not the reason to run
one request at a time; it just means the pool buys nothing for CPU-bound work,
which is why the default is still one thread and the inline path is unchanged.

The split is what keeps the pool safe: the loop thread owns every connection,
buffer and poller and builds the environ; a pool thread owns only the job, and
holds the GIL while it calls the application and serialises the response into
the job buffer. Bytes cross back under one mutex, and the loop is woken through
a pipe it already polls. Backpressure is real rather than advisory — when a
job buffer passes the high water mark the producing thread releases the GIL and
blocks until the loop has written enough of it to the socket, so a streaming
response runs at the speed of the client.

### The asyncio integration is one file descriptor

The interesting trick in the ASGI path: an epoll (or kqueue) descriptor is
*itself pollable*. So instead of running a Swift I/O thread and marshalling work
across to the Python loop, peregrine hands its poller to asyncio:

```python
loop.add_reader(poller_fd, drain)   # drain is a C-level Swift callback
loop.run_forever()
```

asyncio then treats the entire server as one more readable descriptor. The
result is one thread, one event loop, one interpreter: no cross-thread queues,
no `call_soon_threadsafe` wakeups, no GIL handoffs — and uvloop works unchanged,
because `add_reader` is part of the loop contract.

The WSGI path uses no asyncio at all. The poller is the only thing that blocks,
and the GIL is released around it so application threads — the optional pool, or
threads the application started itself — still run.

`await send(...)` normally completes without suspending, because the bytes go
straight into the connection write buffer. When that buffer passes the high
water mark it returns a real `Future` instead, resolved once the socket has
drained back below the low one. Without that, a fast producer writing to a slow
client grows the buffer without bound and never yields to the loop.

---

## Minimising ARC

The brief was to keep Swift's reference counting off the request path — not
to ban classes outright. Start-up configuration, the WSGI thread pool and the
`--reload` watcher use ordinary Swift classes and arrays, because they run once
per process or once per request at most and clarity is worth more there.
On the request path:

**Python objects are never wrapped in Swift classes.** A `PyObject` already has
its own reference count, which under a standard CPython build is a non-atomic
increment protected by the GIL. Putting it behind a Swift class would mean
paying *two* counts, one of them atomic. Instead `PyRef` is a `~Copyable` struct
whose `deinit` calls `Py_DECREF`; the compiler proves single ownership and
inserts the decref exactly once on every path, at zero runtime cost. Borrowed
references are a bare `OpaquePointer`.

**No object per connection.** Connections live in one contiguous slab indexed by
slot, with a free list threaded through the unused entries. Accepting is an
index pop; closing is an index push. Poller tokens pack `(generation, slot)` into
64 bits, and the generation makes a stale event — one epoll collected for a
descriptor we closed earlier in the same batch — a discarded compare rather than
a use-after-free.

**Buffers are values, not objects.** `ByteBuffer` is a trivial struct — a pointer
and three integers, passed in registers — with an explicit `destroy()` at the one
place a buffer dies. It is not a class (that would be ARC on every hand-off) and
not `~Copyable` with a `deinit` (that fights the move-only checker on every
partial mutation of a slab entry). Ownership is a documented invariant here
rather than a language-enforced one; that is the trade this server is built to
make, and it is confined to a handful of files.

**Nothing on the request path becomes a `String`.** The parser produces
`(offset, length)` pairs into the read buffer. Header names, values, paths and
query strings stay as bytes until the moment they are handed to Python, where
they are copied exactly once into a `str` or `bytes`. Logging assembles bytes in
a stack buffer and issues one `write(2)`; there is no string interpolation
anywhere in the server.

**Foundation is not linked.** It would drag in ARC-heavy bridging types for no
benefit here.

The Python side gets the same treatment. `send`, `receive` and the awaitable they
return are C-level types built with `PyType_FromSpec` whose slots are Swift
`@convention(c)` functions, so `await send(msg)` is a `tp_call` plus a
`tp_iternext` and nothing else — no Python frame, and no trip through the event
loop, because a send that completes synchronously returns a pre-completed
awaitable that raises `StopIteration` on its first step.

---

## Other things that make it fast

- **A prototype environ/scope dict** holding every constant entry is built once
  and shallow-copied per request. `PyDict_Copy` on a small dict is a table
  memcpy; the alternative is ten-plus hashed insertions every request.
- **Interned keys.** Every environ and scope key is interned at start-up, so
  dict insertion compares a cached hash instead of hashing key bytes again.
- **Memoised header keys.** `User-Agent` becomes `HTTP_USER_AGENT` (WSGI) or
  lowercased `b"user-agent"` (ASGI) once per process, in an open-addressed cache
  keyed by the raw bytes. The cache stops growing once half full, so a flood of
  unique header names cannot become a memory-exhaustion vector.
- **Character classes are register constants.** `tchar` membership is two 64-bit
  shifts, not a table lookup, so the parser's inner loops touch no memory beyond
  the request itself.
- **A cached `Date` header**, reformatted at most once a second by a
  no-allocation, no-locale civil-from-days conversion.
- **Vectorcall everywhere** — no intermediate argument tuples.
- **Pooled read buffers** recycled LIFO, so the block handed out next is the one
  still in cache.
- **Framing decided with full information.** A WSGI response that is a list gets
  an exact `Content-Length`; a generator gets chunked encoding on HTTP/1.1.
- **`writev`, `TCP_NODELAY`, `accept4`, `MSG`-free reads**, and one `epoll_ctl`
  only when the interest mask actually changes.

---

## Correctness and hardening

The parser is strict wherever strictness prevents request smuggling:

- whitespace between a header name and its colon is rejected;
- `Content-Length` together with `Transfer-Encoding` is rejected;
- two disagreeing `Content-Length` values are rejected;
- a transfer coding that is not `chunked` is refused rather than guessed at;
- `obs-fold` continuation lines are rejected rather than unfolded;
- HTTP/1.1 without `Host` is a 400.

On the response side, an application header containing CR or LF is refused
outright — the classic response-splitting hole. On the request side, header
names containing underscores are dropped (they would otherwise collide with the
dash-to-underscore environ mapping and let a client forge `X-Real-IP`), and a
`Proxy:` header is dropped entirely (httpoxy).

Bodies are bounded by `--max-body`, heads by `--max-header-size`, header count
by a fixed limit, and connections by `--max-connections`; a full table answers
503 and hangs up rather than queueing without bound.

Run the suites:

```bash
swift test                              # 90 unit tests: parser, chunking, buffers,
                                        #   writer, websocket framing, HPACK,
                                        #   proxy trust
bash scripts/integration-test.sh        # 38 end-to-end checks over both protocols
python3 scripts/feature-test.py         # 102 checks for the failure modes a plain
                                        #   request never reaches: slow consumers,
                                        #   stuck-request shutdown, lifespan
                                        #   cleanup, worker restarts, multiworker
                                        #   unix sockets, websockets, reload
bash scripts/framework-test.sh          # 21 checks against real FastAPI and
                                        #   Django applications
<venv>/bin/python scripts/http2-test.py # 24 HTTP/2 checks against the `h2`
                                        #   library, run twice -- cleartext and
                                        #   TLS: multiplexing, flow control,
                                        #   CONTINUATION, cancellation
```

HTTP/2 conformance is checked with [h2spec](https://github.com/summerwind/h2spec),
which is not vendored here:

```bash
peregrine --port 8000 --http2-only examples.asgi_app:app &
h2spec -h 127.0.0.1 -p 8000          # 146 tests, 146 passed

peregrine --port 8443 --tls-cert cert.pem --tls-key key.pem examples.asgi_app:app &
h2spec -h 127.0.0.1 -p 8443 -t -k    # 146 tests, 146 passed
```

The framework suite needs a virtualenv with `fastapi starlette django
websockets` and is what actually proves the parts of the specifications that
only show up in anger: middleware stacks, lifespan managers, streaming response
classes, and a framework running its own thread pool inside ours.

---

## Installing

Peregrine embeds CPython rather than talking to it over a socket, so the binary
is linked against one specific libpython. It therefore ships as a source
distribution and is compiled at install time: the interpreter it links has to be
the interpreter it will serve applications for, and only the installing
environment knows which one that is.

```bash
sudo apt install python3-dev pkg-config libssl-dev   # or: brew install python@3.13 openssl
# plus a Swift 6.1+ toolchain from https://swift.org/install

pip install peregrine-server
```

The build checks that `pkg-config` resolves `python3-embed` to the interpreter
running the install, and then asks the finished binary which libpython it
actually bound (`peregrine --version` reports it) before packaging anything.
The wheel is tagged for that exact interpreter and platform -- `cp312-cp312-
linux_x86_64`, not `py3-none-any` -- so pip refuses it anywhere it would not
genuinely run.

Installing into a virtualenv is the normal case, and the `peregrine` command
then finds that environment by itself: it passes `--venv` for the prefix it is
installed under, and puts those packages *ahead* of any system-wide copies, so a
dependency pinned in the environment is the one the application imports. Point
it somewhere else with `--venv DIR`, or turn the inference off with
`--no-auto-venv`. A virtualenv built for a different Python minor version than
the embedded interpreter is reported as such rather than half-working.

To build from a checkout instead:

```bash
swift build -c release
```

Linux and macOS only: the server is built on epoll/kqueue and POSIX sockets.

---

## Usage

```
peregrine [options] MODULE:ATTRIBUTE

  --host HOST              interface to bind (default 127.0.0.1)
  --port PORT              port to bind (default 8000)
  --unix PATH              listen on a unix socket instead
  --workers N              worker processes, 0 = one per CPU (default 1)
  --protocol wsgi|asgi     force the application protocol (default: detect)
  --root-path PATH         SCRIPT_NAME / ASGI root_path prefix
  --scheme http|https      scheme reported to the application
  --backlog N              listen backlog (default 2048)
  --max-connections N      concurrent connections per worker (default 4096)
  --max-body BYTES         largest accepted request body (default 16 MiB)
  --max-header-size BYTES  largest accepted request head (default 32 KiB)
  --keep-alive MS          idle keep-alive timeout (default 5000)
  --graceful-timeout MS    time in-flight requests get on shutdown (10000)
  --wsgi-threads N         WSGI application threads per worker (default 1)
  --forwarded-allow-ips L  proxies whose X-Forwarded-* headers are trusted
  --factory                the target is a factory returning the application
  --venv DIR               virtualenv whose packages the app should import
  --no-auto-venv           ignore VIRTUAL_ENV from the environment
  --python-path DIR        directory to prepend to sys.path
  --python-home DIR        PYTHONHOME for the embedded interpreter
  --reload                 restart workers when source files change
  --no-uvloop              do not use uvloop even when installed
  --no-lifespan            skip the ASGI lifespan protocol
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
  --log-level LEVEL        debug, info, warning, error, silent
```

The protocol is detected by inspecting the callable: a coroutine function, or
one taking three positional parameters, is ASGI; two parameters is WSGI. Force
it with `--protocol` if your application is wrapped in something opaque.

`SIGTERM` or `SIGINT` drains gracefully, with a deadline. The listener stops
accepting, idle connections close immediately, websockets are sent a
`going away` close, and in-flight requests get `--graceful-timeout` to finish.
Whatever is still running when that expires is cancelled and awaited — so
cancellation is actually delivered rather than merely requested — and only then
does the application receive `lifespan.shutdown`. Doing it in that order is the
point: cancelling every task first would cancel the lifespan task too, and the
application would never reach the code after its `yield`.

Every layer of that is cooperative, and cooperation is not a guarantee: a task
can catch `CancelledError` and carry on, a C extension can sit in a syscall, and
a single worker started without `--workers` has no supervisor to escalate to. So
the cancellation phase has its own bound, the lifespan handler's cancellation
has one too, async generator cleanup has one, and behind all of it a `SIGALRM`
watchdog `_exit`s the process once the grace period plus a margin has passed.
A deadline that nothing enforces is not a deadline.

`SIGHUP` restarts the workers without dropping the listening socket.

### Behind a reverse proxy

Terminating TLS upstream means the client address and scheme reach the
application in headers, and headers are forgeable by anyone who can open a
connection to the server. Nothing is read unless the immediate peer is on the
trust list:

```
peregrine --forwarded-allow-ips 10.0.0.0/8,127.0.0.1 myapp:app
peregrine --unix /run/app.sock --forwarded-allow-ips unix myapp:app
```

`X-Forwarded-For` is walked right to left, skipping hops that are themselves
trusted proxies, so a chain resolves to the real client while a client that
prepends a forged address is not believed. `X-Forwarded-Proto` sets the scheme
(and `ws`/`wss` for websockets), and RFC 7239 `Forwarded` is understood when the
`X-` headers are absent. The list accepts addresses, CIDR blocks, `unix`, and
`*` for every peer — the last of which is only correct when nothing but the
proxy can reach the server.

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
  overlapping properly on `--wsgi-threads`.

## What is supported

**WSGI (PEP 3333):** full environ, `wsgi.input` as a C-level stream (`read`,
`readline`, `readlines`, iteration), `start_response` including `exc_info`
semantics and the legacy `write` callable, `wsgi.file_wrapper`, iterable
`close()`, repeated request headers folded per spec, automatic
`Content-Length`/chunked framing.

**ASGI 3.0 (HTTP):** full scope including `client`, `server`, `raw_path` and
`state`, streaming request bodies, streaming responses with genuine write
backpressure, `http.disconnect`, and the lifespan protocol with state shared
into request scopes. Applications that do not implement lifespan are detected
and skipped. Response headers are accepted in any shape the specification
allows — tuples or lists, `bytes`, `bytearray` or `str`.

An ASGI application is started as soon as the request head is parsed, not once
the body has finished arriving. That is what lets one reject an upload at byte
one -- unauthorised, too large, wrong content type -- instead of paying to
receive all of it first, and it is the only way `receive()` can mean anything on
a request that is still being sent. Body bytes are read no further ahead than
the application has asked for: past the high water mark the worker stops reading
the socket, so an upload nobody is consuming costs TCP window rather than
memory.

Answering early leaves the rest of that body on the wire, and it is not a
request. If what remains is small and already here it is swallowed and the
connection is reused; otherwise that response is the last one on the connection.

A `receive()` made after the response is complete is answered with
`http.disconnect` rather than parked. The request is over at that point, and a
task waiting on a body nobody will read holds the connection with it: it cannot
be handed to the next request until its task ends.

**ASGI 3.0 (WebSocket):** the full connect / accept / receive / send / close
cycle, subprotocol negotiation, extra handshake headers, fragmented messages,
text and binary, keepalive ping/pong with a dead-peer timeout, and a message
size limit.

Frames are decoded as they arrive rather than when the application next calls
`receive()`. That matters more than it sounds: a push-only endpoint, or one
merely busy between receives, would otherwise leave pings unanswered and never
see the pong for the server's own keepalive ping -- so the server would
eventually close a connection that was working perfectly. Data messages
therefore queue, bounded by `--ws-max-queue` and `--ws-max-queue-bytes`, and
the read side switches off at the bound so a slow application becomes TCP
backpressure rather than memory. The framing is strict where leniency would let a peer
desynchronise the stream: an unmasked client frame, a set reserved bit, an
unknown opcode, a fragmented or oversized control frame, an invalid close code
and non-UTF-8 text are each a protocol failure with the close code RFC 6455
prescribes.

**HTTP/1.1:** keep-alive, pipelining, chunked transfer in both directions,
`Expect: 100-continue`, `HEAD`, and the statuses that forbid a body.

A declared `Content-Length` is enforced rather than trusted. An application that
sends more than it promised has the excess dropped instead of written, because
those bytes would be read as the start of the next response on a keep-alive
connection; one that sends less has the connection closed rather than leaving
the client waiting on bytes that are not coming. Either way the application is
told, and the connection is not reused.

## HTTP/2

Cleartext HTTP/2 is served to any client that opens with the connection preface
-- `curl --http2-prior-knowledge`, a gRPC client, or a proxy configured to talk
h2c upstream. The same port still answers HTTP/1.1, because the preface is
recognised in full before anything is assumed. `--http2-only` drops the HTTP/1
fallback for ports that only ever carry h2c, and `--no-http2` turns the whole
thing off.

The upgrade dance from RFC 7540 is deliberately absent: RFC 9113 removed it, no
browser ever used it, and prior knowledge covers every cleartext client that
exists.

**The structural problem** is that a server built around one request per
connection now has many. Peregrine keeps the connection slot as the transport --
socket, read buffer, poller interest, HPACK tables, flow control -- and gives
every stream a slot of its own from the same table, with `fd` set to -1 and a
pointer back to the connection. A stream slot has a head, a body buffer, a write
buffer, a task and a Content-Length budget, so ASGI dispatch, request-body
streaming, write backpressure and disconnect delivery all work on a stream
exactly as they work on a connection. Three things know the difference: writing
(bytes become DATA frames on the parent instead of going to a socket), read
interest (a stream has no descriptor), and teardown.

The request head is rebuilt as HTTP/1.1 text and handed to the ordinary parser.
That costs a copy and a parse per request; in exchange the scope builder, the
trusted-proxy logic and the access log keep working on the representation they
were written for, rather than growing a second one.

**HPACK** is a full implementation -- static and dynamic tables, Huffman in both
directions, the eviction rules -- checked against every example in RFC 7541
appendix C. The Huffman table is generated from the RFC, and a unit test
re-derives all 257 codes from their lengths alone, so a transcription error
could not survive the build. Decoding hands out borrowed pointers rather than
objects, and the dynamic table is a FIFO of descriptors over an append-only
arena, so a compressed header block costs a memcpy per field and no allocations.

**Flow control** is real in both directions. A response is held in the stream
buffer until the peer's window allows it, which is what makes `await send()`
apply backpressure on a multiplexed connection; the window is only given back
as the application actually reads the request body, so an upload nobody is
consuming stops rather than filling memory. The encoder never uses incremental
indexing: mirroring the peer's table would save a few bytes on responses whose
headers barely repeat, and Huffman coding of literals gets most of it for none
of the bookkeeping.

## HTTP/3 and QUIC

```bash
peregrine --http3 --tls-cert fullchain.pem --tls-key privkey.pem myapp:app
```

The QUIC stack is Peregrine's own: packets, loss recovery, congestion control,
streams, flow control, key update, and a TLS 1.3 handshake. OpenSSL supplies
primitives and nothing else -- hash, HKDF, AEAD, key agreement, signature --
because QUIC replaces the TLS record layer outright and `SSL_*` has no way to
be used without it.

Written from scratch, so it is checked against things that share none of it:
the packet protection reproduces RFC 9001 appendix A byte for byte, the
handshake and the HTTP/3 layer are driven by `aioquic` in
`scripts/http3-test.py`, and the QPACK static table is generated by reading
each entry back out of an independent implementation rather than transcribed.

The structure above the transport is HTTP/2's, because the problem is the same
one: the QUIC connection takes a slot in the connection table with no
descriptor at all, each request stream takes a child slot, and the head is
rebuilt as HTTP/1.1 text and re-parsed. Three protocols, one request path.

**QPACK** advertises a dynamic table capacity of zero, and that is a promise
rather than a shortcut: it says no header block on the connection can ever wait
for another stream, which is the head-of-line blocking HTTP/3 exists to remove.
Encoding uses the static table and Huffman literals, which is where nearly all
of the saving was anyway.

One UDP socket serves every client per worker, bound with `SO_REUSEPORT` so the
kernel hashes datagrams to workers by four-tuple. A client that genuinely
migrates may hash to a worker that has never heard of its connection, and
recovers by making a new one.

## WebTransport

WebTransport (draft-ietf-webtrans-http3) runs on top of that: an extended
`CONNECT` with `:protocol: webtransport` that never finishes, carrying streams
and unreliable datagrams that name their session by the identifier of the
CONNECT stream. Sessions, their streams and their datagrams are routed to the
application; the close capsule works in both directions.

ASGI has no WebTransport specification, so this one is Peregrine's. It is
announced the way the specification says a server extension should be, in
`scope["extensions"]["webtransport"]`, and `scope["type"]` is `"webtransport"`.

`receive()` produces:

| message | fields |
| --- | --- |
| `webtransport.connect` | — |
| `webtransport.stream.opened` | `stream`, `bidirectional` |
| `webtransport.stream.receive` | `stream`, `data`, `more_data` |
| `webtransport.datagram.receive` | `data` |
| `webtransport.disconnect` | `code`, `reason` |

`send()` accepts:

| message | fields |
| --- | --- |
| `webtransport.accept` | `headers` (optional) |
| `webtransport.close` | `code`, `reason` |
| `webtransport.stream.open` | `bidirectional` |
| `webtransport.stream.send` | `stream`, `data`, `end_stream` |
| `webtransport.datagram.send` | `data` |

```python
async def app(scope, receive, send):
    assert scope["type"] == "webtransport"
    assert (await receive())["type"] == "webtransport.connect"
    await send({"type": "webtransport.accept"})
    while True:
        message = await receive()
        if message["type"] == "webtransport.disconnect":
            return
        if message["type"] == "webtransport.stream.receive" \
                and not message["more_data"]:
            await send({"type": "webtransport.stream.send",
                        "stream": message["stream"],
                        "data": b"got it", "end_stream": True})
```

`more_data` is false on the last message for a stream whether the peer finished
it or reset it: either way nothing more is coming, which is the only thing an
application can act on. A stream the application opens is answered with
`webtransport.stream.opened` rather than a return value, because ASGI's `send()`
returns nothing; they arrive in the order they were asked for.

Session streams get no slot in the connection table. A slot carries a request
head, a parser and a body buffer, and a WebTransport stream wants none of that:
it is a byte pipe, read straight out of the QUIC receive buffer so that bulk
data is copied once into a Python `bytes` and not before. Backpressure is the
transport's -- the receive window only reopens as the application reads, and
`await send()` waits when the session has more queued than acknowledged.

`scripts/webtransport-test.py` drives all of it with `aioquic`.

## TLS

```bash
peregrine --tls-cert fullchain.pem --tls-key privkey.pem myapp:app
```

OpenSSL is handed the descriptor directly, so a TLS connection is the same
connection as any other -- same slab slot, same poller interest, same buffers,
same state machine -- and the read and write wrappers report `EAGAIN` the way a
socket does, which is what keeps that true. Two things about TLS cannot be
wrapped away, and both are handled explicitly: the handshake happens before any
request exists and can want readability or writability at each step, and a
record is decrypted whole, so OpenSSL can be holding bytes the socket no longer
has -- which a level-triggered poller will never mention again.

**ALPN** is what makes HTTP/2 reachable from a browser, and it is where the
protocol is settled: `h2` if the client offers it, `http/1.1` otherwise, in the
server's order of preference rather than the client's. `--no-http2` and
`--http2-only` narrow the advertised list to match. A TLS listener also reports
`https` to the application, so URLs it builds are right without being told.

TLS 1.2 is the floor, renegotiation is off, and `--tls-ciphers` takes an
OpenSSL cipher list for anyone who needs to narrow the 1.2 suites. Certificates
are checked once at start-up rather than discovered to be unreadable inside
each worker.

## What is not

- **`sendfile` for `wsgi.file_wrapper`.** The wrapper works and streams in
  chunks, but does not yet drop into `sendfile(2)`.
- **QUIC connection migration and 0-RTT.** A connection survives a change of
  address, but not a change of worker, and every handshake is a full one.
- **HTTP/3 server push and WebSocket over HTTP/3.** Extended `CONNECT` is
  advertised, but `webtransport` is the only `:protocol` served.
- **Windows.** The I/O layer is epoll/kqueue.

By default a synchronous WSGI application occupies its worker for the duration
of the call. Scale with `--workers`, and with `--wsgi-threads` when the
application spends its time waiting on I/O rather than on the CPU.
