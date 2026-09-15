# Handler API: design for approval

Status: proposal, 2026-09-15. Nothing here is built. Once approved, it is built in the phases at the end, each one landing with the tests it brings back from GARUDA.md's "Coverage waiting on the handler API" list.

## What it has to keep

- **The synchronous path stays a plain call.** Today's router answers `GET /` with no allocation and no scheduling hop. That is what puts the router at 414k req/s against Hummingbird's 89k (GARUDA.md, step 2). Every rule below serves that.
- **One worker, one thread, no `Task` per request.** Suspension goes through the substrate that already exists (`AsyncOps.swift`): pooled op records, the timer heap, and the ready queue with its 64-resume budget.
- **Identity checks on every resume.** Each resume checks connection `(slot, generation)`, `requestId` and the continuation ticket, so a stale resume never reaches a reused slot.

## Shape

```swift
import Garuda

var routes = Routes()

routes.get("/") { req, res in
    res.send(status: 200)
}
routes.get("/user/:id") { req, res in
    res.send(req.parameter(0))                 // bytes of the id, no String made
}
routes.post("/echo") { req, res in
    res.headers.set("content-type", req.header("content-type") ?? "application/octet-stream")
    res.send(req.body)                         // whole body, buffered up to --max-body
}
routes.get("/delay/:ms") { req, res in
    req.locals[0] = UInt64(req.parameter(0).integer ?? 1)
    res.after(milliseconds: req.locals[0]) { req, res in
        res.send(status: 200)
    }
}

exit(Garuda.serve(routes, arguments: CommandLine.arguments))
```

`Garuda.serve` parses the same flags the `garuda` binary takes, then runs the supervisor. Routes are built before the first fork and inherited by every worker, never mutated after that.

### Routes

- Patterns are compiled at start-up into a byte trie over path segments. Segments can be literal, `:param` or a trailing `*rest`. There is one table per method; HEAD falls back to GET.
- A parameter is an `(offset, length)` span into the request head, so no `String` is made unless the handler asks for one.
- `--root-path` is taken off before matching, as it is now.
- `routes.before { req, res in … }` hooks run in order ahead of the route. A hook either answers or falls through. That is the whole middleware story for now.

### `Request`

`Request` is a `~Copyable` view passed `borrowing`. It holds the worker, slot, generation and request ID, and the compiler stops it outliving the call.

- **Request line:** `method`, `path`, `query`, `target`, `version`, `scheme`, `authority`.
- **Headers:** `header(_:)`, and iteration over all of them as byte spans. Values are the parsed head's slices; HPACK and QPACK headers are rebuilt into the same form.
- **Client:** `remoteAddress` and `remotePort`, with `--forwarded-allow-ips` already applied.
- **Server-assigned:** `requestID`, `traceparent`, and `requestStart` (the kernel arrival time when `--request-start-header` is on, which gives that flag something to feed).
- **Body:** `body` is complete by default. A route can opt into streaming it instead (phase 3).
- **Locals:** `locals` is a fixed per-request block of four `UInt64` stored on the op record. This is how state crosses a continuation without allocating.

### `Response`

`Response` is `~Copyable` too, passed `inout`.

- **One-shot:** `send(status:)`, `send(_ bytes:)` and `send(status:_:)`. They write a `Content-Length` response.
- **Headers:** `status` and `headers.set` / `headers.add`, both valid before the first byte goes out.
- **Streaming:** `start()`, `write(_:) -> WriteResult` and `end()`. On HTTP/1.1 this is chunked; on HTTP/2 and HTTP/3 it is DATA frames through `flushStream` / `flushH3Stream`.
- **Backpressure:** `write` returns `.full` once the connection is above `--write-high-water`. The handler then calls `res.whenWritable { req, res in … }`.

Every response goes through a single engine path, the **response sink**, whatever produced it. Today that logic is scattered or dead; the sink puts it in one place, which is what gives `--compress`, `--cache-size` and `--request-start-header` real work. In order, the sink:

1. **Merges server headers.** A handler's own `X-Request-ID`, `Strict-Transport-Security` or `Alt-Svc` is kept, not doubled.
2. **Frames the response.** `204` and `304` carry no body. HEAD sends the head alone. `Content-Length` is used when known, otherwise chunked or DATA.
3. **Enforces a declared `Content-Length`.** Extra bytes are cut; too few means a reset stream or a closed connection.
4. **Compresses** (`ResponseEncoder`), when the content type is compressible, the body is above the size floor, `no-transform` is absent and there is no `Content-Encoding` already. It then adds `Vary` and weakens the `ETag`.
5. **Captures for the cache** (`ResponseCapture`) when the policy in `ResponseCachePolicy` allows it. `cacheResponded` runs for unsafe methods.
6. **Logs and counts** the request: access log and metrics.

### Suspension

A handler that cannot finish does not return a future. It asks the substrate to call a handler again later:

