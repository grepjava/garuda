# Handler API

The design of Garuda's handler API, the decisions behind it, and what is left
to build.

**The goal:** an application developer can build and test an authenticated JSON
CRUD API backed by a database, without touching pointers, engine internals or
hand-written JSON.

**The measure:** [axum](https://github.com/tokio-rs/axum), in usability and in
speed. [BENCHMARKS.md](BENCHMARKS.md) has the comparisons.

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

### Deadlines return 504

`app.deadline` answers 504, not 503. Garuda already uses 503 for "this worker is
out of capacity" (drain, health probes, pool exhaustion), and a slow route is
not that. A deadline bounds waiting, not computing: nothing preempts a handler
that loops without awaiting.

### Outbound I/O on the worker's poller

Outbound connections, the DNS resolver, TLS, the HTTP client and PostgreSQL all
run on the worker's own poller. `getaddrinfo` blocks, so names are resolved by
Garuda's resolver. Outbound connections live in their own table, so a pooled
idle connection does not keep a draining worker from finishing. An HTTP/2 client
connection's read is a baton passed between waiting requests rather than a task
of its own, because a task living as long as the connection would outlive a
drain.

### Databases

- Drivers are protocol state machines over bytes (`GarudaPostgres`), with no
  sockets or threads inside, so they are tested against recorded exchanges and
  fuzzed like the HTTP parsers. The socket layer and pool are in `Garuda`.
- PostgreSQL first, native on the poller. Redis next.
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
| 3 | Async handlers, cancellation and deadlines, outbound connections, HTTP client, databases, blocking pool | PostgreSQL done; Redis, SQLite and the blocking pool to do |
| 4 | Groups, 405, middleware, response hooks, shipped middleware | Shipped middleware and router merging to do |
| 5 | Streaming, server-sent events, WebSockets, WebTransport | Responses, SSE and WebTransport done |
| 6 | Examples and realistic benchmarks | To do |

### Still to build

**Step 3**
- A Redis driver on the poller.
- SQLite on a bounded blocking pool.
- The blocking pool itself, so an unavoidable blocking call does not stall its
  worker.
- PostgreSQL: `date`, `time`, `interval`, `numeric` and `json` types, `LISTEN`,
  SASLprep.

**Step 4**
- Router values that can be built separately and merged.
- Custom fallbacks for unmatched routes.
- Middleware Garuda ships: authentication, CORS, tracing with a logging API,
  request limits.

**Step 5**
- Streamed request bodies with backpressure, per-route body limits, and early
  responses without buffering the whole upload.
- `--compress` and `--cache-size` acting on handler responses in the sink.
- WebSocket handlers over the engine's existing handshake, framing, UTF-8
  checks, pings, size limits and `--ws-compress`. The handler sees whole
  messages.

**Step 6**
- Runnable examples: CRUD, authentication, streaming, WebSocket.
- Benchmarks past hello-world against axum: path parameters, JSON in and out, a
  database round trip, streaming.
- End-to-end coverage for the engine features listed in the README's
  [Status](README.md#status).
