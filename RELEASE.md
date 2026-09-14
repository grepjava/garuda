<p align="center">
  <img src="assets/peregrine-fiery-roaring.png" alt="peregrine" width="480">
</p>

# Releases

What changed in each version of Peregrine, newest first. Every version listed
here is on [PyPI](https://pypi.org/project/peregrine-server/) as
`peregrine-server`, and from 1.0.0 on also as a
[GitHub release](https://github.com/grepjava/peregrine/releases).

**Keeping this file.** A change someone using Peregrine would notice gets a
line under [Unreleased](#unreleased) in the commit that makes it. When a
version is cut, that section is renamed to the version and its date, a new
empty Unreleased section goes above it, and the GitHub release notes are taken
from it. [DEPLOY.md](DEPLOY.md) has the sequence. Dates are the day the
version reached PyPI, in UTC.

---

## Unreleased

### Fixed

- `--cache-size`: a worker that stalled for more than two seconds part way
  through storing a response could have its slot taken over, then finish
  writing over the entry that replaced it: one response's status served with
  another's body. A slot now stays with its writer for as long as that process
  exists.
- `--cache-size`: a response that changed size could be answered with an older
  copy kept in a slot of another size, or have that older copy come back after
  the newer one expired. Only the copy of the most recent response is served.
- `--cache-size`: a successful POST, PUT, PATCH or DELETE retires what is cached
  for its URL, as RFC 9111 requires, and a GET that was still being answered
  when the change was made is not stored. Until now a GET was answered with the
  response from before the change until that copy expired.
- `--cache-size`: a response's `Age`, its `Date` and the time the application
  took to produce it count against its lifetime. A response already two minutes
  old with `max-age=60` was kept for a minute and served with `Age: 0`.

---

## 1.1.4 — 2026-09-14

### Changed

- Wheels are built for Linux aarch64 as well as x86_64, and tagged
  `manylinux_2_35` rather than `manylinux_2_39`. `pip install` now takes a
  wheel instead of compiling on Debian 12, Ubuntu 22.04, the official
  `python:*-slim` images and ARM machines. Before a release, each wheel is
  installed into `python:*-slim-bookworm` and has to serve a request.

### Documentation

- The README opens with the results, a chart of them and a table translating
  uvicorn and gunicorn options. Its usage block lists `--ktls`,
  `--acme-directory`, `--acme-ca-bundle`, `--cache-size`,
  `--cache-max-object`, `--cache-ttl-max`, `--trace-context` and `--version`,
  which it had been missing.
- A LICENSE file, for the MIT license `pyproject.toml` already declared, and
  PyPI classifiers, keywords and project links.

---

## 1.1.3 — 2026-09-14

### Fixed

- An ASGI application's `send` or `receive` used after its request had ended,
  by a task the request started, no longer reaches the next request on the
  same keep-alive connection. A late `send` could deliver its response in
  place of the next request's, and a late `receive` could take that request's
  body. A late `send` now raises `RuntimeError` while the connection is open,
  as it already did before another request had started, and returns quietly
  once the connection has closed. A late `receive` says `http.disconnect`.
  uvicorn behaves the same way.
- An HTTP/2 request that ends with a trailer section is held to its
  `content-length`, as one ending on a DATA frame already was. A body shorter
  or longer than declared reached the application as if it were whole; the
  stream is now reset with `PROTOCOL_ERROR` (RFC 9113 section 8.1.1). HTTP/3
  already checked this. A request whose trailers arrive after its response
  has finished also closes its stream at once, rather than holding it open
  until the request timeout.
- The ETag of a static file changes when the file is rewritten at the same
  size within one second. It was built from the modification time in whole
  seconds, so a client holding the old tag could be told 304 Not Modified for
  content it had never received. It now uses nanoseconds, which also means
  every static ETag changes once on upgrading: clients revalidate each file
  one time.

### Changed

- `await send()` in an ASGI application finishes without creating a
  `StopIteration` exception. On one worker, a raw ASGI application went from
  116,099 to 118,728 req/s at 2.4 % less server CPU per request (six
  interleaved rounds, `benchmarks/turbo_ab.sh`); FastAPI, whose own code is
  most of each request, was unchanged within noise.

### Documentation

- `BENCHMARKS.md` adds BlackSheep and a closed-loop capacity run past the
  ramp's ceiling, what a response body costs by size, where a request's server
  CPU goes, how many system calls a request makes (and why an io_uring backend
  was not built), and eager task start, measured twice and not kept.
- New harnesses in `benchmarks/`: `turbo_ab.sh` (two builds A/B, server CPU
  per request), `asgi_overhead.py`, `body_sizes.sh`, `syscalls.sh` and
  `eagercmp.sh` (two builds by connection count). `frameworks.sh` can run a
  closed loop.

---

## 1.1.2 — 2026-09-13

Tagged and released on GitHub only. It never went to PyPI; its changes
reached PyPI in 1.1.3.

### New options

- `--trace-context`: a request's W3C `traceparent`, its trace ID and parent
  span ID, recorded in the access log. Never generated, and never changed on
  its way to the application.
- `--cache-size`, `--cache-max-object`, `--cache-ttl-max`: a response cache
  shared by every worker, for GET responses the application marks fresh with
  `s-maxage` or `max-age`. Requests with credentials or cookies, and responses
  that set cookies or are private, are never cached.
- `--ktls`: the Linux kernel encrypts TLS, so `--static-dir` files go out with
  sendfile over HTTPS as they do in the clear. On one worker, HTTPS static
  files went from 1485 to 2172 MiB/s (1 MiB) and 1384 to 2206 MiB/s (16 MiB),
  at about a third less CPU per GiB. Needs the kernel's `tls` module.

### Changed

- `--reload` notices a save within a few tens of milliseconds, woken by
  inotify on Linux and kqueue on macOS instead of waiting for the next scan.
  The scan every `--reload-interval` stays, for filesystems that send no
  notification.

### Documentation

- `RELEASE.md` records what changed in every version, linked from the README.
- `BENCHMARKS.md` measures this build, with the response cache, Elysia on Bun
  as a reference, and `--ktls` static files. `benchmarks/frameworks.sh` can run
  the suite's `javascript/elysia-bun` entry and take another checkout's
  extension module or extra server flags.

---

## 1.1.1 — 2026-09-13

Tag `v1.1.1` on `e2d49f6`. The server is unchanged from 1.1.0.

### Fixed

- The links in the project description on PyPI work. The README linked to the
  other guides by paths relative to the repository, which GitHub resolves and
  PyPI does not; they are full URLs now.

### Changed

- A new logo in the README and every guide.

---

## 1.1.0 — 2026-09-13

Tag `v1.1.0` on `a99b35e`.

### The server runs inside your Python

- `pip install peregrine-server` installs the server as `peregrine._native`, a
  CPython extension module that the `peregrine` command loads into the
  interpreter it was installed into. Before, it was a standalone executable
  embedding `libpython`. The command and its options are unchanged.
- Framework code runs 10–16 % faster that way, inside a distribution `python3`
  rather than a shared `libpython`.
- Wheels for CPython 3.11, 3.12, 3.13, 3.14 and free-threaded 3.14t on Linux
  (`manylinux_2_39_x86_64`).
- Server processes are named `peregrine`, so `top`, `pgrep` and `pkill` find
  them.
- `PEREGRINE_BUILD=binary` still builds the standalone executable, and
  `swift build` still produces it for development.
- The Docker image builds the extension module: copy its `/usr/local`, or
  `pip install` the wheel it exports.

### Faster

- Responses leave in batches instead of one write each: FastAPI 1.8× and
  Flask 1.5× on one worker, before the extension module added its share.
- Static files 73 % faster: one kernel walk per path, one write per small
  file.
- HTTP/3 downloads cost half the CPU. The QUIC congestion window is enforced
  (it was sending 17× what it needed), and datagrams go out in runs with UDP
  GSO.
- One worker on a 4-core machine, FastAPI at 64 / 256 / 512 connections:
  24,672 / 24,117 / 24,320 requests a second, against 17,504 / 15,544 / 15,114
  for uvicorn. Method, the other servers, Flask, and why these figures are not
  comparable with the ones the-benchmarker/web-frameworks publishes:
  [BENCHMARKS.md](BENCHMARKS.md).

### New options

- `--compress`, `--compress-static`: br, zstd or gzip, as the client accepts.
- `--rate-limit`, `--rate-limit-burst`: per client, shared by every worker.
- `--static-dir PREFIX=DIR`: files served by the server, with `sendfile`.
- `--acme-domain`: certificates from Let's Encrypt, renewed automatically.
- Several certificates on one listener, chosen by SNI.
- `--redirect-http`, `--hsts`.
- `--drain-delay`: keep serving while a load balancer catches up on SIGTERM.
- `--health-check-path`: a liveness probe answered without the application.
- `--request-id`, `--request-start-header`.
- `--ws-compress`: WebSocket permessage-deflate.
- `peregrine.logging`: Python logging into the server log.

### Fixed

- A worker could spin at 100 % CPU, ignoring SIGTERM, after a WebTransport or
  WebSocket connection closed under a running session.
- A shutdown signal arriving while a worker was starting was lost.
- A reload hands each worker over to its replacement, waits for the
  replacement to be serving before retiring the old one, and works under every
  execution model, so SIGHUP always reloads.
- `peregrine_workers` reported twice the worker count.
- With every waiting place on the metrics port taken, a new scrape was
  answered before its request had arrived and could lose its response to a
  reset. The one that has waited longest gives up its place instead.
- The rate limiter and the ACME client build on macOS.

### Documentation

- The guides focus on FastAPI (ASGI) and Flask (WSGI).
- [INSTALLATION.md](INSTALLATION.md) covers the extension module, wheels and
  free-threaded builds; [DEPLOY.md](DEPLOY.md) covers how a release reaches
  PyPI.

---

## 1.0.0 — 2026-09-11

Tag `v1.0.0` on `38b4fd7`.

- Relocatable Linux wheels: the server executable with the Swift runtime
  vendored beside it, using the `libpython` of the interpreter that installs
  it. Built by the Wheels workflow, one wheel per interpreter.
- PyPI classifier Production/Stable.
- The benchmark figures measured again on the tree as released.
- The documentation uses the cursive logo.

---

## 0.8.0 — 2026-09-11

The first version on PyPI, as an sdist only: `pip install` compiled it, and
needed Swift. No tag.

- A Python ASGI and WSGI server written in Swift, in the same process as
  CPython.
- HTTP/1.1; HTTP/2 over TLS, with ALPN choosing it; HTTP/3 over a QUIC stack of
  its own, advertised with Alt-Svc; WebSocket; WebTransport over HTTP/3.
- WSGI over HTTP/2 and HTTP/3 as well as HTTP/1.1, with response blocks sent
  as the application produces them.
- `--free-threaded`: workers share one interpreter on a GIL-free CPython, with
  the ASGI lifespan run per worker loop.
- Prometheus metrics on a port of their own; access logs in JSON on request.
- Framing enforced rather than trusted: Transfer-Encoding parsed as a coding
  list, a second Host refused, chunked trailers bounded like the head.
- Peers charged for the HTTP/2 and HTTP/3 streams they cancel, and a QUIC
  address believed only once a packet from it decrypts.
- The parsers that read from the network are fuzzed.
- A Dockerfile that builds the server inside the CPython it serves.
