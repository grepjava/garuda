# Handler API

The design of Garuda's handler API, the decisions behind it, and what is left
to build.

**The goal:** an application developer can build and test an authenticated JSON
CRUD API backed by a database, without touching pointers, engine internals or
hand-written JSON.

**The standard:** a server and framework that holds up in production, to be
chosen on its merits: correct under every protocol it speaks, safe by
construction, pleasant to write in, and fast. The README compares it with axum
feature by feature, and [BENCHMARKS.md](BENCHMARKS.md) has the measurements.

## Principles

- **A handler that can finish synchronously is a plain call.** No allocation,
  no `Task`, no scheduling hop for `GET /`.
- **One worker, one thread.** Each worker is a forked process with one poller.
  Suspended work resumes on that thread.
- **Identity checks on every resume.** A resume checks the connection's
  `(slot, generation)` and the `requestId`, so a stale resume never reaches a
  reused slot.
- **Borrowed bytes cannot escape.** What the request lends, the compiler keeps
  inside the closure it was lent to.
- **The engine owns the response path.** Handlers write into it rather than
  returning response values, which is what keeps a response from being built
  and copied.

## How a request runs

1. **The engine parses and routes.** Routes compile into one byte trie with a
   handler slot per method at each node: literal before parameter before rest,
   with backtracking.
2. **Middleware runs**, compiled into each route's handler when the application
   starts. A route with none keeps its own handler. Synchronous middleware
   runs on the worker. From the first async middleware on, the rest of the
   chain and the handler share one task.
3. **Extractors run** in the order declared, reading lent bytes and producing
   owned values. A failure is a `ResponseError`, answered 400 or 415.
4. **A synchronous handler is called inline.**
5. **An async handler runs on a reused task.** Each worker keeps a pool of
   long-lived tasks (up to 1,024, then a queue) on a `TaskExecutor` that runs
   jobs only on the worker's thread. The loop drains the executor in the same
   turn that hands a request to a task or wakes one.
6. **The answer goes through the response sink**, which runs `onSend` hooks,
   merges server headers, frames the body and enforces `Content-Length`.
7. **Cancellation.** A reset stream or closed connection resumes a handler
   waiting on the engine, such as `response.sleep` or a streamed write, so that
   it throws and unwinds. A handler waiting on anything else finds
   `response.isCancelled` set when it resumes, and whatever it sends is
   dropped.

What an async handler costs, from probes on Swift 6.3.3 under WSL2, one million
requests each (single figures move by up to 2× there):

| How the async handler runs | ns per request | Allocations per request |
|---|---:|---:|
| A new `Task` per request, loop outside the executor | 1,200–2,250 | 5 |
| `Task.immediate`, loop running as a job on its executor | ~500 | 4 |
| **A reused task from the pool**, no wait | **~360** | **0** |
| A reused task, one wait resumed by the loop | ~660 | 0 |
| A reused task, 4 KiB of locals held across the wait | ~850 | 0 |
| A reused task, five nested async calls | ~1,050 | 0 |

An async route costs about 0.4–1 µs and no allocation. A request's own CPU
time is about 6 µs, and a database round trip 100 µs or more. A new `Task` per
request is 3–6× slower, and allocates. The probes are in
[benchmarks/async-probes/](benchmarks/async-probes/).

## Decisions

### Two layers: raw and typed

The raw `(borrowing Request, inout Response)` handler is public and zero-copy,
for proxies, streaming and hot paths. The typed API is built on it. Both
register through the same names, and a closure with no `await` takes the
synchronous overload. Registration is generic over a parameter pack of
extractors.

### Ownership

`Request` and `Response` are `~Copyable`. Bytes are lent as `Span<UInt8>` to a
closure (`withBody`, `withPath`, `withHeader`). A span that would escape does
not compile, with no experimental feature needed. Owned copies (`String`,
`[UInt8]`, decoded types) are made only when asked for.
`scripts/compile-fail-test.sh` checks six ways borrowed data could escape,
compiled through SIL diagnostics, since `-typecheck` does not run the lifetime
checks. Request context is keyed by type and tagged with the request's
identity.

### Errors

