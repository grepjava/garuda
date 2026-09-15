<p align="center">
  <img src="assets/garuda-stylized-lockup.png" alt="Garuda" width="640">
</p>

# Architecture

A Garuda server is one Swift executable: the `Garuda` library and the routes an
application registers with it. A supervisor process owns the listening
sockets and forks worker processes; each worker is a single thread running a
readiness poller over a flat table of connections. It parses HTTP/1.1, HTTP/2
and HTTP/3 itself, and answers requests with synchronous handlers whose
responses go through one response sink into the connection's write buffer.
The handler API is early and will change ([HANDLER-API.md](HANDLER-API.md)).
The binary links OpenSSL, zlib and the Swift runtime, nothing else. Foundation
is not linked.

The protocols are described in [TRANSPORT.md](TRANSPORT.md). What works today
and what does not yet is tracked in [GARUDA.md](GARUDA.md).

```
Sources/
  CGaruda/            C shim: epoll/kqueue, sockets, signals, fork, sendfile,
                      TLS (garuda_tls.c), crypto primitives for QUIC, UDP with
                      recvmmsg/GSO, ACME, and the shared-memory tables for
                      metrics, rate limiting and the response cache
  GarudaCore/         ByteBuffer, BufferPool, Poller, logging, the Date cache
  GarudaHTTP/         HTTP/1.1 parser, chunked decoder, response writer, HPACK,
                      QPACK, HTTP/2 and HTTP/3 framing, WebSocket framing,
                      forwarded-header trust, cache policy, root path
  GarudaQUIC/         QUIC transport and the TLS 1.3 handshake it needs
  Garuda/             supervisor, worker loop, connection table, dispatch,
                      handler API, route table, response sink, async
                      substrate, HTTP/2 and HTTP/3 servers, static files,
                      TLS glue, reload, ACME, metrics, CLI
  garuda-server/      the benchmark executable: the-benchmarker's routes,
                      served through the handler API
  GarudaConformance/  garuda-conformance: routes that make engine behaviour
                      observable to the end-to-end suites
  GarudaFuzzTargets/  fuzz targets and seeds, driven by pgfuzz/
Tests/GarudaTests/    unit tests
```

`Package.swift` builds these as the targets `CGaruda`, `GarudaCore`,
`GarudaHTTP`, `GarudaQUIC` and `Garuda` (the library product of the same name),
the `garuda` and `garuda-conformance` executables, and `GarudaFuzzTargets`
with its `pgfuzz` driver.
Swift never imports an OpenSSL header. It sees TLS sessions, contexts and
loaded keys as opaque handles behind functions in the shim.

---

## Processes

### The supervisor owns the sockets

Everything runs under a supervisor, including a single worker
(`Runtime.swift`, `runSupervisor`). Before the first fork it:

- opens the listening sockets. For TCP that is **one socket per worker slot**,
  each with `SO_REUSEPORT`, so every worker has its own accept queue in the
  kernel: no shared accept lock, no thundering herd. For a unix socket it is
  **one socket shared by every worker**, because a path can only be bound once;
- maps the pages every worker shares: the metrics page (two slots per worker,
  see below), the `--rate-limit` table, and the `--cache-size` table;
- checks the TLS certificates once, so a bad path is one error at start-up
  rather than one per worker.

Workers are forked with `pg_fork_worker`. It blocks the piped signals across
the fork and gives the child a signal pipe of its own, so a signal that arrives
during the fork is not lost. A child closes every other slot's listener and
keeps only its own. (A unix socket is the same descriptor in every slot, so it
keeps that one.)

The supervisor keeps the sockets open for as long as it runs. That is what lets
a worker be *replaced* without dropping connections. The kernel assigns a
connection to one socket in the `SO_REUSEPORT` group when the SYN arrives, not
when `accept()` is called. A socket that leaves the group takes its accept
queue and its half-finished handshakes with it, however carefully its worker
drained. A replacement inherits the same socket, so the group never loses a
member.

The metrics listener, the `--redirect-http` listener and the QUIC socket are
opened by each worker for itself, also with `SO_REUSEPORT`.

### Readiness and replacement

Every worker is forked with a readiness pipe. Once it has built its poller,
TLS context and listeners and run the application's `onStart`, it writes one
byte and closes its end. The
supervisor reads rather than polls: one byte means ready, and end of file means
the worker died during start-up.

