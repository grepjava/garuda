<p align="center">
  <img src="assets/peregrine-mark.png" alt="peregrine" width="360">
</p>

# Architecture

Peregrine embeds CPython. There is no socket between Swift and Python, no
serialisation step and no second process: Swift owns the accept loop, the
parser and the response writer, and calls the application directly. Everything
below follows from that one decision.

The protocols themselves are in [TRANSPORT.md](TRANSPORT.md).

```
Sources/
  CPeregrine/        C shim: epoll/kqueue, sockets, signals, TLS, crypto,
                     UDP, and the CPython macros Swift cannot import
  PeregrineCore/     buffers, buffer pool, poller, logging, date cache
  PeregrineHTTP/     HTTP/1.1 parser, chunked decoder, response writer,
                     HPACK, QPACK, HTTP/2 and HTTP/3 framing
  PeregrinePython/   PyRef, interned constants, custom Python types
  PeregrineQUIC/     QUIC transport and the TLS 1.3 handshake it needs
  PeregrineWSGI/     environ building, wsgi.input, start_response
  PeregrineASGI/     scope and message building
  PeregrineServer/   connection table, worker loop, both dispatchers,
                     HTTP/2, HTTP/3, WebSocket, WebTransport, supervisor
  peregrine/         command line entry point
```

`Python.h`, `openssl/ssl.h` and `openssl/evp.h` never appear in a header Swift
imports. Everything they offer arrives through opaque functions in the shim,
which is what keeps the Swift side free of the macro soup and the C++-ish
declarations those headers contain.

---

## One process per worker

Each worker is a separate process with its own interpreter and its own poller.
How the listening socket is shared depends on the address family, because the
two have opposite constraints:

- **TCP:** every worker opens its own socket with `SO_REUSEPORT`, so each gets
  an independent accept queue in the kernel. No shared accept lock, no
  thundering herd; the kernel spreads connections by hashing the four-tuple.
- **UDP (HTTP/3):** the same, with the same consequence and one extra one — a
  client that migrates to an address hashing to a different worker reaches a
  worker that has never heard of its connection.
- **Unix:** a path can only be bound once, so the supervisor creates the
  listener and the workers inherit it across `fork`. Letting each worker bind
  for itself would have every worker unlink and replace the socket the previous
  one had just published, leaving only the last one reachable.

The supervisor restarts workers that die, forwards signals, and owns the
`--reload` watcher. `SIGHUP` restarts the workers without dropping the
listening socket.

---

## One thread per worker, when the interpreter allows it

A worker is a process for one reason: the GIL. A second thread cannot serve a
second request, so the only way to a second core is a second interpreter, and
the only way to a second interpreter is a second process. CPython 3.13 shipped
a build without the GIL (PEP 703) and that reasoning stops applying.
`--free-threaded` is the option that says so — the workers become threads of
one process, and nothing else about them changes.

What makes that a small change rather than a rewrite is that a worker never
reaches outside itself. It owns its poller, its connection slab, its buffer
pool, its date cache and its event loop; the only things it reads that it does
not own are written once at start-up and never again — the interned constants,
the internal Python types, the glue functions, the application object. So the
work was to move the last few pieces of per-worker state off the process:

- `currentWorker` became a thread-local. It is what a `send`/`receive` callable
  or the asyncio reader callback uses to find its worker, and those arrive from
  Python carrying nothing but a connection token.
- The ASGI event loop, the lifespan handle and the scope builder moved from
  statics onto `Worker`. The scope builder is the one that mattered: it carries
  a mutable memoised header-name cache and a scratch buffer, so one shared
  across threads would have been a data race on the request path.

The main thread is not a worker. It costs one mostly-idle thread and buys the
ordering that matters: **signals land somewhere that is not serving a request.**
Worker threads are started with every signal blocked; the main thread owns the
signal pipe and asks each worker to drain by writing down a pipe that worker
already polls, so `handleSignals` cannot tell the difference between that and a
real signal.

**The lifespan follows the event loop, not the process.** This started out the
other way around — one lifespan on the main thread's loop, one `startup` for one
application — and that was wrong. `startup` is where an application builds
asyncio objects, and an asyncio object binds to the loop that was running when
it was created; a pool built on the supervising loop and awaited from a worker's
loop is the "attached to a different loop" error, when it fails loudly at all.
So each worker thread runs the lifespan on its own loop and publishes its own
`state` mapping to the scopes that loop serves, and shuts it down on that loop
once its own requests have drained. The startups are serialised behind a mutex:
they run against one application object that has never had to be thread-safe.

`--lifespan-scope process` asks for the original reading — exactly one `startup`,
on the supervising loop — which is right for start-up that opens nothing
loop-bound, and only then. There the shutdown ordering is what it always was:
every worker drains and is joined *first*, and only then does the application get
`lifespan.shutdown`.

What is genuinely shared is the application, which is the point. One import,
one set of module-level caches, one warm JIT — instead of N copies. Four workers
serving a CPU-bound application on four cores reach the same throughput either
way, in 47 MB as threads against 143 MB as processes. Connection pools are the
exception, and belong to their loop for the reason above: an application that
wants one pool per worker thread puts it in the lifespan `state` mapping, which
is per loop here, rather than in a module global.

