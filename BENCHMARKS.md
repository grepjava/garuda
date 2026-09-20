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
measures requests that do something, each answered with the same bytes by
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
| me | `GET /me`, bearer token | an HS256 JWT verified and its subject answered: `JWT<Claims>` against jsonwebtoken |
| upload | `POST /upload`, 1 MiB | a body read whole and its length answered |
| download | `GET /download` | 1 MiB answered from memory |
| relay | `GET /relay` | an origin's `/stream` fetched with the framework's HTTP client and streamed on as it arrives: `client.stream` against reqwest |
| churn | `GET /user/12345` | a new connection for every request |
| h2 | `GET /user/12345` | over prior-knowledge HTTP/2 |
| overload | `GET /db/517` at 1,024 connections | a pool of 32 far short of them; then `user` at 64 connections straight after, as `recovery` |
| skew | `GET /user/12345` on 56 connections | while 8 more ask for `/spin`, which holds the CPU about 2 ms a request: what quick requests pay for sharing a server with slow ones |
| spike | as skew | with the slow requests starting a second into the run, on workers that already hold quick connections |

```bash
(cd benchmarks/workloads/garuda-app && swift build -c release)
DATABASE_URL='postgres://user:pass@127.0.0.1/db?sslmode=disable' bash benchmarks/workloads.sh
```

Each workload is checked before it is measured: a server that answers fast and
wrong prints FAILED instead of a figure. Then closed-loop oha at 64
connections, a 1 s warm-up and a 5 s run (`WARMUP`, `DURATION`), Garuda with
a worker per CPU against Tokio's default of a thread per CPU (`WORKERS`
changes Garuda's), and 32 connections to the database for either
(`POOL_TOTAL`). The script makes and fills the table it reads. The relay's
origin is the Garuda application on another port, the same for both, so what
differs is the relaying.

Each line says, beside requests a second and p50, p95 and p99: the server's
CPU time per request, user and system together, which says what a figure
cost; the server's memory after the run as proportional set size, which
charges a page shared by several processes -- the Swift runtime, libssl --
a share to each rather than whole to every one, so eight worker processes
are not charged eight times for their libraries; and the requests that
failed. It takes about three minutes; `WORKLOADS` picks some. Like
vs-axum.sh it is a check between changes, not a figure to publish.

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

### Beyond the first four, 2026-09-19

The first run of every workload, the same box, 5 s each. Memory here was
still each process's resident set, summed, which charges each of Garuda's
eight workers for the shared libraries again; the script now reports
proportional set size.

| workload | Garuda | p99 ms | CPU µs/req | axum | p99 ms | CPU µs/req |
|---|---:|---:|---:|---:|---:|---:|
| user | 173,106 | 1.035 | 19 | 129,628 | 1.370 | 24 |
| json | 131,878 | 2.904 | 34 | 112,915 | 1.756 | 32 |
| db | 47,186 | 3.285 | 77 | 44,840 | 2.477 | 72 |
| stream | 37,665 | 3.350 | 87 | 34,431 | 3.462 | 73 |
| me | 72,817 | 3.575 | 81 | 112,888 | 1.874 | 32 |
| upload | 2,275 | 57.7 | 1,755 | 1,339 | 104.6 | 3,697 |
| download | 1,326 | 105.7 | 3,855 | 2,080 | 56.3 | 1,913 |
| relay | 12,180 | 11.0 | 368 | 4,090 | 43.9 | 546 |
| churn | 38,886 | 2.180 | 60 | 34,126 | 3.377 | 88 |
| h2 | 107,770 | 2.965 | 28 | 105,828 | 1.562 | 30 |
| overload | 36,648 | 45.5 | 98 | 38,090 | 30.3 | 85 |
| recovery | 149,649 | 2.775 | 22 | 142,285 | 1.256 | 21 |

Two were well behind, and CPU per request says it was work, not waiting:

- **download** spent twice axum's CPU on each megabyte. A profile put a
  fifth of it in copying the body into the connection's write buffer and
  as much again in the kernel zeroing fresh pages for that buffer, which
  was allocated for each response and freed after it. A body of 64 KiB or
  more answered from an array is now written from the array: the head and
  the body go out in one writev, and the connection keeps the array until
  it has gone. The same run afterwards: 2,074 against axum's 2,075, at
  1,882 µs a request against 1,917.
