# Garuda

**We are building a pure-Swift web framework on Peregrine's engine.**

This repository was forked from [Peregrine](https://github.com/grepjava/peregrine) at 6200167 on 2026-09-14. Everything below that commit is Peregrine's history. What is here today is still Peregrine, a Python ASGI/WSGI server. That changes as the framework work lands.

## Goal

Swift handlers are served directly by the engine, with no CPython anywhere on the request path. Garuda keeps what the engine already does:
- the HTTP/1.1 parser and HTTP/2 framing
- HPACK and QPACK, QUIC and HTTP/3, WebTransport
- TLS with ACME certificates
- the response cache, static files with `sendfile`, and compression
- rate limiting, metrics, and graceful reload

## Where we start: measured, not assumed

Per-request CPU for one worker pinned to one core, with a raw hello-world app. Measured in WSL2 on an i9-12900KF:

| server | user µs | kernel µs |
|---|---:|---:|
| Peregrine, raw ASGI | 5.26 | 4.74 |
| Elysia on Bun | 1.54 | 4.73 |

- The kernel cost is the same for both. Peregrine's user time is about 3.2 µs of Python plus asyncio, about 1 µs of its own Swift and C, and 0.4 µs of uvloop.
- **A pure-Swift handler should cost about 1 µs of user time**, which puts it at roughly Bun's level. No server can go below the kernel's 4.7 µs, which works out to about 210k requests a second per core on that machine.
- the-benchmarker/web-frameworks, published dataset of 2026-09-13, 16 CPUs, 512 connections:
  - raw WSGI on Peregrine 1.0, with Python on every request: 130,843 req/s;
  - Vapor: 88,435; Hummingbird: 82,488;
  - the top 15 in any language: 147k–176k.

So the realistic target is the top tier, level with Bun, and clearly ahead of today's Swift frameworks. It is not a runaway record on hello-world routes: every fast server there is already close to the kernel's floor.

## What is not true yet

- **TLS is not pure Swift.** TCP TLS is OpenSSL (`Sources/CPeregrine/peregrine_tls.c`). The QUIC handshake is built in Swift from OpenSSL's crypto primitives (`peregrine_crypto.c`).
- **There is no request-view API yet.** Handlers currently get an ASGI scope (a Python dict) or a WSGI environ.
- **The engine is linked to Python.** `CPeregrine` depends on `CPython`, and `PeregrineServer` on `PeregrinePython` (`Package.swift`). Removing Python means splitting those targets, not replacing one call.

## First steps

1. **Measure the pure-Swift ceiling with no new code.** `--health-check-path` is answered in `Sources/PeregrineServer/Worker.swift` before dispatch: the request is parsed and a 200 written, with no Python per request. Run it at `/` with the suite's zrk command at 64, 256 and 512 connections, next to Elysia on Bun. Split CPU per request the same way the table above was measured.
2. **Build a synchronous router spike at that dispatch seam:**
   - routes matched on method and path bytes;
   - the response written straight into the connection's write buffer;
   - benchmarked with the suite's contract (`GET /`, `GET /user/:id`, `POST /user`) against Hummingbird and Vapor.
3. **Decouple CPython from the engine targets**, so that a Garuda binary links no libpython.
4. **Only then design the public API:** async handlers without a scheduling hop per request, middleware, and bodies.

## Open questions

- Whether to rename the `Peregrine*` targets and products now, or once the split is done. They are unchanged for now.
- Whether Garuda keeps a Python mode, or drops the ASGI and WSGI code entirely once the split is done.