The trade is isolation: a crash takes every worker with it, where the process
supervisor would have restarted one. So the two compose rather than compete —
`--free-threaded --reload` puts the supervisor in front of a single threaded
child, and in production systemd plays the same part.

---

## The asyncio integration is one file descriptor

The interesting trick in the ASGI path: an epoll (or kqueue) descriptor is
*itself pollable*. So instead of running a Swift I/O thread and marshalling
work across to the Python loop, Peregrine hands its poller to asyncio:

```python
loop.add_reader(poller_fd, drain)   # drain is a C-level Swift callback
loop.run_forever()
```

asyncio then treats the entire server as one more readable descriptor. The
result is one thread, one event loop per worker: no cross-thread queues, no
`call_soon_threadsafe` wakeups, no GIL handoffs — and uvloop works unchanged,
because `add_reader` is part of the loop contract. Under `--free-threaded` a
process holds several of these, one per worker thread, and each is still the
same self-contained arrangement — the loops never speak to each other.

HTTP/3 adds one thing to this: QUIC has timers of its own — an acknowledgement
owed in milliseconds, a probe that has to fire — so a worker serving QUIC
cannot sleep for the usual interval. The loop's periodic callback runs at 20 ms
instead of the default, and the poll timeout is shortened to whatever the
nearest QUIC deadline is.

The WSGI path uses no asyncio at all. The poller is the only thing that blocks,
and the GIL is released around it so application threads — the optional pool,
or threads the application started itself — still run.

---

## The connection table

Connections live in one contiguous slab indexed by slot, with a free list
threaded through the unused entries. Accepting is an index pop; closing is an
index push.

Poller tokens pack `(generation, slot)` into 64 bits, and the generation makes
a stale event — one epoll collected for a descriptor we closed earlier in the
same batch — a discarded compare rather than a use-after-free. The same token
is what a Python `send`/`receive` callable carries, so an application holding
one after its connection has gone finds an empty slot instead of somebody
else's.