A thrown error conforming to `ResponseError` is the answer, and is not logged as
a fault. `throws(HTTPError)` allocates nothing. An untyped `throws` costs one
allocation for an error without a payload and three for one carrying a
`String`, and only when thrown. Anything that is not a `ResponseError` is a 500
and a log line.

### State and fork semantics

`app.state` runs a factory in each worker after the fork. What it builds belongs
to that worker, and an object captured before the fork is copied into each
worker rather than shared. State every worker must see lives outside the
process. A factory that throws stops that worker's start-up. Asking for state
nobody registered is a 500 naming the type.

### Middleware sees the response through a hook

Tower's model, `next(request)` returning a response value, would mean building
every response as a value and copying it out later, because handlers answer
into the sink and async ones answer later. Instead, middleware runs before the
handler and registers `response.onSend`, which the sink runs before the head is
written, whoever answered. `use` covers its whole scope regardless of where it
is called. The cost: middleware cannot retry a handler or hold a scope around
its run.

### CORS is a policy of a scope, not a middleware in order

`app.cors` does not take a place among the `use` calls. The innermost scope's
policy runs in front of all of a route's middleware. A browser's preflight
carries no credentials, so authentication in front of it would refuse every
preflight. And a 401 from that authentication needs Access-Control-Allow-Origin,
or the page cannot read it. A preflight to a path routed only for other methods
is answered from the 405 branch of dispatch, using the policy of one of the
routes the path does have, so a CORS route needs no OPTIONS route of its own.

### Deadlines return 504

`app.deadline` answers 504, not 503. Garuda already uses 503 for "this worker is
out of capacity" (drain, health probes, pool exhaustion), and a slow route is
not that. A deadline bounds waiting, not computing: nothing preempts a handler
that loops without awaiting.

### Blocking work on threads of each worker's own

`blocking { … }` runs its closure on a pool of threads that belongs to the
worker process, started when first used, and brings the result back through a
pipe on the worker's poller. The waiting task resumes on its worker, so the rest
of the handler keeps every guarantee a handler has. The pool is per worker
because workers are processes. Threads are bounded by `--blocking-threads` and
waiting work by `--blocking-queue`, past which the work is refused 503 rather
than queued without limit. The closure is `@Sendable`: it runs concurrently with
the worker's other requests, so the compiler checks what it captures. Work
cannot be interrupted, so a cancelled request learns of it only when its work
returns.

### Outbound I/O on the worker's poller

Outbound connections, the DNS resolver, TLS, the HTTP client, PostgreSQL and Redis all
run on the worker's own poller. `getaddrinfo` blocks, so names are resolved by
Garuda's resolver. Outbound connections live in their own table, so a pooled
idle connection does not keep a draining worker from finishing. An HTTP/2 client
connection's read is a baton passed between waiting requests rather than a task
of its own, because a task living as long as the connection would outlive a
drain.

### Databases

- Drivers are protocol state machines over bytes (`GarudaPostgres`, `GarudaRedis`), with no
  sockets or threads inside, so they are tested against recorded exchanges and
  fuzzed like the HTTP parsers. The socket layer and pool are in `Garuda`.
- PostgreSQL first, native on the poller, then Redis the same way. A Redis
  reply parser resumes from a stack rather than re-reading, because a large
  reply arrives over many reads. A pooled connection is closed rather than
  reused whenever a command may have changed its session, which is simpler to
  get right than restoring it.
- SQLite through a bounded blocking pool, since it is a library doing disk I/O.
- Any other database through an async bridge to an existing Swift driver, at a
  thread hop per call.
- Not postgres-nio: it brings SwiftNIO's threads into every worker and a thread
  hop into every query.

### Streaming

`response.stream()` sends the head through the ordinary sink with a flag that
leaves the response open, and returns a `ResponseBodyWriter`. A typed handler
returns `StreamingBody`, whose producer the handler's task runs after the
handler returns. A write waits on a continuation in the slot above
`writeHighWaterMark` (512 KiB), and every flush and QUIC acknowledgement checks whether to
wake it. The wake is queued on the executor, never run inside the flush. Only
one writer waits at a time; another finds it waiting and returns, its bytes
queued behind. A stalled reader is closed after `--request-timeout`.
`EventStream` is built on the writer.