| call | continuation kind | resumes when |
|---|---|---|
| `res.after(milliseconds:)` | `.timer` (exists) | the deadline passes |
| `res.whenWritable` | `.writable` | the write buffer falls under the high-water mark |
| `req.body.read` | `.bodyReadable` | more request body arrived, or it ended |

- **What a continuation is:** a stored handler value plus the request's identity. Nothing else is kept.
- **What makes a closure free:** a closure that captures nothing, and keeps its state in `req.locals`, costs no allocation.
- **What a capturing closure costs:** it still works, but Swift boxes its context once per suspension. The documentation says so rather than forbidding it.

### Cancellation, errors and lifecycle

- **Cancellation.** A reset stream, an aborted HTTP/3 stream or a closed connection already goes through `cancelOps`. The API adds two things: `res.onCancel { req in … }` for the handler's own cleanup, and `req.isCancelled` for code between suspensions.
- **Errors.** A handler that throws before sending anything gets a `500`, and the connection lives on. After the head has gone out, the stream is reset, or the HTTP/1.1 connection closed.
- **Lifecycle hooks.** `Garuda.serve(routes, onStart:, onShutdown:)` runs its hooks per worker. `onShutdown` runs after in-flight requests have drained or `--graceful-timeout` has passed.
- **Logging.** `Log` is exposed with the same levels, and `--log-level` applies to handler records.

### WebSocket and WebTransport

- **WebSocket.** `routes.webSocket("/chat") { req, ws in … }`, with `ws.onMessage`, `ws.send(text:)`, `ws.send(binary:)` and `ws.close(code:)`.
  - The engine owns the handshake (`pg_sha1`, `pg_base64`), framing (`WebSocketCodec`) and UTF-8 checks (`UTF8Validator`).
  - It also owns `--ws-compress` (`WSDeflate`), pings, timeouts and size limits.
  - The handler only sees whole messages. Delivery is a continuation kind, like any other wait.
- **WebTransport.** `routes.webTransport("/wt") { req, session in … }`, with `session.onStream`, `session.onDatagram`, `session.openStream()` and `session.close(code:reason:)`.
  - It is built on `WTSession` and the HTTP/3 capsule reader, and it replaces today's `501`.
  - HTTP/3 keeps advertising extended CONNECT and WebTransport throughout.

## Where it lives

- **`Sources/Garuda`, a new target.** It holds the public API and is the only module applications import. The `Garuda` library product moves to it. `GarudaServer` stays the engine, with its internals `internal` or `package`.
- **`Sources/garuda`.** It keeps serving the-benchmarker contract, rebuilt on the public API, so the benchmark measures the API applications will use.
- **`Sources/GarudaConformance`, a second executable.** It holds the routes the end-to-end tests need: echo, a header dump, status and header setters, streaming, a throwing route, WebSocket echo, WebTransport echo. The retired checks come back as scripts against it.

## Performance gate

A phase does not land if it costs the router contract more than 5% on GARUDA.md's step-2 zrk table, or on the pinned per-request user time. The comparison is against `e03d073`, measured in the same session. A unit test also counts allocations across `dispatch` for `GET /` and `GET /user/:id`, and requires zero.

## Phases

1. **Routes, `Request`, one-shot `Response`, the response sink, errors, lifecycle hooks.**
   - The router contract moves onto it.
   - Brings back:
     - echo the request body (the buffered cases);
     - read request headers, client address and scheme (including `X-Request-Start`);
     - set status and headers;
     - errors and lifecycle.
2. **Streaming responses, `.writable`, compression and caching in the sink.**
   - Brings back:
     - large and streamed bodies (the whole `--compress` list);
     - cacheable responses.
3. **Streaming request bodies, `.bodyReadable`, cancellation hooks.**
   - Brings back:
     - see cancellation;
     - the backpressure, partial-delivery and early-answer items under "Echo the request body".
4. **Logging API.**
   - Brings back: a logging API.
5. **WebSocket handlers.**
   - Brings back: the WebSocket half of "WebSocket and WebTransport handlers".
6. **WebTransport handlers.**
   - Brings back: the WebTransport half.

## Decisions wanted

1. **Continuations now, `async`/`await` later.**
   - Recommended: handlers suspend through the continuation calls above. Calling an `async` function from the worker's synchronous loop needs a `Task`, which is the hop this design exists to avoid.
   - An `async` facade, with its own executor on the worker, can come later and be measured against this.
   - The alternative: `async` handlers from the start, accepting a task per request that suspends.
2. **State across a suspension.**
   - Recommended: fixed `req.locals`, with capturing closures allowed but documented as allocating.
   - The alternative: closures only, and accept the allocation.
3. **`~Copyable` `Request` and `Response`.**
   - Recommended: the compiler stops a handler keeping either past its call.
   - The alternative: copyable structs with a generation check at run time. Simpler to read, but the misuse only shows up when it happens.
4. **The `garuda` binary keeps the benchmark contract; conformance routes go in a separate executable.**
   - Recommended: this keeps test routes out of what gets benchmarked and shipped.