- **me**, a bearer token checked on every request, cost 81 µs against 32.
  The token was split and base64-decoded as Swift strings, a character at a
  time; its header, the same on every token an issuer writes, was decoded
  again each time; the HMAC looked its digest up and hashed the key's pads
  for every token; and every optional field the JSON coder read -- four in
  the registered claims -- walked the object three times, since the
  container left `decodeIfPresent` to the standard library's default. Now
  the token is read from its bytes, a key set keeps the headers it has
  decoded, an HMAC key is set up once, and an optional member is found in
  one walk. The same run afterwards: 115,884 against axum's 129,923, at 43
  µs a request against 28. What is left is spread thin: the HMAC, the task
  an async route runs on, and generic metadata looked up for the claims
  type, none of it more than a few percent.

Memory, read as proportional set size, was 60 MiB for Garuda's eight
workers against 6 to 22 for axum. Each worker had readied all 4,096
connection slots its table holds when it started, over a kilobyte apiece;
a slot is now readied the first time one is needed, and the same workloads
run in 16 to 20 MiB.

Garuda's p99 is higher than axum's on the small requests, where its p50 is
lower: requests are spread over eight processes by the kernel as they
connect, and none can take another's work, where Tokio's threads steal it.
[Spreading connections](#spreading-connections-2026-09-19) below is what came
of that. Under overload each failed 26 requests of the 1,024 connections, and
each served the next 64 connections at full rate straight after.

### Spreading connections, 2026-09-19

`--balance` (ARCHITECTURE.md, Balancing connections) replaces the kernel's
hash with one shared listener that a worker ahead of the others steps back
from (`accept`), and adds moving quick connections off a worker where they
would wait (`adaptive`, now the default). `SERVERS="garuda:reuseport
garuda:accept garuda:adaptive axum"` runs each.

**How connections land.** 64 connections opened at once against 8 workers,
three runs each, per worker:

| mode | connections per worker |
|---|---|
| `reuseport` | 4 4 6 9 10 10 10 11 · 4 5 7 8 8 10 10 12 · 2 4 5 7 10 12 12 12 |
| `accept` | 4 6 7 8 8 10 10 11 · 4 4 4 4 8 9 12 19 · 0 4 4 5 11 13 13 14 |
| `adaptive` | 4 4 4 4 7 8 10 23 · 0 4 4 4 5 11 12 24 · 0 4 4 4 6 11 12 23 |

Neither shared-listener mode spreads a burst of connections evenly yet. A
worker that steps back does so for one turn, and the burst outlasts it.
Moving leaves a connection alone unless it would wait less elsewhere, and on
uniform load it would not.
On uniform load it made no difference to the tail: with requests all alike,
a worker holding 15 connections and one holding 4 are both answering as fast
as they can.

**Where it matters: slow requests.** Load generator pinned to four CPUs and
four workers to the other four (`WORKERS=4 PIN=0-3:4-7`), 62 connections of
quick requests and 2 of `/spin`, two to four runs each. Figures are the
quick requests':

| | skew req/s | skew p99 | spike req/s | spike p99 |
|---|---:|---:|---:|---:|
| `reuseport` | 118,000–183,000 | 2.8–3.5 ms | 125,000–153,000 | 2.9–3.7 ms |
| `accept` | 113,000–176,000 | 0.6–1.3 ms | 124,000–149,000 | 3.0–3.6 ms |
| `adaptive` | 111,000–134,000 | 0.9–1.2 ms | 120,000–137,000 | 0.9–1.1 ms |
| axum | 93,000–103,000 | 1.1–1.3 ms | 106,000–114,000 | 1.1–1.2 ms |

Under the kernel's hash, quick connections share workers with the slow ones
and wait behind them. With the slow requests there from the start, placement
alone fixes it: their workers are busier, step back, and the quick
connections land on the others. When the slow requests start later, only
moving connections can: `adaptive` sends the quick ones to the workers with
the shortest expected wait, and their tail matches axum's work stealing at
higher throughput. The wide ranges are real: each run places the slow
connections afresh.

Getting there took three wrong turns, each visible in these workloads:

- Moving connections whenever connection counts were uneven shuffled them
  between workers that were all flat out, and each moved request waited
  behind a 2 ms one on arrival. Now only a shorter expected wait moves
  anything.
- Moving by busyness alone sent quick connections to a worker half busy with
  slow requests: less busy, but a longer wait. The wait is now worked out
  from how long the loop's turns take, which is long both behind one slow
  request and behind many quick ones.
- Watching the shared listener with `EPOLLEXCLUSIVE` told a waiting
  connection to one worker only, and when that worker stepped back the rest
  of the queue waited for the next connection to wake someone. With a new
  connection per request that fell to 3,300 requests a second, with 60
  connections queued and every worker idle. Every worker is woken now, and
  a worker steps back only for one that is accepting.

**Uniform load.** The same pinned setup, two runs each, requests a second
(p99 in ms):

| workload | `reuseport` | `adaptive` | axum |
|---|---|---|---|
| user | 151,591 (0.54) | 150,745–151,322 (0.54–0.60) | 147,654–149,278 (0.57–0.62) |
| json | 101,729 (1.35) | 100,628–100,850 (1.28–1.49) | 113,891–114,830 (1.03–1.04) |
| db | 35,840–38,663 (2.7–2.9) | 35,887–36,004 (3.0–3.1) | 37,891–37,944 (2.6–2.8) |
| stream | 40,460–41,103 (1.9–2.2) | 40,261–40,393 (1.9) | 36,533–36,652 (2.2–2.3) |
| me | 77,965–78,853 (1.7–2.3) | 77,954–78,619 (1.6–1.7) | 109,669–111,502 (1.0–1.1) |
| download | 2,177–2,197 | 2,188–2,201 | 2,216–2,229 |
| churn | 39,985–40,076 (1.9) | 39,768–39,959 (1.9) | 33,652–33,906 (3.5–3.9) |
| h2 | 100,535–101,485 (0.8) | 101,828–105,333 (0.8–0.9) | 101,261–101,287 (0.9) |

The first run of the day read higher on this box whatever ran first (user
184,230 and json 118,642 for `reuseport`), and is left out.

**Kernel TLS.** The same four workers over HTTPS, OpenSSL 3.5 and kernel 7.0,
two runs each, requests a second:

| | HTTP/1.1 `/user` | HTTP/2 `/user` | HTTP/1.1 1 MiB from memory | HTTP/1.1 1 MiB file |
|---|---:|---:|---:|---:|
| OpenSSL encrypting | 113,826–124,794 | 79,007–91,908 | 2,447–2,471 | 2,204–2,207 |
| `--ktls` | 116,859–123,789 | 79,708–92,121 | 1,753–1,829 | 1,712–1,718 |

The kernel's software encryption is slower than OpenSSL's for bulk data, even
when `sendfile` saves the copy, so `--ktls` stays off by default. What it
buys here is HTTPS connections that can move between workers.

### Gathering slow connections, 2026-09-19

`skew` and `spike` at their defaults, 8 slow connections among 64, on all 8
CPUs with nothing pinned, showed what the runs above had not: with a slow
connection on every worker, `adaptive` served the quick requests at 20,000–
24,000 requests a second on `skew` (p99 6.4–7.0 ms), less than `accept` and
axum. Placement had spread the slow connections one per worker, and moving
quick ones cannot help when every worker has a slow one. Gathering the slow
connections onto fewer workers (ARCHITECTURE.md, Gathering slow connections)
fixed it.

Every workload, 8 workers, two rounds with the servers in opposite order,
requests a second (p99 in ms):

| workload | `adaptive` | `accept` | `reuseport` | axum |
|---|---|---|---|---|
| user | 142,024–171,468 (1.2–1.9) | 141,296–143,500 (2.5) | 141,700–142,265 (2.4–2.7) | 130,200–150,280 (1.2–1.3) |
| json | 110,068–131,042 (2.7–3.3) | 109,629–111,769 (2.8–3.4) | 108,916–111,099 (3.4) | 112,556–122,438 (1.7–1.8) |
| db | 42,646–46,142 (2.9–3.1) | 42,785–43,132 (2.7–2.9) | 42,729–43,583 (2.8–3.3) | 44,419–44,567 (2.5) |
| stream | 36,619–36,855 (3.4) | 36,680–36,824 (3.4) | 36,468–36,954 (3.4–3.5) | 34,277–34,290 (3.5) |
| me | 94,964–108,133 (3.8–4.1) | 95,781–96,112 (4.0–4.2) | 95,026–95,245 (3.8–3.9) | 113,140–113,833 (1.9) |
| upload | 2,193–2,209 | 2,203–2,225 | 2,199–2,241 | 1,341–1,342 |
| download | 2,067–2,071 | 2,070–2,074 | 2,064–2,069 | 2,073–2,078 |
| relay | 12,128–12,161 (10.7–10.8) | 11,981–12,237 (10.7–10.9) | 11,740–11,940 (11.3–11.7) | 3,994–4,140 (43.9–44.5) |
| churn | 37,588–37,864 (2.1) | 37,795–38,489 (2.0–2.1) | 37,853–38,127 (2.1–2.2) | 33,430–33,593 (3.4–3.5) |
| h2 | 110,776–113,546 (1.0) | 112,533–113,785 (0.8–1.1) | 106,398–107,330 (3.0) | 104,824–105,658 (1.6) |
| overload | 36,343–36,372 | 36,751–37,010 | 36,518–36,838 | 37,400–38,125 |
| recovery | 148,609–151,209 (2.8–2.9) | 149,101–149,438 (2.9) | 149,331–149,578 (2.9) | 142,681–142,701 (1.2–1.3) |
| skew | 70,497–70,742 (3.3–3.4) | 86,688–91,302 (3.9–4.2) | 20,733–43,394 (6.3–7.3) | 49,326–49,532 (3.2–3.6) |
| spike | 120,857–129,553 (2.4–2.8) | 103,611–109,445 (3.6–3.9) | 70,002–79,167 (6.6–7.6) | 63,984–64,388 (3.0–3.1) |

Whichever server ran first read higher on user and json, as before: the
higher figures for `adaptive` and for axum are each from the round that
server ran first in.

- `adaptive` is the best balance. It is level with the other modes on
  uniform load, takes 0.5 to 1.5 ms off the p99 of small requests and 2 ms
  off HTTP/2's against `reuseport`, and is the only mode whose quick requests
  keep a tail near axum's whether the slow requests come first or later.
- `accept` serves more quick requests on `skew`, where the slow connections
  happen to land on some workers and not others, but has the longer tail. It
  falls behind `adaptive` when the slow requests start later.
- `reuseport` is the worst of the three wherever connections differ.
- Against axum, Garuda leads on throughput everywhere except json, me, db and overload,
  and on upload, relay and churn by a wide margin. axum keeps the shorter p99
  on json, me and recovery: small requests under closed-loop load, where
  Tokio's threads take one another's work request by request.


### Checking a JWT without awaiting, 2026-09-19

`/me` checked its HS256 token in an async route, so every request started a
task, and the check copied the token into arrays and decoded the claims
twice. One pinned worker against one pinned Tokio thread, 64 connections,
requests a second:

| | before | after |
|---|---:|---:|
| `/me`, synchronous route | -- | 62,331–62,844 |
| `/me`, async route | 41,278–41,445 | 49,164–49,434 |
| axum | 64,132–67,320 | |

The same token checked by hand in a raw handler reads 71,500: what is left
between that and the extractor is finding the verifier and the bearer
token's string, about 2 µs a request.

All 8 workers, two rounds in opposite order (p99 in ms):

| | Garuda | axum |
|---|---|---|
| me | 114,579–137,706 (2.9–3.1) | 113,983–124,915 (1.7–1.9) |
| json | 111,739–127,774 (3.0–3.2) | 114,198–114,265 (1.7) |

Throughput on `me` went from 95,000–108,000 to level with axum or ahead. The
p99 is where it was: Garuda's small requests have about twice axum's tail
under closed-loop load on every route, which is a separate question from
what any one handler costs.

### Short turns and short time slices, 2026-09-19

Garuda's p99 on small requests was about twice its median on every route,
axum's about 1.1 times. Two causes, found one at a time.

**Turns.** One pinned worker, 64 connections, `/user`, with the most events a
loop turn takes from the poller varied (p50 / p99 in ms):

| events per turn | req/s | p50 | p99 |
|---|---:|---:|---:|
| 256 (before) | 114,268–123,977 | 0.49–0.52 | 1.00–1.11 |
| 64 | 120,243 | 0.50 | 1.03 |
| 48 | 119,744 | 0.53 | 0.70 |
| 32 | 119,953–121,574 | 0.51–0.53 | 0.63–0.67 |
| 16 | 121,292 | 0.52 | 0.65 |
| axum | 91,107–93,104 | 0.69–0.71 | 0.84–0.91 |

On the same worker `/json` went from 1.94 to 1.18 ms and `/me` from 2.06 to
1.23. How often responses are flushed made no difference. A turn now takes 32.

**Time slices.** On 8 workers the cap changed nothing for `/json` and `/me`:
their p99 stayed at 3 ms. Counted from `/proc/<pid>/schedstat` over a run of
`/json`, the kernel took the CPU from Garuda's workers 3,213–3,587 times a
second, against 697–808 for axum's threads, and they sat runnable but not
running for 20–23 µs a request, against 10. The kernel's slice on this box is
2.8 ms, and a worker that loses its CPU keeps every connection it owns waiting
for it. With each worker asking for a shorter slice (8 workers, event cap on,
p99 in ms):

| | user | json | me |
|---|---:|---:|---:|
| kernel's slice (2.8 ms) | 0.92–1.08 | 3.06–3.09 | 3.04–3.07 |
| 1 ms | 1.13–1.27 | 2.30–2.38 | 2.30–2.37 |
| 300 µs | 1.07–1.20 | 1.97–2.02 | 1.89–2.04 |
| 100 µs | 1.06–1.07 | 1.98–2.00 | 1.96–2.00 |
| axum | 1.21–1.32 | 1.60–1.69 | 1.72–1.89 |
| axum, 300 µs | 1.12–1.25 | 1.57–1.59 | 1.65–1.65 |

Throughput did not move. Each worker now asks for 300 µs (`--sched-slice`).

**Every workload after both**, 8 workers, two rounds in opposite order
(p99 in ms):

| workload | Garuda | axum |
|---|---|---|
| user | 138,012–164,897 (1.1–1.3) | 130,163–132,828 (1.3) |
| json | 111,076–134,587 (1.7–2.1) | 113,000–113,189 (1.7–1.8) |
| db | 42,984–45,506 (2.8–3.0) | 44,584–45,019 (2.5) |
| stream | 35,743–35,948 (3.0–3.1) | 33,959–34,162 (3.5–3.6) |
| me | 114,828–130,934 (1.8–2.0) | 113,659–113,883 (1.8–1.9) |
| upload | 2,181–2,209 | 1,340–1,341 |
| download | 2,065 | 2,079–2,085 |
| relay | 11,463–11,545 (11.0–11.1) | 3,786–4,068 (44.1) |
| churn | 37,848–38,298 (2.1) | 33,408–33,537 (3.4–3.5) |
| h2 | 113,566–115,523 (1.0) | 104,809–105,209 (1.6) |
| overload | 36,044–36,226 | 37,794–38,041 |
| recovery | 145,439–146,873 (1.4) | 140,899–141,969 (1.3) |
| skew | 63,430–73,623 (2.0–3.3) | 48,370–53,891 (3.4–3.7) |
| spike | 85,714–118,768 (1.9–2.9) | 62,620–65,610 (3.0–3.2) |

`spike` reads 89,000–112,000 over repeated runs with the slice on or off: where
the slow connections land decides it.

### Over HTTPS, 2026-09-19

`TLS=1 bash benchmarks/workloads.sh`: Garuda with OpenSSL 3.5, axum with
rustls 0.23 through axum-server, the same self-signed P-256 certificate, 8
workers against Tokio's 8 threads, two rounds in opposite order (p99 in ms,
server CPU per request in µs):

