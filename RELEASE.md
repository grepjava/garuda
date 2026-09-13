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

### New options

- `--trace-context`: a request's W3C `traceparent`, its trace ID and parent
  span ID, recorded in the access log. Never generated, and never changed on
  its way to the application.

### Changed

- `--reload` notices a save within a few tens of milliseconds, woken by
  inotify on Linux and kqueue on macOS instead of waiting for the next scan.
  The scan every `--reload-interval` stays, for filesystems that send no
  notification.

### Documentation

- `RELEASE.md` records what changed in every version, linked from the README.

---

## 1.1.1 — 2026-09-13

Tag `v1.1.1` on `c00bf07`. The server is unchanged from 1.1.0.

### Fixed

- The links in the project description on PyPI work. The README linked to the
  other guides by paths relative to the repository, which GitHub resolves and
  PyPI does not; they are full URLs now.

### Changed

- A new logo in the README and every guide.

---

## 1.1.0 — 2026-09-13

Tag `v1.1.0` on `575597b`.

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

Tag `v1.0.0` on `9ce817e`.

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
