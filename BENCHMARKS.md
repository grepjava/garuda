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

## Caveats

- **Compare within one table.** Figures from different sessions move by tens
  of percent, and by more on a machine whose CPUs are shared with anything
  else. Never set a number from one session beside a number from another.
- **Single runs need care.** They move by 20–30%. vs-axum.sh is a check
  between changes. Quote frameworks.sh with three runs at every level.
- **Give Garuda a worker count that matches the machine.** Every other server
  here sizes its threads from the CPU count. Garuda does not: `--workers` is
  whatever it is told, and a count that does not match costs more than the
  difference between any two of these servers.
- **The load generator shares the server's CPUs** unless `PIN` separates them.
  A closed-loop figure can be the load generator's limit.
- **Use a dedicated machine** for figures that matter, with nothing else
  running and no builds or tests alongside.
- **A long sweep and a short run are different measurements.** On the bench
  box a full `frameworks.sh` sweep takes about 20 minutes and its rates settle
  some 30% below what `vs-axum.sh` reads in 87 seconds, for every server
  alike: the CPU cannot hold its clocks that long. Never read a sweep's figure
  against a short run's.
- **The order servers are measured in is part of the measurement, and it does
  not cancel.** `workloads.sh` runs one server through every workload and then
  the next. Whichever goes second reads lower -- but not equally: on this box
  Garuda loses about 17% on `user` and axum about 1%, so the default
  `SERVERS="garuda axum"` quietly flatters Garuda. Whatever is measured first
  in a whole session reads highest of all. To compare servers, give each an
  invocation of its own with `SERVERS` naming one, rotate them between rounds
  so each takes each position, and read the rounds together. Comparing two
  builds of the *same* server is safe as long as both are measured in the same
  position.

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

Every figure below was taken on **2026-09-20**, on one machine, from the tree
at `b1cbbb0`. Nothing here is carried over from an earlier session: a number
that is not in this file was not measured today.

**The machine.** An Intel Core i5-8250U with 8 CPUs at 1.60 GHz, Ubuntu 26.04.1,
kernel 7.0.0, nothing else running and no builds or tests alongside. Swift
6.3.3, rustc through cargo 1.98.1, OpenJDK 25.0.4, OpenSSL 3.5. zrk 2.5.0 and
oha 1.16.0 share the machine with the server, which is what the caveat above
about the load generator means: these are figures from one box, not from a
pair.

**The servers.** Garuda at `b1cbbb0` with 8 workers; axum 0.8.9 and actix-web
4.15.0 on Tokio 1.53.1; Vert.x 5.1.7 on Netty's epoll transport; Hummingbird
2.26.0 and Vapor 4.122.1 on SwiftNIO 2.102.0. Every one but Garuda sizes its
threads from the CPU count, which here is 8, so Garuda was given 8 workers to
match.

### Hello world: six servers

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

### Requests that do work, against axum

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

### The same over HTTPS

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
| user | 115,293 (1.52; 34) | 106,851 (1.47; 34) | **109,530** (1.50; 29) |
| json | 94,273 (2.19; 47) | 94,630 (1.93; 45) | **95,542** (1.90; 38) |
| db | 35,663 (3.46; 107) | 38,606 (3.22; 96) | **39,800** (2.83; 81) |
| stream | 14,659 (7.44; 245) | **15,154** (6.91; 227) | 10,213 (42.0; 122) |
| me | 92,034 (2.29; 51) | 91,485 (2.20; 50) | **101,948** (1.96; 35) |
| upload | 2,127 (58.7; 1,811) | **2,205** (63.1; 1,733) | 1,332 (116; 3,443) |
| download | 1,705 (75.0; 2,327) | 1,668 (56.8; 2,026) | **1,800** (49.6; 1,799) |
| relay | 8,013 (14.4; 562) | **8,830** (13.2; 490) | 3,171 (44.8; 638) |
| churn | 4,834 (26.9; 1,017) | **6,783** (15.8; 582) | 5,896 (16.8; 577) |
| h2 | 82,320 (1.52; 45) | 79,333 (1.66; 41) | **89,575** (1.76; 36) |
| overload | 28,777 (65.9; 134) | 30,672 (52.2; 119) | **32,649** (39.0; 101) |
| recovery | 111,005 (1.57; 35) | 116,306 (1.44; 31) | **116,424** (1.46; 27) |
| skew | 47,066 (4.58; 105) | 51,135 (3.33; 85) | **51,328** (3.17; 70) |
| spike | 56,370 (4.20; 84) | 62,279 (3.21; 68) | **62,676** (2.99; 56) |

Measured this way Garuda leads four of fourteen over HTTPS on BoringSSL, and
is within about a percent of axum on `json`, `recovery`, `skew` and `spike`
where the old table showed a wider gap in either direction. The honest
summary is that over TLS the two are close on most small-request workloads,
Garuda is well ahead where it streams or relays, and axum is ahead on `me`
and `h2`.

**BoringSSL against OpenSSL, the same tree otherwise.** The record layer and
handshake compiled against each (`AVIAN_TLS_BORINGSSL`; the libraries live in
one binary because swift-nio-ssl's copy carries a `CNIOBoringSSL` symbol
prefix, so ACME and JWT keep OpenSSL). **CPU a request falls on thirteen of
the fourteen and rises on none**, which is a steadier signal than throughput
on a box whose absolute level drifts:

| | throughput | CPU a request |
|---|---|---|
| churn | **+40.3%** | 1,017 -> **582 us** |
| spike | +10.5% | 84 -> 68 |
| relay | +10.2% | 562 -> 490 |
| skew | +8.6% | 105 -> 85 |
| db | +8.3% | 107 -> 96 |
| overload | +6.6% | 134 -> 119 |
| recovery | +4.8% | 35 -> 31 |
| h2 | -3.6% | 45 -> 41 |
| user | -7.3% | 34 -> 34 |

`churn` is a handshake a request, and it is the one that moves most, exactly
as the library probe above predicted: 40.5% cheaper a handshake there, 40.3%
more throughput here. Two measurements of different things agreeing is the
reason to believe either.

**Why `user` and `h2` go the other way, and it is not the cryptography.**
Both use *less* CPU on BoringSSL and still read lower, which is the signature
of an extra syscall rather than extra work. aviancore 0.6.6 asked OpenSSL to
read what the socket has in one call instead of a record's 5-byte header and
then its body in two. BoringSSL lists `SSL_CTX_set_read_ahead` among its
no-ops -- its header says the function "returns one", and that is all it does
-- so the request is silently ignored. Counted off the worker while it
served `/user/12345`:

| | read syscalls | requests | reads a request |
|---|---|---|---|
| OpenSSL | 256,092 | 255,802 | **1.00** |
| BoringSSL | 635,988 | 317,690 | **2.00** |

Exactly one against exactly two. So the keep-alive figures above are what
BoringSSL gives *while paying an extra read per request*, and a greedy BIO
that restores read-ahead should recover that ground. Until that is written
and measured, the `user` and `h2` rows stand as they are.

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

**kernel TLS is not worth switching on here.** The same sweep with
`--ktls`: every one of the fourteen workloads slower, by 2 to 9% -- `user`
120,473, `json` 98,451, `download` 1,532, `skew` 45,716 -- while axum's rows
moved under 1%, so the box was steady. This machine has no NIC TLS offload,
so software kTLS buys a copy and pays for setting it up, and the connection
migration it allows does not cover that. It stays off by default, which is
what `--ktls` already documents.

### What the TLS library itself costs

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