| workload | Garuda | axum |
|---|---|---|
| user | 107,182–130,171 (1.6–1.7; 31–37) | 109,565–113,087 (1.4–1.5; 27–29) |
| json | 82,893–98,484 (2.1–2.4; 48–56) | 96,433–96,563 (1.8–1.9; 37–38) |
| db | 35,147–35,414 (3.5–3.6; 109) | 40,052–40,094 (2.8; 80) |
| stream | 14,115–14,814 (7.3–7.7) | 8,847–13,544 (41.9–42.1) |
| me | 87,403–100,398 (2.2–2.3; 47–54) | 101,344–107,291 (1.9–2.0; 33–36) |
| upload | 2,134–2,135 | 1,340–1,345 |
| download | 1,629–1,728 | 1,789–1,793 |
| relay | 7,888–7,934 (13.7–14.6) | 3,196–3,366 (45.3–45.4) |
| churn | 4,766–4,964 (26.0–28.2; 993–1,032) | 5,901–5,913 (16.7–16.8; 574–577) |
| h2 | 82,145–83,354 (1.5–1.6; 46–47) | 89,350–89,504 (1.7–1.8; 36) |
| overload | 28,029–28,529 | 32,553–32,584 |
| recovery | 110,494–110,676 (1.6) | 116,243–117,678 (1.4) |
| skew | 45,704–46,847 (4.5–4.7) | 51,009–51,364 (3.1–3.2) |
| spike | 55,478–55,901 (4.2–4.3) | 63,119–63,614 (2.9–3.0) |

