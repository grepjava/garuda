<p align="center">
  <img src="assets/peregrine-fiery-roaring.png" alt="peregrine" width="480">
</p>

# Benchmarks

Two questions, answered with the load command and the applications of
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/),
but on one worker and on a different machine. The figures here are **not**
comparable with the ones that site publishes; see
[Relation to the published results](#relation-to-the-published-results).

1. **FastAPI (ASGI):** Peregrine against uvicorn, granian and fastpysgi, one
   worker, at 64, 256 and 512 connections.
2. **Flask (WSGI):** Peregrine against uvicorn, granian and fastpysgi, one
   worker, at 64, 256 and 512 connections.

[Extension 1.1.2](#extension-112-1-worker) adds the next build under the same
load: unchanged throughput, the response cache, Elysia on Bun beside it, and
kernel TLS for static files.

On one worker of this machine Peregrine answers FastAPI 1.41–1.60× as fast as
the next server at each level, and Flask 1.42–1.47× as fast as the next server
(fastpysgi) and more than twice as fast as uvicorn and granian. That is
Peregrine as a wheel installs it, the `peregrine._native` extension module; the
standalone executable, which embeds `libpython`, is 10–16 % behind it.

---

## Method

The load command and the applications are the benchmark suite's own, taken from
[the-benchmarker/web-frameworks at ac364e9](https://github.com/the-benchmarker/web-frameworks/tree/ac364e9b1674c9f9edd184afc9a876a75fbcdf10)
(`master`, 2026-09-11), the revision whose results the site showed when these
were measured. The machine, the worker count, the Python version and some of
the servers are not, and every difference is listed below.

| | |
|---|---|
| Load generator | [zrk](https://github.com/zoxy-io/zrk) 2.5.0 |
| Warm-up | `zrk -c 50 -d 5s --plain URL` |
| Each level | `zrk --plain -c N -d 15s -m GET --format json -R1000:100000 --interval 1s --timeout 8s --latency URL` |
| Levels | 64, 256 and 512 connections, `GET /` |
| Figure | zrk's `achieved_rate`, in requests per second |
| Latency | p50 and p99, corrected for coordinated omission |
| Applications | the suite's `python/fastapi` and `python/flask` sources, byte for byte: [benchmarks/contract/](benchmarks/contract/) |
| Servers | uvicorn and granian with the suite's engine commands and `--workers 1`; Peregrine as `python -m peregrine` and as the executable; fastpysgi and uvicorn's WSGI adapter as described below |
| Host | WSL2 on 4 cores, Ubuntu 24.04, CPython 3.12.3, load generator on the same machine |

Versions: FastAPI 0.141.1 (Starlette 1.6.0, Pydantic 2.13.5), Flask 3.1.3
(Werkzeug 3.1.8), uvicorn 0.52.4 with uvloop 0.22.1 and httptools 0.8.0, granian 2.8.2,
fastpysgi 0.6.

The load command is the suite's `collect` command, `.tasks/config.rake` line 152
at that revision: an open-loop ramp from 1,000 to 100,000 requests a second over
the run, with keep-alive on. Two things in the suite say otherwise and are out
of date. Its README describes oha with keep-alive disabled, and the comment just
above the command describes `--closed`, a closed loop in which each response
triggers the next request — but the command does not pass `--closed`. The
repository does not record which command produced a published dataset. The
site's latencies, a p99 of about 5 s for FastAPI on uvicorn, are what this ramp
produces and a closed loop would not.

Every figure below comes from one session, one server after another. Separate
sessions on this machine differ by up to 10 %, which is more than some of the
gaps being measured.

**Where this differs from upstream:**

| | upstream at ac364e9, published 2026-09-11 | here |
|---|---|---|
| Host | 16 CPUs, 7.7 GB, Linux 7.1 (Fedora) | WSL2 on 4 cores, 31 GB, Ubuntu 24.04 |
| Workers | `--workers $(nproc)`, one per CPU | 1 |
| Python | 3.14 | 3.12.3 |
| FastAPI entry | uvicorn (hypercorn, daphne and granian are also configured) | Peregrine, uvicorn, granian, fastpysgi |
| Flask entry | gunicorn with sync workers (uwsgi, waitress and granian are also configured) | Peregrine, uvicorn's WSGI adapter, granian, fastpysgi |
| fastpysgi | raw ASGI and WSGI applications, no framework | the FastAPI and Flask applications |
| Runs | request counts are published in thirds, so each figure is a mean of three runs | three runs, the median by `achieved_rate` |

- **One worker.** It compares what each server does with a core, and keeps the
  load generator from competing with the servers for the same four cores. It is
  also the main reason these figures cannot be set beside the site's: a server's
  throughput on sixteen workers is not sixteen times its throughput on one, and
  dividing the site's figures by sixteen does not give a single-worker result.
- **Median rather than mean.** A developer machine is noisier than a dedicated
  benchmark host, and one disturbed run moves a mean of three more than a median.
- **Peregrine is measured in both forms.** `peregrine` is `python -m peregrine`
  with the extension module, which is what a wheel installs. The executable
  row is the same server built as a standalone binary embedding `libpython`.
  Peregrine is not on the site.
- **uvicorn serves Flask through `--interface wsgi`.** The suite has no uvicorn
  engine for Flask; its Flask engines are gunicorn, uwsgi, waitress and granian.
  uvicorn's WSGI adapter is included here because the comparison asked for is
  the same servers on both frameworks.
- **fastpysgi serves the FastAPI and Flask applications.** The suite's
  `fastpysgi-asgi` and `fastpysgi-wsgi` entries run hand-written raw ASGI and
  WSGI applications. Here the same launch they use,
  `fastpysgi.run(app, host, port, workers=N)`, is given the FastAPI and Flask
  applications every other server runs, so the framework is the same for all.

### Relation to the published results

The site shows one entry per framework, each on its default server with a
worker per CPU. At ac364e9 the entries these benchmarks touch are, in requests
per second at 64 / 256 / 512 connections:

| site entry | what it runs | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| `fastapi` | FastAPI on uvicorn | 41,461 | 44,182 | 43,226 |
| `flask` | Flask on gunicorn, sync workers | 1,413 | 8,866 | 6,376 |
| `fastpysgi-asgi` | a raw ASGI application, no framework | 92,108 | 89,267 | 88,817 |
| `fastpysgi-wsgi` | a raw WSGI application, no framework | 96,673 | 96,557 | 96,483 |

None of them measures what the tables below measure. They use every one of
sixteen CPUs rather than one worker, Python 3.14 rather than 3.12, a different
server for Flask, and for fastpysgi no framework at all. The tables below show
how these servers compare with each other on one worker of this machine —
Peregrine 1.4–1.6× uvicorn and granian on FastAPI, for instance — and the
published results neither confirm nor contradict that.

Source: [`data.min.json` at ac364e9](https://github.com/the-benchmarker/web-frameworks/blob/ac364e9b1674c9f9edd184afc9a876a75fbcdf10/data.min.json),
the file the site's frontend loads.

**Reading the latencies.** The ramp ends far above what any of these servers
can do on one core, so for most of each run requests are offered faster than
they are answered. Latency corrected for coordinated omission counts the time a
request waited to be sent, so it measures how fast that queue grows: seconds,
not milliseconds. Compare the servers here with each other — not with a
closed-loop benchmark, and not with the site's latencies, which come from the
same ramp on a machine with four times the cores and sixteen workers.

Reproduce:

```bash
PYTHON=~/fastapi-bench-venv/bin/python bash scripts/build-extension.sh
swift build -c release --scratch-path ~/pgbuild
bash benchmarks/frameworks.sh > results.tsv
```

`WORKERS`, `CONNS`, `RUNS`, `DURATION`, `FRAMEWORKS`, `SERVERS`, `VENV`,
`PEREGRINE`, `ZRK`, `CONTRACT`, `EXT_ROOT`, `PEREGRINE_EXTRA_ARGS` and `BUN`
override the defaults. The virtualenv needs `fastapi`,
`flask`, `uvicorn[standard]`, `granian` and `fastpysgi`; `peregrine-ext` needs
the extension module built for that virtualenv's python, and `peregrine` the
executable.

---

## FastAPI (ASGI), 1 worker

Requests per second:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | **24,672** | **24,117** | **24,320** |
| Peregrine, executable | 21,696 | 21,841 | 21,504 |
| uvicorn | 17,504 | 15,544 | 15,114 |
| granian | 15,647 | 15,574 | 15,209 |
| fastpysgi, running FastAPI | 11,337 | 10,843 | 10,264 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 1.45 / 4.95 | 1.55 / 5.25 | 1.56 / 5.25 |
| Peregrine, executable | 1.82 / 5.75 | 1.79 / 5.65 | 1.63 / 5.65 |
| uvicorn | 2.46 / 7.03 | 2.52 / 7.01 | 2.55 / 7.23 |
| granian | 2.41 / 6.97 | 2.46 / 6.98 | 2.43 / 6.96 |
| fastpysgi, running FastAPI | 3.10 / 8.03 | 3.09 / 8.23 | 3.25 / 8.35 |

No server returned an error or a non-2xx response at any level.

## Flask (WSGI), 1 worker

Requests per second:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | **14,768** | **14,992** | **14,458** |
| Peregrine, executable | 13,084 | 13,029 | 12,488 |
| fastpysgi, running Flask | 10,419 | 10,202 | 9,978 |
| uvicorn (`--interface wsgi`) | 6,554 | 6,545 | 5,722 |
| granian | 6,427 | 6,152 | 6,257 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 2.51 / 7.11 | 2.52 / 7.06 | 2.53 / 7.24 |
| Peregrine, executable | 2.52 / 7.57 | 2.77 / 7.55 | 2.50 / 7.49 |
| fastpysgi, running Flask | 3.27 / 8.34 | 3.27 / 8.37 | 3.28 / 8.41 |
| uvicorn (`--interface wsgi`) | 3.97 / 9.68 | 3.91 / 9.55 | 4.11 / 9.75 |
| granian | 3.90 / 9.67 | 4.14 / 9.82 | 4.08 / 9.83 |

No server returned an error or a non-2xx response at any level.

---

## Extension 1.1.2, 1 worker

The build after 1.1.1 adds trace context, a response cache, notified reload and
kernel TLS. It was measured as the extension module in one session on
2026-09-13, with the same load, applications and machine as the tables above.
Elysia on Bun ran in the same session as a non-Python reference. The version in
the code is still 1.1.1; "1.1.2" names this build.

Requests per second:

| server | application | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| Peregrine 1.1.2 | FastAPI | 25,681 | 24,960 | 24,520 |
| Peregrine 1.1.1, [above](#fastapi-asgi-1-worker) | FastAPI | 24,672 | 24,117 | 24,320 |
| Peregrine 1.1.2 | Flask | 15,143 | 15,158 | 15,036 |
| Peregrine 1.1.1, [above](#flask-wsgi-1-worker) | Flask | 14,768 | 14,992 | 14,458 |
| Peregrine 1.1.2, `--cache-size 64` | FastAPI, responses fresh for 60 s | 96,636 | 96,472 | 96,370 |
| Peregrine 1.1.2, `--cache-size 64` | Flask, responses fresh for 60 s | 96,642 | 96,521 | 96,390 |
| Elysia 1.4.30 on Bun 1.4.2 | the suite's `javascript/elysia-bun` | 96,610 | 96,455 | 96,442 |

Latency, p50 / p99, in milliseconds:

| server | application | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| Peregrine 1.1.2 | FastAPI | 1,438 / 4,966 | 1,455 / 5,024 | 1,602 / 5,196 |
| Peregrine 1.1.2 | Flask | 2,481 / 7,051 | 2,422 / 6,961 | 2,532 / 7,039 |
| Peregrine 1.1.2, `--cache-size 64` | FastAPI | 0.051 / 6.9 | 0.053 / 10.1 | 0.055 / 3.1 |
| Peregrine 1.1.2, `--cache-size 64` | Flask | 0.052 / 15.1 | 0.052 / 8.2 | 0.055 / 4.5 |
| Elysia 1.4.30 on Bun 1.4.2 | | 0.057 / 4.8 | 0.069 / 13.5 | 0.061 / 3.7 |

No server returned an error or a non-2xx response at any level.

- **Without the cache, 1.1.2 is 1.1.1.** It is 1–4 % ahead at every level, but
  the 1.1.1 figures come from an earlier session, and sessions on this machine
  differ by up to 10 %. Read it as no regression, not as a speed-up. Every new
  feature is off unless its option is given.
- **About 96,500 requests a second is the ceiling of this load, not a server's
  capacity.** The ramp offers requests no faster than that over a 15 s run,
  and a server that answers everything it is offered reaches it. The
  sub-millisecond p50 shows these three rows did. Upstream's `fastpysgi-wsgi`
  publishes 96,673 on sixteen CPUs for the same reason. So cached Peregrine and
  Elysia both exceed what this benchmark can measure, and the table does not
  say which is faster. The cache is at least 3.8× uncached FastAPI and 6.4×
  uncached Flask.
- **The cached rows are a best case, not a production figure.** Every request
  is the same GET with no cookie, for a response marked fresh, so every
  request after the first is a hit. Real traffic has cookies and credentials,
  which are never cached, many URLs, and responses the application does not
  mark fresh. It lands between the cached and uncached rows, according to its
  hit rate.
- **A cache hit never reaches Python.** The response is copied out of memory
  every worker shares, in Swift, and the framework, which is most of the work,
  is not run. Only GET responses the application marks fresh with `s-maxage`
  or `max-age` are kept. Requests with cookies or credentials, and responses
  that set cookies or are private, never are; see
  [Caching responses](CONFIG.md#caching-responses). The cached applications,
  [benchmarks/cached/](benchmarks/cached/), are the contract ones plus
  `Cache-Control: public, s-maxage=60`.
- **Elysia runs as one process.** The suite's entry runs `cluster.ts`, which
  starts one `bun ./app.ts` per CPU. Here `app.ts` runs alone, to match one
  worker. The sources are the suite's, byte for byte:
  [benchmarks/elysia-bun/](benchmarks/elysia-bun/).

### Static files over HTTPS, with `--ktls`

With `--ktls` the kernel encrypts TLS, so `--static-dir` files go out with
`sendfile` over HTTPS, as they already did over plain HTTP. This was measured
earlier on the same branch with
[benchmarks/static_files.sh](benchmarks/static_files.sh). That is a different
load from the tables above: closed-loop `oha`, 16 connections, 10 s per cell,
one worker, random bytes read into the page cache first.

| file | HTTPS, MiB/s | with `--ktls`, MiB/s | server CPU per GiB | with `--ktls` |
|---|---:|---:|---:|---:|
| 1 MiB | 1,485 | 2,172 (+46 %) | 713 ms | 495 ms (−31 %) |
| 16 MiB | 1,384 | 2,206 (+59 %) | 767 ms | 491 ms (−36 %) |

Plain HTTP costs 64–77 ms of server CPU per GiB on the same machine. Of the
roughly 420 ms per GiB HTTPS still adds with `--ktls`, about half is the
AES-256-GCM encryption itself, 218 ms per GiB, which kernel TLS moves into the
kernel but does not remove.

Reproduce, with the kernel's `tls` module loaded (`sudo modprobe tls`):

```bash
MODES=https bash benchmarks/static_files.sh
PEREGRINE_EXTRA_ARGS=--ktls MODES=https bash benchmarks/static_files.sh
```

The framework rows:

```bash
SERVERS=peregrine-ext bash benchmarks/frameworks.sh
CONTRACT=benchmarks/cached PEREGRINE_EXTRA_ARGS="--cache-size 64" SERVERS=peregrine-ext bash benchmarks/frameworks.sh
FRAMEWORKS=elysia SERVERS=elysia-bun bash benchmarks/frameworks.sh
```

The Elysia row needs [Bun](https://bun.sh) and port 3000, since the suite's
`app.ts` listens there. The script runs `bun install` the first time.

### BlackSheep on Peregrine, and Elysia on Bun past the ceiling

Measured in one session on 2026-09-13, at 9d1aace:
- **Applications:** [BlackSheep](https://github.com/Neoteroi/BlackSheep) 2.6.3,
  run as ASGI in the extension module
  ([benchmarks/contract/blacksheep_app.py](benchmarks/contract/blacksheep_app.py),
  the same as the suite's `python/blacksheep`); Elysia 1.4.30 on Bun 1.4.2.
- **Setup:** one worker or process each, on CPython 3.12.

First the suite's ramp, as in the tables above, which cannot tell the two apart
at the top:

| server | 64 | 256 | 512 | p50 / p99 ms at 64 |
|---|---:|---:|---:|---:|
| BlackSheep on Peregrine | 76,321 | 78,735 | 75,042 | 0.458 / 406.9 |
| Elysia on Bun | 96,659 | 96,490 | 96,407 | 0.057 / 16.4 |

Then closed-loop capacity. The server is pinned to one CPU and `oha` to the
other three, and each connection sends its next request as soon as the last is
answered:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| BlackSheep on Peregrine | 74,781 | 72,996 | 70,757 |
| Elysia on Bun | 208,830 | 242,964 | 237,983 |

Latency, p50 / p99, in milliseconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| BlackSheep on Peregrine | 0.790 / 2.5 | 3.159 / 10.1 | 6.593 / 18.6 |
| Elysia on Bun | 0.271 / 0.8 | 0.951 / 2.8 | 1.934 / 5.7 |

No run returned an error or a non-2xx response. Every figure is the median of
three runs.

- **On one core, Elysia on Bun serves 2.8–3.4× what BlackSheep on Peregrine
  does.** The ramp hid this: Elysia answered everything it was offered, and
  BlackSheep fell behind at about 76,000, which its p99 of hundreds of
  milliseconds shows.
- **BlackSheep is the fastest Python framework measured here**, about three
  times FastAPI's 25,000 on the same server.
- **The load may be what limits Elysia.** Three CPUs of `oha` against one of
  Bun, so its figure is a floor rather than its ceiling.

```bash
FRAMEWORKS=blacksheep SERVERS=peregrine-ext bash benchmarks/frameworks.sh
LOAD=closed PIN=0:1-3 FRAMEWORKS=blacksheep SERVERS=peregrine-ext bash benchmarks/frameworks.sh
LOAD=closed PIN=0:1-3 FRAMEWORKS=elysia SERVERS=elysia-bun bash benchmarks/frameworks.sh
```

BlackSheep has to be installed in the benchmark venv: `pip install blacksheep`.

---

## The ASGI path, change by change

Changes to the per-request ASGI path since 1.1.2, unreleased. Each was
measured on its own against the build before it, and kept only if it helped.

[benchmarks/turbo_ab.sh](benchmarks/turbo_ab.sh) runs two builds of the
extension module in one session:
- **Server:** one worker pinned to one CPU.
- **Load:** closed-loop `oha -c 64` for 15 s on the other three CPUs.
- **Rounds:** six, interleaved A B then B A, after an A/A calibration run
  whose spread is that session's noise.
- **Second measure:** alongside requests per second, the server's own CPU
  time per request, read from `/proc/<pid>/task/*/schedstat`. It moves less
  than req/s when the load generator is what is short of CPU.

The applications are the raw ASGI app,
[benchmarks/contract/asgi.py](benchmarks/contract/asgi.py), and the FastAPI
app above. Figures are medians of the six rounds.

On this build a raw ASGI request costs the server about 9 µs of CPU, at about
116,000 requests a second on one worker. That replaces an older 60,000 from
before responses were batched and before the extension module. A FastAPI
request costs about 43 µs, most of it FastAPI's own code.

| change | application | req/s | server CPU per request | rounds B faster, cheaper | A/A spread, req/s and CPU | kept |
|---|---|---:|---:|:---:|:---:|:---:|
| `await send()` finishes without creating a `StopIteration` | raw ASGI | 116,099 → 118,728 (+2.3 %) | 9.21 → 9.00 µs (−2.4 %) | 5/6, 6/6 | 0.7 %, 1.0 % | yes |
| | FastAPI | 25,098 → 24,984 (−0.5 %) | 42.97 → 42.65 µs (−0.7 %) | 3/6, 2/6 | 2.7 %, 2.1 % | |
| a finished task checked with `task.exception()` from Swift, not a Python function | raw ASGI | 115,556 → 114,261 (−1.1 %) | 9.22 → 9.46 µs (+2.5 %) | 2/6, 2/6 | 4.5 %, 3.2 % | no |
| | FastAPI | 25,033 → 24,912 (−0.5 %) | 42.65 → 42.98 µs (+0.8 %) | 3/6, 2/6 | 0.1 %, 0.3 % | |
| one completed awaitable per worker for every `send`, not one allocated per call | raw ASGI | 117,640 → 119,136 (+1.3 %) | 9.03 → 8.93 µs (−1.1 %) | 3/6, 4/6 | 4.0 %, 3.9 % | no |
| | FastAPI | 25,175 → 25,165 (−0.0 %) | 42.58 → 42.52 µs (−0.1 %) | 3/6, 4/6 | 0.9 %, 0.0 % | |
| each request's task started eagerly, so an application that never waits finishes before dispatch returns | raw ASGI | 96,693 → 105,157 (+8.8 %) | 10.48 → 9.42 µs (−10.2 %) | 6/6, 6/6 | 4.3 %, 5.3 % | no |
| | FastAPI | 20,906 → 20,466 (−2.1 %) | 48.74 → 49.82 µs (+2.2 %) | 2/6, 2/6 | 0.3 %, 1.2 % | |

- **A change within noise on FastAPI is expected.** The framework is most of
  a FastAPI request, so a saving of a fraction of a microsecond on the server
  side is a percent of a raw ASGI request and a fraction of one on FastAPI.
- **The second change is why every change goes through the server.**
  [benchmarks/asgi_overhead.py](benchmarks/asgi_overhead.py), which times the
  same asyncio work in-process, predicted it would save 0.23–0.29 µs a
  request. Measured end to end, it saved nothing.
- **Eager start helped raw ASGI and hurt everything else.** From Python 3.12 a
  task can run its coroutine's first step as it is created, and every request
  in both applications finished inside that step. In-process it saved
  0.8–1.0 µs of the task's cost. The row above is the second of two sessions.
  The first gave raw ASGI +10.7 % and −10.4 % and FastAPI −1.0 % and +1.0 %,
  inside an A/A spread of 5.7 % and 6.6 %. In every round of both, latency
  was worse:
  - FastAPI p99 8.33–9.05 ms against 6.50–7.09 ms, and p50 2.69–2.77 ms
    against 2.57–2.64 ms.
  - Raw ASGI p99 2.35–2.55 ms against 2.19–2.37 ms.

  Nothing found explains the latency. It is not a longer drain taking in
  more requests, because the poller is read once per wakeup. So it was
  reverted.
- **The in-process benchmark does size what is left.** With uvloop, the
  asyncio task each request runs in costs 1.1–1.3 µs of the ~9. Building the
  scope costs 0.6–0.8 µs for 3 headers and about 1.5 µs for 15. Neither is
  the bulk of it.
- **Where the rest goes, sampled.** One worker's CPU was sampled every
  millisecond under the same load, about 5,700 samples each. A raw ASGI
  request divides as follows:
  - `write()` 42 % and the other system calls 7 %. On loopback, sending a
    response also delivers it to the load generator's socket, so this share
    is higher than it would be over a network.
  - The Python interpreter 32 %: the application and the asyncio work around
    it. The distribution's `python3.12` carries no symbols to split it further.
  - Peregrine's own Swift and C 10 %, of which parsing the request is 1.5 %
    and building the scope 1 %.
  - uvloop 4 %.

  On FastAPI the interpreter is 80 %, `write()` 9 % and Peregrine 3.5 %. The
  callable Peregrine's channels are called through is 0.1 %, so nothing left
  on the server side is large enough for another change like these to show.

Reproduce, with two checkouts each built with `scripts/build-extension.sh`:

```bash
BUILD_A=../peregrine-before BUILD_B=. bash benchmarks/turbo_ab.sh
python benchmarks/asgi_overhead.py
```

### Response bodies by size

What a response body costs, as it grows.
[benchmarks/bodies_app.py](benchmarks/bodies_app.py) answers `GET /<bytes>`
with a body of that many random bytes, built once and kept, so the
application's work is the same at every size. It runs on one worker pinned to
one CPU, with closed-loop `oha -c 64` for 10 s on the other three.
Measured on 2026-09-13.

| body | req/s | MiB/s | server CPU per request | per KiB |
|---:|---:|---:|---:|---:|
| 1 KiB | 105,159 | 103 | 9.99 µs | 9.99 µs |
| 16 KiB | 67,932 | 1,061 | 16.18 µs | 1.01 µs |
| 64 KiB | 44,450 | 2,778 | 23.90 µs | 0.37 µs |
| 256 KiB | 17,433 | 4,358 | 61.03 µs | 0.24 µs |
| 1 MiB | 4,943 | 4,943 | 220.81 µs | 0.22 µs |

Sampled the same way as above, the server's CPU divides like this:

| body | `write()` | copies and the rest of libc | Python | Peregrine |
|---:|---:|---:|---:|---:|
| 1 KiB | 40.5 % | 2.8 % | 30.9 % | 11.4 % |
| 64 KiB | 52.1 % | 8.8 % | 22.1 % | 7.0 % |
| 1 MiB | 66.1 % | 23.6 % | 6.0 % | 1.6 % |

- **The body is copied twice, and the kernel's copy is the bigger one.** It is
  copied once from the application's `bytes` into the connection's write
  buffer, and once into the socket inside `write()`. Over loopback that second
  copy also delivers into the load generator's socket.
- **The copy in userspace is what not copying could save, and it only matters
  when the body is large.** libc's unnamed functions, which are `memmove`
  here, are about 3 % of the CPU at 1 KiB, which is the floor, 9 % at 64 KiB
  and 24 % at 1 MiB. Writing a large body straight from the application's
  `bytes`, with `writev`, could save at most about 6 % of the CPU at 64 KiB
  and about 20 % at 1 MiB. It saves nothing on a typical API response of a
  few KiB, where Python is the cost.

```bash
bash benchmarks/body_sizes.sh
```

---

## What the gap is made of

On a hello-world route the framework is most of the work, so the difference
between servers is the part of each request that is not the framework:
parsing, calling into Python, and writing the response.

- **Peregrine has no Python in its request path.** Parsing, the ASGI scope or
  WSGI environ, and response framing are all in Swift. uvicorn's HTTP protocol
  and its WSGI adapter are Python; granian's WSGI path hands each request across
  threads.
- **Responses leave in batches.** A write wakes the reader on the other end of
  the socket, and that wake-up costs more than the write itself. FastAPI
  responses go out together at the end of each event-loop iteration, and Flask
  responses at the end of each batch of events. Before this, a FastAPI request
  spent 18 µs in `write()` against uvicorn's 3.5 µs.
- **Where Python's own code lives matters.** A distribution `python3.12` is a
  statically linked, position-dependent executable. The same FastAPI code runs
  about 16 % slower in `libpython3.12.so`, where every call inside the
  interpreter goes through the tables a shared library needs. The executable
  has to load that library; the extension module runs inside `python3.12`,
  like uvicorn, granian and fastpysgi do. That is the whole difference between
  the two Peregrine rows.

---

## Processes or free-threaded

The same two applications with `--workers N` (processes, CPython 3.12) and with
`--workers N --free-threaded` (threads of one process, CPython 3.14t), both
through the extension module. Closed-loop `oha`, 15 s per cell, requests per
second — a different load from the tables above, so the two are not comparable
either:

| application | workers | model | 64 | 256 | 512 |
|---|---:|---|---:|---:|---:|
| FastAPI | 1 | processes | 25,125 | 25,177 | 24,386 |
| FastAPI | 1 | free-threaded | 23,841 | 23,953 | 24,673 |
| FastAPI | 4 | processes | 72,772 | 80,493 | 80,262 |
| FastAPI | 4 | free-threaded | 66,230 | 70,931 | 71,665 |
| Flask | 1 | processes | 14,799 | 14,749 | 14,799 |
| Flask | 1 | free-threaded | 14,016 | 14,044 | 14,122 |
| Flask | 4 | processes | 52,512 | 54,306 | 53,444 |
| Flask | 4 | free-threaded | 41,222 | 41,801 | 41,867 |

With four workers, threads reach 88–91 % of four processes on FastAPI and
77–79 % on Flask.

That is threading model **and** interpreter version, not a clean A/B: 3.14t
pays a single-thread reference-counting cost that 3.12 does not. On a
hello-world route `--free-threaded` is not a throughput upgrade. It is for
memory and for state shared across workers: with a CPU-bound application, four
threads match four processes at a third of the resident memory, because the
application is imported once — see
[Free-threaded Python](CONFIG.md#free-threaded-python).

Reproduce with `EXTENSION=1 bash benchmarks/gil_vs_ft.sh`. It needs the
extension module built for both interpreters — `scripts/build-extension.sh`
with `PYTHON` set to each, and `PKG_CONFIG_PATH` pointing at the free-threaded
one's `lib/pkgconfig` — and a virtualenv for each with FastAPI and Flask.
Without `EXTENSION=1` it runs two executables instead, one linked against each
interpreter. `GIL_BIN`, `FT_BIN`, `GIL_VENV`, `FT_VENV`, `APPS`, `DURATION`
and `CONNS` override the defaults.
