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

On one worker Peregrine answers FastAPI 1.24–1.34× as fast as the next server
at each level, and Flask 1.16–1.40× as fast as the next server (fastpysgi) and
1.8–2.3× as fast as uvicorn and granian.

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
| Servers | the suite's engine commands, with `--workers 1` |
| Host | WSL2 on 4 cores, Ubuntu 24.04, CPython 3.12.3, load generator on the same machine |

Versions: FastAPI 0.141.1 (Starlette 1.6.0, Pydantic 2.13.5), Flask 3.1.3
(Werkzeug 3.1.8), uvicorn 0.52.4 with uvloop 0.22.1 and httptools 0.8.0, granian 2.8.2,
fastpysgi 0.6.

The command is taken from the suite's `.tasks/config.rake`, which is what its
`collect` targets run. Its README and some comments still describe an older
setup (oha, keep-alive disabled). The command itself is an open-loop ramp from
1,000 to 100,000 requests a second over the run, with keep-alive on.

**Where this differs from the published results, and why:**

- **One worker.** The suite starts every server with `--workers $(nproc)`. One
  worker compares what each server does with a core, and keeps the load
  generator from competing with the servers for the same four cores.
- **Median of three runs.** The suite takes one run per level. A developer
  machine is noisier than a dedicated benchmark host, so each level runs three
  times and the median run by `achieved_rate` is reported.
- **uvicorn serves Flask through `--interface wsgi`.** The suite has no uvicorn
  engine for Flask; its Flask engines are gunicorn, uwsgi, waitress and granian.
  uvicorn's WSGI adapter is included here because the comparison asked for is
  the same servers on both frameworks.
- **fastpysgi serves the FastAPI and Flask applications.** The suite's
  `fastpysgi-asgi` and `fastpysgi-wsgi` entries run hand-written raw ASGI and
  WSGI applications. Here the same launch they use,
  `fastpysgi.run(app, host, port, workers=N)`, is given the FastAPI and Flask
  applications every other server runs, so the framework is the same for all
  four.

**Reading the latencies.** The ramp ends far above what any of these servers
can do on one core, so for most of each run requests are offered faster than
they are answered. Latency corrected for coordinated omission counts the time a
request waited to be sent, so it measures how fast that queue grows: seconds,
not milliseconds. Compare the servers with each other, not with a closed-loop
benchmark.

Reproduce:

```bash
bash benchmarks/frameworks.sh > results.tsv
```

`WORKERS`, `CONNS`, `RUNS`, `DURATION`, `FRAMEWORKS`, `SERVERS`, `VENV`,
`PEREGRINE` and `ZRK` override the defaults. The virtualenv needs `fastapi`,
`flask`, `uvicorn[standard]`, `granian` and `fastpysgi`.

---

## FastAPI (ASGI), 1 worker

Requests per second:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | **20,319** | **20,469** | **18,944** |
| uvicorn | 16,043 | 15,236 | 14,430 |
| granian | 14,544 | 15,241 | 15,254 |
| fastpysgi | 11,253 | 11,153 | 10,434 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 1.75 / 5.64 | 2.01 / 5.99 | 1.81 / 5.88 |
| uvicorn | 2.25 / 7.22 | 2.76 / 7.26 | 2.62 / 7.25 |
| granian | 2.72 / 7.23 | 2.48 / 7.09 | 2.38 / 6.98 |
| fastpysgi | 2.95 / 7.95 | 3.20 / 8.21 | 3.11 / 8.30 |

No server returned an error or a non-2xx response at any level.

## Flask (WSGI), 1 worker

Requests per second:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | **12,196** | **14,042** | **13,256** |
| uvicorn (`--interface wsgi`) | 6,705 | 6,234 | 5,282 |
| granian | 6,022 | 5,843 | 6,250 |
| fastpysgi | 10,532 | 10,057 | 10,056 |

Latency, p50 / p99, in seconds:

| server | 64 | 256 | 512 |
|---|---:|---:|---:|
| **Peregrine** | 2.80 / 7.60 | 2.71 / 7.44 | 2.69 / 7.53 |
| uvicorn (`--interface wsgi`) | 4.27 / 9.79 | 4.32 / 9.79 | 3.99 / 9.79 |
| granian | 3.99 / 9.76 | 4.27 / 9.89 | 4.28 / 10.05 |
| fastpysgi | 3.21 / 8.30 | 3.13 / 8.43 | 3.22 / 8.42 |

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
- **Peregrine starts with a handicap.** It embeds CPython as a shared library,
  and the same FastAPI code runs about 16 % slower in `libpython3.12.so` than
  in the statically linked `python3.12` that the other three servers run under.

---

## Processes or free-threaded

The same two applications with `--workers N` (processes, CPython 3.12) and with
`--workers N --free-threaded` (threads of one process, CPython 3.14t).
Closed-loop `oha`, 15 s per cell, requests per second:

| application | workers | model | 64 | 256 | 512 |
|---|---:|---|---:|---:|---:|
| FastAPI | 1 | processes | 22,072 | 21,210 | 21,909 |
| FastAPI | 1 | free-threaded | 20,215 | 20,784 | 20,755 |
| FastAPI | 4 | processes | 66,623 | 69,043 | 67,341 |
| FastAPI | 4 | free-threaded | 54,242 | 62,366 | 63,042 |
| Flask | 1 | processes | 12,946 | 13,084 | 12,978 |
| Flask | 1 | free-threaded | 12,298 | 12,197 | 12,202 |
| Flask | 4 | processes | 45,470 | 46,002 | 46,553 |
| Flask | 4 | free-threaded | 37,252 | 36,784 | 33,217 |

With four workers, threads reach 81–94 % of four processes on FastAPI and
71–82 % on Flask.

That is threading model **and** interpreter version, not a clean A/B: 3.14t
pays a single-thread reference-counting cost that 3.12 does not. On a
hello-world route `--free-threaded` is not a throughput upgrade. It is for
memory and for state shared across workers: with a CPU-bound application, four
threads match four processes at a third of the resident memory, because the
application is imported once — see
[Free-threaded Python](CONFIG.md#free-threaded-python).

Reproduce with `bash benchmarks/gil_vs_ft.sh`. It needs two Peregrine builds,
one linked against a GIL CPython and one against a free-threaded one
(`python3.13t` or newer, with `LD_LIBRARY_PATH` or an rpath pointing at its
`lib`). `GIL_BIN`, `FT_BIN`, `GIL_VENV`, `FT_VENV`, `APPS`, `DURATION` and
`CONNS` override the defaults.
