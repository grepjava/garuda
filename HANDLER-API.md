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

**Design for approval, 2026-09-15.** Step 1 builds the ownership model, the application instance, the test client and the packaging fix. It also settles how the later steps' syntax runs, because that decides what must be owned. The measurements below come from probes on Swift 6.3.3 under WSL2, one million requests each; single figures move by up to 2× between runs there.

#### What an application will look like

Steps 2 to 4 build most of this; step 1 makes it possible.

```swift
import Garuda

let app = Application()

app.onWorkerStart { worker in
    worker.state(try await Database.connect(url: env("DATABASE_URL")))
}

app.get("/") { () in
    "Hello"
}

app.get("/user/:id") { (id: Path<Int>) in                 // no await: a plain call
    JSON(User(id: id.value, name: "Ada"))
}

app.get("/db/user/:id") { (id: Path<Int>, db: State<Database>) async throws(HTTPError) in
    guard let user = try await db.value.user(id.value) else { throw .notFound }
    return JSON(user)
}

app.middleware { request, next async throws in
    guard let user = try await auth.verify(request.header("authorization")) else {
        throw HTTPError.unauthorized
    }
    return try await next(request.with(user))
}

try app.run()
```

```swift
@Test func userIsFound() async throws {
    let response = try await app.test.get("/user/1")
    #expect(response.status == .ok)
    #expect(try response.json(User.self).name == "Ada")
}
```

- **The developer never chooses sync or async.** Each registration method has a synchronous and an `async` overload. A closure with no `await` selects the synchronous one; a closure with an `await` selects the async one. Parameter packs take any number of typed extractors. Checked: five routes, with none, one and three extractors, each selected the expected overload, handed the handler the extracted values, and a `Path<Int>` given `abc` threw.
- **Today's `(borrowing Request, inout Response)` handlers stay** as the raw layer, for proxies, streaming and the benchmark route. The typed API is built on it.

#### How a request runs

1. **The engine parses and routes**, as now.
2. **Extractors run on the worker thread, before any task exists.** They read borrowed request bytes and produce owned values: `Int`, `String`, `Decodable` types. A failure is a typed error and becomes a 400, with no task involved.
3. **A synchronous handler is called inline.** No task and no allocation, which is today's cost.
4. **An async handler runs on a reused handler task.** Each worker keeps a pool of long-lived tasks on an executor owned by its loop. A request resumes an idle one, and it runs in the same loop turn on the same thread. When all are busy a new task joins the pool, up to a bound; past it, requests wait in the ready queue.
5. **Cancellation** (a reset stream, a closed connection) cancels the handler's work, and every resume keeps its `(slot, generation, requestId)` check.

What an async handler costs:

| how the async handler runs | ns per request | allocations per request |
|---|---:|---:|
| a new `Task` per request, loop outside the executor | 1,200–2,250 | 5 |
| `Task.immediate`, loop running as a job on its executor | ~500 | 4 |
| **a reused task from the pool**, no wait | **~360** | **0** |
| a reused task, one wait resumed by the loop | ~660 | 0 |
| a reused task, 4 KiB of locals held across the wait | ~850 | 0 |
| a reused task, five nested async calls | ~1,050 | 0 |

- **An async route costs about 0.4–1 µs and no allocation**, next to a request's ~6 µs of CPU and a database round trip's 100 µs or more. A synchronous route pays nothing.
- **A new `Task` per request is ruled out.** It is 3–6× slower, and allocates.
- **A task created on demand runs inline only when the loop itself runs on the executor**: from outside it, `Task.immediate` with that executor preferred queued all of 1,000,000 tasks instead. The worker loop therefore runs as a job on its own executor.

#### Errors

- **`HTTPError`, thrown with typed throws, allocates nothing.** Measured: `throws(HTTPError)` 0 allocations per request; untyped `throws` 1 for a payload-free error and 3 for one carrying a `String`.
- **Untyped `throws` is still accepted.** It costs its allocations only when an error is thrown.
- **An error that conforms to a response protocol becomes that response.** Any other error is a 500 and a log line.

#### Ownership

