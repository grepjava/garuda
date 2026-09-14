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

The realistic target stays the top tier, level with Bun, and clearly ahead of today's Swift frameworks. Hello-world will not set a runaway record: every fast server there is already close to the kernel's floor.

## What is not true yet

- **TLS is not pure Swift.** TCP TLS is OpenSSL (`Sources/CGaruda/garuda_tls.c`). The QUIC handshake is built in Swift from OpenSSL's crypto primitives (`garuda_crypto.c`).
- **The public handler API is still thin.** Sync routes and a timer-backed `GET /delay/:ms` sit on the continuation substrate (`AsyncOps.swift`). There is no middleware, no request-view type, and no client I/O helpers yet. HTTP/2 and HTTP/3 still answer router routes with status only (`h2FailRequest` / `h3FailRequest`), so `/user/:id` and delay bodies are HTTP/1.1 for now.
- **WebSocket and WebTransport application APIs are stubs** until Swift handlers exist.

## First steps

1. **Measure the pure-Swift ceiling with no new code.** Done, 2026-09-14. `--health-check-path /` on the then-current engine, suite zrk at 64 / 256 / 512 next to Elysia, CPU split as in the table above. Swift user time is already Bun's; see those figures.
2. **Build a synchronous router spike at that dispatch seam.** Done. `Sources/GarudaServer/Router.swift` matches method and path bytes at `Worker.dispatch` after health-check, rate-limit, static, compress, and cache. Contract:
   - `GET /` → 200, empty body
   - `GET /user/:id` → 200, the id bytes as the body
   - `POST /user` → 200, empty body
   Still to do: benchmark that contract against Hummingbird and Vapor with suite zrk.
3. **Decouple CPython from the engine targets.** Done. `Package.swift` has no CPython; ASGI/WSGI and the Python package are gone. A Garuda binary links OpenSSL, zlib, and the Swift runtime — not libpython.
4. **Async without a scheduling hop per request.** Done as the first substrate; the public API still grows on top of it.

### Async architecture (step 4)

Principle: **do not require a scheduling handoff before useful work.** Sync `respondRoute` stays a normal call. Suspension is opt-in via worker-owned continuations and pooled ops — not `Task` / Tokio-style spawn.

- **Sync is the ordinary path.** A handler that can finish does so inline. `GET /` allocates no op.
- **Worker-owned request continuations + pooled operation records.** Uncommon wait state lives in `AsyncOps`, not a fat enum on every `Connection` slot.
- **Two identity layers.** Connection `(slot, generation)` is for fd lifetime (bumped only on allocate). `requestId` (and op generation) names the request: a keep-alive timer from request A must not resume B.
- **Own the runtime pieces explicitly:** continuations, a timer heap, cancellation cleanup, a worker-local ready queue (drain budget 64), fairness hooks. That is a small runtime whether we call it one or not.
- **Keep `Connection` small.** Captured Swift closures can ARC/allocate even without `Task`; avoid them on the hot path.
- **Reject independently scheduled tasks before first useful work.** `await` is a *possible* suspend, not a spawn — judge by generated code, not assumption.
- **Not yet:** client TCP/DNS, `io_uring` as a completion backend, Swift Concurrency facade, full per-turn CPU budgets.
- **Judge later on mixed load:** immediate responses, upstream waits, slow clients, cancellations, HTTP/2 concurrency — throughput, p99, memory, CPU.
