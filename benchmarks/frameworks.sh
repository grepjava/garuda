#!/usr/bin/env bash
# garuda, the-benchmarker/web-frameworks' axum, actix, Vert.x, Hummingbird and
# Vapor entries, and Elysia on Bun as a reference, under the load command of that suite at
# 4bb9eaa (develop, 2026-09-13). The results are not comparable with the
# figures that site publishes; BENCHMARKS.md says why.
#
#   bash benchmarks/frameworks.sh > results.tsv
#   FRAMEWORKS="swift rust" SERVERS="garuda axum" WORKERS=4 AGG=mean bash benchmarks/frameworks.sh
#   FRAMEWORKS="swift rust java" SERVERS="garuda axum actix vertx" WORKERS=8 AGG=mean bash benchmarks/frameworks.sh
#   FRAMEWORKS=swift SERVERS="garuda hummingbird vapor" WORKERS=4 AGG=mean bash benchmarks/frameworks.sh
#   LOAD=closed PIN=0:1-3 FRAMEWORKS=elysia SERVERS=elysia-bun bash benchmarks/frameworks.sh
#
# The load is the upstream collect command, flag for flag (.tasks/config.rake
# line 149 at that revision; the --closed in the comment above it is not in the
# command):
#
#   warm-up    zrk -c 50 -d 5s --plain URL
#   per level  zrk --plain -c N -d 15s -m GET --format json -R1000:500000
#                  --interval 1s --timeout 8s --latency URL
#
# That is an open-loop ramp from 1,000 to 500,000 requests a second over the
# run (RATE), keep-alive on, latency corrected for coordinated omission, and the
# figure reported is zrk's achieved_rate -- the number the results site
# ranks by.
#
# LOAD=closed replaces the ramp with closed-loop oha, `oha -c N -z DURATION`,
# which measures capacity instead. The ramp offers its average rate at most,
# so a server that keeps up with it shows that ceiling and nothing more.
# PIN="0:1-3" runs the server on CPU 0 and the load generator on CPUs 1-3, so
# the two do not take turns on a core; it applies to either load. SwiftNIO
# sizes its event loops from the CPU count, not the affinity mask, so a pinned
# Hummingbird or Vapor runs one loop per CPU on the one core it is given. Tokio
# sizes its runtime from std::thread::available_parallelism, which reads the
# affinity mask, so a pinned axum runs one worker thread.
#
# Differences from upstream; BENCHMARKS.md lists them all:
#   WORKERS=1  upstream starts every server with $(nproc) workers. WORKERS is
#              garuda's, Elysia's and Vert.x's (-instances); Hummingbird and
#              Vapor are one process with SwiftNIO's default of an event loop
#              per CPU, axum one process with Tokio's default of a worker
#              thread per CPU, and actix one process with its default of a
#              worker per CPU.
#   RUNS=3     upstream's published figures are means of three runs. Each level
#              here runs three times and, by default, the median by
#              achieved_rate is kept (AGG=mean for upstream's way).
#
# Output, one TSV line per cell:
#   framework server workers connections req/s p50_ms p75_ms p90_ms p99_ms errors [every run]
#
# Needs zrk >= 2.4 (github.com/zoxy-io/zrk), or oha for LOAD=closed, python3
# to read their JSON, and whichever servers are asked for.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GARUDA=${GARUDA:-$ROOT/.build/release/garuda}
# The suite's swift/hummingbird-framework and swift/vapor-framework entries,
# built as its Dockerfile builds them:
#   swift build -c release -Xswiftc -enforce-exclusivity=unchecked
HUMMINGBIRD=${HUMMINGBIRD:-$HOME/swiftbench/hummingbird-framework/.build/release/server}
VAPOR=${VAPOR:-$HOME/swiftbench/vapor-framework/.build/release/server}
# The suite's rust/axum entry (benchmarks/axum/, byte for byte), built as
# rust/Dockerfile builds it; built on first use when AXUM is not given.
AXUM=${AXUM:-$ROOT/benchmarks/axum/target/release/server}
# The suite's rust/actix entry (benchmarks/actix/), built the same way.
ACTIX=${ACTIX:-$ROOT/benchmarks/actix/target/release/server}
# The suite's java/vertx entry (benchmarks/vertx/), built with `mvn package`
# and run as java/vertx/config.yaml runs it, on the JDK that JAVA names.
VERTX=${VERTX:-$ROOT/benchmarks/vertx/target/server.jar}
JAVA=${JAVA:-java}
MVN=${MVN:-mvn}
CARGO=${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}
ZRK=${ZRK:-zrk}
OHA=${OHA:-oha}
LOAD=${LOAD:-ramp}
PORT=${PORT:-3000}
WORKERS=${WORKERS:-1}
CONNS=${CONNS:-"64 256 512"}
RUNS=${RUNS:-3}
# How the runs at a level become one figure: median, the run with the median
# achieved_rate, or mean, every column averaged and errors summed, which is how
# upstream publishes.
AGG=${AGG:-median}
DURATION=${DURATION:-15s}
# The warm-up before the first level; upstream runs 5s.
WARMUP=${WARMUP:-5s}
# zrk's open-loop ramp, requests a second from start to end of a run. Upstream
# raised the end from 100,000 to 500,000 at 4bb9eaa; the old figure capped a
# run at about 96,500 req/s.
RATE=${RATE:-1000:500000}
# swift: garuda, hummingbird and vapor answer the contract natively.
# rust: axum and actix, which listen on 0.0.0.0:3000 themselves, so PORT must
# be 3000.
# java: vertx, which listens on 3000 itself, so PORT must be 3000.
# elysia: upstream's javascript/elysia-bun (benchmarks/elysia-bun/, byte for
# byte), which listens on 3000 itself, so PORT must be 3000. Needs bun on PATH
# or in ~/.bun.
FRAMEWORKS=${FRAMEWORKS:-swift}
SERVERS=${SERVERS:-"garuda hummingbird vapor"}
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
# "server_cpus:load_cpus" for taskset, e.g. 0:1-3; empty runs both unpinned.
PIN=${PIN:-}
PIN_SERVER=()
PIN_LOAD=()
if [ -n "$PIN" ]; then
    PIN_SERVER=(taskset -c "${PIN%%:*}")
    PIN_LOAD=(taskset -c "${PIN#*:}")