- **Borrowed bytes only inside a closure.** The raw `Request` gains `withBody { (span: Span<UInt8>) in … }`, `withPath`, `withQuery` and `withHeader(_:)`, which hand out `Span`s the compiler keeps inside the closure. Checked: a closure that stores its span does not compile ("lifetime-dependent variable 'span' escapes its scope"), with no experimental feature. The accessors that return `ByteSpan` become internal. A `Span`-returning property would need the experimental `Lifetimes` feature and stays out.
- **Owned values for keeping.** `String`, `[UInt8]` and decoded types, made only when asked for.
- **Typed request context instead of `locals`.** Values keyed by type (`request.context[User.self]`), stored with the request's identity and checked on every access, so a context read after the request has ended fails loudly instead of reading another request's data.
- **Tests.** Compile-fail tests, one file per way borrowed data could escape, compiled through SIL diagnostics (`-emit-sil`; `-typecheck` does not run the lifetime checks). Runtime tests for a resume after cancellation and after slot reuse.

#### The application instance and the test client

- **`Application`** owns the routes, middleware, state factories and a programmatic `Configuration`. `app.run()` fills the configuration from the command line unless it was given one, and runs the supervisor. It replaces `Routes`, the global `installedRoutes` and the global `lifecycle`. The compiled route table belongs to the application and is freed when it shuts down; workers still inherit it through the fork.
- **`app.test`** runs a request through routing, extraction, middleware, the handler and the response sink in-process, on a test worker with no socket, and returns the parsed response.
- **`app.test.withServer { url in … }`** starts the application on an ephemeral port for integration tests and shuts it down deterministically.

#### Packaging

- **`-enforce-exclusivity=unchecked` leaves the library targets.** It stays on the executables. The performance gate decides whether library code needs changing to win back what the flag gave.
- **CI builds an external package that depends on Garuda by version** (a tagged `file://` repository, which SwiftPM treats as remote), so `unsafeFlags` cannot creep back.

#### Decisions (taken 2026-09-15)

1. **The module is renamed `Garuda`**, so applications write `import Garuda`. The `Garuda` enum goes; `Application` replaces `Garuda.serve`.
2. **The raw `(borrowing Request, inout Response)` API stays public**, closure-scoped as above, as the zero-copy layer under the typed one.

The probes behind the figures in this section are in [benchmarks/async-probes/](benchmarks/async-probes/).

#### Order of work

1. Packaging, and the module rename if approved.
2. `Application`, `Configuration` and the test client, over today's raw handlers.
3. Ownership: the closure-scoped accessors, the typed request context and the compile-fail tests.
4. The worker executor and the handler task pool, with a unit test that an async handler allocates nothing after warm-up. This is the foundation step 3's async handlers are registered on.

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

- **`async throws` handlers beside synchronous ones**, registered through the overloads and run on the handler task pool that step 1 builds ([How a request runs](#how-a-request-runs)). An `await` resumes on the worker thread; a synchronous handler keeps today's path. The pool's cost, about 0.4–1 µs and no allocation per async request, is measured again on the real engine before this lands.
- **Cancellation and deadlines.** A reset stream or closed connection cancels the handler's task; a response after disconnect is dropped safely; per-route deadlines.
- **Outbound connections on the worker's poller**, built once: TCP, TLS and Unix sockets, DNS, timeouts, cancellation and a per-worker pool. The HTTP client and every database driver use it; none opens sockets of its own.
- **An outbound HTTP client** on that layer.
- **Databases** (decided 2026-09-15):
  - **Drivers are protocol state machines over bytes.** No sockets, threads or poller inside, so each is small, tested against recorded exchanges, and fuzzed like the HTTP parsers.
  - **A common query API** (`query`, `execute`, transactions) decodes rows straight into `Decodable` types with step 2's decoder. Features particular to one database, such as PostgreSQL's `LISTEN` or Redis pub/sub, stay on that driver's own type.
  - **PostgreSQL first**, native on the poller: SCRAM authentication, TLS, the extended query protocol with typed parameters, common column types, a pool per worker. **Redis next**; its protocol is small.
  - **SQLite** through the bounded blocking pool: it is an embedded library doing disk I/O, not a network protocol.
  - **Any other database** through the async bridge with an existing Swift driver, at a thread hop per call, until there is demand for a native one.
  - **Fallback** if the native PostgreSQL driver stalls: libpq in non-blocking mode (`PQconnectStart`, `PQsendQueryParams`, `PQconsumeInput`) on the same poller. It keeps one thread per worker at the cost of a C dependency, and needs a numeric host address so that name resolution does not block.
  - Not chosen: postgres-nio, which brings SwiftNIO's threads into every worker process and a thread hop into every query.
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

Taken 2026-09-15 for the roadmap:

5. **Databases (step 3).** A shared outbound connection layer on the poller, native PostgreSQL then Redis, SQLite on the blocking pool, any other database through the async bridge, and libpq in non-blocking mode as the fallback. Not postgres-nio.