A worker that exits on its own is restarted in its slot. `SIGHUP` replaces the
workers **one slot at a time**:

1. fork the replacement for slot *i*, and move the slot to the other half of
   its metrics pair (the outgoing worker is still writing to its own half);
2. wait for the replacement's readiness byte. Both workers serve the slot
   meanwhile. The wait is bounded at 60 s, after which the old worker is
   retired anyway;
3. send the old worker `SIGQUIT`. Its replacement is already serving, so there
   is nothing for `--drain-delay` to wait for;
4. once the old worker has exited, move on to slot *i + 1*.

If a replacement dies before it reports ready, the slot goes back to the worker
it was replacing and the pass stops, so one worker that cannot start never
takes the others down with it. A reload requested while a pass is running
queues another pass. Each reload flushes the shared response cache.

### `--reload`: restarting on a rebuilt executable

The handlers are compiled into the server, so the file that matters is the
executable (`ReloadWatcher.swift`). The supervisor watches its directory with
inotify or kqueue, and also re-stats it every `--reload-interval`, because a
bind mount or WSL's view of a Windows drive may never send a notification. A
change counts once the file's signature (device, inode, size, mode, mtime) has
held still for 300 ms, since a linker writes in several steps.

Forked workers can never run the new code, so the supervisor replaces itself
(`Reexec.swift`). It waits until no restart pass, handover, retiring worker or
ACME helper is in flight. Then it checks that the new file actually runs
(`pg_probe_executable`) and `exec`s it with the same arguments. The listening
descriptors are left open across the exec, and they travel together with the
worker pids in `GARUDA_REEXEC` (`fd,fd,…;pid,pid,…`). The new image takes that
record and adopts the old workers, which are still its children. It then
replaces them exactly as a `SIGHUP` would. If the worker or listener count no
longer matches, it stops the inherited workers and closes their sockets rather
than leave them unsupervised.

A change to `--tls-cert`, `--tls-key` or an extra SNI certificate needs no
exec: new workers read the files again as they start, so the supervisor just
begins a replacement pass. Certificates managed by `--acme-domain` are not
watched, because their helper already triggers the reload.

### ACME

`--acme-domain` runs the ACME client in a **helper process** forked from the
supervisor, one at a time. It is a process rather than a thread because the
supervisor forks workers, and forking while another thread holds the
allocator's lock would leave the child with a lock nobody releases. The helper
closes the listeners and the signal pipe, and its exit status is its whole
report. Exit 0 means a new certificate is on disk, and the supervisor replaces
the workers onto it. Failures back off from one minute, doubling up to six
hours. With nothing cached at start-up the server boots on a self-signed
placeholder, because the workers that answer the `tls-alpn-01` challenge need
a certificate to start.

### Shutdown

- **`SIGTERM`**: the supervisor forwards it. Each worker starts failing its
  `--health-check-path` with 503, keeps serving for `--drain-delay`, then
  drains.
- **`SIGINT` / `SIGQUIT`**: drain now. A second one cuts a drain delay short.
- **Draining** (`beginDraining`) closes keep-alive connections that are idle
  *between* requests. A freshly accepted connection that has not been read yet
  is kept, because its client may already have sent a request. The worker
  stops polling the listener, closes its handle on it and its redirect
  listener, and ends its loop once the table is empty. The application's
  `onShutdown` runs after the loop ends.
- **`--graceful-timeout`** bounds in-flight requests. Past it, every remaining
  connection is closed.
- Behind that, a `SIGALRM` watchdog `_exit`s the worker ten seconds after the
  grace period, and the supervisor `SIGKILL`s any worker still alive past
  drain delay + grace period + 2 s.

---

## The worker

A worker is one thread and one `Worker` struct, reached through a raw pointer
(`makeWorker`). Its loop is `runSynchronousLoop`:

```swift
while running {
    let timeout = quicPollTimeout(200)   // 0 if the ready queue has work
    let n = poller.wait(timeoutMillis: timeout)
    if n > 0 { processEvents(n) }
    fireDueTimers()                      // TimerHeap -> ReadyQueue
    drainReadyQueue()                    // at most 64 resumes
    quicTick()                           // QUIC loss/ack/idle timers
    sweepTimeouts()                      // once a second: idle, stalls, drain
    if draining && quiescent { running = false }
}
```

