# Handler API

The design of Garuda's handler API, and the decisions behind it.

**The goal:** an application developer can build and test an authenticated JSON
CRUD API backed by a database, without touching pointers, engine internals or
hand-written JSON.

**The standard:** a server and framework that holds up in production, to be
chosen on its merits: correct under every protocol it speaks, safe by
construction, pleasant to write in, and fast. The README compares it with axum
feature by feature, and [BENCHMARKS.md](BENCHMARKS.md) has the measurements.

Garuda 2 runs on [Vega](https://github.com/grepjava/vega)'s work-stealing
runtime. The application API is largely Garuda 1's; the engine underneath, the
process model and some of the decisions below are not.

## Principles

- **One handler API, and it is async.** A handler that never awaits converts
  to it, and runs inline in the task that read the request: no task is made
  for it and nothing is allocated. A unit test holds a plain route, a typed
  `Path` route and a middleware chain to zero allocations per request.
- **Shards of threads.** A shard is a process running a work-stealing runtime
  over several threads. A suspended handler may resume on any thread of its
  shard, and never on another shard. A crash takes down one shard's
  connections, and the supervisor starts the shard again.
- **Borrowed bytes cannot escape.** What the request lends, the compiler keeps
  inside the closure it was lent to.
- **The connection owns the response path.** A handler, or the value it
  returns, writes the status, headers and body into the connection's exchange.
  Nothing is written to the wire until the handler and its middleware have
  returned, or a streamed body starts. So middleware can still change the
  response after `next`, and no response is built as a value and copied out.
- **Slow handlers get at most half the threads.** A route that holds its
  thread for long runs in the heavy lane, so quick requests always have
  threads left to run on.

## How a request runs

1. **The connection reads and parses.** HTTP/1.1 runs one task per
   connection, which reuses one exchange for every request on it. HTTP/2 and
   HTTP/3 decode each stream's request into an exchange of the stream's own,
   so routing, middleware and extractors see the same request either way. The
   body is collected whole before dispatch and held to the body limit.
2. **Some requests are answered before routing**, when the server is
   configured for it: the health check, the rate limit, static files and the
   response cache.
3. **The route table matches.** Routes compile into one flat table. At each
   segment a literal is tried before a parameter, and a parameter before a
   trailing `*rest`, with backtracking. No route means the scope's fallback
   if there is one, then 404. A path routed only for other methods is 405
   with `Allow`, or a CORS preflight answer.
4. **A heavy route waits for a heavy-lane permit.**
5. **Middleware runs**, composed into each route's handler when the
   application compiles. A route with none keeps its own handler.
6. **Extractors run** in the order declared, reading lent bytes and producing
   owned values. A failure is a `ResponseError`: 400 for a path parameter,
   query or JSON body that will not decode, 415 for a form or multipart body
   sent as something else, and 422 for a value that breaks its type's rules.
7. **The handler is called.** On HTTP/1 it runs in the connection's task. On
   HTTP/2 and HTTP/3 it runs in a task from the shard's pool, so a handler
   that waits holds up no other stream. There is one exception: a route that
   has run many times without suspending, and is not heavy, is answered where
   its request was read. On HTTP/2 that is the connection's reader, when the
   stream is the connection's only one; on HTTP/3 it is the endpoint. A typed
   handler's return value writes itself into the response.
8. **The connection writes the answer.** It runs the `onSend` hooks and adds
   the server's headers (Date, Server, and Alt-Svc, Strict-Transport-Security
   and X-Request-ID where configured). It sets Content-Length from the body
   and frames it. A Content-Length, Transfer-Encoding or Connection header
   the handler set is dropped, since the server owns framing and the
   connection; a streamed body is the exception, where a declared
   Content-Length is honoured. A handler that returns without answering is
   answered 500, with a line in the log.
9. **Cancellation.** On HTTP/2 and HTTP/3, a stream the client resets has its
   task cancelled, so a handler waiting on I/O or a sleep stops waiting, and
   whatever it answers is dropped. A cancelled task is not reused. On
   HTTP/1, nothing interrupts a handler whose client has gone. A streamed
   write throws `HandlerWaitError.cancelled` once the client is gone, and
   any other answer goes nowhere.

## Decisions

### Two layers: raw and typed

The raw handler, `(borrowing Request, borrowing Response) async throws`, is
public and zero-copy, for proxies, streaming and hot paths. The typed API is
built on it. Both register through the same names, and they never compete: a
closure taking a request and a response is not a pack of extractors returning
a response. Typed registration is generic over a parameter pack of
extractors, so a handler may take none, one or several.