fi
# Extra flags for garuda, e.g. "--access-log".
# shellcheck disable=SC2206 -- deliberately split into words.
GARUDA_ARGS=(${GARUDA_EXTRA_ARGS:-})
URL="http://127.0.0.1:$PORT/"
OUT=$(mktemp -d)

# Only the server this script started is stopped, and as a process group, so
# the workers it forked go with it and no unrelated server is touched.
# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
server_trap_cleanup
server_require_port_free "$PORT" || exit 1

start() {
    local server=$1 framework=$2
    case "$server" in
    garuda)
        # The router answers the contract itself.
        server_start "${PIN_SERVER[@]}" "$GARUDA" --log-level error \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "${GARUDA_ARGS[@]}" ;;
    hummingbird)
        # The suite's config.yaml passes host and port through the environment.
        SERVER_HOSTNAME=127.0.0.1 SERVER_PORT=$PORT server_start "${PIN_SERVER[@]}" "$HUMMINGBIRD" ;;
    vapor)
        SERVER_HOSTNAME=127.0.0.1 SERVER_PORT=$PORT VAPOR_ENV=production \
            server_start "${PIN_SERVER[@]}" "$VAPOR" serve ;;
    axum|actix)
        [ "$PORT" = 3000 ] || { echo "$server listens on 3000; PORT=$PORT"; return 1; }
        local binary=$AXUM
        [ "$server" = actix ] && binary=$ACTIX
        if [ ! -x "$binary" ]; then
            # rust/Dockerfile's build command; the profile repeats Cargo.toml's.
            (cd "$ROOT/benchmarks/$server" && "$CARGO" build --release \
                --config 'profile.release.lto=true' \
                --config 'profile.release.panic="abort"' \
                --config 'profile.release.codegen-units=1') || return 1
        fi
        server_start "${PIN_SERVER[@]}" "$binary" ;;
    vertx)
        [ "$PORT" = 3000 ] || { echo "vertx listens on 3000; PORT=$PORT"; return 1; }
        if [ ! -f "$VERTX" ]; then
            (cd "$ROOT/benchmarks/vertx" && "$MVN" -q package) || return 1
        fi
        # Upstream passes -instances $(nproc): one verticle per event loop.
        server_start "${PIN_SERVER[@]}" "$JAVA" -jar "$VERTX" -instances "$WORKERS" ;;
    elysia-bun)
        # Upstream runs cluster.ts, which spawns one `bun ./app.ts` per CPU.
        # One worker is app.ts itself; cluster.ts only when WORKERS is every CPU.
        [ "$PORT" = 3000 ] || { echo "elysia-bun listens on 3000; PORT=$PORT"; return 1; }
        # server_start runs here, not in a subshell, so SERVER_PID survives.
        cd "$ROOT/benchmarks/elysia-bun" || return 1
        [ -d node_modules/elysia ] || "$BUN" install --production || { cd "$ROOT"; return 1; }
        if [ "$WORKERS" = 1 ]; then
            NODE_ENV=production server_start "${PIN_SERVER[@]}" "$BUN" ./app.ts
        else
            NODE_ENV=production PATH="$(dirname "$BUN"):$PATH" server_start "${PIN_SERVER[@]}" "$BUN" run cluster.ts
        fi
        cd "$ROOT" ;;
    *)
        echo "unknown server $server"
        return 1 ;;
    esac > "$OUT/$server-$framework.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$URL" && return 0
        sleep 0.25
    done
    return 1
}