In the clear Garuda leads or ties everywhere but `db`; over HTTPS axum leads
on most small requests. What TLS adds to a request's CPU is the difference:
11 to 17 µs for Garuda on `user`, `json` and `me`, 3 to 6 for axum, and on
`churn`, a full handshake a request, 1,000 µs against 575.

Found so far, one worker against one Tokio thread:

- Each request cost two reads: OpenSSL read a record's 5-byte header and then
  its body. With reads going ahead it is one, as for rustls (above; the
  table is after that change, which moved the CPU per request by a microsecond
  or two).
- Keeping OpenSSL's buffers between requests rather than releasing them
  (`SSL_MODE_RELEASE_BUFFERS`) is worth 2 to 5% and costs 34 KiB per idle
  connection; not done.
- A POST with a JSON body is where the gap is widest: 38,700 requests a
  second on one worker against axum's 57,000 to 59,000, where in the clear it
  is 63,600 against 70,500. Not found yet.

### Where a JSON POST spends its time, 2026-09-20

`/json` is the widest gap left, so the route was taken apart a stage at a
time: one worker pinned to a core, 64 connections from three others, every
route answering the same 55 bytes, so that only the work before the answer
differs. Two rounds, CPU per request in microseconds:

| route | what it does | µs a request |
|---|---|---|
| get-text | GET, no extractor, a constant string | 7.9–8.6 |
| post-text | POST, the body arrives and is not read | 8.1–8.8 |
| raw-body | POST, the body read and not parsed | 8.1 |
| raw-decode | and `JSONCoder.decode` | 11.8–11.9 |
| raw-full | and `send(json:)` | 14.4–14.7 |
| post-decode | `Body<Order>` in place of the raw read | 13.1–13.3 |
| json | the route as it ships | 15.6–16.0 |
| gen-decode | the raw read, decoded by written-out code | 8.9 |
| gen-full | and encoded by written-out code | 10.6–10.7 |