```swift
import Garuda

let app = Application()

// Raw: the request's bytes lent, the answer written into the response.
app.get("/echo/:word") { request, response in
    request.withParameter(0) { response.send($0) }
}

// Typed: values extracted in, a value returned.
app.get("/pair/:a/:b") { (a: Path<String>, b: Path<Int>) in
    "\(a.value)-\(b.value)"
}

app.run()
```

There are no synchronous overloads. Garuda 1 needed them to keep a handler
that does not wait off its task pool. Here a handler that does not suspend
already runs inline, so one async signature costs it nothing.

### Ownership

`Request` and `Response` are `~Copyable` views of the connection's exchange,
and a handler cannot keep either past its return. Bytes are lent as
`Span<UInt8>` to a closure (`withBody`, `withPath`, `withQuery`,
`withParameter`, `withHeader`). A span that would escape does not compile,
with no experimental feature needed. Owned copies (`path`, `query`,
`parameter(_:)`, `header(_:)`, `body`, decoded types) are made only when asked
for. Holding the request across an `await` is safe: the task that owns the
connection's buffer is the one suspended in the handler, so nothing moves
underneath it, whichever thread it resumes on.

`scripts/compile-fail-test.sh` compiles code that tries to keep request data
past where it is lent, and expects each attempt to fail. It compiles through
`-emit-sil`, since `-typecheck` does not run the lifetime checks.

Request context (`request[context: Key.self]`, `Context<Key>`) is keyed by a
`RequestContextKey` type. The first four values live in the exchange itself,
and the context is cleared before the next request on the connection, so a
value never reaches another request.

### Errors

A thrown error conforming to `ResponseError` is the answer, and is not logged
as a fault. Its body is `{"error":"…"}`, or no body when its `reason` is nil.
`HTTPError` is the ordinary one: a status and an optional reason. Anything
that is not a `ResponseError` is a 500 and a log line, with nothing about it
told to the client.

An error that knows which field is at fault says so, and the body carries
`fields` beside `error`. The alternative was a message per error and a client
that parses English. Naming the field costs one array that is usually empty,
and lets a form mark the input that was refused. JSON decoding errors and
validation both fill it.

### Validation is a conformance, not a call at the route

Rules beyond a type's shape live on the type, as `Validated`, and `Body`,
`Query` and `Form` hold whatever they decode to them. The conformance is the
opt-in: there is no `validate` at each route to forget, and no annotation to
scan for. A type with no rules pays one failed cast per extraction.

Every broken rule is answered, not the first, because a form with three wrong
fields should not be filled in three times. The status is 422 rather than 400
to keep two different failures apart. A body that is not the type means the
client is building its request wrongly. A body that is the type, with a value
this application will not take, means the client is fine and the value is
wrong.

### A route that cannot work is found before serving

`Path` takes path parameters by position, and `State<T>` takes what
`app.state` built. Both can be asked for and not be there, and both would
answer 500 to whoever sent the request that found out. Neither is a runtime
condition. The handler's parameter types and the route's pattern are known
when the route is registered, and the state factories are known before any
shard starts.

`app.problems()` compares them, and `run()` logs every problem at once and
exits with status 2 rather than serve. It is a list rather than a throw so
that a test can assert on it.

What it will not find is what is not declared. A middleware calling
`request.state(T.self)` makes a call in a closure, and an optional extractor
is a route saying it can do without. Both keep the answer they had: a missing
state is a 500 naming the type, and `State<T>?` is nil.

### Authorization is a rule with a name

A `Policy` is `(Value) -> Bool` and a name for what it requires, and
`authorize` is middleware that applies one to a scope. Two things follow from
the name: the 403 says what would have been enough, and the OpenAPI document
can say it too. Two follow from it being a plain function: a rule is tested
without a server, and rules combine (`and`, `or`, `about`) with their names
combining as well.

A policy cannot await, because a rule that has to ask something is a
different thing. `authorize` has a closure form for that. A rule about the row
a handler works on belongs in the handler, which has already loaded the row,
and throws `AuthorizationError(needs:)` to answer the same way. The split
keeps the common rule (a role, a scope, a flag on the account) free of I/O on
every request in the scope.

`authenticate` and `authorize` describe their scope's routes through
`describeRoutes`, which adds to the OpenAPI entry of every route in a scope.
It is applied as the document is written rather than at registration, so a
rule covers the routes registered before it as well, the way `use` does.

### State and shards

