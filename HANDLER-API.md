# Handler API

Status, 2026-09-15: phase 1 is implemented. Routes, a `Request` view, a one-shot `Response`, the response sink, errors and lifecycle hooks serve the benchmark contract (`Sources/garuda-server`) and the end-to-end conformance routes (`Sources/GarudaConformance`). A review of that code set the roadmap below, which replaces the earlier phase list.

**The goal of the roadmap:** an application developer can build and test an authenticated JSON CRUD API backed by a database, without touching pointers, integer state slots, manual JSON or engine internals.

**The measure:** [axum](https://github.com/tokio-rs/axum), in usability and in speed. The first quick comparison is in [BENCHMARKS.md](BENCHMARKS.md#against-axum-quick-comparison).

## What it has to keep

- **A handler that can finish synchronously is a plain call.** No allocation, no `Task`, no scheduling hop for `GET /`. That is what serves the contract at 1.95× axum on the suite's ramp.
- **One worker, one thread.** Each worker is a forked process with one poller. Suspended work resumes on that thread.
- **Identity checks on every resume.** Each resume checks connection `(slot, generation)`, `requestId` and the continuation ticket, so a stale resume never reaches a reused slot.
- **Pointer-based operations stay available inside the engine.** Ordinary application code should not need them.

## What phase 1 delivers

```swift
import Garuda

let app = Application()

app.get("/") { _, response in
    response.send(status: 200)
}
app.get("/user/:id") { request, response in
    request.withParameter(0) { response.send($0) }   // the id's bytes, lent, no String made
}
app.post("/echo") { request, response in
    request.withHeader("content-type") { response.addHeader("content-type", $0) }
    request.withBody { response.send($0) }          // the whole body, buffered up to --max-body
}
app.get("/delay/:ms") { request, response in
    let ms = UInt64(min(5000, max(1, request.withParameter(0) { $0.integer } ?? 1)))
    response.after(milliseconds: ms) { _, response in
        response.send(status: 200)
    }
}

exit(app.run())
```

This is the phase-1 API as step 1 has reshaped it so far: the routes and hooks belong to an `Application`, and the module is `Garuda`.

- **Routes.** `get`, `head`, `post`, `put`, `delete`, `patch`, `options` and `on`. Segments are literal, `:param` or a trailing `*rest`. Patterns compile into a byte trie when the application first runs or is tested: literal before parameter before rest, with backtracking, HEAD falling back to GET, at most eight parameters. `--root-path` is taken off before matching.
- **`Request`**, a `~Copyable` view passed `borrowing`: `method`, `path`, `query`, `parameter(_:)`, `version`, `scheme`, `authority`, `header(_:)`, `forEachHeader`, `body`, `remoteAddress` and `remotePort` (with `--forwarded-allow-ips` applied), `requestID`, `requestStart` (kernel arrival under `--request-start-header`). Bytes are lent to closures (`withPath`, `withParameter`, `withHeader`, `withBody` and the rest) and copied on request (`path`, `parameter(_:)`, `header(_:)`, `body`); `request[context:]` holds typed values for the request.
- **`Response`**, `~Copyable`, passed `inout`: `status`, `addHeader`, `send(status:)`, `send(status:_:)` for bytes, strings and arrays, and `after(milliseconds:then:)`.
- **The response sink.** Every response goes through one engine path. It merges the server's headers without doubling a handler's own `X-Request-ID`, `Strict-Transport-Security` or `Alt-Svc`. It frames 204, 304 and HEAD. It enforces a declared `Content-Length`: extra bytes are cut, too few reset the stream or close the HTTP/1.1 connection.
- **Errors.** A handler that throws, or returns without answering, gets a 500; the connection lives on.
- **Lifecycle.** `app.onWorkerStart` hooks run in each worker before it reports ready, and `app.onWorkerShutdown` hooks after its loop ends.
- **Running and testing.** `app.run()` parses the command line; `app.run(configuration:)` takes a `ServerConfig` through the same checks. `app.test` serves the routes from a worker in the test process over a socket pair, with no port.

## What phase 1 gets wrong

Checked against the code:

- **Borrowed data escapes.** `Request` is `~Copyable`, but `body`, `path`, `parameter(_:)` and `header(_:)` returned `ByteSpan`, a copyable struct holding a raw pointer. A handler could keep one past the request, and read another request's bytes through it. Fixed in step 1: the bytes are lent to closures as `Span`s, and `scripts/compile-fail-test.sh` checks that storing, returning or capturing one does not compile.
- **`RequestLocals` was a copyable raw `Connection` pointer** with no request-identity check, holding four `UInt64` words. Fixed in step 1: `request[context: Key.self]` holds typed values tagged with the request.
- **Handlers are synchronous.** The only suspension is a timer. There is no way to await a database query or an HTTP request. Half fixed in step 3: a handler may now be `async throws` and runs on the worker's task pool, but until outbound I/O lands there is still nothing to await but a timer.
- **Everything is bytes.** Parameters are positional and still percent-encoded; query strings and bodies are raw; there is no JSON. `garuda-conformance` hand-writes query decoding and JSON output.
- **No application state.** Lifecycle hooks return nothing, and a failing `onStart` cannot stop start-up.
- **No composition.** No middleware, nesting or merging. A known path under the wrong method gets the same 404 as an unknown path.
- **No streaming.** The body is buffered whole before dispatch, and `send` is one-shot.
- **Hard to test.** `Garuda.serve` installed process-global routes that lived forever, read the process arguments and ran the supervisor. Fixed in step 1: `Application` owns its routes and hooks, `run(configuration:)` needs no command line, and `app.test` runs requests in-process.
- **Not usable as a versioned dependency.** Every target applied `unsafeFlags(["-enforce-exclusivity=unchecked"])`, and SwiftPM refuses them in a package depended on by version: "the target 'GarudaServer' in product 'Garuda' contains unsafe build flags". Fixed in step 1.

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
- **A task created on demand runs inline only when the loop itself runs on the executor**: from outside it, `Task.immediate` with that executor preferred queued all of 1,000,000 tasks instead. The pool does not create tasks per request, so the loop stays plain code and drains the executor itself: handing a request to a task, or waking one from a wait, is followed by a drain in the same turn.

#### Errors

- **`HTTPError`, thrown with typed throws, allocates nothing.** Measured: `throws(HTTPError)` 0 allocations per request; untyped `throws` 1 for a payload-free error and 3 for one carrying a `String`.
- **Untyped `throws` is still accepted.** It costs its allocations only when an error is thrown.
- **An error that conforms to a response protocol becomes that response.** Any other error is a 500 and a log line.

#### Ownership

- **Borrowed bytes only inside a closure.** The raw `Request` gains `withBody { (span: Span<UInt8>) in … }`, `withPath`, `withQuery` and `withHeader(_:)`, which hand out `Span`s the compiler keeps inside the closure. Checked: a closure that stores its span does not compile ("lifetime-dependent variable 'span' escapes its scope"), with no experimental feature. The accessors that return `ByteSpan` become internal. A `Span`-returning property would need the experimental `Lifetimes` feature and stays out.
- **Owned values for keeping.** `String`, `[UInt8]` and decoded types, made only when asked for.
- **Typed request context instead of `locals`.** Values keyed by type (`request[context: User.self]`), stored with the request's identity and checked on every access, so a context read after the request has ended fails loudly instead of reading another request's data.
- **Tests.** Compile-fail tests, one file per way borrowed data could escape, compiled through SIL diagnostics (`-emit-sil`; `-typecheck` does not run the lifetime checks). Runtime tests for a resume after cancellation and after slot reuse.

#### The application instance and the test client

- **Landed so far:** `Application` with its routes and worker hooks, `run()` and `run(configuration:)` over a `ServerConfig` checked as the command line is, and `app.test`, a worker in the test process driven over a socket pair. Then ownership: the lent-bytes accessors, owned copies, `request[context:]`, and six compile-fail checks in `Tests/CompileFail` run by `scripts/compile-fail-test.sh`. Then the handler task pool (`Sources/Garuda/HandlerTasks.swift`): a `TaskExecutor` per worker that runs jobs only on the worker's thread, long-lived tasks that prefer it (up to 1,024 per worker, then a queue), an engine wait (`Response.sleep`) that a closed connection or reset stream cancels, and a unit test that counts heap allocations on the worker's turns: none per request, after warm-up, for a synchronous route, an async route, or an async route that waits once. Async handlers stay internal until step 3. Middleware and state factories arrive with steps 2 and 4.
- **`Application`** owns the routes, middleware, state factories and a programmatic `Configuration`. `app.run()` fills the configuration from the command line unless it was given one, and runs the supervisor. It replaces `Routes`, the global `installedRoutes` and the global `lifecycle`. The compiled route table belongs to the application and is freed when it shuts down; workers still inherit it through the fork.
- **`app.test`** runs a request through routing, extraction, middleware, the handler and the response sink in-process, on a test worker with no socket, and returns the parsed response.
- **`app.test.withServer { url in … }`** starts the application on an ephemeral port for integration tests and shuts it down deterministically.

#### Packaging

- **No target sets unsafe flags.** Done: `-enforce-exclusivity=unchecked` is gone from `Package.swift`, and it was not worth keeping. At 64 connections, four workers, one round, the default build served 382,793 requests a second against 384,994 with the flag, 0.6% less.
- **CI builds an external package that depends on Garuda by version** (the `dependency` job: a tagged `file://` repository, which SwiftPM treats as remote), so unsafe flags cannot creep back.

#### Decisions (taken 2026-09-15)

1. **The module is renamed `Garuda`**, so applications write `import Garuda`. The `Garuda` enum goes; `Application` replaces `serve`.
2. **The raw `(borrowing Request, inout Response)` API stays public**, closure-scoped as above, as the zero-copy layer under the typed one.

The probes behind the figures in this section are in [benchmarks/async-probes/](benchmarks/async-probes/).

#### Order of work

1. Packaging, and the module rename if approved.
2. `Application`, `Configuration` and the test client, over today's raw handlers.
3. Ownership: the closure-scoped accessors, the typed request context and the compile-fail tests.
4. The worker executor and the handler task pool, with a unit test that an async handler allocates nothing after warm-up. This is the foundation step 3's async handlers are registered on. Landed.

### 2. Typed extraction, responses, errors and state

**Landed 2026-09-16.** All five sub-steps under [Order of work](#order-of-work-1) are in the tree: the JSON coder, typed answers and errors, typed extraction, typed per-worker state, and forms with multipart. What is left for later steps: the rest of step 3 — cancellation and deadlines, outbound connections, an HTTP client and the databases — then middleware and 405 (4), streaming (5).

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

#### Order of work

1. **The JSON coder.** Landed: `JSONCoder.encode` and `JSONCoder.decode` over the standard library's `Encodable` and `Decodable`, in `Sources/Garuda/JSON*.swift`. The writer streams, closing containers as the document goes out rather than building a tree; the reader proves the document is JSON once and then reads only where the type asks, walking an object's members instead of copying them into a dictionary. Nesting is bounded at 64 both ways. 18 unit tests, and a fuzz target (`json`) whose invariant is that a document which decodes encodes again and reads back as the same value.
2. **Typed responses and errors.** Landed: `HTTPStatus` (`response.send(status: .created, json: user)`, `response.status == .ok`, and an integer literal wherever a status is wanted, so a number nobody named still works); `send(json:)`, `send(text:)`, `send(html:)`, `send(bytes:contentType:)` and `redirect(to:status:)`, each setting the content type it implies unless the handler set one; and `ResponseError`, which a thrown error conforms to in order to become the answer. `HTTPError(.conflict, "the name is taken")` answers 409 with `{"error":"the name is taken"}`, and `JSONError` conforms too, so a body that is not what it claimed is a 400 saying which key, wherever it is decoded. An error that conforms is an answer, not a fault, so it is not logged as one; anything else is still a 500 and a log line. JSON answers encode into a buffer the worker keeps.
3. **Typed extraction.** Landed: a handler declares what it needs and returns what it means — `app.get("/user/:id") { (id: Path<Int>) in JSON(user(id.value)) }`. Registration is generic over a pack of `RequestExtractor`s, so a handler takes none, one or several. `Path<Value>` takes the next path parameter, percent-decoded; `Query<Value>` decodes the whole query string into a type (a repeated name is a list, an absent one is nil where the type allows it, `+` is a space); `Body<Value>` decodes the JSON body. What the handler returns writes itself: `JSON`, `HTML`, `Text`, `Bytes`, `Redirect`, a `String`, an `HTTPStatus`, or an Optional whose nil is the ordinary 404. Every failure is one shape — a 400 whose body names what was wrong — because `ExtractionError`, `QueryError` and `JSONError` all conform to `ResponseError`. The raw `(borrowing Request, inout Response)` handlers register through the same names and never compete with these, since a request and a response are not a pack of extractors.
4. **Typed application state.** Landed: `app.state { worker in try Database.connect(…) }` registers a factory that runs once in each worker, after the fork and before that worker reports ready, and `State<Database>` hands what it built to any handler that asks for it — beside the other extractors, in any order. One value per type. A factory that throws stops that worker's start-up with its error: the child exits 1 and the supervisor sees the readiness pipe hang up, rather than a worker serving without what it needed. An optional `shutdown:` runs when the worker's loop has ended, newest first. Asking for state nobody registered is a 500 naming the type, since that is the program's fault and not the client's. The test client builds and tears down state exactly as a worker does, so a test exercises the same path.

   **Fork semantics.** Each worker is a process, so what a factory builds belongs to that worker alone: a pool per worker, not one shared between them. An object captured before the fork is copied into each worker, not shared with the others. State every worker must see lives outside the process — a database, a cache.
5. **Forms, then multipart.** Landed: `Form<Value>` decodes an `application/x-www-form-urlencoded` body — a query string in the body, so it goes through the same reader, with `+` a space, `%XX` undone, a repeated name a list and an absent one nil where the type allows it. `Multipart` cuts a `multipart/form-data` body into its parts, each with its name, the client's filename when it sent one, its own content type and its bytes, reachable as `form.text("title")`, `form.file("avatar")` and `form.all("tag")`. The engine has already read the body whole, up to `--max-body`, so this is a parse over bytes in hand rather than a stream, bounded by that limit and by a cap of 1,000 parts; streaming uploads wait for step 5 of the roadmap. A body sent as the wrong kind of document is a 415 rather than a 400, since sending the wrong kind is not the same as sending a malformed one.

### 3. Async handlers and real integrations

**Started 2026-09-16.** Async handlers, cancellation and deadlines, outbound connections with TLS, DNS and a pool, and the HTTP client are in the tree. The databases and the blocking pool are not.

- **`async throws` handlers beside synchronous ones.** Landed: the same names register a handler that awaits — `app.get("/user/:id") { (id: Path<Int>) async throws in JSON(try await load(id.value)) }` — beside one that does not, with the extractors and return values of step 2 unchanged. A closure that does not await is not async, so it takes the synchronous overload and today's path; one that does runs on the handler task pool step 1 built, where every resumption is back on the worker's own thread, which the executor asserts rather than assumes. Extraction happens before the handler body, in the order declared, so a bad parameter is still the 400 it was. A thrown `ResponseError` is the answer from a task exactly as from a synchronous handler, and anything else is a 500 and a log line. `Response.sleep(milliseconds:)` waits on the worker's own timers.
- **Cancellation and deadlines.** Partly landed: a reset stream or closed connection already cancels a handler waiting on the engine, which resumes to throw and unwind. A handler waiting on anything else cannot be unwound, so it resumes to find its request gone — `response.isCancelled` says so, and every `send` and `addHeader` is checked against the request the handler was given, so a late answer is dropped rather than sent to whoever has since taken the slot. Deadlines land with it: `app.deadline(milliseconds: 500) { … }` gives every route registered inside it a limit, a request still unanswered that long after dispatch is answered 504, and a handler waiting on the engine for it is unwound. A deadline bounds **waiting, not computing** — a worker is one thread, so nothing preempts a handler that loops without awaiting, and such a handler still stops its worker. A deadline that fires while the handler is running leaves it running: the client has its answer, and everything the handler does afterwards is dropped in silence, with `isCancelled` telling it so if it asks. 504 rather than 503, because 503 already means "this worker is out of capacity, route elsewhere" — the drain and health probes and both pool-exhaustion answers — and a slow route is not that.
- **Outbound connections on the worker's poller.** Started: TCP and Unix sockets connect without blocking, on the worker's own poller and thread, with a bounded wait for coming up and for readability or writability afterwards. They live in a table of their own rather than among the accepted connections, because `quiescent` is `table.liveCount == 0` and a pooled outbound connection there would stop a draining worker ever finishing. Names are refused, not resolved: `getaddrinfo` blocks, and blocking the worker is the one thing this layer exists to avoid, so naming belongs in the layer above. Landed with it: outbound TLS that verifies the name — or the address — asked for, with the ALPN offer part of a pooled connection's identity; a DNS resolver on the poller (resolv.conf, UDP with TCP fallback, a TTL cache) rather than `getaddrinfo`; connect-by-name trying every address; and a per-worker pool that keeps only connections left clean.
- **An outbound HTTP client** on that layer. Landed: `request.client`, HTTP/1.1 over plaintext and HTTP/1.1 or HTTP/2 over TLS as ALPN decides. An HTTP/2 connection is shared by every request to the same place — the read is a baton passed between waiting requests rather than a task of its own, because a connection-lifetime task would outlive a drain, and a burst of requests to somewhere new waits on one connect rather than each opening its own. It does not follow redirects or send `Accept-Encoding`.
- **Databases** (decided 2026-09-15). PostgreSQL landed: the wire protocol, SCRAM-SHA-256 and the session and query machines in `GarudaPostgres` as byte-level state machines; the socket layer and a per-worker `PostgresPool` in `Garuda`; rows decoded into `Decodable` types; transactions, with a connection left mid-transaction never pooled. Not yet: binary formats, `LISTEN`, Redis, SQLite.
  - **Drivers are protocol state machines over bytes.** No sockets, threads or poller inside, so each is small, tested against recorded exchanges, and fuzzed like the HTTP parsers.
  - **A common query API** (`query`, `execute`, transactions) decodes rows straight into `Decodable` types with step 2's decoder. Features particular to one database, such as PostgreSQL's `LISTEN` or Redis pub/sub, stay on that driver's own type.
  - **PostgreSQL first**, native on the poller: SCRAM authentication, TLS, the extended query protocol with typed parameters, common column types, a pool per worker. **Redis next**; its protocol is small.
  - **SQLite** through the bounded blocking pool: it is an embedded library doing disk I/O, not a network protocol.
  - **Any other database** through the async bridge with an existing Swift driver, at a thread hop per call, until there is demand for a native one.
  - **Fallback** if the native PostgreSQL driver stalls: libpq in non-blocking mode (`PQconnectStart`, `PQsendQueryParams`, `PQconsumeInput`) on the same poller. It keeps one thread per worker at the cost of a C dependency, and needs a numeric host address so that name resolution does not block.
  - Not chosen: postgres-nio, which brings SwiftNIO's threads into every worker process and a thread hop into every query.
- **A bounded pool for unavoidable blocking work**, so a blocking call does not stall the worker.

### 4. Middleware and router composition

**Started 2026-09-16.** Landed: 405 with `Allow`, found by asking the router once per method so the union across routes a path can reach is exact; `group(prefix)` with nesting; `use(middleware)` scoped to the enclosing group and independent of registration order, compiled into each route's handler at start-up with routes that have none left untouched. A middleware runs before the handler and can short-circuit or add headers, and may itself be async (`use` takes an async closure; the sync prefix of the chain stays on the worker, and from the first async middleware on the rest of the chain and the handler share one task). It sees the answer through `response.onSend`, a hook the response sink runs before the head is written — status, headers and body can all change — rather than by wrapping the handler: handlers answer into the sink and async ones answer later, so a `next(request)` that returns a response value (tower's model) would mean buffering every response, and was rejected on 2026-09-16 for that cost. `Context<Key>` hands what middleware stored to typed handlers. Not yet: router values to merge, custom fallbacks, and the middleware Garuda ships.

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
- **WebTransport handlers.** Landed 2026-09-16, first in step 5 because axum cannot serve WebTransport at all. `app.webTransport(pattern) { (session, extractors…) async throws in }`: middleware and extractors run on the CONNECT, so they refuse a session with an ordinary status, and the session is accepted when the handler is called. `WebTransportSession` accepts and opens streams, sends and receives datagrams and closes with a code; `WebTransportStream` reads, writes (waiting above `--write-high-water`), finishes and resets. Waits are continuations on the session and its streams, resumed from the frame loop. The session comes first in the handler because Swift will not pass arguments after a parameter pack. The stream shape here is what streaming bodies, SSE and WebSockets should follow. The engine side is Peregrine's, restored; `scripts/webtransport-test.py` (46, aioquic) covers it.

### 6. Conformance restored, realistic axum benchmarks

- The rest of GARUDA.md's "Coverage waiting on the handler API" comes back.
- Runnable examples: CRUD, authentication, streaming, WebSocket.
- Benchmarks past hello-world against axum: path parameters, JSON in and out, a database round trip, streaming.

## Where it lives

- **`Garuda`, the engine's own module** (`Sources/Garuda`). The public API lives beside the engine it drives, so there is no module boundary on the per-request path, and applications write `import Garuda`. Engine types stay `internal` wherever the API does not need them.
- **`Sources/garuda-server`** serves the-benchmarker contract through the public API, so the benchmark measures what applications use.
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