What each stage costs, by subtraction:

- **Parsing a POST and taking its body in: 0.2 µs.** Reading the body is
  free; it has already arrived, and the handler is only lent it. Nothing in
  the request path accounts for the gap.
- **Codable decoding: 3.8 µs. Codable encoding: 2.5 µs.** Together they are
  6.3 of the 7.7 µs that separates `/json` from a GET answering a constant.
- **Extraction and the answer's type: 2.4 µs**, split evenly between
  `Body<Order>` and returning `JSON<Receipt>` rather than calling
  `send(json:)`. The profile says where it goes: `getCache`,
  `_swift_getGenericMetadata`, `__swift_instantiateConcreteTypeFromMangledName`
  and `tryCast` are about 6% of the worker's time, and generic metadata is
  looked up again for every request.
- **Written-out code, of the kind a macro would generate, decodes in 0.8 µs
  and encodes in 1.7.** Decoding is 4.8 times faster, and the pair together
  cost about what Codable's encoding alone costs. End to end that is
  14.4 µs down to 10.7, or 69,300 requests a second up to 93,800: a third
  more, on one worker, against axum's 70,500.

Two things this corrects. A microbenchmark on a quiet dev box measured the
same Codable work at 1.5 µs decoding and 1.0 encoding, less than half what
it costs in the server, because a tight loop keeps the metadata caches and
the instruction cache warm and a server does not. And the JSON coder's own
scanner is not what costs: Garuda's coder is about three times faster than
Foundation's on the same types, and yyjson, the C parser, reads this body in
0.12 µs. What costs is Codable itself — its containers, its existentials
and the metadata it looks up for each of them. A parser swap cannot reach
that, which is why `swift-yyjson`, yyjson behind `Codable`, measured 1.7
times slower than Garuda's own coder rather than faster.