A `Topic` has to reach clients held by every worker process, so a message goes
into a ring mapped before the fork (`avian_bus.c`) and every worker, the
publisher included, reads it back from there. No lock is held across processes:
one writer claims the ring by compare-and-swap for the copy of one message, and
a claim whose process has died is taken over. Readers take no claim; they copy
a message and then check the writer has not come round to it. The ring keeps
what it has room for, not only what is unread, and that is what serves
`Last-Event-ID` from any worker. A worker with subscribers arms a wake before
it sleeps; a publisher writes to the eventfd of each armed worker and disarms
it, so a burst costs one wake per worker. A subscriber waits the way a sleeping
handler does, on its request's slot or its WebSocket's timed waits, so the
connection closing ends the wait. A subscriber's queue is bounded, and what
does not fit becomes a single `.missed`.

A route registered with `onStreamingBody` has its own body limit, kept beside
the routes, and is dispatched when its head arrives instead of after its body.
The body stays in the connection's buffer until the handler reads it. Reading
is what lets more in: on HTTP/1.1 it restores read interest, on HTTP/2 it
returns window, and on HTTP/3 the stream window grows only by what was read, so
one window bounds what a slow handler leaves unread. The reader's state lives
apart from the connection slot, so when a connection closes, what arrived is
handed to the reader before it throws `incomplete`. That is what makes an
interrupted upload resumable.

Resumable uploads are a separate target, `GarudaUploads`, like `GarudaPostgres`:
a file store locked with `flock`, the draft's routes, and limits enforced in the
handler rather than by the engine, so a 413 can carry `Upload-Limit`.

WebTransport sessions and streams use the same shape: waits are continuations
on the session and stream, resumed from the frame loop. The session comes first
in a WebTransport handler because Swift will not pass arguments after a
parameter pack.

## Where it lives

- **`Sources/Garuda`** holds the public API beside the engine, so there is no
  module boundary on the request path. Engine types stay `internal` where the
  API does not need them.
- **`Sources/garuda-server`** serves the-benchmarker's contract through the
  public API, so the benchmark measures what applications use.
- **`Sources/GarudaConformance`** holds routes that make engine behaviour
  observable to the end-to-end suites. It is not an example to copy.

## Performance gate

A change does not land if it costs the benchmark contract more than 5% against
the commit before it, measured in the same session (`benchmarks/frameworks.sh`,
four workers, 64 connections). `benchmarks/vs-axum.sh` runs after each roadmap
step. A unit test counts heap allocations across dispatch and requires zero per
request after warm-up for synchronous routes, async routes and async routes that
wait once.

## Roadmap

| Step | Scope | State |
|---|---|---|
| 1 | Ownership, `Application`, test client, handler task pool, packaging | Done |
| 2 | JSON, typed answers and errors, extraction, per-worker state, forms and multipart | Done |
| 3 | Async handlers, cancellation and deadlines, outbound connections, HTTP client, databases, blocking pool | PostgreSQL, Redis and the blocking pool done; SQLite to do |
| 4 | Groups, 405, middleware, response hooks, routers, fallbacks, shipped middleware | CORS and authentication done; tracing and request limits to do |
| 5 | Streaming, server-sent events, WebSockets, WebTransport | Responses, request bodies, SSE with keep-alive and replay, broadcast across workers, WebSockets over HTTP/1.1, resumable uploads and WebTransport done |
| 6 | Examples and realistic benchmarks | To do |

### Still to build

**Step 3**
- SQLite on the blocking pool.
- PostgreSQL: `date`, `time`, `interval`, `numeric` and `json` types, `LISTEN`,
  SASLprep.

**Step 4**
- Middleware Garuda ships: tracing with a logging API, request limits.

**Step 5**
- WebSocket over HTTP/2 (RFC 8441) and HTTP/3 (RFC 9220).
- Broadcasting to many WebSockets and event streams, across workers.

**Step 6**
- Runnable examples: CRUD, authentication, streaming, WebSocket.
- Benchmarks past hello-world against axum: path parameters, JSON in and out, a
  database round trip, streaming.
- End-to-end coverage for the engine features listed in the README's
  [Status](README.md#status).