The poll timeout is the default 200 ms, cut to the nearest QUIC deadline and
the nearest timer deadline (rounded *up*, because waking early only spins). It
is 0 while the ready queue still holds work.

### Poll tokens

The poller is epoll on Linux and kqueue elsewhere, with a reused event array of
256. Every registration carries a 64-bit token. A connection's token is
`(generation << 24) | slot`. Fixed tokens name the listener, the signal pipe,
the QUIC socket, the metrics listener, the redirect listener, and eight slots
for scrapes or redirects whose request has not finished arriving. Those are
answered without a connection slot.

### The connection table

Connections live in one contiguous slab of `Connection` structs, indexed by
slot, with a free list threaded through the unused entries
(`Connection.swift`). Accepting is an index pop and closing is an index push.
`allocate` bumps the slot's `generation`. An event whose token carries an old
generation is for a descriptor closed earlier in the same batch, and it is
discarded with one compare.

A slot is a connection **or a stream**. An HTTP/2 or HTTP/3 request stream
takes a slot from the same table, with `fd = -1` and `parentSlot` pointing at
the connection that carries it. An HTTP/3 connection's own slot has no
descriptor either, because the UDP socket belongs to the QUIC listener. Code
above the transport treats all of these alike; see
[one request path](TRANSPORT.md#one-request-path).

States: `readingHead → [readingBody] → dispatching → writing → (reuse |
close)`. The long-lived states are `http2` and `http3`, plus `closing` for a
stream whose response finished before its upload did. A full table answers 503
and closes rather than queueing. Accepts are bounded at 64 per wake-up, and
`EMFILE` pauses accepting until a slot is freed.

### An HTTP/1.1 request

1. **Read.** `fill` drains the socket into the pooled read buffer. Over TLS it
   keeps reading while OpenSSL still holds decrypted bytes, because a
   level-triggered poller will not mention those again.
2. **Parse.** `HTTPParser.parse` produces `(offset, length)` slices into the
   read buffer and allocates nothing.
3. **Begin.** `beginRequest` bumps `requestId` and clears any continuation.
   It decides keep-alive (not while draining, not past the per-connection
   request limit), rejects an oversized `Content-Length` with 413 and sends
   `100 Continue` if asked. It also settles body framing. A Content-Length
   body is read into its own `body` buffer, never past its declared end, so
   the head bytes stay valid where they are. A chunked body needs the read
   buffer for framing, so the head is copied into `headStore` first.
4. **Dispatch** once the body is complete (below).
5. **Finish.** `finishResponse` runs once the write buffer drains. If the
   request body was never fully read, a small remainder already on the socket
   is swallowed, and otherwise the connection closes. Then the slot either
   returns to `readingHead` (processing any pipelined bytes already buffered)
   or closes.

### The dispatch seam

`Worker.dispatch` is where every request, whatever carried it, is answered.
In order:

1. stamp the start time (access log, metrics), assign `--request-id` and
   `--trace-context`;
2. `--no-websockets`: an upgrade request is refused with 501;
3. `--health-check-path`: 200, or 503 once draining;
4. `--rate-limit`: 429 with `Retry-After`;
5. `--static-dir`: a file, if one matches (`StaticFiles.swift`);
6. `--compress`: negotiate the coding, then `--cache-size`: answer from the
   shared cache. Both exist, but today no response is compressible or stored;
   see [GARUDA.md](GARUDA.md);
7. an extended CONNECT (`:protocol` on HTTP/3) is refused with 501;
8. **`dispatchRoute`** (`Respond.swift`): the route table, then the handler.

`--redirect-http` is not part of this path. It is a separate listener in each
worker that answers plain HTTP with a redirect to https and closes
(`HTTPS.swift`).

### Routes and handlers

`Application.run` compiles the application's routes and hooks before the
first fork (`Application.swift`), so every worker inherits the same table and
only reads it through its `application` pointer. A test client points a worker
of its own at the same compiled table (`TestClient.swift`).
`RouteTable` (`RouteTable.swift`) splits each pattern into literal, `:param`
and trailing `*rest` segments and lays them out as a flat byte trie.
`CompiledRoutes.match` walks the request path as it arrived, after stripping
`--root-path`, trying a literal before a parameter and a parameter before the
rest, and backtracking when a branch leads nowhere. Parameters are offsets and
lengths in the path, at most 8 of them. `HEAD` falls back to `GET`. No match is
a 404, and the connection is kept.

`runHandler` calls the handler with a `Request` and a `Response`, both
`~Copyable` views of the connection slot. Request headers are read from the
worker's shared header table. When another request's head has been parsed
into it since, the head is parsed again from bytes that stay put until the
request is answered, so that costs a parse and never a copy. A handler that
throws, or returns without answering or waiting, gets a 500.

`respond` (`Respond.swift`) is the response sink every handler answer goes
through. It writes the status line, `Date` (from a cache reformatted at most
once a second) and `Server` unless the handler set them, the server headers
(`writeServerHeaders`: Alt-Svc, HSTS, X-Request-ID) unless the handler set its
own, the handler's headers, `Content-Length`, `Connection` and the body into
the connection's write buffer. It then flushes once, so head and body leave in
one `write`. A 204 or 1xx gets no `Content-Length`, a 304 keeps the handler's,
and a `HEAD` response states the length and sends no body. A body longer than
a declared `Content-Length` is cut to it. A shorter one closes the HTTP/1.1
connection after it, or resets the stream, so a client never takes it for
whole. On a stream the same call goes to `respondH2` or `respondH3`, which
encode the head with HPACK or QPACK (`encodeServerHeaders` /
`encodeServerHeadersH3`) and queue the body on the stream.

---

## The async substrate

`GET /` allocates nothing and never suspends: a handler that can finish does
so inside `dispatch`. Waiting is opt-in, and it is implemented without `Task`
or any other scheduler hop (`AsyncOps.swift`). Today its only user is
`Response.after(milliseconds:then:)`, the one way a handler can wait.

**`AsyncOpPool`** is a fixed-capacity slab of `AsyncOp` records (one per
possible connection) with a free list. Each record has a generation bumped on
allocate, and stores its slot, the `requestId` it was armed for, its kind
(`timer`), a microsecond deadline and its heap index.

**`TimerHeap`** is a min-heap of `(deadlineUs, opIndex, opGeneration)`, with
each op remembering its index so it can be removed from the middle. Deadlines
come from `pg_monotonic_us`, not the coarse millisecond clock, plus one
microsecond for truncation, so a timer never fires early. `popDue` discards
heap nodes whose op has been recycled or unlinked.

**Per-connection continuation fields** keep `Connection` small: `contState`
(`none` / `waiting` / `ready`), `contKind` (what to do on resume), `contOp` and
`contOpGeneration` (the one op this request is parked on), and `contTicket`.

**Two identities.** The connection generation names the slot's lifetime and
changes only on allocate. `requestId` names the request and changes at every
`beginRequest` (or stream open). A keep-alive connection reuses its slot and
generation, so a timer armed by request A must match on `requestId` too, or it
could resume request B.

**`ReadyQueue`** is a bounded FIFO ring buffer, sized to a power of two at least
the table capacity. Its entries carry `slot`, `generation`, `requestId` and a
`ticket`. The ticket is a per-worker serial stamped on the connection when it
becomes ready, so if a request is armed again after becoming ready, only the
newest entry can resume it. Cancelling does not remove queue entries.
`isRunnable` rejects stale ones at drain time instead. If the queue is full
when a continuation becomes ready, it is compacted in place to drop stale
entries (a slot has at most one runnable entry, so there is always room). The
resume never runs inline.

The flow for `Response.after`:

1. `armDelay` clears any previous continuation, allocates an op, pushes it on
   the heap and parks the connection as `waiting`, with the handler to call
   stored as `contHandler`. With no op free, the request is answered 503;
2. `fireDueTimers` pops due entries; `completeTimerOp` frees the op and, if the
   slot, `requestId`, state and `contOp` still match, `enqueueReady` marks it
   `ready` with a fresh ticket and queues it;
3. `drainReadyQueue` resumes up to **64** continuations per turn. Only resumes
   that actually run spend the budget; stale entries cost a check each. A
   resume calls `contHandler` through `runHandler`, with fresh views of the
   same request. While work remains, the next poll uses timeout 0.

**Cancellation** always goes through `cancelOps`, which frees exactly the op
named by `contOp` (checked against `contOpGeneration`) and unlinks it from the
heap. It never scans the pool. It runs on every `beginRequest` and keep-alive
completion, and from `closeConnection`. Every way a stream can end reaches
`closeConnection`: an HTTP/2 `RST_STREAM`, an HTTP/3 `RESET_STREAM` or
`STOP_SENDING`, or its parent connection closing (which closes each child
first). So a cancelled stream takes its timer with it
(`scripts/router-streams-test.py`).

---

## Keeping ARC and allocation off the request path

Classes and dictionaries are used where they run once per process or once per
connection: `H2Connection`, `H3Connection`, `QUICConnection`, `QUICListener`,
`TLSContext`, `ReloadWatcher`, the supervisor. On the request path:

- **No object per connection.** Connections are slab entries, reached by
  pointer.
- **Buffers are values.** `ByteBuffer` is a pointer and three integers, with an
  explicit `destroy()` at teardown. A class would put ARC on every hand-off. A
  `~Copyable` struct with a `deinit` fights the move-only checker on every
  partial mutation of a slab entry. Ownership is a documented invariant,
  confined to a few files.
- **Pooled read buffers**, recycled LIFO (`BufferPool`), so the block handed
  out next is the one still in cache.
- **Nothing becomes a `String`** unless a handler asks for one. The parser
  yields slices, the route table matches bytes, header values, parameters and
  the body reach a handler as byte spans, and log lines are assembled in a
  buffer and written with one `write`.
- **Character classes are register constants.** `tchar` membership is two
  64-bit shifts.
- **Interest changes only when the mask does.** `setInterest` skips the
  `epoll_ctl` call when nothing changed.
- **`accept4`**, `TCP_NODELAY`, `sendfile` for static files (and `SSL_sendfile`
  under `--ktls`), `recvmmsg` and UDP GSO for QUIC.

## Limits and backpressure

- Heads are bounded by `--max-header-size`, header count by a fixed limit, and
  bodies by `--max-body`, counted cumulatively as bytes arrive, on every
  protocol. Connections are bounded by `--max-connections`, and a full table
  answers 503.
- An HTTP/1.1 body is never read past its declared length. Bytes after it
  belong to the next pipelined request and wait in the socket, with read
  interest off, until the current response finishes.
- A write buffer that grew past four read-buffer sizes is freed once it drains,
  so one large response does not pin memory on an idle keep-alive connection.
- A multiplexed stream moves bytes to its connection only while the
  connection's own write buffer is under the write high-water mark, and HTTP/2
  flow control applies on top of that. See [TRANSPORT.md](TRANSPORT.md).
- `sweepTimeouts` runs once a second. It enforces `--keep-alive` on idle
  connections and `--request-timeout` on a head, body or response that has
  stopped moving. HTTP/2 connections with no streams time out as idle, and
  QUIC runs its own negotiated idle timeout.

## Engine code with nothing to serve yet

These parts compile and are reachable from the command line, but the handler
API does not reach them yet:

- **WebSocket**: framing, UTF-8 validation and permessage-deflate live in
  GarudaHTTP and are unit-tested. The server never enters the `websocket`
  state, and `WebSocket.swift` only holds the state struct and stubs.
- **WebTransport**: HTTP/3 advertises it and recognises session streams and
  datagrams. `WebTransport.swift` stubs drop them, and a CONNECT is answered
  501.
- **Response compression** (`Compression.swift`) and the **response cache**
  (`ResponseCache.swift`, `garuda_cache.c`): handler responses are not
  compressed or stored. Both wait for streaming responses.

## Testing

- `swift test`: unit tests for the parser, HPACK (RFC 7541 appendix C and the
  Huffman code), QUIC packet protection (RFC 9001 vectors generated by
  `scripts/quic-vectors.py`), QUIC streams, WebSocket framing and deflate,
  cache policy, trace context, root path, the route table
  (`RouteTableTests`), and the async substrate (`AsyncOpsTests`).
- `pgfuzz` with `GarudaFuzzTargets` for the parsers.
- `scripts/`: end-to-end suites against independent clients. Transport
  coverage is in [TRANSPORT.md](TRANSPORT.md#testing). `feature-test.py` (62)
  covers supervision, shutdown, unix sockets and reload. The shell scripts
  cover ACME, static files, rate limiting, redirects, request IDs, trace
  context, SNI, draining and `reload-test.sh`. `handler-test.py` runs
  `garuda-conformance` and covers the handler API: request bodies, headers,
  client and scheme, response framing, errors and lifecycle hooks.
