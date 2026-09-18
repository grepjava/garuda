<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Benchmarks

How Garuda's performance is measured, and the results so far. Benchmarks are a
check on the engine, not its purpose: a change that makes Garuda slower should
be noticed, and these runs are how.

The reference points are axum and actix on Rust, Vert.x on the JVM, and
Hummingbird and Vapor on Swift, all from
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/).
Every server but Garuda runs that suite's own application, built as the suite
builds it, under the suite's load command.

## What is measured, and why

The route is hello-world: `GET /`, status 200, empty body. Requests that do
work -- JSON, a database, streaming -- are [measured separately](#requests-that-do-work). A handler that does
nothing leaves only the server's own cost: parsing, dispatch, writing the
response, and the socket calls. That is what these figures measure. They do not
say what an application built on Garuda will serve.

The machine is not the suite's, and the path from load generator to server is
loopback here. The figures cannot be set beside the ones the suite's site
publishes.

## Quick comparison with axum

[benchmarks/vs-axum.sh](benchmarks/vs-axum.sh) is a check to repeat between
changes. It takes under two minutes.

```bash
swift build -c release --product garuda
bash benchmarks/vs-axum.sh
```

It runs [frameworks.sh](#the-framework-suite) three times with
`CONNS=64 RUNS=1 WARMUP=2s FRAMEWORKS="swift rust" SERVERS="garuda axum"`,
Garuda then axum in each pass:

| pass | settings | what it shows |
|---|---|---|
| ramp | `WORKERS=4 DURATION=15s` | the suite's zrk ramp; Garuda's 4 workers against Tokio's default of a worker thread per CPU |
| closed | `WORKERS=4 DURATION=10s LOAD=closed` | closed-loop oha, the same processes: capacity, not the ramp |
| pinned | `WORKERS=1 DURATION=10s LOAD=closed PIN=0:1-3` | server on CPU 0, oha on CPUs 1–3; one Garuda worker against one Tokio thread |

Tokio sizes its runtime from `std::thread::available_parallelism`, which reads
the affinity mask, so pinned axum runs one worker thread.

It prints one line per pass and server to stdout: requests a second, p50 and
p99 in milliseconds, and errors. The last line is the total time in seconds.
`GARUDA` points it at a binary other than `.build/release/garuda`. It needs
what frameworks.sh needs for Garuda and axum: zrk, oha, python3, curl, cargo
for the first axum build, and port 3000. It prints its figures and records
none: a short run is a check, not a figure to keep.

## The framework suite

[benchmarks/frameworks.sh](benchmarks/frameworks.sh) runs every level with
several runs each. Use it for a figure to quote.

```bash
swift build -c release --product garuda
FRAMEWORKS="swift rust" SERVERS="garuda axum" WORKERS=4 AGG=mean \
    bash benchmarks/frameworks.sh > axum.tsv
HUMMINGBIRD=/path/to/hummingbird-framework/.build/release/server \
VAPOR=/path/to/vapor-framework/.build/release/server \
FRAMEWORKS=swift SERVERS="garuda hummingbird vapor" WORKERS=4 AGG=mean \
    bash benchmarks/frameworks.sh > swift.tsv
FRAMEWORKS="swift rust java" SERVERS="garuda axum actix vertx" WORKERS=$(nproc) AGG=mean \
    bash benchmarks/frameworks.sh > four.tsv
```

### Method

The load is the suite's collect command at
[4bb9eaa](https://github.com/the-benchmarker/web-frameworks/blob/4bb9eaa/.tasks/config.rake#L149),
flag for flag:

| step | command |
|---|---|
| warm-up, once per server | `zrk -c 50 -d 5s --plain URL` |
| each run | `zrk --plain -c N -d 15s -m GET --format json -R1000:500000 --interval 1s --timeout 8s --latency URL` |

That is an open-loop ramp from 1,000 to 500,000 requests a second over the run,
with keep-alive on and latency corrected for coordinated omission. The figure
is zrk's `achieved_rate`, the number the suite's site ranks by.

`LOAD=closed` replaces zrk with closed-loop `oha -c N -z DURATION` (warm-up
`oha -z WARMUP -c 50`), which measures capacity. oha's "aborted due to
deadline" requests are not counted as errors.

The servers:

- **Garuda**: `.build/release/garuda --log-level error --host 127.0.0.1 --port PORT --workers WORKERS`.
- **axum**: the suite's `rust/axum` entry, byte for byte, in
  [benchmarks/axum/](benchmarks/axum/). On first use the script builds it with
  `cargo build --release` and the suite's `rust/Dockerfile` profile: LTO,
  `panic = "abort"`, one codegen unit. One process, Tokio's default of a worker
  thread per CPU. It listens on 3000 itself.
- **actix**: the suite's `rust/actix` entry, byte for byte, in
  [benchmarks/actix/](benchmarks/actix/), built the same way as axum. One
  process with actix-web's default of a worker per CPU. It listens on 3000
  itself.
- **Vert.x**: the suite's `java/vertx` entry, byte for byte, in
  [benchmarks/vertx/](benchmarks/vertx/), built with `mvn package` and run as
  its `config.yaml` runs it: `java -jar target/server.jar -instances WORKERS`
  (upstream passes `$(nproc)`). It needs JDK 25 and Maven, uses Netty's epoll
  transport, and listens on 3000 itself.
- **Hummingbird and Vapor**: the suite's `swift/hummingbird-framework` and
  `swift/vapor-framework` entries, byte for byte, built as its Dockerfile
  builds them: `swift build -c release -Xswiftc -enforce-exclusivity=unchecked`.
  Each is one process with SwiftNIO's default of an event loop per CPU. They
  are started with `SERVER_HOSTNAME` and `SERVER_PORT`; Vapor with `serve` and
  `VAPOR_ENV=production`.

Variables it reads:

| variable | default | meaning |
|---|---|---|
| `FRAMEWORKS` | `swift` | `swift` pairs with garuda, hummingbird, vapor; `rust` with axum and actix; `java` with vertx |
| `SERVERS` | `garuda hummingbird vapor` | servers to run |
| `WORKERS` | `1` | Garuda's worker count, and Vert.x's `-instances` |
| `CONNS` | `64 256 512` | connection levels |
| `RUNS` | `3` | runs per level |
| `AGG` | `median` | `median` keeps the median run by req/s; `mean` averages every column and sums errors, as the suite publishes |
| `DURATION` | `15s` | length of a run |
| `WARMUP` | `5s` | length of the warm-up |
| `RATE` | `1000:500000` | zrk's ramp, start:end requests a second |
| `LOAD` | `ramp` | `closed` for oha |
| `PIN` | empty | `server_cpus:load_cpus` for `taskset`, e.g. `0:1-3` |
| `PORT` | `3000` | must stay 3000 for axum, actix and Vert.x |
| `GARUDA_EXTRA_ARGS` | empty | extra Garuda flags, e.g. `--access-log` |

Binaries default to `.build/release/garuda`,
`benchmarks/axum/target/release/server` and
`benchmarks/actix/target/release/server` (built if missing),
`benchmarks/vertx/target/server.jar` (built if missing),
`~/swiftbench/hummingbird-framework/.build/release/server` and
`~/swiftbench/vapor-framework/.build/release/server`; `GARUDA`, `AXUM`,
`ACTIX`, `VERTX`, `HUMMINGBIRD` and `VAPOR` override them, and `ZRK`, `OHA`,
`CARGO`, `JAVA` and `MVN` the tools.
It needs zrk 2.4 or later (oha for `LOAD=closed`), python3 to read their JSON,
and curl. Output goes to stdout, one TSV line per server and level:

```
framework  server  workers  connections  req/s p50_ms p75_ms p90_ms p99_ms errors  [every run's req/s]
```

Server logs go to a temporary directory that is removed at the end.

### Recorded run: six servers

**2026-09-18**, Garuda at 9f947f6 with 4 workers. `GET /`, the suite's ramp,
the mean of three 15-second runs at each level, no errors anywhere. Requests a
second:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda | 351,259 | 356,389 | 328,101 |
| actix-web 4.15.0 | 348,490 | 359,141 | 321,417 |
| Vert.x 5.1.7 | 317,001 | 310,806 | 293,570 |
| axum 0.8.9 | 190,125 | 293,221 | 296,588 |
| Hummingbird 2.26.0 | 83,939 | 88,592 | 93,614 |
| Vapor 4.122.1 | 56,368 | 56,100 | 56,994 |

Latency at 256 connections, p50 / p99 in milliseconds:

| entry | p50 | p99 |
|---|---:|---:|
| actix-web | 8.8 | 715 |
| Garuda | 10.5 | 1,000 |
| Vert.x | 28.6 | 1,441 |
| axum | 104.0 | 1,433 |
| Hummingbird | 2,120 | 6,408 |
| Vapor | 3,038 | 7,963 |

- Host: WSL2 with 4 CPUs of an Intel Core i9-12900KF, Ubuntu 24.04, kernel
  6.18, with zrk 2.5.0 on the same CPUs. Swift 6.3.3, SwiftNIO 2.102.0, rustc
  1.96.0, Tokio 1.53.1, OpenJDK 25.0.4 with Netty's epoll transport. Garuda ran
  4 workers; the others size their threads from the CPU count.
- Garuda and actix are a tie: the gaps between them are smaller than the spread
  between runs of either (Garuda's three runs at 256 ranged 333k-376k, actix's
  at 512 ranged 272k-367k).
- Vert.x follows about 10% behind, then axum.
- Garuda served about 4x Hummingbird and 6x Vapor, as it did in the earlier
  Swift-only run.
- axum's 190,125 at 64 connections, with a p50 of 540 ms against 104 ms at 256,
  is out of line with its own higher levels. The suite runs one 5-second
  warm-up per server, before the first level only, and that is the level that
  pays for whatever axum warms up.
- Every server's p99 is hundreds of milliseconds or worse, so all six fell
  behind the ramp at some point in a run. These are rates under an offered load
  none of them could hold, which is what the suite measures.

## Caveats

- **Compare within one table.** On the shared-CPU WSL2 machine, figures from
  different sessions move by tens of percent.
- **Single runs need care.** Single runs there move by 20–30%. vs-axum.sh is a
  check between changes. Quote frameworks.sh with three runs at every level.
- **The load generator shares the server's CPUs** unless `PIN` separates them.
  A closed-loop figure can be the load generator's limit.
- **Use a dedicated machine** for figures that matter, with nothing else
  running and no builds or tests alongside.
- **A long sweep and a short run are different measurements.** On the bench
  box a full `frameworks.sh` sweep takes about 20 minutes and its rates settle
  some 30% below what `vs-axum.sh` reads in 87 seconds, for every server
  alike: the CPU cannot hold its clocks that long. Never read a sweep's figure
  against a short run's.

## Requests that do work

Hello-world measures the server. [benchmarks/workloads.sh](benchmarks/workloads.sh)
measures four requests that do something, each answered with the same bytes by
two applications written the way each framework documents:
[workloads/garuda-app](benchmarks/workloads/garuda-app/Sources/workloads/main.swift)
on Garuda's typed routes, and [workloads/axum](benchmarks/workloads/axum/src/main.rs)
on axum 0.8 with tokio-postgres and deadpool.

| workload | request | what it exercises |
|---|---|---|
| user | `GET /user/12345` | a path parameter, answered as text |
| json | `POST /json`, 60 bytes | a JSON body decoded into a struct, another encoded |
| db | `GET /db/517` | one row from PostgreSQL by primary key, as JSON; a pool of 32 connections either way |
| stream | `GET /stream` | 64 KiB streamed as 16 chunks of 4 KiB, chunked |

```bash
(cd benchmarks/workloads/garuda-app && swift build -c release)
DATABASE_URL='postgres://user:pass@127.0.0.1/db?sslmode=disable' bash benchmarks/workloads.sh
```

Each workload is checked before it is measured: a server that answers fast and
wrong prints FAILED instead of a figure. Then closed-loop oha at 64
connections, a 2 s warm-up and a 10 s run, Garuda with a worker per CPU
against Tokio's default of a thread per CPU (`WORKERS` changes Garuda's), and
32 connections to the database for either (`POOL_TOTAL`). The script makes and fills the table it reads.
It takes under two minutes, and like vs-axum.sh it is a check between
changes, not a figure to publish.

### First run, 2026-09-19

The bench box: 8 cores, Ubuntu 26.04, PostgreSQL 18.6 on the same machine.
One run each; requests a second, p50 and p99 in milliseconds.

| workload | Garuda | p50 | p99 | axum | p50 | p99 |
|---|---:|---:|---:|---:|---:|---:|
| user | 183,993 | 0.367 | 0.423 | 135,474 | 0.427 | 1.222 |
| json | 88,995 | 0.593 | 2.109 | 119,483 | 0.475 | 1.538 |
| db | 31,456 | 1.958 | 3.431 | 45,545 | 1.359 | 2.476 |
| stream | 17,364 | 3.663 | 8.385 | 34,802 | 1.811 | 3.359 |

Routing was ahead, as hello-world is. The other three were behind, and the
profiles said why:

- **stream**: every `body.write` was its own system call and its own wakeup
  of the reader. Writes now go out together when the handler next waits.
- **json**: the coder built a coding path, an array, for every value, and
  `Array`'s elements came through the generic `encode<T>`/`decode<T>` and
  paid for an encoder and a boxed container each. Paths are now built only
  when read and the standard scalars are written and read directly.
- **db**: read interest on the connection to PostgreSQL was added and taken
  away around every statement, two `epoll_ctl` calls each time. It now
  stays. And calling a non-mutating method through a `Worker` pointer copied
  the whole worker, retaining every reference in it; `Worker` is now
  `~Copyable`, so the compiler cannot.

### After those changes, 2026-09-19

The same box, the same script, one run each:

| workload | Garuda | p50 | p99 | axum | p50 | p99 |
|---|---:|---:|---:|---:|---:|---:|
| user | 184,837 | 0.358 | 0.446 | 134,653 | 0.430 | 1.233 |
| json | 119,585 | 0.462 | 1.132 | 119,160 | 0.475 | 1.568 |
| db | 37,150 | 1.620 | 3.325 | 45,619 | 1.357 | 2.460 |
| stream | 39,967 | 1.584 | 2.027 | 34,810 | 1.815 | 3.395 |

Single runs here vary by about 10%: axum's json read 118,814 and 132,745 on
two runs of the same binary.

The database was still behind. It was not the per-worker pools: one Garuda
worker against one Tokio thread, both pinned to the same CPU with the same
pool of 8 and nothing to balance, read 24,015 against 30,272. Kernel time per
request was the same, 19.0 against 19.4 µs; Garuda spent 9 µs more in user
space. Two causes, both fixed:

- **The client did too much per statement.** The RowDescription that comes
  with every run was read into new strings every time, the statement cache
  hashed the SQL up to three times, buffers were allocated per statement,
  and each result built a dictionary of its column names. Now the same
  description reuses the columns read from it last time, the cache is
  looked up once, the buffers are kept, and a few columns are searched in
  order.
- **The pool was unfair.** A released connection went back to the idle list
  with the oldest waiter woken, and whoever asked before that waiter ran --
  a new request, or the one that had just released it -- took it. The
  waiter queued again at the back. p99 was 4.6 ms against axum's 2.5; with
  the connection handed straight to the oldest waiter it is 2.9.

The script also gave Garuda four workers against Tokio's thread per CPU; it
now defaults to a worker per CPU for both, with the same 32 connections to
the database in all (`POOL_TOTAL`).

### At equal threads, 2026-09-19

Eight Garuda workers with four connections each against axum on eight
threads with one pool of 32:

| workload | Garuda | p50 | p99 | axum | p50 | p99 |
|---|---:|---:|---:|---:|---:|---:|
| user | 166,923 | 0.337 | 1.309 | 134,836 | 0.428 | 1.254 |
| json | 119,899 | 0.350 | 3.143 | 119,717 | 0.474 | 1.547 |
| db | 42,166 | 1.447 | 2.999 | 45,391 | 1.366 | 2.450 |
| stream | 37,206 | 1.660 | 3.081 | 34,657 | 1.824 | 3.359 |

The database reads within 7% here and 46,482 against 47,194 on another run;
single runs move by about 10%. PostgreSQL itself is the limit on this box:
axum reads 51,188 with 16 connections, 45,619 with 32 and 36,512 with 64,
every backend another process competing for the same eight cores. What is
left on Garuda's side is mostly the concurrency runtime: every
`swift_task_switch` reads the task's preferred executor under a lock, a few
percent of a database request.