`app.state` runs a factory in each shard, after the shard starts and before
it accepts a connection. What it builds belongs to that shard, and every
thread of the shard shares it, which is why it must be `Sendable`. Factories
run in the order registered, so a later one can read an earlier one's value
through `start.state(T.self)`. `onShardStart` hooks run after them, and
`onShardStop` hooks and each state's `shutdown` run when the shard has
stopped serving. A factory or start hook that throws stops that shard's
start-up, and the supervisor tries again.

On Linux shards are forked; on macOS each shard runs the executable again.
Either way, an object made before `run` is a separate copy in each shard,
not shared. State every shard must see lives outside the processes, in a
database or in one of the shared regions the server maps for its own use
(the rate limit, the response cache, metrics and topics). With `--shards 0`,
the default on macOS and Windows, there is one shard, in the process itself.

Under the exec launch every shard runs `main` again up to `run`, so the
routes an application registers must come out the same every time.

### Middleware is an onion, and keeps a send hook

A layer is `handle(request, response, next:)`. It runs before the layers
inside it and gets the response back after them. It can answer and not call
`next`, change the status or headers after `next`, or catch what the handler
threw: a retry, a transaction rolled back. Garuda 1 could not do this,
because its handlers answered into the connection whenever they finished.
Here the head is not written until the chain returns, so a layer can change
the response on the way out. `next` cannot escape the call, so the chain
allocates nothing. `use` covers its whole scope wherever in the scope it is
called. Global middleware is outermost, then each group's, from the outside
in.

`response.onSend` stays, for what a layer cannot see after `next`: an answer
made once it has unwound, such as the 500 for a handler that threw past it,
or the answer to a handler that never answered. Hooks run once, when the
status, headers and body are final and before the head is written. The hook
registered last runs first.

### Sessions write when they change

A session change is written to the store when the handler makes it:
`try await session.set(…)` returns once the store holds it. Saving once at
the end would leave a gap: a save after the response could land after the
client's next request had read the old data, and a streamed response's head
goes out before the handler returns. So a handler that changes several keys
uses `session.update { … }` for one write. The cookie for a new ID is added
by a send hook as the head is made, which is why the session changes before
the answer.

A `MemorySessionStore` belongs to one shard. With more than one shard, a
client's next request can reach a shard that never saw its session, and the
server warns of this as it starts. GarudaRedis and GarudaSQLite have stores
for that case.

### CSRF protection reads Fetch Metadata, not tokens

`app.csrfProtection` decides from Sec-Fetch-Site, and from Origin against
Host when a browser sends no Sec-Fetch-Site. Every current browser sends one
or the other on a request that changes something. A synchronizer token needs
a session and a field in every form; a double-submit cookie needs both.
Either way the server does work to check what the browser already says. A
request with neither header was not made by a browser page, and passes: the
attack is a page using the browser's cookies, not a client that has them.

### OpenAPI schemas are read by decoding, not by macros

utoipa and aide derive schemas with macros on each type. Garuda gets them from
the `Decodable` conformance the route already needs: a recording decoder
decodes the type once with placeholders and writes down which keys it asked
for, of which types, and which with `decodeIfPresent`. Nothing is annotated,
and the schema cannot drift from what the route actually decodes. What
decoding cannot show (a custom `init(from:)` that parses a string) a type
states with `OpenAPISchemaDescribing`. Route methods return an
`OpenAPIOperation` for the rest, so a summary sits beside the route it
describes.

### `@JSON` is a macro, where schemas are not

The section above gets OpenAPI schemas out of the `Decodable` conformance a
route already has, and does not ask anyone to annotate a type. Reading and
writing JSON is the one place that argument does not hold, and the difference
is what the compiler can be asked for. A schema is a description, and decoding
a type once with a recording decoder produces it exactly. Speed is not a
description: `Codable` decides at run time what a macro can decide at compile
time (which member comes next, what type it is, where it goes), and no amount
of reading the conformance recovers that. On the JSON workload, generated
conformances take about a fifth off the time a request takes.

So `@JSON` writes the `JSONReadable` and `JSONWritable` conformances out, and
is opt-in twice over. A type without it is decoded and encoded exactly as
before, and an application that does not import `GarudaJSON` never builds a
macro plugin at all. That is why it is a separate module rather than part of
`Garuda`.

It refuses rather than guesses. A dictionary or a set member, whose order
nothing fixes; a generic struct, whose conformance would need constraints; an
initializer in the body, which replaces the memberwise initializer the
generated reader delegates to: each stops the build with a message naming
what to write instead. The alternative, falling back to `Codable` for the
shapes it cannot do, would be the worst of both: the type looks opted in and
is not, and nothing says so.