warm_up() {
    if [ "$LOAD" = closed ]; then
        "${PIN_LOAD[@]}" "$OHA" -z "$WARMUP" -c 50 --no-tui "$URL" > /dev/null 2>&1
    else
        "${PIN_LOAD[@]}" "$ZRK" -c 50 -d "$WARMUP" --plain "$URL" > /dev/null 2>&1
    fi
}

# One run at $1 connections: "req/s p50 p75 p90 p99 errors", latencies in ms.
one_run() {
    local json="$OUT/run.json"
    rm -f "$json"
    if [ "$LOAD" = closed ]; then
        "${PIN_LOAD[@]}" "$OHA" -z "$DURATION" -c "$1" --no-tui --output-format json \
            -o "$json" "$URL" > /dev/null 2>&1
        python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0 0 -1")
    raise SystemExit
pct = d.get("latencyPercentiles") or {}
codes = d.get("statusCodeDistribution") or {}
errors = sum(int(v) for k, v in codes.items() if not k.startswith("2"))
# oha stops a timed run with one request in flight per connection and counts
# those as "aborted due to deadline"; they are the run ending, not the server.
errors += sum(int(v) for k, v in (d.get("errorDistribution") or {}).items()
              if k != "aborted due to deadline")
ms = lambda key: (pct.get(key) or 0) * 1000.0
print("%.0f %.3f %.3f %.3f %.3f %d" % (d["summary"]["requestsPerSec"], ms("p50"), ms("p75"),
                                       ms("p90"), ms("p99"), errors))
PY
        return
    fi
    "${PIN_LOAD[@]}" "$ZRK" --plain -c "$1" -d "$DURATION" -m GET --format json --output "$json" \
        -R"$RATE" --interval 1s --timeout 8s --latency "$URL" > /dev/null 2>&1
    python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0 0 -1")
    raise SystemExit
lat = d.get("latency_us") or {}
errors = sum(int(v or 0) for v in (d.get("errors") or {}).values())
ms = lambda key: (lat.get(key) or 0) / 1000.0
print("%.0f %.3f %.3f %.3f %.3f %d" % (d.get("achieved_rate") or 0, ms("p50"), ms("p75"),
                                       ms("p90"), ms("p99"), errors))
PY
}

printf 'framework\tserver\tworkers\tconnections\treq/s p50_ms p75_ms p90_ms p99_ms errors\truns\n'
for framework in $FRAMEWORKS; do
    for server in $SERVERS; do
        # Each framework pairs only with its own servers.
        case "$framework:$server" in
        swift:garuda|swift:hummingbird|swift:vapor|rust:axum|rust:actix|java:vertx|elysia:elysia-bun) ;;
        *) continue ;;
        esac
        server_stop
        if ! start "$server" "$framework"; then
            printf '%s\t%s\t%s\tFAILED TO START\n' "$framework" "$server" "$WORKERS"
            tail -5 "$OUT/$server-$framework.log"
            continue
        fi
        warm_up
        for c in $CONNS; do
            runs=""
            for _ in $(seq 1 "$RUNS"); do
                runs="$runs$(one_run "$c")"$'\n'
            done
            if [ "$AGG" = mean ]; then
                figure=$(printf '%s' "$runs" | grep -v '^$' | awk '
                    { for (i = 1; i <= 5; i++) s[i] += $i; e += $6; n++ }
                    END { printf "%.0f %.3f %.3f %.3f %.3f %d", s[1]/n, s[2]/n, s[3]/n, s[4]/n, s[5]/n, e }')
            else
                figure=$(printf '%s' "$runs" | grep -v '^$' | sort -n -k1,1 \
                    | sed -n "$(( (RUNS + 1) / 2 ))p")
            fi
            all=$(printf '%s' "$runs" | grep -v '^$' | awk '{printf "%s ", $1}')
            printf '%s\t%s\t%s\t%s\t%s\t[%s]\n' "$framework" "$server" "$WORKERS" "$c" \
                "$figure" "$all"
        done
    done
done
server_stop
rm -rf "$OUT"
