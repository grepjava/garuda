# Handler API

Status, 2026-09-15: phase 1 is implemented. Routes, a `Request` view, a one-shot `Response`, the response sink, errors and lifecycle hooks serve the benchmark contract (`Sources/garuda`) and the end-to-end conformance routes (`Sources/GarudaConformance`). A review of that code set the roadmap below, which replaces the earlier phase list.

**The goal of the roadmap:** an application developer can build and test an authenticated JSON CRUD API backed by a database, without touching pointers, integer state slots, manual JSON or engine internals.

**The measure:** [axum](https://github.com/tokio-rs/axum), in usability and in speed. The first quick comparison is in [BENCHMARKS.md](BENCHMARKS.md#against-axum-quick-comparison).

## What it has to keep

- **A handler that can finish synchronously is a plain call.** No allocation, no `Task`, no scheduling hop for `GET /`. That is what serves the contract at 1.95× axum on the suite's ramp.
- **One worker, one thread.** Each worker is a forked process with one poller. Suspended work resumes on that thread.
- **Identity checks on every resume.** Each resume checks connection `(slot, generation)`, `requestId` and the continuation ticket, so a stale resume never reaches a reused slot.
- **Pointer-based operations stay available inside the engine.** Ordinary application code should not need them.

## What phase 1 delivers

```swift
import GarudaServer

var routes = Routes()

routes.get("/") { _, response in
    response.send(status: 200)
}
routes.get("/user/:id") { request, response in
    response.send(request.parameter(0))          // the id's bytes, no String made
}
routes.post("/echo") { request, response in
    response.addHeader("content-type", request.header("content-type") ?? "application/octet-stream")
    response.send(request.body)                  // the whole body, buffered up to --max-body
}
routes.get("/delay/:ms") { request, response in
    let ms = UInt64(min(5000, max(1, request.parameter(0).integer ?? 1)))
    response.after(milliseconds: ms) { _, response in
        response.send(status: 200)
    }
}

exit(Garuda.serve(routes))
```

- **Routes.** `get`, `head`, `post`, `put`, `delete`, `patch`, `options` and `on`. Segments are literal, `:param` or a trailing `*rest`. Patterns compile at start-up into a byte trie: literal before parameter before rest, with backtracking, HEAD falling back to GET, at most eight parameters. `--root-path` is taken off before matching.
- **`Request`**, a `~Copyable` view passed `borrowing`: `method`, `path`, `query`, `parameter(_:)`, `version`, `scheme`, `authority`, `header(_:)`, `forEachHeader`, `body`, `remoteAddress` and `remotePort` (with `--forwarded-allow-ips` applied), `requestID`, `requestStart` (kernel arrival under `--request-start-header`), `locals`.
- **`Response`**, `~Copyable`, passed `inout`: `status`, `addHeader`, `send(status:)`, `send(status:_:)` for bytes, strings and arrays, and `after(milliseconds:then:)`.
- **The response sink.** Every response goes through one engine path. It merges the server's headers without doubling a handler's own `X-Request-ID`, `Strict-Transport-Security` or `Alt-Svc`. It frames 204, 304 and HEAD. It enforces a declared `Content-Length`: extra bytes are cut, too few reset the stream or close the HTTP/1.1 connection.
- **Errors.** A handler that throws, or returns without answering, gets a 500; the connection lives on.
- **Lifecycle.** `Garuda.serve(routes, onStart:, onShutdown:)` runs `onStart` in each worker before it reports ready and `onShutdown` after its loop ends.

## What phase 1 gets wrong

Checked against the code:

- **Borrowed data escapes.** `Request` is `~Copyable`, but `body`, `path`, `parameter(_:)` and `header(_:)` return `ByteSpan`, a copyable struct holding a raw pointer. A handler can keep one past the request, and read another request's bytes through it.
- **`RequestLocals` is a copyable raw `Connection` pointer** with no request-identity check, and holds four `UInt64` words.
- **Handlers are synchronous.** The only suspension is a timer. There is no way to await a database query or an HTTP request.
- **Everything is bytes.** Parameters are positional and still percent-encoded; query strings and bodies are raw; there is no JSON. `garuda-conformance` hand-writes query decoding and JSON output.
- **No application state.** Lifecycle hooks return nothing, and a failing `onStart` cannot stop start-up.
- **No composition.** No middleware, nesting or merging. A known path under the wrong method gets the same 404 as an unknown path.
- **No streaming.** The body is buffered whole before dispatch, and `send` is one-shot.
- **Hard to test.** `Garuda.serve` installs process-global routes that live forever, reads the process arguments and runs the supervisor.
- **Not usable as a versioned dependency.** Every target applies `unsafeFlags(["-enforce-exclusivity=unchecked"])`, and SwiftPM refuses `unsafeFlags` in a package depended on by version.

## Roadmap

Each step lands with its tests, passes the [performance gate](#performance-gate), and runs `benchmarks/vs-axum.sh`.

### 1. Safe ownership, an application instance, a test client

- **Borrowed access is closure-scoped `Span`.** `request.withBody { (span: Span<UInt8>) in … }`. Swift 6.3.3 checks it with no experimental feature: a closure that stores `span` does not compile ("lifetime-dependent variable 'span' escapes its scope"). A `Span`-returning property (`request.body.count`) needs the experimental `Lifetimes` feature, so it stays out of the public API until that feature is stable.
- **Owned values for storage and suspension.** `String`, `[UInt8]` and decoded types, made only when the handler asks.
- **Typed request-local storage**, checked against the request's identity, replacing `locals`.
- **Tests.** Compile-fail tests for each way borrowed data could escape. Runtime tests for resume after cancellation and after slot reuse.
- **An owned application instance** with explicit programmatic configuration and deterministic cleanup. `Garuda.serve` stays as the one-line entry point over it.
- **A test client** that runs routing, extraction and middleware without opening a port, and an integration harness with an ephemeral port and controlled shutdown.
- **Packaging.** `-enforce-exclusivity=unchecked` moves to the executables, or its gain is won back in the source; an external package that depends on Garuda by version builds in CI.
- **The async design** (step 3) is settled here, because it decides what must be owned: only owned values live across an `await`.

### 2. Typed extraction, responses, errors and state

| Input | Output |
|---|---|
| Named, typed, decoded path parameters | `JSON<T: Encodable>` |
| Typed query decoding | Text, HTML, bytes, redirects |
| `Decodable` JSON bodies | A typed HTTP status |
| Forms, then multipart | Header replacement and append |
| One consistent decoding failure response | Application errors convertible to responses |

- **Decode only what the handler asks for**, straight from the request bytes, with no intermediate dictionary.
- **Garuda's own JSON coder.** `Encodable` and `Decodable` are in the standard library; `JSONEncoder` and `JSONDecoder` are Foundation, which Garuda does not use.
- **Typed application state.** `onStart` builds a worker's services (connection pools, clients) and returns them typed; handlers reach them without a cast. A throwing `onStart` stops start-up with its error. `onShutdown` tears them down.
- **Fork semantics, stated.** Each worker is a process: state built in `onStart` is per worker, and a mutable object captured before the fork is copied, not shared. State every worker must see lives outside the process: a database, a cache.
- **Typed request context** for an authenticated user and tracing.

### 3. Async handlers and real integrations

- **`async throws` handlers beside synchronous ones.** Async handlers run on an executor owned by the worker and driven by its poller, so an `await` resumes on the worker thread. A synchronous handler keeps today's path. The cost of an async handler that never suspends is measured against a synchronous one before this lands.
- **Cancellation and deadlines.** A reset stream or closed connection cancels the handler's task; a response after disconnect is dropped safely; per-route deadlines.
- **An outbound HTTP client** on the worker's poller.
- **One database adapter.** Open decision: postgres-nio, which brings SwiftNIO threads into every worker process (started in `onStart`, after the fork), or a PostgreSQL client on Garuda's own poller, which keeps one thread per worker and is more work.
- **A bounded pool for unavoidable blocking work**, so a blocking call does not stall the worker.

### 4. Middleware and router composition

- **Grouping, nesting and merging** of routers.
- **Middleware, global and per route**, that can short-circuit, await the handler and transform its response. The chain is compiled at start-up: a request allocates no wrappers.
- **405 with `Allow`** for a known path under the wrong method (the trie already keeps a slot per method at every node), and custom fallbacks.
- **Middleware Garuda ships:** authentication, CORS, tracing (with a logging API: level applied to handler records, level mapping, multi-line records), timeouts, request limits.

### 5. Streaming, SSE, WebSockets

- **Streaming request bodies and responses**, with backpressure reaching the producer: `write` reports a full connection above `--write-high-water`, and a reader waits for more body.
- **Early responses** without buffering the whole upload, and **per-route body limits**. A body limit alone does not make thousands of concurrent buffered uploads cheap.
- **Compression and caching in the sink.** `--compress` (`ResponseEncoder`, with `Vary` and a weakened `ETag`) and `--cache-size` (`ResponseCapture`, `ResponseCachePolicy`) act on handler responses.
- **Server-sent events.**
- **WebSocket handlers.** The engine keeps the handshake, framing (`WebSocketCodec`), UTF-8 checks, `--ws-compress`, pings, timeouts and size limits; the handler sees whole messages.
- **WebTransport handlers** follow on `WTSession`, replacing today's 501. HTTP/3 keeps advertising extended CONNECT and WebTransport throughout.

### 6. Conformance restored, realistic axum benchmarks

- The rest of GARUDA.md's "Coverage waiting on the handler API" comes back.
- Runnable examples: CRUD, authentication, streaming, WebSocket.
- Benchmarks past hello-world against axum: path parameters, JSON in and out, a database round trip, streaming.

## Where it lives

- **`GarudaServer`, the engine's own target.** The public API lives beside the engine it drives, and the `Garuda` library product points at it. A separate module named `Garuda` would collide with the `Garuda` enum every application calls, and would put a module boundary on the per-request path. Engine types stay `internal` wherever the API does not need them.
- **`Sources/garuda`** serves the-benchmarker contract through the public API, so the benchmark measures what applications use.
- **`Sources/GarudaConformance`** holds the routes the end-to-end suites need. It is not benchmarked, and it is not an example to copy.

## Performance gate

A step does not land if it costs the contract more than 5% against the commit before it, measured in the same session (`frameworks.sh`, four workers, 64 connections). `benchmarks/vs-axum.sh` runs after every step. A unit test counts allocations across dispatch for `GET /` and `GET /user/:id` and requires zero.

## Decisions

Taken 2026-09-15 for phase 1, and where the roadmap changes them:

1. **Continuations now, `async` later.** Revised: async handlers are step 3, on a worker-owned executor, and their design is settled in step 1. Continuations stay as the engine's mechanism underneath.
2. **Fixed `req.locals` words for state across a suspension.** Replaced in step 1 by typed request-local storage with an identity check.
3. **`~Copyable` `Request` and `Response`.** Kept, but not enough on its own: the views they hand out become closure-scoped `Span`s in step 1.
4. **The `garuda` binary keeps the benchmark contract; conformance routes live in a separate executable.** Kept.

Open: the database adapter (step 3).