A `CodingKeys` and an `encode(to:)` of the type's own are refused for a
sharper reason. They are not shapes the macro cannot manage, but instructions
it would silently overrule. The generated code takes precedence over
`Codable`, so a type whose `CodingKeys` sent `display_name` would go on
sending `display_name` through `JSONDecoder` and start sending `name` through
a route, and a member the keys left out would start being published. Adding
an attribute for speed must not change what a type sends, so both stop the
build. Name the members what the JSON calls them, or leave `Codable` to do it
alone. The same applies to `@PostgresRow` (in `GarudaSQL`), which reads each
property from the column of its own name: with a `CodingKeys` in the way,
which column that is would depend on which path ran.

Both branches of a `#if` count. A macro is expanded before the branches are
chosen, so it cannot know which one this build takes, and a `CodingKeys` that
only a debug build compiles is refused along with the rest. A type whose JSON
depended on the configuration is worse than one that will not build. What
cannot be caught is a declaration outside the type's body: an extension is
invisible to any macro, which is the reason not to pair either attribute with
a `Codable` form written by hand.

### CORS is a policy of a scope, not a middleware in order

`app.cors` does not take a place among the `use` calls. The innermost scope's
policy runs in front of all of a route's middleware. A browser's preflight
carries no credentials, so authentication in front of it would refuse every
preflight. And a 401 from that authentication needs
Access-Control-Allow-Origin, or the page cannot read it. A preflight to a
path routed only for other methods is answered from the 405 branch of
dispatch, using the policy of one of the routes the path does have, so a CORS
route needs no OPTIONS route of its own.

### Deadlines return 504

`app.deadline` answers 504, not 503. Garuda uses 503 for "this server cannot
take this now": a scope's `concurrencyLimit` reached, and the health check
while the server drains. A slow route is not that.

The routes inside `app.deadline(limit) { … }` run under Vega's I/O deadline
(`Runtime.withIODeadline`). A socket, pipe or database wait still pending when
the time is up gives up with `IOError.timedOut`, and so does any that would
start after it. If that reaches the deadline unanswered, the request is
answered 504. A deadline bounds I/O waits, not computing: nothing preempts a
handler that loops without awaiting, and a `Runtime.sleep`, a channel or a
child task's wait is not cut short either. An offloaded handler is not cut
short.

### The heavy lane

Work stealing alone lets a burst of requests that each hold the CPU for
milliseconds take every thread, and then a quick request waits behind them.
So each route keeps an average of how long its handler holds a thread. A
route whose average passes `--heavy-threshold` (500 µs by default), or one
registered through `app.heavy`, is heavy. Its handler runs only once it holds
one of the shard's heavy-lane permits, of which there are half as many as
threads, rounded up. The other threads are left to everything else.

"Holds a thread" is not wall time. A handler that awaits a database or a
timer gives its thread up while it waits, and is not heavy for waiting. Only
a run that finished without suspending counts as a sample. A handler that
computes between awaits is not seen this way, so it is registered with
`app.heavy.get(…)` and the rest. `--no-heavy-lane` turns the lane off.

### Blocking work goes to the blocking pool

A shard has a few worker threads, and every connection of the shard is served
on them. A handler that blocks its thread (a synchronous file read, a C
library that waits on a lock or the network) takes that thread from every
other request until it returns. `app.offload.get(…)` and its siblings register
a route whose extractors run as usual, whose synchronous handler runs on
Vega's blocking pool (`Runtime.blocking`), and whose answer is written back on
the worker. The handler is not async: the work that awaits belongs in an
ordinary route. What it takes and returns crosses threads, so it must be
`Sendable`. A pool thread cannot be stopped: neither a deadline nor a client
that goes away cuts an offloaded handler short.

The heavy lane is for work that computes; offloading is for work that blocks
without computing.

### Outbound I/O on the runtime

The HTTP client, PostgreSQL and Redis run on Vega's sockets and TLS, on the
same threads as the server, so a handler's outbound call is an await like any
other. An HTTP client connection goes back to the pool only when its
response was read whole and both ends mean to keep it, and redirects are
followed only when asked for. Over TLS the client offers h2, and one HTTP/2
connection is shared by every request to the same origin. Each such
connection has a reader task of its own. Garuda 1 passed the read between
waiting requests instead, because its workers could not spare a task.

### Databases

- The drivers are vega-db's, re-exported by `GarudaPostgres`, `GarudaRedis`
  and `GarudaSQLite`, with what joins them to Garuda: `UUID` and `Timestamp`
  as columns, JSON through Garuda's coder, and for PostgreSQL, spans on the
  application's tracer. `@PostgresRow` is in `GarudaSQL`, apart from the driver, because it
  needs swift-syntax.
