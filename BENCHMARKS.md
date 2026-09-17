<p align="center">
  <img src="assets/garuda-stylized-lockup-tamil5.png" alt="Garuda" width="640">
</p>

# Benchmarks

How Garuda's performance is measured, and the results so far. Benchmarks are a
check on the engine, not its purpose: a change that makes Garuda slower should
be noticed, and these runs are how.

The reference points are [axum](https://github.com/tokio-rs/axum), a widely
used Rust framework, and Hummingbird and Vapor, from
[the-benchmarker/web-frameworks](https://web-frameworks-benchmark.netlify.app/).
Every server but Garuda runs that suite's own application, built as the suite
builds it, under the suite's load command.

## What is measured, and why

The route is hello-world: `GET /`, status 200, empty body. A handler that does
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
for the first axum build, and port 3000.

### Recorded passes

**2026-09-15.** Garuda: phase 1 of the handler API
([HANDLER-API.md](HANDLER-API.md)), on top of 0e0cbbc. axum 0.8.9 on Tokio
1.53.1 and hyper 1.11.1, built with rustc 1.96.0 (the suite's Dockerfile uses
1.98). One run per pass, 88 s in all, no errors. Requests a second:

| pass | Garuda | axum | Garuda ÷ axum |
|---|---:|---:|---:|
| ramp, 15 s | 390,324 | 200,048 | 1.95× |
| closed loop, 10 s | 201,360 | 167,078 | 1.21× |
| pinned, one core each, 10 s | 200,890 | 116,799 | 1.72× |

Latency, p50 / p99 in milliseconds:

| pass | Garuda | axum |
|---|---:|---:|
| ramp | 3.9 / 646 | 471 / 2,973 |
| closed loop | 0.26 / 1.21 | 0.30 / 1.01 |
| pinned | 0.27 / 1.08 | 0.53 / 2.28 |

- axum's ramp latencies are queueing. It fell behind the offered rate.
- The closed-loop figure is probably oha's limit, not Garuda's. Garuda served
  the same ~201k on four workers sharing the CPUs with oha as on one pinned
  core. Read 1.21× as a floor. The pinned 1.72× may be one too.

**2026-09-16, dedicated server.** The first run on the benchmark machine: 8
cores, Ubuntu 26.04, with the load generator on the same host. One run per pass,
87 s in all. Requests a second:

| pass | Garuda | axum | Garuda ÷ axum |
|---|---:|---:|---:|
| ramp, 15 s | 297,198 | 185,660 | 1.60× |
| closed loop, 10 s | 175,475 | 148,001 | 1.19× |
| pinned, one core each, 10 s | 126,341 | 103,965 | 1.22× |

The dev machine (WSL2) is too noisy for the 5% gate: the same unchanged binary
read between 345,250 and 377,247 requests a second across four runs there.
Performance decisions are taken on the dedicated server.

**End of handler API step 3**, on the benchmark machine, 64 connections. Only
the ratios were recorded: Garuda served 1.71× axum's requests a second on the
ramp, 1.22× closed-loop and 1.21× pinned to one core, with under half axum's
closed-loop p99.

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

### Recorded run: axum, actix and Vert.x

**2026-09-17**, Garuda at e0fb3b6. `GET /`, the suite's ramp, the mean of three
runs at each level. Host: the dedicated benchmark machine, an Intel Core
i5-8250U (4 cores, 8 threads), 3.3 GB, Ubuntu 26.04, with zrk 2.5.0 on the
same machine. axum 0.8.9 on Tokio 1.53.1 and actix-web 4.15.0 built with rustc
1.93.1; Vert.x 5.1.7 on OpenJDK 25.0.4.

As upstream runs it, every server with all 8 CPUs (`WORKERS=8`), load unpinned.
Requests a second:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda | 203,397 | 179,075 | 164,323 |
| axum | 172,055 | 180,136 | 148,930 |
| actix | 190,299 | 180,040 | 171,059 |
| Vert.x | 185,496 | 167,935 | 153,826 |

Servers on CPUs 0-3 and zrk on CPUs 4-7 (`PIN=0-3:4-7 WORKERS=4`):

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda | 212,552 | 184,035 | 177,375 |
| axum | 191,195 | 167,958 | 162,726 |
| actix | 188,013 | 186,110 | 179,313 |
| Vert.x | 194,215 | 180,094 | 165,546 |

- The four are within about 15% of each other at every level, and within 5%
  at 256 and 512. Runs of one server at one level moved by up to 16%.
- Every p50 is hundreds of milliseconds and every p99 seconds: all four fell
  behind the ramp, so these rates are what this machine can serve and
  generate at once, not the servers' own ceilings. actix had 5 and 2 errors at
  64 connections; the others none.
- Pinning does not separate the load: CPUs 0-3 and 4-7 are hyperthreads of the
  same four cores. A machine with a second host for the load generator is what
  would separate the servers.
- These rates are lower than the same machine gives in a short run, for every
  server. Twenty minutes of continuous load on a 15 W laptop CPU under the
  `powersave` governor is a throttling shape: `vs-axum.sh` right afterwards
  read 296,072 req/s for Garuda and 199,132 for axum on the ramp, against
  203,397 and 172,055 here. Compare a sustained sweep only with another
  sustained sweep.

### Recorded run: Hummingbird and Vapor

**2026-09-15**, Garuda at 09eb178 with 4 workers. `GET /`, the suite's ramp,
the mean of three runs, no errors. Requests a second:

| entry | 64 | 256 | 512 |
|---|---:|---:|---:|
| Garuda router | 414,234 | 389,445 | 370,945 |
| Hummingbird 2.26.0 | 88,864 | 102,399 | 99,706 |
| Vapor 4.122.1 | 60,411 | 58,946 | 60,837 |

- Swift 6.3.3, SwiftNIO 2.102.0. Host: WSL2, 4 CPUs of an Intel Core
  i9-12900KF, with the load generator on the same CPUs.
- Garuda ran on the built-in router that the handler API has since replaced.
  The axum passes above ran through the handler API.
- Garuda served about 4× Hummingbird and 6–7× Vapor at every level.
- No latencies. The ramp offers far more than Hummingbird and Vapor can serve,
  so their p50s are seconds of queueing, not the cost of a request.
- No pinned pass. SwiftNIO sizes its event loop group from cgroup limits or the
  online CPU count, not from CPU affinity. Under `taskset`, Hummingbird and
  Vapor would each run four loops on one core.

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

## Planned

Hello-world measures the server. Next, benchmarks that measure a request doing
work:

- path parameters (`GET /user/:id`)
- JSON in and out
- a database round trip
- streaming response bodies
