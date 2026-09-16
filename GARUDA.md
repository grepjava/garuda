# Garuda

**A pure-Swift web framework on Peregrine's engine.**

This repository was forked from [Peregrine](https://github.com/grepjava/peregrine) at 6200167 on 2026-09-14. Everything below that commit is Peregrine's history. The engine has been renamed Garuda, CPython/ASGI/WSGI have been removed, and a synchronous Swift router answers at the HTTP dispatch seam.

## Goal

Swift handlers are served directly by the engine, with no CPython anywhere on the request path. Garuda keeps what the engine already does:
- the HTTP/1.1 parser and HTTP/2 framing
- HPACK and QPACK, QUIC and HTTP/3, WebTransport
- TLS with ACME certificates
- the response cache, static files with `sendfile`, and compression
- rate limiting, metrics, and graceful reload

## Where we start: measured, not assumed

Per-request CPU for one worker pinned to CPU 0, load generator on CPUs 1–3, closed-loop oha 15 s at 64 connections. Mean of three runs, WSL2 on an i9-12900KF, 2026-09-14:

| server | user µs | kernel µs | req/s |
|---|---:|---:|---:|
| Peregrine, `--health-check-path /` | **1.27** | 5.42 | 152,480 |
| Elysia on Bun | 1.45 | 4.36 | 175,572 |
| Peregrine, raw ASGI | 5.07 | 4.90 | 105,745 |

Earlier session (raw ASGI 5.26 / 4.74, Elysia 1.54 / 4.73) matches the last two rows within run-to-run spread.

- **The Swift path is already at Bun's user time.** `--health-check-path` answers in `Worker.swift` before dispatch: parse, write 200, no Python per request. 1.27 µs user versus Elysia's 1.45. The remaining gap on one core is kernel (5.42 vs 4.36) and, in that measurement, the CPython process still sitting in the address space.
- Raw ASGI's extra ~3.8 µs of user time is Python plus asyncio, as assumed. uvloop is a small slice of that.
- Kernel is 4.4–5.4 µs for every server here. Nobody goes below that. 1 / 5.8 µs ≈ 172k req/s per core, which is what Elysia actually delivered on one pinned worker; 210k would need kernel-only.

Suite zrk (`-c N -d 15s -R1000:500000`), four workers, mean of three runs, same session. Zero errors:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Peregrine, `--health-check-path /` | **330,563** | **322,119** | 291,295 |
| Elysia on Bun | 282,771 | 321,087 | **297,502** |
| Peregrine, raw ASGI | 216,249 | 251,656 | 247,575 |

Health-check beat or matched this session's Elysia at 64 and 256. Elysia was slower here than the 346k–357k in BENCHMARKS.md; two of the three health-check runs at 64 were 349k and 349k, in that published band. Shared-CPU noise is large. The claim that holds is: **a Swift handler at this dispatch seam is in Bun's band, not Vapor's.**

the-benchmarker/web-frameworks, published dataset of 2026-09-13, 16 CPUs, 512 connections:
- raw WSGI on Peregrine 1.0, with Python on every request: 130,843 req/s;
- Vapor: 88,435; Hummingbird: 82,488;
- the top 15 in any language: 147k–176k.

The target is axum, in speed and in usability: level with Bun at least, and clearly ahead of today's Swift frameworks. The first quick comparison has Garuda at 1.95× axum on the suite's ramp and 1.72× on one pinned core ([BENCHMARKS.md](BENCHMARKS.md#against-axum-quick-comparison)). Hello-world will not set a runaway record: every fast server there is already close to the kernel's floor.

## What is not true yet

- **TLS is not pure Swift.** TCP TLS is OpenSSL (`Sources/CGaruda/garuda_tls.c`). The QUIC handshake is built in Swift from OpenSSL's crypto primitives (`garuda_crypto.c`).
- **The public handler API is early.** An `Application`, a `~Copyable` `Request` that lends its bytes to closures and a one-shot `Response` serve the benchmark contract and `garuda-conformance` alike over HTTP/1.1, HTTP/2 and HTTP/3, and `app.test` runs them in-process. Handlers are synchronous and suspend only through `response.after(milliseconds:)`; there is no typed extraction, JSON, application state, middleware, 405 or streaming yet. A stream cancelled while its handler waits takes the timer with it (`scripts/router-streams-test.py`). [HANDLER-API.md](HANDLER-API.md) has the roadmap.
- **The WebSocket application API is a stub** until handlers for it exist. WebTransport sessions have handlers (`app.webTransport`), HTTP/3 only.
- **Some flags have nothing to act on.** `--compress` has no response to compress (the response sink does not compress yet, and static files are served pre-compressed or not at all), and `--cache-size` never stores one. Both arrive with streaming responses.
- **`--reload` watches the executable, not the sources.** A rebuild (`swift build` in another terminal) has the supervisor exec the new file with its listening sockets kept open, then replace the workers one slot at a time, so no connection is dropped (`scripts/reload-test.sh` rebuilds under load). A changed `--tls-cert` or `--tls-key` replaces the workers without an exec. Nothing builds for you.

## Coverage waiting on the handler API

The roadmap step that brings back each line below is in [HANDLER-API.md](HANDLER-API.md#roadmap).

235 end-to-end checks went with CPython, because they needed an application to answer. The engine features they covered stayed in the binary, untested end to end until a handler could produce what each test needs.

**Brought back by phase 1**, in `scripts/handler-test.py` against `garuda-conformance`, 107 checks:

- **Echo the request body, buffered.** Content-Length, chunked with a trailer section, pipelined, 100-continue, 1 MiB either way, a body far larger than a TLS record. HTTP/2 and HTTP/3 bodies larger than a frame or a window, and drip-fed ones arriving in order.
- **Read request headers, client address and scheme.** The request ID handed to the handler: the client's replaced, a trusted proxy's kept, untouched without the flag, over HTTP/1.1 and HTTP/2. `traceparent` passed through unchanged. `X-Request-Start` stamping, including a request queued behind a blocking handler. `X-Forwarded-For` and `Forwarded`, with trusted-hop walking. The https scheme, HTTP version and authority on HTTP/2 and HTTP/3, and the full set of headers received. (Dropping underscore header names is retired: it guarded CGI-style environments, where `X-Foo` and `X_Foo` collide; a handler reads header names as they were sent.)
- **Set status and headers.** 204 and 304 framing and keep-alive after them. A handler's Content-Length not duplicated. A handler's own `X-Request-ID`, `Strict-Transport-Security` and `Alt-Svc` kept, not doubled. A declared Content-Length enforced against a body longer or shorter: cut to length, or the stream reset or the connection closed.
- **Errors and lifecycle.** 500 when a handler throws, with the connection surviving. Start-up hooks once per worker, and the shutdown hook after in-flight requests drain. SIGTERM and SIGINT during a slow start-up hook. Bounded shutdown against a handler that never answers and against a shutdown hook that never returns.

**Still waiting**, each line a capability a handler needs and the tests it brings back:

- **Stream the request body** (step 5). Request-body backpressure, delivery in pieces, answering before an upload finishes and draining the rest.
- **See cancellation** (step 3). A reset HTTP/2 or HTTP/3 stream stopping the handler's work, not only a parked timer.
- **Large and streamed responses** (step 5). Chunked framing for a stream, bodies with no declared length on HTTP/2 and HTTP/3, large writes under flow control, a window update arriving mid-response, write backpressure and memory under a slow client. `--compress`: codec choice, Content-Length removal, Vary, weak ETag, no-transform, event streams, flushing pieces, the small-body exemption, HTTP/1.0 close framing, HTTP/2.
- **Cacheable responses** (step 5). `--cache-size`: store, hit, HEAD from a GET, 304 revalidation, retirement on unsafe methods, Age and TTL, credentials and no-cache kept out, flush on reload, hit metrics.
- **WebSocket handlers** (step 5). Handshake, framing, UTF-8 checks, size limits, pings and timeouts, control frames while the handler is busy, `--ws-compress`. (WebTransport sessions, streams, datagrams and close capsules are back: `scripts/webtransport-test.py`.)
- **A logging API** (step 4). Level applied to handler records, level mapping, multi-line records.

## First steps

1. **Measure the pure-Swift ceiling with no new code.** Done, 2026-09-14. `--health-check-path /` on the then-current engine, suite zrk at 64 / 256 / 512 next to Elysia, CPU split as in the table above. Swift user time is already Bun's; see those figures.
2. **Build a synchronous router spike at that dispatch seam.** Done, then replaced. The spike, `Router.swift`, matched method and path bytes at `Worker.dispatch` after health-check, rate-limit, static, compress, and cache. Phase 1 of the handler API now answers the same contract through `Routes` at the same seam; in the same session, suite zrk at 64 connections, four workers, the spike at 0e0cbbc served 350,161 requests a second and the handler API 343,334, 2% less. Contract:
   - `GET /` → 200, empty body
   - `GET /user/:id` → 200, the id bytes as the body
   - `POST /user` → 200, empty body
   Measured against Hummingbird and Vapor, 2026-09-15: suite zrk at 4bb9eaa (`-c N -d 15s -R1000:500000`, `GET /`), mean of three runs, WSL2, the load generator sharing the server's 4 CPUs, zero errors. Garuda ran four workers at 09eb178. Hummingbird 2.26.0 and Vapor 4.122.1 are the suite's `swift/*-framework` entries, byte for byte, built as its Dockerfile builds them (Swift 6.3.3, `-c release -Xswiftc -enforce-exclusivity=unchecked`), each one process with SwiftNIO 2.102.0's default of an event loop per CPU. `FRAMEWORKS=swift SERVERS="garuda hummingbird vapor" WORKERS=4 AGG=mean bash benchmarks/frameworks.sh`:

   | entry | 64 | 256 | 512 |
   |---|---:|---:|---:|
   | Garuda router | **414,234** | **389,445** | **370,945** |
   | Hummingbird | 88,864 | 102,399 | 99,706 |
   | Vapor | 60,411 | 58,946 | 60,837 |

   About 4× Hummingbird and 6–7× Vapor at every level. Latencies are not in the table: the ramp offers far more than Hummingbird and Vapor can serve, so their corrected p50s are seconds of queueing, not per-request cost. There is no pinned one-core pass: SwiftNIO sizes its loop group from cgroup limits or the online CPU count, not from affinity, so under `taskset` both would run four loops on one core. Figures from different sessions here move by tens of percent; compare rows within one table.
3. **Decouple CPython from the engine targets.** Done. `Package.swift` has no CPython; ASGI/WSGI and the Python package are gone. A Garuda binary links OpenSSL, zlib, and the Swift runtime — not libpython.
4. **Async without a scheduling hop per request.** Done as the first substrate; the public API still grows on top of it.

### Async architecture (step 4)

Principle: **do not require a scheduling handoff before useful work.** A handler that finishes synchronously stays a normal call from `dispatchRoute`. Suspension is opt-in via worker-owned continuations and pooled ops — not `Task` / Tokio-style spawn.

- **Sync is the ordinary path.** A handler that can finish does so inline. `GET /` allocates no op.
- **Worker-owned request continuations + pooled operation records.** Uncommon wait state lives in `AsyncOps`, not a fat enum on every `Connection` slot.
- **Two identity layers.** Connection `(slot, generation)` is for fd lifetime (bumped only on allocate). `requestId` (and op generation) names the request: a keep-alive timer from request A must not resume B.
- **Own the runtime pieces explicitly:** continuations, a timer heap, cancellation cleanup, a worker-local ready queue (drain budget 64), fairness hooks. That is a small runtime whether we call it one or not.
- **Keep `Connection` small.** Captured Swift closures can ARC/allocate even without `Task`; avoid them on the hot path.
- **Reject independently scheduled tasks before first useful work.** `await` is a *possible* suspend, not a spawn — judge by generated code, not assumption.
- **Not yet:** client TCP/DNS, `io_uring` as a completion backend, Swift Concurrency facade, full per-turn CPU budgets.
- **Judge later on mixed load:** immediate responses, upstream waits, slow clients, cancellations, HTTP/2 concurrency — throughput, p99, memory, CPU.