- The PostgreSQL and Redis protocols are state machines over bytes in
  vega-db, with no sockets inside. The connections and pools run on Vega's
  I/O. A pool is made with `app.state`, so each shard has its own.
- SQLite runs every statement on Vega's blocking pool, since it is a library
  doing disk I/O and waiting on file locks. One connection writes and several
  read. Transactions begin IMMEDIATE, because the lock upgrade a deferred one
  needs fails at once instead of waiting. Each shard opens the file for
  itself, and SQLite's own locks order the writers.
- Not postgres-nio: it brings SwiftNIO's event loops into every shard and a
  thread hop into every query.

### Streaming

`response.stream()` makes the head the way every other answer's is made
(middleware's headers, `onSend` hooks, the server's own) and returns a
`ResponseBodyWriter`. A typed handler returns `StreamingBody`, whose producer
runs once the handler and the middleware around it have returned. The body is
framed as it is written: chunked on HTTP/1.1, DATA frames on HTTP/2 and
HTTP/3. Throwing part-way cuts it off (the connection closed, the stream
reset), so no client takes half a body for all of it.

A write queues its bytes and returns. When the backlog has passed
`ServerConfig.writeHighWaterMark` (512 KiB), it waits until the backlog falls
to `writeLowWaterMark` (128 KiB). So a client that reads slowly slows the
handler writing to it, and nothing else. Writers in child tasks of the
handler may write at once, and each waits. A client that goes away, or takes
nothing for `ServerConfig.writeTimeout` (30 seconds), ends every write with
`HandlerWaitError.cancelled`. `EventStream` is built on the writer, and sends
a keep-alive comment after `--sse-keep-alive` of silence.

### Topics across shards

A `Topic` has to reach clients held by every shard, so a message goes into a
ring in a region every shard maps (`garuda_bus.c`, `--broadcast-size`). Every
shard, the publisher's included, reads it back from there. No lock is held
across processes. One writer claims the ring by compare-and-swap for the copy
of one message, and a claim whose process has died is taken over. Readers
take no claim: they copy a message and then check that the writer has not
come round to it.

The ring keeps what it has room for, not only what is unread, and that is
what serves `Last-Event-ID` from any shard. Each shard has one thread that
sleeps on the ring and hands messages to its subscribers. A publisher wakes
each sleeping shard once (a futex on Linux), so a burst costs one wake per
shard. A subscriber's queue is bounded (`--broadcast-queue`), and what does
not fit, or what the ring no longer holds, arrives as a single `.missed`.

### WebSockets and WebTransport

A WebSocket route is an ordinary route until it is accepted: middleware and
extractors run in front of it, and a request either refuses is answered with
an ordinary status. WebSockets run over HTTP/1.1, and over HTTP/2 and HTTP/3
through extended CONNECT. WebTransport sessions run over HTTP/3 the same way.
In both handlers the session comes first (`webSocket(_:subprotocols:_:)`
hands a `WebSocket`, `webTransport(_:_:)` a `WebTransportSession`), because
Swift will not pass arguments after a parameter pack.

Request bodies are collected whole before the handler runs. Resumable uploads
are coming.

## Where it lives

- **`Sources/Garuda`** holds the public API beside the engine, so there is no
  module boundary on the request path. Engine types stay `internal` where the
  API does not need them.
- **`Sources/GarudaWire`** and **`Sources/GarudaQUIC`** are the protocols as
  state machines over bytes: the HTTP/1.1 parser, HPACK, QPACK, frames, and
  QUIC. Neither touches a socket.
- **`Sources/garuda-server`** serves the-benchmarker's contract and the
  workloads through the public API, so the benchmark measures what
  applications use.
- **`Sources/garuda-conformance`** holds routes that make engine behaviour
  observable to the end-to-end suites under `scripts/`. It is not an example
  to copy.

## Performance checks

`AllocationTests` counts heap allocations across dispatch, and requires zero
per request after warm-up for a plain route, a typed `Path` route and a
middleware chain. [benchmarks/frameworks.sh](benchmarks/frameworks.sh)
compares Garuda with other frameworks on the-benchmarker's contract, and
[benchmarks/workloads.sh](benchmarks/workloads.sh) measures path parameters,
JSON in and out, a database round trip, streaming, uploads, downloads, a
relay, handshake churn, HTTP/2, overload, and quick requests sharing a server
with slow ones. [BENCHMARKS.md](BENCHMARKS.md)
records the results and the method.

## Status

What is still missing is listed under [Status](README.md#status) in the
README, not here.