A slot is a connection *or* a stream. A stream slot has `fd = -1` and a pointer
back to its parent, and everything above the transport treats the two
identically; see [one request path](TRANSPORT.md#one-request-path).

---

## Minimising ARC

The brief was to keep Swift's reference counting off the request path — not to
ban classes outright. Start-up configuration, the WSGI thread pool, the QUIC
connection objects and the `--reload` watcher use ordinary Swift classes and
arrays, because they run once per process, or once per connection, and clarity
is worth more there. On the request path:

**Python objects are never wrapped in Swift classes.** A `PyObject` already has
its own reference count, which under a standard CPython build is a non-atomic
increment protected by the GIL. Putting it behind a Swift class would mean
paying *two* counts, one of them atomic. Instead `PyRef` is a `~Copyable`
struct whose `deinit` calls `Py_DECREF`; the compiler proves single ownership
and inserts the decref exactly once on every path, at zero runtime cost.
Borrowed references are a bare `OpaquePointer`.

**No object per connection.** The slab above.

**Buffers are values, not objects.** `ByteBuffer` is a trivial struct — a
pointer and three integers, passed in registers — with an explicit `destroy()`
at the one place a buffer dies. It is not a class (that would be ARC on every
hand-off) and not `~Copyable` with a `deinit` (that fights the move-only
checker on every partial mutation of a slab entry). Ownership is a documented
invariant here rather than a language-enforced one; that is the trade this
server is built to make, and it is confined to a handful of files.

**Nothing on the request path becomes a `String`.** The parser produces
`(offset, length)` pairs into the read buffer. Header names, values, paths and
query strings stay as bytes until the moment they are handed to Python, where
they are copied exactly once into a `str` or `bytes`. Logging assembles bytes
in a stack buffer and issues one `write(2)`; there is no string interpolation
anywhere in the server.

**Foundation is not linked.** It would drag in ARC-heavy bridging types for no
benefit here.

The Python side gets the same treatment. `send`, `receive` and the awaitable
they return are C-level types built with `PyType_FromSpec` whose slots are
Swift `@convention(c)` functions, so `await send(msg)` is a `tp_call` plus a
`tp_iternext` and nothing else — no Python frame, and no trip through the event
loop, because a send that completes synchronously returns a pre-completed
awaitable that raises `StopIteration` on its first step.

---

## The WSGI thread pool

`--wsgi-threads N` turns on a bounded pool. A synchronous application spends
most of its wall clock *waiting* — on a database, a cache, another service —
and CPython releases the GIL around every blocking syscall, so those waits can
overlap. The GIL is not the reason to run one request at a time; it just means
the pool buys nothing for CPU-bound work, which is why the default is still one
thread and the inline path is unchanged.

The split is what keeps the pool safe:

- the **loop thread** owns every connection, buffer and poller, builds the
  environ, and encodes anything that touches a per-connection compressor;
- a **pool thread** owns only the job, and holds the GIL while it calls the
  application and serialises the response into the job buffer.

Bytes cross back under one mutex, and the loop is woken through a pipe it
already polls.

Backpressure is real rather than advisory: when a job buffer passes the high
water mark the producing thread releases the GIL and blocks until the loop has
written enough of it, so a streaming response runs at the speed of the client.

---

## Backpressure

Three producers can outrun their consumer, and each is stopped by the same
idea — refuse to buffer, and let the pressure reach whoever is producing.

- **An ASGI application writing a response.** `await send(...)` normally
  completes without suspending, because the bytes go straight into the write
  buffer. When that buffer passes the high water mark it returns a real
  `Future` instead, resolved once the connection has drained back below the low
  one. On a multiplexed stream "drained" means acknowledged by the peer, not
  written to a socket — so the transport tells the layer above when an
  acknowledgement frees send buffer, and a producer parked on a window update
  that a peer with a large window would never send is a bug that has been
  fixed rather than a hazard to live with.
- **A client uploading a body.** Body bytes are read no further ahead than the
  application has asked for: past the high water mark the worker stops reading
  the socket, so an upload nobody is consuming costs TCP window rather than
  memory. On HTTP/2 and HTTP/3 the window is only given back as the application
  actually reads.
- **A peer flooding a WebSocket.** Decoded messages queue, bounded by
  `--ws-max-queue` and `--ws-max-queue-bytes`, and the read side switches off
  at the bound.
- **A WSGI application streaming a response.** PEP 3333 makes this the
  application's own problem to feel: a yielded block goes to the socket before
  the next is requested, and a `write()` goes out before it returns, so a
  producer faster than the client parks in the write that will not complete.
  Inline that means draining the block to the socket entirely, waiting on
  writability as often as it takes — stopping at the high water mark instead
  strands up to that much of the block, and on the inline path there is nothing
  to send it while the application runs. On a pool thread the same block is
  handed to the loop, which writes it while the application produces the next
  one, and the high water mark parks the thread. Buffering it all until the
  application returns, which is what the server used to do, hides the pressure
  and delays every byte.

  The exception is a WSGI response on an HTTP/2 or HTTP/3 stream, where a block
  can only go as far as the peer's flow-control window allows. Waiting for more
  window inline would deadlock — the `WINDOW_UPDATE` that would release it
  arrives on the loop that is blocked — so the bytes stay with the transport
  and go out when the loop next runs. `--wsgi-threads` is what removes that
  gap, because then the loop is running.

Bodies are bounded by `--max-body`, heads by `--max-header-size`, header count
by a fixed limit, and connections by `--max-connections`; a full table answers
503 and hangs up rather than queueing without bound.

---

## Other things that make it fast

- **A prototype environ/scope dict** holding every constant entry is built once
  and shallow-copied per request. `PyDict_Copy` on a small dict is a table
  memcpy; the alternative is ten-plus hashed insertions every request.
- **Interned keys.** Every environ and scope key is interned at start-up, so
  dict insertion compares a cached hash instead of hashing key bytes again.
- **Memoised header keys.** `User-Agent` becomes `HTTP_USER_AGENT` (WSGI) or
  lowercased `b"user-agent"` (ASGI) once per process, in an open-addressed
  cache keyed by the raw bytes. The cache stops growing once half full, so a
  flood of unique header names cannot become a memory-exhaustion vector.
- **Character classes are register constants.** `tchar` membership is two
  64-bit shifts, not a table lookup.
- **A cached `Date` header**, reformatted at most once a second by a
  no-allocation, no-locale civil-from-days conversion.
- **Vectorcall everywhere** — no intermediate argument tuples.
- **Pooled read buffers** recycled LIFO, so the block handed out next is the
  one still in cache.
- **Framing decided with full information.** A WSGI response that is a list
  gets an exact `Content-Length`; a generator gets chunked encoding on
  HTTP/1.1, and on a multiplexed stream the end of the stream is the framing.
- **`writev`, `TCP_NODELAY`, `accept4`, `MSG`-free reads**, and one
  `epoll_ctl` only when the interest mask actually changes.
- **`recvmmsg` for QUIC**, 32 datagrams per syscall.

---

## Shutdown

`SIGTERM` or `SIGINT` drains gracefully, with a deadline. The listener stops
accepting, idle connections close immediately, websockets are sent a `going
away` close, and in-flight requests get `--graceful-timeout` to finish.
Whatever is still running when that expires is cancelled and awaited — so
cancellation is actually delivered rather than merely requested — and only then
does the application receive `lifespan.shutdown`.

Doing it in that order is the point: cancelling every task first would cancel
the lifespan task too, and the application would never reach the code after its
`yield`, so its cleanup — closing database pools, flushing telemetry — would
silently not run.

Every layer of that is cooperative, and cooperation is not a guarantee: a task
can catch `CancelledError` and carry on, a C extension can sit in a syscall,
and a single worker started without `--workers` has no supervisor to escalate
to. So the cancellation phase has its own bound, the lifespan handler's
cancellation has one too, async generator cleanup has one, and behind all of it
a `SIGALRM` watchdog `_exit`s the process once the grace period plus a margin
has passed. A deadline that nothing enforces is not a deadline.
