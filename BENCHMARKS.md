<p align="center">
  <img src="assets/peregrine-cursive-segoe.png" alt="peregrine" width="480">
</p>

# Benchmarks

Two questions, answered the way
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/)
answers them:

1. **FastAPI (ASGI):** Peregrine against uvicorn, granian and fastpysgi, one
   worker, at 64, 256 and 512 connections.
2. **Flask (WSGI):** Peregrine against uvicorn, granian and fastpysgi, one
   worker, at 64, 256 and 512 connections.

On one worker Peregrine answers FastAPI 1.41–1.60× as fast as the next server
at each level, and Flask 1.42–1.47× as fast as the next server (fastpysgi) and
more than twice as fast as uvicorn and granian. That is Peregrine as a wheel
installs it, the `peregrine._native` extension module; the standalone
executable, which embeds `libpython`, is 10–16 % behind it.

---

## Method

The load, the applications and the server commands are the benchmark suite's
own. Only the worker count and the number of runs differ, and both are stated
below.

| | |
|---|---|
| Load generator | [zrk](https://github.com/zoxy-io/zrk) 2.5.0 |
| Warm-up | `zrk -c 50 -d 5s --plain URL` |
| Each level | `zrk --plain -c N -d 15s -m GET --format json -R1000:100000 --interval 1s --timeout 8s --latency URL` |
| Levels | 64, 256 and 512 connections, `GET /` |
| Figure | zrk's `achieved_rate`, in requests per second — the number the results site ranks by |
| Latency | p50 and p99, corrected for coordinated omission |
| Applications | the suite's `python/fastapi` and `python/flask` sources, byte for byte: [benchmarks/contract/](benchmarks/contract/) |
| Servers | the suite's engine commands, with `--workers 1`; Peregrine as `python -m peregrine` and as the executable |
| Host | WSL2 on 4 cores, Ubuntu 24.04, CPython 3.12.3, load generator on the same machine |

Versions: FastAPI 0.141.1 (Starlette 1.6.0, Pydantic 2.13.5), Flask 3.1.3
(Werkzeug 3.1.8), uvicorn 0.52.4 with uvloop 0.22.1 and httptools 0.8.0, granian 2.8.2,
fastpysgi 0.6.

The command is taken from the suite's `.tasks/config.rake`, which is what its
`collect` targets run. Its README and some comments still describe an older
setup (oha, keep-alive disabled). The command itself is an open-loop ramp from
1,000 to 100,000 requests a second over the run, with keep-alive on.

Every figure below comes from one session, one server after another. Separate
sessions on this machine differ by up to 10 %, which is more than some of the
gaps being measured.

**Where this differs from the published results, and why:**

- **One worker.** The suite starts every server with `--workers $(nproc)`. One
  worker compares what each server does with a core, and keeps the load
  generator from competing with the servers for the same four cores.
- **Median of three runs.** The suite takes one run per level. A developer
  machine is noisier than a dedicated benchmark host, so each level runs three
  times and the median run by `achieved_rate` is reported.
- **Peregrine is measured in both forms.** `peregrine` is `python -m peregrine`
  with the extension module, which is what a wheel installs. The executable
  row is the same server built as a standalone binary embedding `libpython`.
- **uvicorn serves Flask through `--interface wsgi`.** The suite has no uvicorn
  engine for Flask; its Flask engines are gunicorn, uwsgi, waitress and granian.
  uvicorn's WSGI adapter is included here because the comparison asked for is
  the same servers on both frameworks.
- **fastpysgi serves the FastAPI and Flask applications.** The suite's
  `fastpysgi-asgi` and `fastpysgi-wsgi` entries run hand-written raw ASGI and
  WSGI applications. Here the same launch they use,
  `fastpysgi.run(app, host, port, workers=N)`, is given the FastAPI and Flask
  applications every other server runs, so the framework is the same for all.

**Reading the latencies.** The ramp ends far above what any of these servers
can do on one core, so for most of each run requests are offered faster than
they are answered. Latency corrected for coordinated omission counts the time a
request waited to be sent, so it measures how fast that queue grows: seconds,
not milliseconds. Compare the servers with each other, not with a closed-loop
benchmark.

Reproduce:

```bash
PYTHON=~/fastapi-bench-venv/bin/python bash scripts/build-extension.sh
swift build -c release --scratch-path ~/pgbuild
bash benchmarks/frameworks.sh > results.tsv
```

`WORKERS`, `CONNS`, `RUNS`, `DURATION`, `FRAMEWORKS`, `SERVERS`, `VENV`,
`PEREGRINE` and `ZRK` override the defaults. The virtualenv needs `fastapi`,
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
| fastpysgi | 11,337 | 10,843 | 10,264 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 1.45 / 4.95 | 1.55 / 5.25 | 1.56 / 5.25 |
| Peregrine, executable | 1.82 / 5.75 | 1.79 / 5.65 | 1.63 / 5.65 |
| uvicorn | 2.46 / 7.03 | 2.52 / 7.01 | 2.55 / 7.23 |
| granian | 2.41 / 6.97 | 2.46 / 6.98 | 2.43 / 6.96 |
| fastpysgi | 3.10 / 8.03 | 3.09 / 8.23 | 3.25 / 8.35 |

No server returned an error or a non-2xx response at any level.

## Flask (WSGI), 1 worker

Requests per second:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | **14,768** | **14,992** | **14,458** |
| Peregrine, executable | 13,084 | 13,029 | 12,488 |
| fastpysgi | 10,419 | 10,202 | 9,978 |
| uvicorn (`--interface wsgi`) | 6,554 | 6,545 | 5,722 |
| granian | 6,427 | 6,152 | 6,257 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 2.51 / 7.11 | 2.52 / 7.06 | 2.53 / 7.24 |
| Peregrine, executable | 2.52 / 7.57 | 2.77 / 7.55 | 2.50 / 7.49 |
| fastpysgi | 3.27 / 8.34 | 3.27 / 8.37 | 3.28 / 8.41 |
| uvicorn (`--interface wsgi`) | 3.97 / 9.68 | 3.91 / 9.55 | 4.11 / 9.75 |
| granian | 3.90 / 9.67 | 4.14 / 9.82 | 4.08 / 9.83 |

No server returned an error or a non-2xx response at any level.

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
second:

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