The written-out decoder takes the happy path only — no escapes, no unknown
keys — so generated code that handles everything would give a little of that
back.

### Every workload against axum, 2026-09-20

`bash benchmarks/workloads.sh` with `skew` and `spike` added to the list: 8
Garuda workers against Tokio's 8 threads, 64 connections, 5 seconds a
workload, one run each. Requests a second, then p99 in milliseconds and the
server's CPU per request in microseconds where they say something.

Both applications are written the way each framework's documentation writes
one, and both now generate their JSON code: serde's derive on the axum side,
and on Garuda's the `JSONReadable` and `JSONWritable` conformances for
`Order`, `Receipt` and `Item`, written out by hand because `@JSON` is not
written yet. Everything else in the two applications is unchanged.

| workload | Garuda | axum |
|---|---|---|
| user | **160,070** (1.19; 20) | 130,108 (1.37; 24) |
| json | **142,778** (1.56; 30) | 113,313 (1.74; 32) |
| db | 44,230 (2.67; 83) | **44,659** (2.49; 72) |
| stream | **36,071** (3.04; 88) | 34,317 (3.48; 74) |
| me | **128,831** (1.84; 35) | 112,922 (1.87; 32) |
| upload | **2,162** (1,912) | 1,342 (3,678) |
| download | 2,072 | **2,082** |
| relay | **11,538** (10.9; 381) | 4,029 (43.6; 566) |
| churn | **37,581** (2.13; 64) | 33,322 (3.49; 93) |
| h2 | **115,565** (0.96; 29) | 104,403 (1.63; 31) |
| overload | 35,565 | **37,391** |
| recovery | **150,559** | 142,341 |
| skew | **72,973** (2.43; 89) | 47,118 (3.77; 149) |
| spike | **107,038** (2.55; 54) | 61,934 (3.07; 102) |

Garuda is ahead on eleven of the fourteen, level on `db` and `download`, and
behind on `overload` by 5%. Where it is ahead by most, it is for a reason
that has been measured rather than guessed:

- `skew` and `spike`, by 55% and 73%, from gathering slow connections onto
  fewer workers so that quick requests have somewhere to go.
- `relay` by nearly three times, and at a quarter of the p99: the client
  streams a response on as it arrives rather than holding it.
- `json` by 26%, from reading and writing that type's JSON directly. Against
  Codable the same sweep is level with axum, which is where it sat before.
- `churn`, `h2` and `user` by 13%, 11% and 23%, with a p99 below axum's on
  all three, from the short turns and short scheduler slices.

The tail is now Garuda's on every small request: 1.56 against 1.74 on `json`,
0.96 against 1.63 on `h2`, 1.19 against 1.37 on `user`. It used to be about
twice axum's.

Where it is not ahead: `db` is a Postgres round trip either way and the
difference is the driver's 11 microseconds of CPU; `overload` is 16 times the
connections against a pool far short of them, where what is being measured is
mostly how a pool queues.

A worker is a process, so memory starts higher -- 13 MiB against axum's 5 --
and grows more slowly: 38 against 44 by the end of the run.

