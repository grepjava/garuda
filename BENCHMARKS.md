<p align="center">
  <img src="assets/garuda-stylized-lockup.png" alt="Garuda" width="640">
</p>

# Benchmarks

Garuda next to [axum](https://github.com/tokio-rs/axum), the framework it
aims to beat, and next to Hummingbird and Vapor, the Swift framework entries of
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/).
Every entry but Garuda is that suite's own application for the same contract,
built as its Dockerfile builds it, and the load is the suite's command. The
machine is not the suite's, so the figures here are **not** comparable with the
ones the site publishes; see [Relation to the published results](#relation-to-the-published-results).

- **Against axum, Garuda served 1.95× on the suite's ramp and 1.72× on one
  pinned core**, in a quick comparison of one run per pass, with no errors from
  either. The closed-loop pass, 1.21×, is probably held down by the load
  generator.
- **Against the Swift frameworks, the router served 414,234 / 389,445 /
  370,945 requests a second**, about 4× Hummingbird and 6–7× Vapor at every
  level.
- **Garuda answers through its public handler API** since phase 1 of
  [HANDLER-API.md](HANDLER-API.md) ([Sources/garuda-server/main.swift](Sources/garuda-server/main.swift)).
  The Swift-framework figures are older: they were measured on the hand-written
  router the API replaced.
- Figures from Peregrine, the Python server Garuda was forked from, are kept
  at the end under [Historical: Peregrine (Python), before the fork](#historical-peregrine-python-before-the-fork).
  They are not Garuda's.

---

## Against axum, quick comparison

Measured on 2026-09-15. Garuda: phase 1 of the handler API, on top of
0e0cbbc. axum 0.8.9 on Tokio 1.53.1 and hyper 1.11.1: the suite's `rust/axum`
entry, byte for byte ([benchmarks/axum/](benchmarks/axum/)), built with rustc
1.96.0 as the suite's `rust/Dockerfile` builds it (release, LTO,
`panic = "abort"`, one codegen unit). `GET /` at 64 connections, one run per
pass, `bash benchmarks/vs-axum.sh`, 88 s in all. Requests per second:

| pass | Garuda | axum | Garuda ÷ axum |
|---|---:|---:|---:|
| suite ramp, 15 s | **390,324** | 200,048 | 1.95× |
| closed loop, 10 s | **201,360** | 167,078 | 1.21× |
| pinned, one core each, 10 s | **200,890** | 116,799 | 1.72× |

Latency, p50 / p99 in milliseconds:

| pass | Garuda | axum |
|---|---:|---:|
| suite ramp | 3.9 / 646 | 471 / 2,973 |
| closed loop | 0.26 / 1.21 | 0.30 / 1.01 |
| pinned | 0.27 / 1.08 | 0.53 / 2.28 |

- **The passes.**
  - *Suite ramp:* the suite's zrk command ([Method](#method)), Garuda's four
    worker processes against axum's one process with Tokio's default of a
    worker thread per CPU. axum's ramp latencies are queueing: it fell behind
    the offered rate.
  - *Closed loop:* `oha -c 64 -z 10s`, the same processes, capacity instead of
    the ramp.
  - *Pinned:* the server on CPU 0 and oha on CPUs 1–3. One Garuda worker
    against one Tokio worker thread: Tokio sizes its runtime from
    `std::thread::available_parallelism`, which reads the affinity mask.
- **The closed-loop figure is probably oha's ceiling, not Garuda's.** Garuda
  served the same ~201k on four workers sharing the CPUs with oha as on one
  pinned core. Read 1.21× as a floor; the pinned 1.72× may be one too.
- **One run each, after a 2 s warm-up.** Single runs on this machine move by
  20–30%. The script is a check to repeat between changes. For a figure to
  quote, run `frameworks.sh` with three runs at every level:
  `FRAMEWORKS="swift rust" SERVERS="garuda axum" WORKERS=4 AGG=mean bash benchmarks/frameworks.sh`.
- **rustc 1.96.0 here**; the suite's Dockerfile uses 1.98.

---

## Results, 4 workers

Measured on 2026-09-15, Garuda at 09eb178. Requests per second, `GET /`, the
mean of three runs:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda router | **414,234** | **389,445** | **370,945** |
| Hummingbird 2.26.0 | 88,864 | 102,399 | 99,706 |
| Vapor 4.122.1 | 60,411 | 58,946 | 60,837 |

- **No latencies.** The ramp offers far more than Hummingbird and Vapor can
  serve, so their corrected p50s are seconds of queueing, not what a request
  costs. Set beside the router's, they would say nothing.
- **No pinned one-core pass.** SwiftNIO sizes its event loop group from cgroup
  limits or the online CPU count, not from CPU affinity, so under `taskset`
  Hummingbird and Vapor would each run four loops on one core.
- **Compare rows within one table.** The load generator shares the server's
  four CPUs, and figures from different sessions on this machine move by tens
  of percent.

## Method

| | |
|---|---|
| Load generator | [zrk](https://github.com/zoxy-io/zrk), the suite's load command at [4bb9eaa](https://github.com/the-benchmarker/web-frameworks/blob/4bb9eaa/.tasks/config.rake#L149) |
| Warm-up | `zrk -c 50 -d 5s --plain URL` |
| Each level | `zrk --plain -c N -d 15s -m GET --format json -R1000:500000 --interval 1s --timeout 8s --latency URL` |
| Levels | 64, 256 and 512 connections, `GET /` |
| Figure | zrk's `achieved_rate`, in requests per second, the mean of three runs |
| Garuda | release build at 09eb178, `garuda --log-level error --host 127.0.0.1 --port 3000 --workers 4` |
| Hummingbird, Vapor | the suite's `swift/hummingbird-framework` and `swift/vapor-framework` entries, byte for byte, built as its Dockerfile builds them: Swift 6.3.3, `swift build -c release -Xswiftc -enforce-exclusivity=unchecked`. Each is one process with SwiftNIO 2.102.0's default of an event loop per CPU |
| Host | WSL2, 4 CPUs of an Intel Core i9-12900KF; load generator on the same machine, sharing those CPUs |

The command is an open-loop ramp from 1,000 to 500,000 requests a second over
the 15 s of a run, keep-alive on, latency corrected for coordinated omission.

### Relation to the published results

The site's dataset of 2026-09-13, on 16 CPUs at 512 connections, has Vapor at
88,435 and Hummingbird at 82,488 requests a second, and the top 15 entries in
any language between 147k and 176k. Here, on four CPUs shared with the load
generator, Hummingbird served 99,706 and Vapor 60,837 at 512: the host and the
path from load generator to server (loopback here) differ too much for the two
to be set side by side.

---

## Before the router: the Swift path on Peregrine's engine

Measured on 2026-09-14, the day of the fork, before the router existed and
before CPython was removed. `--health-check-path /` answers in `Worker.swift`
before dispatch, with no Python per request, so it measured what a Swift
handler at that seam could cost; CPython was still loaded in the process.

Per-request CPU for one worker pinned to CPU 0, load generator on CPUs 1–3,
closed-loop oha for 15 s at 64 connections, the mean of three runs:

| server | user µs | kernel µs | req/s |
|---|---:|---:|---:|
| Peregrine, `--health-check-path /` | **1.27** | 5.42 | 152,480 |
| Elysia on Bun | 1.45 | 4.36 | 175,572 |
| Peregrine, raw ASGI | 5.07 | 4.90 | 105,745 |

- **The Swift path was already at Bun's user time**: 1.27 µs against Elysia's
  1.45. The gap on one core was kernel time, 5.42 against 4.36.
- Raw ASGI's extra ~3.8 µs of user time was Python and asyncio.
- Kernel time was 4.4–5.4 µs for every server. At 5.8 µs a request, one core
  gives about 172k requests a second, which is what Elysia delivered on one
  pinned worker.

The suite's zrk command, four workers, the mean of three runs, the same
session, no errors:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Peregrine, `--health-check-path /` | **330,563** | **322,119** | 291,295 |
| Elysia on Bun | 282,771 | 321,087 | **297,502** |
| Peregrine, raw ASGI | 216,249 | 251,656 | 247,575 |

The health-check path beat or matched that session's Elysia at 64 and 256.
Elysia was slower here than the 346k–357k of the other session that day
([below](#historical-peregrine-python-before-the-fork)); shared-CPU noise
between sessions is that large.

---

## Reproduce

The quick comparison against axum, under two minutes:

```bash
swift build -c release --product garuda
bash benchmarks/vs-axum.sh
```

[benchmarks/vs-axum.sh](benchmarks/vs-axum.sh) prints one line per pass and
server. It runs `frameworks.sh` three times (ramp, closed loop, pinned) with
one run at 64 connections and a 2 s warm-up, and needs what that script needs
for Garuda and axum, below.

Every level, three runs each:

```bash
swift build -c release --product garuda
FRAMEWORKS="swift rust" SERVERS="garuda axum" WORKERS=4 AGG=mean \
    bash benchmarks/frameworks.sh > axum.tsv
HUMMINGBIRD=/path/to/hummingbird-framework/.build/release/server \
VAPOR=/path/to/vapor-framework/.build/release/server \
FRAMEWORKS=swift SERVERS="garuda hummingbird vapor" WORKERS=4 AGG=mean \
    bash benchmarks/frameworks.sh > swift.tsv
```

[benchmarks/frameworks.sh](benchmarks/frameworks.sh) prints one TSV line per
entry and level, with every run. It needs:

- **zrk** 2.4 or later on `PATH`, or `ZRK`; **python3**, which reads zrk's JSON
  output; **curl**; and port 3000 free, or `PORT`.
- **Garuda** at `.build/release/garuda`, or `GARUDA`. `WORKERS` is Garuda's
  worker count (default 1); `GARUDA_EXTRA_ARGS` adds server flags.
- **Hummingbird and Vapor** built from the suite's `swift/hummingbird-framework`
  and `swift/vapor-framework` entries with
  `swift build -c release -Xswiftc -enforce-exclusivity=unchecked`. The script
  looks for their executables at
  `~/swiftbench/hummingbird-framework/.build/release/server` and
  `~/swiftbench/vapor-framework/.build/release/server` unless `HUMMINGBIRD`
  and `VAPOR` say otherwise, and starts them with `SERVER_HOSTNAME` and
  `SERVER_PORT` (Vapor with `serve` and `VAPOR_ENV=production`).
- **axum** from [benchmarks/axum/](benchmarks/axum/), the suite's `rust/axum`
  entry. The script builds it with `cargo` on first use, with the flags of the
  suite's `rust/Dockerfile`, or runs `AXUM` if given. It listens on 3000 itself,
  so `PORT` must stay 3000.
- `AGG=mean` averages the runs, as the suite publishes; the default, `median`,
  keeps the median run. `RUNS` (3), `CONNS` (`64 256 512`), `DURATION` (15s),
  `WARMUP` (5s) and `RATE` (`1000:500000`) override the rest. `LOAD=closed` runs closed-loop oha
  instead of the ramp, and `PIN=0:1-3` pins server and load generator.

`FRAMEWORKS=elysia SERVERS=elysia-bun` still runs the suite's Elysia entry
([benchmarks/elysia-bun/](benchmarks/elysia-bun/)) as a reference. It needs
[Bun](https://bun.sh) and port 3000.

The other harnesses Peregrine had in `benchmarks/` (A/B builds, body sizes,
memory, syscalls, static files, the Python framework comparisons) all started
Python applications and have been removed. They come back, where still worth
having, once the handler API can serve what they measured.

---

## Historical: Peregrine (Python), before the fork

**These are Peregrine's figures, not Garuda's.** Peregrine is the Python ASGI
and WSGI server Garuda was forked from; every request below, except Elysia's,
ran Python. They are kept for scale. The full write-up, with latencies, every
run and the Python method, is [Peregrine's BENCHMARKS.md at v1.1.5](https://github.com/grepjava/peregrine/blob/v1.1.5/BENCHMARKS.md).

Measured on 2026-09-14 on Peregrine at b8d6ae9, the build 1.1.5 shipped: the
suite's Python entries on Peregrine and its Elysia entry, four workers, the
same zrk command (zrk 2.5.0), the same host. Requests per second, the mean of
three runs, no errors:

| entry | application | 64 | 256 | 512 |
|---|---|---:|---:|---:|
| peregrine-wsgi | raw WSGI | **293,025** | **302,417** | 256,660 |
| peregrine-asgi | raw ASGI | 221,826 | 271,396 | **260,155** |
| peregrine-blacksheep | BlackSheep 2.6.3 | 179,208 | 202,141 | 197,687 |
| peregrine-fastapi | FastAPI 0.141.1 | 57,553 | 72,306 | 76,818 |
| peregrine-flask | Flask 3.1.3 | 49,933 | 50,423 | 50,964 |
| peregrine-django | Django 6.1.1 | 46,058 | 47,806 | 45,806 |
| elysia-bun, reference | Elysia 1.4.30 on Bun 1.4.2 | 346,465 | 350,622 | 356,547 |

In the site's dataset of 2026-09-13 (16 CPUs), raw WSGI on Peregrine 1.0
served 130,843 requests a second at 512 connections.
