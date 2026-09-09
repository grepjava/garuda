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
swift test                              # 80 unit tests: parser, chunking, buffers,
                                        #   writer, websocket framing, proxy trust
bash scripts/integration-test.sh        # 38 end-to-end checks over both protocols
python3 scripts/feature-test.py         # 78 checks for the failure modes a plain
                                        #   request never reaches: slow consumers,
                                        #   stuck-request shutdown, lifespan
                                        #   cleanup, worker restarts, multiworker
                                        #   unix sockets, websockets, reload
bash scripts/framework-test.sh          # 21 checks against real FastAPI and
                                        #   Django applications
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
sudo apt install python3-dev pkg-config     # or: brew install python@3.13
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
the cancellation phase has its own bound, and behind all of it a `SIGALRM`
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

## What is not

- **HTTP/2 and HTTP/3.**
- **TLS.** Terminate it upstream; that is where it belongs for this class of
  server anyway.
- **`sendfile` for `wsgi.file_wrapper`.** The wrapper works and streams in
  chunks, but does not yet drop into `sendfile(2)`.
- **Windows.** The I/O layer is epoll/kqueue.

By default a synchronous WSGI application occupies its worker for the duration
of the call. Scale with `--workers`, and with `--wsgi-threads` when the
application spends its time waiting on I/O rather than on the CPU.
