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

Garuda 2 reads `--workers N` as `--shards N`, and each shard then takes a
thread per CPU it is given. So `WORKERS=4` on 8 CPUs is four shards of two
threads, not Garuda 1's four single-threaded processes. Add `--threads 1`
(`GARUDA_EXTRA_ARGS`) for Garuda 1's shape. On the bench box that is worth
43% on the closed pass ([Garuda 2.0.0](#garuda-200)).

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

## Caveats

**Reading the numbers here.**

- **Compare within one table.** Figures from different sessions move by tens
  of percent. Never set one beside another.
- **Single runs move by 20-30%.** `vs-axum.sh` is a check between changes;
  quote `frameworks.sh` with three runs at every level.
- **A long sweep and a short run are different measurements.** A 20-minute
  `frameworks.sh` sweep settles about 30% below what `vs-axum.sh` reads in 87
  seconds, for every server alike: the CPU cannot hold its clocks that long.
- **Give Garuda a worker count that matches the machine.** Every other server
  here sizes its threads from the CPU count; Garuda takes what `--workers`
  says. A mismatch costs more than the gap between any two of these servers.

**Taking a measurement.** Each of these was learned by having it invent a
result:

- **Position is part of the measurement.** Whichever server runs second reads
  lower, and not equally -- Garuda loses about 17% on `user`, axum about 1% --
  so the default `SERVERS="garuda axum"` flatters Garuda. Whatever runs first
  in a session reads highest of all. Give each arm its own invocation, rotate
  which leads, and read the rounds together. Two builds of the *same* server
  are safe in the same position.
- **Do not touch the box while it measures.** A round taken while its own
  session edited a file and grepped the tree read at roughly *half* speed in
  every HTTPS cell. On four CPUs, editing a file is not nothing.
- **Publish the spread, not the mean.** A mean hides a contaminated round. One
  cell read -18.6% over rounds 2-4, -13.7% over all four and -5.0% over
  rounds 2-3: three defensible subsets, three answers. Report an unstable cell
  as unstable.
- **Discarding rounds can introduce the bias it removes.** Dropping a warm-up
  and a spoiled round can leave a remainder where one arm never leads -- and
  leading is the inflated position. Check the balance of lead positions in
  what survives.
- **A before-and-after is not an A/B.** Two measurements either side of a
  change carry everything else that moved between them. Where it matters, put
  both arms in one binary behind a switch and rotate.
- **The load generator shares the server's CPUs** unless `PIN` separates them.
  A closed-loop figure can be the load generator's limit.

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
failed. It takes about three minutes; `WORKLOADS` picks some.

It is a check between changes first. The table recorded below is one run of
each workload, not three, so read a difference of a few per cent as nothing:
what it is good for is the differences that are larger than that.

## Recorded runs

### Garuda 2.0.0

Taken on **2026-10-16**, on the same i5-8250U as the Garuda 1 runs after this
one, from the tree at `aebd720` on Vega 0.4.8 and vega-db 0.2.3. Garuda 1 is
the reference, at 1.1.0 (`release/1.x`, `cbad05b`), built with the same Swift
6.3.3. The raw logs, and the scripts that drove them, are in
[benchmarks/results/2.0.0](benchmarks/results/2.0.0).

**The method.** Three things are new since the Garuda 1 runs below, and each
takes one of the box's own effects out of the comparison:

- **The clock is capped at 2.4 GHz** (`scaling_max_freq` on every CPU). Left
  alone, the CPU runs at 3.4 GHz until its turbo budget runs out, then at
  about 2.7. Throughput follows the clock, so whichever server ran first
  after an idle gap won. With the cap, the same binary repeats to within
  about 1%. That also makes every figure lower than the uncapped ones below,
  so the two sets cannot be compared.
- **The server and the load run on separate physical cores.** CPU *n* and
  *n*+4 are hyperthreads of one core, so the server runs on CPUs 0, 1, 4 and
  5 and oha on 2, 3, 6 and 7 (`PIN="0,1,4,5:2,3,6,7"`). Garuda 1 gets
  `--workers 4`. Garuda 2 sizes itself, with no `--shards` or `--threads`,
  and on those four CPUs that is one shard of four threads.
- **Each server gets its own invocation, and the order alternates.** Garuda
  1 goes first in rounds 1 and 3, Garuda 2 in rounds 2 and 4. There are four
  rounds and none is discarded. Each server leads twice, so any advantage
  from going first falls on both equally.

#### Requests that do work

This is `workloads.sh` with `WORKLOADS="user json churn skew spike h2 stream
download upload db"`: 64 connections, a 1 s warm-up and a 5 s run. Each cell
is the median of the four rounds, followed by (p99 ms; CPU microseconds a
request). The last column gives the lowest and highest round, Garuda 1 first.

| workload | Garuda 1.1 | Garuda 2.0 | 2.0 against 1.1 | rounds, 1.1 / 2.0 |
|---|---|---|---:|---|
| user | 137,046 (0.62; 25) | **140,280** (0.55; 28) | +2.4% | 136.4-138.7k / 140.1-141.8k |
| json | 112,916 (1.01; 35) | **119,286** (0.68; 33) | +5.6% | 112.3-113.5k / 118.5-120.1k |
| churn | 25,258 (2.82; 61) | 25,097 (2.88; 130) | -0.6% | 25.1-25.3k / 25.1-25.1k |
| skew | **88,768** (0.99; 41) | 79,912 (1.01; 51) | -10.0% | 88.2-95.9k / 78.3-116.5k |
| skew, slow side | **636** (36.4) | 584 (20.4) | -8.3% | 632-662 / 573-591 |
| spike | **130,480** (0.68; 31) | 112,402 (0.75; 37) | -13.9% | 95.4-132.7k / 92.1-121.4k |
| h2 | 93,176 (0.93; 34) | **96,062** (0.82; 40) | +3.1% | 92.7-93.3k / 96.0-96.3k |
| stream | **37,896** (2.14; 92) | 27,307 (2.95; 142) | -27.9% | 37.4-38.1k / 27.2-29.0k |
| download | **2,162** (55.4; 1,390) | 1,868 (68.8; 1,494) | -13.6% | 2.08-2.42k / 1.77-1.88k |
| upload | 2,028 (103; 1,983) | **2,172** (60.0; 1,750) | +7.1% | 2.02-2.04k / 2.17-2.54k |
| db | **30,050** (3.34; 93) | 28,185 (5.23; 102) | -6.2% | 30.0-30.2k / 27.5-28.2k |

These match the figures taken when phase 4 of the port closed, on the same box
with the same settings. Nothing has moved by more than the rounds' own spread.
Garuda 2 now reads `user` 140k against 141k then, `json` 119k against
121-122k, `h2` 96k against 96k, `stream` 27.3k against 27.2k, `download`
1.87k against 1.87k, and `upload` 2.17k against 2.16k. Garuda 1 also reads
what it read then: 137k, 113k, 93k, 38k, 2.16k and 2.03k.

What the table shows:

- **Garuda 2 is ahead when requests are small and the connection stays
  open.** It leads on `user`, `json` and `h2`, with a lower p99 on all
  three: 0.55 against 0.62 ms on `user` and 0.68 against 1.01 on `json`. It
  also leads on `upload`, at 60 ms p99 against 103. On `user` and `h2` it
  spends slightly more CPU a request (28 against 25 us, 40 against 34) and
  still serves more.
- **`stream` is the gap that is known and still open.** Garuda 2 is 28%
  behind, at 142 us a request against 92. That is where it stood when
  phase 4 closed, and why streamed responses cost more CPU a request was
  left open then.
- **`download` is 14% behind**, at 1,494 us of CPU a request against 1,390.
  Its p50 is 33 ms against 29.
- **`db` is 6% behind**, at 102 us of CPU against 93 and a p99 of 5.2 ms
  against 3.3. Garuda 2's HTTP handling is ahead on `user`, so the
  difference is most likely in vega-db's PostgreSQL driver and pool. That
  has not been profiled.
- **`skew` and `spike` are behind, but each server had one outlier round on
  them.** Garuda 2 read 116k on `skew` in one round and 78-81k in the other
  three. Garuda 1 read 95k on `spike` in one round and 130-133k in the rest.
  The medians put Garuda 1 ahead by 10-14%. The outliers show that a single
  round of either row is not a result. The slow side is a trade: Garuda 2
  serves 8% fewer of the 2 ms requests, but their p99 is 20 ms against 36.
- **`churn` most likely measures oha, not the server.** Both servers read
  25.1k to 25.3k in every round, which points to oha's rate of new
  connections as the ceiling. The difference shows in CPU instead: a new
  connection costs Garuda 2 130 us against Garuda 1's 61.

#### HTTP/3

These are the first HTTP/3 figures for either version. The client for all
three protocols is oha 1.16.0, built with `--features http3` (quinn), so only
the protocol changes between rows. The route is `GET /user/12345` over HTTPS
with a self-signed P-256 certificate and `--http3`. The load is 64
connections with a 1 s warm-up and a 5 s run, under the same pinning and
clock. There are four rounds: the servers alternate and the order of the
protocols rotates. Each cell is the median requests a second, followed by
(p99 ms; CPU microseconds a request):

| protocol | Garuda 1.1 | Garuda 2.0 | 2.0 against 1.1 |
|---|---|---|---:|
| HTTPS/1.1 | 107,454 (1.15; 33) | **108,209** (0.74; 36) | +0.7% |
| HTTP/2, a stream a connection | 70,342 (1.25; 44) | **72,263** (1.09; 51) | +2.7% |
| HTTP/3, a stream a connection | 47,920 (1.98; 82) | **50,662** (1.80; 77) | +5.7% |
| HTTP/2, 8 streams a connection | 127,748 (7.0; 31) | **138,596** (5.06; 28) | +8.5% |
| HTTP/3, 8 streams a connection | 76,893 (9.6; 52) | **137,451** (6.06; 26) | **+78.8%** |

The rounds are tight. Garuda 2's HTTP/3 rows span 50.4-51.7k and
137.1-139.2k, and Garuda 1's span 47.7-48.7k and 76.5-77.1k.

- **With 8 streams a connection, Garuda 2's HTTP/3 is level with its
  HTTP/2**: 137k against 139k, at 26 microseconds a request against 28.
- **With one stream a connection, HTTP/3 serves 70% of what HTTP/2 does**,
  at 77 us a request against 51. Each request is then a datagram in each
  direction, so nothing shares the cost of a packet.
- **Garuda 1's HTTP/3 gains much less from more streams.** It goes from 48k
  to 77k between one stream a connection and 8, while Garuda 2 goes from
  51k to 137k. Over the same step Garuda 1's CPU a request falls from 82 us
  to 52, and Garuda 2's falls from 77 to 26.
- **oha's own `requestsPerSec` is wrong over HTTP/3, so these figures do not
  use it.** After the deadline, oha waits 5-10 s for its QUIC connections
  to close and counts that time too. For a run that served 253,000 requests
  in 5 s it printed 17k. The table divides requests by the 5 s instead.
  [drivers/h3.sh](benchmarks/results/2.0.0/drivers/h3.sh) also prints how
  long the load was busy: requests times mean latency, divided by the number
  of concurrent requests. That comes to 4.9 s in every row, so the load
  filled the run.

#### Against axum, hello world

This is `vs-axum.sh` as it stands, with the clock capped and nothing pinned
except in its own `pinned` pass. axum is the suite's entry, built at
`~/garuda/benchmarks/axum`. There are eight rounds, four with Garuda first and
four with axum first. frameworks.sh loops over `FRAMEWORKS` before `SERVERS`,
so reversing `SERVERS` alone does not change the order, and the axum-first
rounds reverse both. Garuda 1 got two rounds, one in each order. Each cell is
the median requests a second, followed by p99:

| pass | Garuda 2.0 | axum 0.8.9 | Garuda 1.1 |
|---|---|---|---|
| ramp | 122,293 (4.7-6.9 s) | **137,622** (4.5-4.7 s) | 207,107 (3.1-3.3 s) |
| closed | 107,280 (4.0 ms) | **121,666** (1.37 ms) | 141,462 (0.66 ms) |
| pinned | **83,064** (0.94 ms) | 74,880 (1.04 ms) | 94,265 (0.85 ms) |

The order made no difference to either server. Garuda 2 read 120.6-124.4k on
the ramp and 106.1-108.4k closed, in both orders.

- **In the pinned pass, one thread against one thread, Garuda 2 leads axum
  by 11% and trails Garuda 1 by 12%** on the empty `GET /`. That is a gap in
  the cost of each request, and it is larger than on `user` above, where
  Garuda 2 leads.
- **In the unpinned passes Garuda 2 trails axum, and most of that comes from
  what `--workers 4` means to it.** vs-axum.sh passes `--workers 4`, which
  Garuda 2 reads as `--shards 4`. Each shard then sizes its threads from the
  machine, at two each. Garuda 2 so runs eight worker threads where Garuda 1
  ran four single-threaded processes, and oha and zrk use those same CPUs.
  Given `--workers 4 --threads 1`, the shape Garuda 1 has, the same binary
  does **153k closed**, ahead of Garuda 1's 141k and axum's 122k. On the
  ramp it does 147-151k, ahead of axum's 138k
  ([workers-layout.log](benchmarks/results/2.0.0/vs-axum/workers-layout.log)).
  One shard of eight threads reads 104k. That points to the cost being more
  threads than the load generator leaves CPUs for, not shards as such.
- **Garuda 1 is still well ahead on the ramp**: 205k against 147-151k, even
  with Garuda 2 at four shards of one thread. That pass is zrk's open-loop
  ramp to 500,000 requests a second, so it measures how a server behaves when
  it is far behind the offered load.

The runs below are Garuda 1's. They were measured before any of the method
above existed, and where they say Garuda, they mean Garuda 1.

### Garuda 1, 2026-09-20

Every Garuda 1 figure below was taken on **2026-09-20**, on one machine, from the tree
at `b1cbbb0`. Nothing here is carried over from an earlier session: a number
that is not in this file was not measured today.

**The machine.** An Intel Core i5-8250U with 8 CPUs at 1.60 GHz, Ubuntu 26.04.1,
kernel 7.0.0, nothing else running and no builds or tests alongside. Swift
6.3.3, rustc through cargo 1.98.1, OpenJDK 25.0.4, OpenSSL 3.5. zrk 2.5.0 and
oha 1.16.0 share the machine with the server, which is what the caveat above
about the load generator means: these are figures from one box, not from a
pair.

**The servers.** Garuda 1 at `b1cbbb0` with 8 workers; axum 0.8.9 and actix-web
4.15.0 on Tokio 1.53.1; Vert.x 5.1.7 on Netty's epoll transport; Hummingbird
2.26.0 and Vapor 4.122.1 on SwiftNIO 2.102.0. Every one but Garuda sizes its
threads from the CPU count, which here is 8, so Garuda was given 8 workers to
match.

#### Hello world: six servers (Garuda 1)

`GET /`, status 200, empty body. The suite's ramp from 1,000 to 500,000
requests a second, the mean of three 15-second runs at each level. Requests a
second:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda | **194,073** | 177,028 | **167,433** |
| actix-web 4.15.0 | 188,259 | **178,540** | 162,117 |
| Vert.x 5.1.7 | 185,423 | 161,055 | 153,471 |
| axum 0.8.9 | 172,735 | 178,152 | 146,422 |
| Hummingbird 2.26.0 | 58,668 | 59,771 | 58,998 |
| Vapor 4.122.1 | 48,766 | 48,744 | 48,260 |

Latency at 256 connections, p50 / p99 in milliseconds:

| entry | p50 | p99 |
|---|---:|---:|
| Garuda | 675 | 3,374 |
| axum | 706 | 3,472 |
| actix-web | 812 | 3,621 |
| Vert.x | 827 | 3,926 |
| Hummingbird | 2,894 | 7,768 |
| Vapor | 3,230 | 8,423 |

- Garuda, actix and axum are one group. Garuda leads at 64 and 512 and is
  1,500 requests a second behind actix at 256, which is inside the spread
  between runs of either: Garuda's three runs at 64 ranged 177,731–207,025 and
  actix's 177,513–207,699. Read the three as a tie and Vert.x as just behind.
- Garuda served about three times Hummingbird and four times Vapor.
- Garuda's 64-connection run recorded one error in three runs. The others
  recorded none anywhere.
- Every server's p99 is seconds. All six fell behind the ramp, which is what
  the suite measures: a rate under an offered load none of them can hold.
- **A worker count that does not match the machine is worth more than the
  difference between these servers.** Run once by mistake with 20 workers on
  these 8 CPUs, Garuda read 166,490 / 144,825 / 140,511 and placed fourth. The
  other five size themselves and cannot be got wrong this way.

#### Hello world again, with the measurement order taken out (Garuda 1)

The run above measures every server inside one invocation, in a fixed order,
and whichever goes later reads lower. This one does not: each server is
measured in an invocation of its own and the six rotate by one each round, so
over rounds 2-7 every server occupies every position exactly once. Round 1 is
discarded. `benchmarks/fw-arms.sh`, 256 connections, 8 workers, three 15-second
runs per arm, 2026-09-20. No server recorded an error in any round.

| entry | lowest round | median | highest round | spread |
|---|---:|---:|---:|---:|
| ntex 2.18 | 177,252 | **181,303** | 186,634 | 5.2% |
| axum 0.8.9 | 175,890 | **176,794** | 179,579 | 2.1% |
| Garuda 1.0.1 | 173,025 | **174,575** | 177,289 | 2.4% |
| elysia-bun | 163,953 | **167,754** | 171,494 | 4.5% |
| Hummingbird 2.26.0 | 61,186 | **62,068** | 62,468 | 2.1% |
| Vapor 4.122.1 | 48,233 | **48,359** | 48,797 | 1.2% |

p99 at 256 connections, median of the six rounds: ntex 3,149 ms, axum
3,469 ms, Garuda 3,489 ms, elysia-bun 3,847 ms, Hummingbird 7,660 ms, Vapor
8,446 ms.

What this says, and what it does not:

- **Garuda is third, 1.3% behind axum and 3.7% behind ntex.** The first of
  those is not a result: Garuda's rounds span 173.0k-177.3k and axum's
  175.9k-179.6k, so the two overlap and six rounds cannot separate them. ntex
  clears Garuda's range, barely, in every round.
- **Garuda is 4.1% ahead of elysia-bun, 2.8x Hummingbird and 3.6x Vapor**, and
  those gaps are far outside any arm's spread.
- **Round 1 is why the discard exists.** Garuda's round-1 reading was 197,741 --
  **13.3% above its own median and above every one of its six balanced
  rounds**. No other arm's round-1 excess reached 3% (ntex +2.6%, elysia +1.4%,
  axum -0.8%, Vapor 0.0%, Hummingbird -2.7%). Why the effect is this large for
  this one server on a cold machine is not explained here; it is recorded
  because a one-round comparison would have reported Garuda in first place by
  12%.
- **Position within a round is now small.** Each arm's first-position round
  lands within 2.2% of its own median, in both directions. Running one server
  per invocation is what buys that; the 17% order bias measured earlier came
  from sharing an invocation.
- A three-second unrotated smoke test taken the same evening read Garuda
  226k, ntex 231k and axum 184k. Every one of those is wrong, Garuda's by 29%.
  Short single runs are not a cheap version of this table.

#### Requests that do work, against axum (Garuda 1)

`bash benchmarks/workloads.sh` with `skew` and `spike` added: 8 Garuda workers
against Tokio's 8 threads, 64 connections, a 1 s warm-up and a 5 s run,
one run each. Requests a second, then p99 in milliseconds and the server's CPU
per request in microseconds.

Both applications are written the way each framework's documentation writes
one, and both generate their JSON code: serde's derive on the axum side,
`@JSON` on Garuda's, over `Order`, `Receipt` and `Item`.

| workload | Garuda | axum |
|---|---|---|
| user | **168,353** (1.01; 20) | 130,671 (1.34; 24) |
| json | **144,050** (1.63; 29) | 113,613 (1.74; 32) |
| db | 43,902 (2.87; 83) | **45,000** (2.47; 72) |
| stream | **35,512** (3.09; 91) | 34,360 (3.43; 74) |
| me | **131,209** (1.83; 35) | 114,277 (1.85; 32) |
| upload | **2,185** (59; 1,857) | 1,343 (109; 3,676) |
| download | 2,061 (51; 1,887) | **2,074** (56; 1,900) |
| relay | **11,607** (10.8; 378) | 4,324 (43.6; 483) |
| churn | **38,328** (2.08; 65) | 33,045 (3.53; 94) |
| h2 | **115,715** (0.97; 27) | 105,690 (1.60; 30) |
| overload | 35,886 (48; 101) | **37,705** (32; 86) |
| recovery | **146,477** (1.38; 23) | 138,565 (1.36; 21) |
| skew | **68,990** (2.85; 94) | 48,606 (3.67; 144) |
| spike | **86,302** (2.96; 67) | 60,545 (3.08; 106) |

Garuda is ahead on eleven of the fourteen and behind on three: `db` by 2%,
`download` by 1% and `overload` by 5%.

- `relay` is nearly three times, at a quarter of the p99: the client streams a
  response on as it arrives rather than holding it.
- `skew` and `spike` are 42% and 43%, from gathering slow connections onto
  fewer workers so that quick requests have somewhere to go.
- `json` is 27%, from reading and writing that type's JSON directly rather
  than through `Codable`.
- `upload` is 63% at half the CPU a request.
- The tail is Garuda's on every small request: 1.01 against 1.34 on `user`,
  0.97 against 1.60 on `h2`, 1.63 against 1.74 on `json`.
- Where it is behind: `db` is a Postgres round trip either way and the
  difference is the driver's 11 microseconds of CPU; `overload` is 16 times
  the connections against a pool far short of them, where what is measured is
  mostly how a pool queues.
- A worker is a process, so memory starts higher -- 13 MiB against axum's 6 --
  and grows more slowly: 39 against 42 by the end.

#### The same over HTTPS (Garuda 1)

> **The figures below replace an earlier table that was measured wrong.**
> `workloads.sh` runs one server through every workload and then the next,
> and on this box whichever runs **second reads lower** -- Garuda by about
> 17% on `user`, axum by about 1%. Because the bias is not the same for the
> two, running them in one invocation does not cancel it, and the default
> `SERVERS="garuda axum"` puts Garuda first. The old table was taken that way
> and **overstated Garuda throughout**; it claimed 128,996 on `user` against
> axum's 109,391, where measuring each first gives 115,293 against 109,530.
> A second effect compounds it: whatever is measured first in a session reads
> highest of all, which is where that 128,996 came from.
>
> Everything below gives **each arm an invocation of its own**, so every one
> is the server measured first, and **rotates the arms over three rounds** so
> each takes each position exactly once. Figures are the mean of the three.

`TLS=1`: Garuda on OpenSSL 3.5.5, the same Garuda with its record layer built
against BoringSSL, and axum on rustls 0.23 through axum-server, all on the
same self-signed P-256 certificate. Requests a second, with (p99 ms; CPU
microseconds a request).

| workload | Garuda, OpenSSL | Garuda, BoringSSL | axum |
|---|---|---|---|
| user | 106,690 (1.59; 36) | 108,701 (1.49; 32) | **109,810** (1.49; 29) |
| json | 88,867 (2.23; 50) | 96,029 (1.99; 44) | **96,048** (1.88; 37) |
| db | 35,495 (3.56; 108) | 39,038 (3.19; 94) | **39,791** (2.84; 80) |
| stream | 14,262 (7.60; 253) | **14,693** (7.17; 238) | 10,974 (42.0; 142) |
| me | 90,420 (2.35; 52) | 95,508 (2.19; 47) | **103,350** (1.97; 34) |
| upload | 2,177 (57.1; 1,756) | **2,182** (55.6; 1,739) | 1,329 (116; 3,465) |
| download | 1,664 (70.7; 2,336) | 1,688 (59.5; 2,043) | **1,805** (49.3; 1,804) |
| relay | 7,945 (14.2; 565) | **8,724** (15.1; 495) | 3,085 (46.1; 667) |
| churn | 4,875 (26.8; 1,010) | **6,850** (15.1; 574) | 5,894 (16.7; 574) |
| h2 | 82,178 (1.46; 46) | 79,749 (1.63; 40) | **90,133** (1.75; 36) |
| overload | 28,521 (62.4; 134) | 31,000 (60.1; 118) | **32,566** (36.2; 100) |
| recovery | 111,236 (1.59; 34) | **118,992** (1.41; 29) | 116,703 (1.44; 26) |
| skew | 47,365 (4.44; 104) | 50,518 (3.30; 86) | **51,291** (3.20; 70) |
| spike | 56,208 (4.29; 84) | **63,232** (3.15; 66) | 62,344 (2.95; 56) |

The three rounds are read without the session's first, for the reason under
Caveats: whatever is measured first of all reads high, and rotating the arms
cannot cancel that because only one arm can hold that slot. It was worth
about 20% on the one row it touched -- OpenSSL's `user` read 130,965 there
against 103,657 and 109,723 in its other two rounds -- which is enough to
invert a comparison.

On BoringSSL Garuda leads six of fourteen over HTTPS, ties `json` to within
20 requests a second, and is within two percent on `user`, `skew` and `db`.
axum keeps `me`, `h2`, `download` and `overload`.

**BoringSSL against OpenSSL, the same tree otherwise.** The record layer and
handshake compiled against each (`AVIAN_TLS_BORINGSSL`; the libraries live in
one binary because swift-nio-ssl's copy carries a `CNIOBoringSSL` symbol
prefix, so ACME and JWT keep OpenSSL). **CPU a request falls on thirteen of
the fourteen and rises on none**, which is a steadier signal than throughput
on a box whose absolute level drifts:

| | throughput | CPU a request |
|---|---|---|
| churn | **+40.5%** | 1,010 -> **574 us** |
| spike | +12.5% | 84 -> 66 |
| db | +10.0% | 108 -> 94 |
| relay | +9.8% | 565 -> 495 |
| overload | +8.7% | 134 -> 118 |
| json | +8.1% | 50 -> 44 |
| recovery | +7.0% | 34 -> 29 |
| skew | +6.7% | 104 -> 86 |
| me | +5.6% | 52 -> 47 |
| stream | +3.0% | 253 -> 238 |
| user | +1.9% | 36 -> 32 |
| download | +1.5% | 2,336 -> 2,043 |
| upload | +0.3% | 1,756 -> 1,739 |
| h2 | **-3.0%** | 46 -> 40 |

`churn` is a handshake a request, and it is the one that moves most, exactly
as the library probe above predicted: 40.5% cheaper a handshake there, 40.5%
more throughput here. Two measurements of different things agreeing is the
reason to believe either.

**Read ahead had to be written by hand.** BoringSSL lists
`SSL_CTX_set_read_ahead` among its no-ops -- its header says the function
"returns one", and that is all it does -- so its record layer asks the socket
for a record's 5-byte header and then for the body, where OpenSSL asks once.
That was worth about 7% on `user` and it was visible as a contradiction
before it was understood: BoringSSL spent *less* CPU a request and still read
lower, which is the shape of an extra syscall rather than extra work.
aviancore now gives BoringSSL a BIO that reads greedily. Counted off the
worker while it served `/user/12345`:

| | read syscalls | requests | reads a request |
|---|---|---|---|
| OpenSSL | 238,338 | 238,054 | **1.00** |
| BoringSSL, plain | 664,534 | 331,944 | **2.00** |
| BoringSSL, greedy BIO | 351,665 | 351,413 | **1.00** |

`user` was recorded going from 7% behind OpenSSL to 2% ahead when the BIO
landed, and `json` from level to 8% ahead. **Treat those two as
unconfirmed.** They compare measurements taken either side of a change rather
than an A/B, so they carry whatever else moved between them, and a later A/B
(below) puts the BIO's worth at about 1%. One saved `read` a request cannot
be worth nine points.

#### What HTTP/2's 3% is not (Garuda 1)

`h2` is the one workload still behind OpenSSL. Each of these was checked
rather than assumed, and each came back negative:

| candidate | why not |
|---|---|
| the read count | the greedy BIO restored it to 1.00, same as OpenSSL |
| `av_tls_pending` answering 1 rather than a byte count | every caller tests it against zero |
| the cryptography | `h2` spends 40 us a request against OpenSSL's 46 -- the saving is there and does not become throughput |
| write batching | `strace` over 2,000 requests: 2.03 writes a request on OpenSSL against 2.02 on BoringSSL for h2, 1.02 against 1.01 for HTTP/1.1 |
| the greedy BIO itself | switching it off makes `h2` *slower*, table below |
| this machine | Peregrine reproduced the shape on another codebase and box: CPU a request -13% on both transports, matching here to a tenth of a point |

The greedy BIO was the last hypothesis. One binary against itself, the BIO
off at run time with `AVIAN_NO_GREEDY=1` so the arms differ by a branch and
not a build, five rotated rounds with the first discarded and the lead
balanced two-all:

| rounds 2-5 | greedy on | greedy off | |
|---|---|---|---|
| `user` req/s | 106,647 / 107,612 / 107,417 / 107,462 | 106,578 / 105,022 / 106,267 / 107,508 | +0.9% |
| `h2` req/s | 78,759 / 78,717 / 79,925 / 78,442 | 78,437 / 77,929 / 78,052 / 77,450 | +1.3% |
| `h2` CPU a request | 38.5 us | 40.0 us | -3.8% |
| `h2` p99 | 1.631 ms | 1.672 ms | -2.4% |

Every greedy reading beats every plain one. **So the cause is unknown, and
nothing is queued to test.** What stands: BoringSSL makes a request about 13%
cheaper in CPU whichever transport carries it, HTTP/1.1 turns that into
throughput and HTTP/2 does not.

One earlier claim here has been withdrawn outright. Peregrine's figure of
h2's p99 worsening, and its -7.8% at eight connections, were artefacts of
running the baseline arm first every time; alternated, the -7.8% became
+3.7% and the p99 gap vanished (1.351 ms against 1.336). Its CPU figures
survive, because they agree with numbers measured separately here rather
than because of the method that produced them.

In the clear Garuda leads eleven of fourteen; over HTTPS, measured the way
above, it leads four. The difference is what TLS adds to a request's CPU,
and it is not the same for the two. The figures in the next table are the
OpenSSL build, which is what the profiling below was done on:

| request | Garuda, clear -> HTTPS | axum, clear -> HTTPS |
|---|---|---|
| user | 20 -> 31 us (+11) | 24 -> 29 us (+5) |
| json | 29 -> 42 us (+13) | 32 -> 37 us (+5) |
| me | 35 -> 46 us (+11) | 32 -> 34 us (+2) |
| churn | 65 -> 995 us (+930) | 94 -> 578 us (+484) |

OpenSSL costs Garuda two to three times what rustls costs axum per request,
and on `churn`, which is a full handshake a request, nearly twice. That is
where the HTTPS gap comes from rather than from the request handling -- and
building the record layer against BoringSSL closes most of the `churn` half
of it, which is the strongest evidence that the diagnosis was right.

Profiling both servers on one pinned worker found where it goes. On a
keep-alive request OpenSSL is 22% of Garuda's CPU, and the largest single
symbol in it was `ERR_clear_error` at 1.37% of the whole process -- three
times what encrypting the data cost -- which is now off the hot path. What
is left is the record layer's own bookkeeping: `EVP_CIPHER_CTX_ctrl` and
`EVP_CIPHER_CTX_get_iv_length` about 0.7% together, and the buffer
allocation `SSL_MODE_RELEASE_BUFFERS` asks for, about 0.7%. On a handshake
72% of Garuda's CPU is OpenSSL, and it is EVP object churn rather than
mathematics: `EVP_PKEY_generate` 11.8%, `EVP_PKEY_fromdata` and its
parameters 8.5%, algorithm fetching 2.9%. For contrast axum's handshake is
`aws_lc` RDRAND 25.9%, SHA-512 15.2% and X25519 8.3% -- primitives, not
bookkeeping. Both negotiate the same TLS 1.3 with the same cipher and the
same X25519MLKEM768 group, both resume sessions, and kernel TLS is a
regression here rather than a win (below), so none of those explain it.

**What the workloads below do not cover, and it matters.** These fourteen are
request-shaped: the largest body any of them moves is a megabyte, and most
move a few hundred bytes. They say nothing about a server sending large files
through `sendfile`, which is the one place kernel TLS earns its keep -- and
BoringSSL has none, so whatever the switch costs there, these rows cannot
show it.

Peregrine, built on the same aviancore, measured it on a 4-CPU box: one
worker, `--static-dir`, seven rounds over three arms with the lead rotating
and the first round discarded, so each arm led exactly twice.

**Static files are where BoringSSL wins by the largest margin.** Against
OpenSSL without kernel TLS, throughput and CPU move together in every cell and
the sign matches every earlier run:

| file | HTTPS/1.1 | CPU a GiB | HTTP/2 | CPU a GiB |
|---|---|---|---|---|
| 64 KiB | +23.5% | -19.4% | +44.8% | -30.8% |
| 1 MiB | +31.1% | -22.9% | +44.2% | -31.0% |
| 16 MiB | +30.8% | -22.8% | +35.3% | -25.8% |

**Against OpenSSL *with* kernel TLS, that box cannot resolve the difference,
and no magnitude should be quoted.** Per round across the six kept rounds,
HTTPS/1.1, BoringSSL against kTLS:

| file | per-round | mean | spread |
|---|---|---|---|
| 64 KiB | +20.3 +35.1 +1.0 +24.8 +24.1 +12.2 | +19.6% | 34 points |
| 1 MiB | -5.7 +7.0 -24.1 -2.0 +3.1 -5.5 | -4.5% | 31 points |
| 16 MiB | -0.2 -0.3 -10.1 -2.3 -1.4 -7.3 | -3.6% | 10 points |

At 1 MiB the sign changes three times around a 4.5-point mean. That is not a
measurement. Three runs have now produced -18.6%, -13.7%, -5.0%, -4.5% and
-3.6% for nominally one quantity, and the earlier -8.4% and -13.7% published
here are **withdrawn, not confirmed at a smaller value**. What stands: at
64 KiB BoringSSL is ahead; at 1 MiB and 16 MiB the difference is inside
run-to-run variation on that hardware. A magnitude for large-file kernel TLS
needs a quiet dedicated machine.

**It was never an HTTP/2 question.** Kernel TLS is consistently *worse* than
no kernel TLS over h2 -- 37.6% more CPU a GiB at 1 MiB -- because framed bytes
cannot go out by `sendfile` in the first place.

Peregrine also measures the handshake through a whole server, on another
machine, over five pairs: **CPU a request down 44.6%**, 0.361 ms to 0.200.
The throughput half of that measurement, 2,791 to 4,889 requests a second,
came from an unalternated run and is withdrawn. The CPU figure is kept
because its two distributions do not overlap at
all across the five pairs -- 0.352 to 0.376 ms against 0.190 to 0.209 -- a gap
wider than any ordering drift seen on that box. The pinned-core probe above
predicted 40.5% cheaper handshakes; a different codebase on a different box
found 44.6%.

**Kernel TLS was not worth switching on here even when it existed**, which
is part of why losing it was an acceptable trade. Measured while OpenSSL
still held the record layer, the same sweep with `--ktls` made every one of
the fourteen workloads slower by 2 to 9% -- `user` 120,473, `json` 98,451,
`download` 1,532, `skew` 45,716 -- while axum's rows moved under 1%, so the
box was steady. This machine has no NIC TLS offload, so software kTLS buys a
copy and pays to set it up. It is unavailable now in any case: `--ktls` is
accepted and ignored.

#### What the TLS library itself costs (Garuda 1)

The profile above says the HTTPS gap is OpenSSL's bookkeeping rather than
Garuda's integration. That is a claim about a library, so it can be measured
without a server in the way. `benchmarks/tls-probes` compiles one source
against OpenSSL 3.5.5 and against BoringSSL -- swift-nio-ssl's vendored copy,
whose prefix header maps the ordinary names onto prefixed ones, so both arms
are the same program -- and runs a client and a server in one process over a
socketpair, counting `CLOCK_PROCESS_CPUTIME_ID`. One core, five alternating
pairs, ECDSA P-256, the `user` workload's record shape.

Two things had to be pinned first. OpenSSL 3.5 offers X25519MLKEM768 by
default while BoringSSL takes classical X25519, and OpenSSL leads with
AES-256-GCM while BoringSSL takes AES-128-GCM; unpinned, the run measures
those policies rather than the libraries. Both are held at X25519 and
AES-128-GCM-SHA256, and both arms print what they negotiated.

| | OpenSSL 3.5.5 | BoringSSL | |
|---|---|---|---|
| handshake | 752.6 us | **447.7 us** | 40.5% cheaper |
| record pair, measured | 9.62 us | 8.09 us | 15.9% cheaper |
| record pair, less the 4.43 us socketpair floor | 5.19 us | **3.66 us** | 29.5% cheaper |

The five pairs do not overlap on either figure: OpenSSL spanned 749.0-757.0
us of handshake and BoringSSL 447.0-448.8. The floor is the same round trip
with no TLS at all, and subtracting it separates the library's work from the
syscall bill both arms pay.

Against the profile shares, that projects to about 6.5% of process CPU on a
keep-alive HTTPS request (22% of CPU, 29.5% cheaper) and about 29% of it on
a handshake (72%, 40.5% cheaper). **That projection is arithmetic on a
profile, not a throughput measurement**, and this tree has already seen a
profile share fail to turn into throughput once: `@PostgresRow` removed the
Codable cost the profile attributed 1.5% to and moved `/db` not at all.
Nothing here has been measured through a server, and swapping the library
would mean porting `avian_crypto.c`, `avian_acme.c` and `CGarudaJWT` too, so
this records what the library costs and not a decision to change it.

Note what the comparison does **not** support. swift-nio-ssl is not a third
option: it vendors this same BoringSSL, so its Swift API cannot be faster
than the measurement above, and reaching it would mean a memory-BIO buffer
pump and a SwiftNIO dependency in a server that does its own I/O.

## What changed, and when

The figures above are of one tree. These are the changes that moved them,
newest first, so that a number can be traced to a commit. None of them is
re-measured here: each was measured against the tree before it, and those
trees are gone.

- `fc66653` `@PostgresRow` writes a type's reader, so a result row does not
  go through `Codable`. It made no difference to `db` that can be told from
  noise, which is recorded with it.
- `b9189f2` aviancore 0.6.7: OpenSSL's error queue is cleared on the way out
  of a failure rather than before every read and write. Two to three
  microseconds of CPU off every TLS request.
- `b1cbbb0` `@JSON` writes a type's JSON reading and writing, so a type does
  not go through `Codable`.
- `4ce7a9f` `JSONReadable` and `JSONWritable`: the coder takes a type's own
  code when it has it.
- `58de76c` whether a decoded type has validation rules is asked once for
  that type, not once a request.
- `e9fc721` at most 32 events a loop turn, and 300 µs scheduler slices, so a
  small request's p99 is not twice its median.
- `7f859cd` a JWT is checked without awaiting when the keys are in hand.
- `0b60d22` slow connections are gathered onto fewer workers when every
  worker holds one.
- `82e4241` `--balance adaptive`: connections are shared among workers by
  load.
- `754b34a` TLS records are read ahead, so a request costs one read and not
  two.
