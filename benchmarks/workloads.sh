#!/usr/bin/env bash
# Garuda and axum on requests that do work: closed-loop oha at 64 connections
# for 5 s a workload, one run each, about three minutes in all. The same
# requests, answered with the same bytes by two applications written the way
# each framework's own documentation writes them:
#
#   user      GET  /user/12345   a path parameter, answered as text
#   json      POST /json         a 60-byte JSON body decoded, and a Receipt encoded
#   db        GET  /db/517       one row from PostgreSQL by primary key, as JSON
#   stream    GET  /stream       64 KiB streamed as 16 chunks of 4 KiB
#   me        GET  /me           an HS256 bearer token verified, its subject answered
#   upload    POST /upload       a 1 MiB body read whole, its length answered
#   download  GET  /download     1 MiB answered from memory
#   relay     GET  /relay        an origin's /stream fetched and streamed on as it arrives
#   churn     GET  /user/12345   a new connection for every request
#   h2        GET  /user/12345   over prior-knowledge HTTP/2
#   overload  GET  /db/517       at 16 times the connections, the pool far short of them;
#             then /user/12345 at the usual 64, to see the server come back
#   skew      GET  /user/12345   on 56 connections while 8 more ask for /spin, which
#             holds the CPU for about 2 ms a request: what the quick requests
#             pay for sharing a server with slow ones (cpu counts both)
#   spike     the same, but the slow requests start a second into the run, on
#             workers that already hold quick connections
#
# SERVERS names what runs: garuda, axum, and garuda:MODE for Garuda under
# --balance MODE (garuda:adaptive, garuda:accept, garuda:reuseport).
#
# benchmarks/workloads/garuda-app is the Garuda side and
# benchmarks/workloads/axum the axum side. Garuda runs WORKERS workers, one
# per CPU unless told otherwise, the number of threads Tokio runs by default.
# The database gets POOL_TOTAL connections either way: one pool of them for
# axum, and an equal share of them in each Garuda worker's own pool. The
# relay's origin is the Garuda application on ORIGIN_PORT, the same origin for
# both, so what differs is the relaying.
#
# Each line gives requests a second; p50, p95 and p99 in milliseconds; the
# server's CPU time per request, user and system, in microseconds, which says
# what a figure cost where requests a second alone does not; the server's
# memory after the run; and the requests that failed.
#
#   (cd benchmarks/workloads/garuda-app && swift build -c release)
#   createdb bench      # once; the script makes and fills the table
#   bash benchmarks/workloads.sh
#   WORKLOADS="user db" DURATION=10s bash benchmarks/workloads.sh
#   GARUDA_FLAGS="--sched-slice 0" bash benchmarks/workloads.sh   # more flags for Garuda
#
# Needs oha, python3, curl, psql, cargo for the first axum build, a PostgreSQL
# that DATABASE_URL reaches, Linux's /proc, and ports 3000 and 3001.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GARUDA_APP=${GARUDA_APP:-$ROOT/benchmarks/workloads/garuda-app/.build/release/workloads}
AXUM_APP=${AXUM_APP:-$ROOT/benchmarks/workloads/axum/target/release/workloads}
CARGO=${CARGO:-$(command -v cargo || echo "$HOME/.cargo/bin/cargo")}
OHA=${OHA:-oha}
PSQL=${PSQL:-psql}
DATABASE_URL=${DATABASE_URL:-postgres://garuda:garuda-secret@127.0.0.1:5432/bench?sslmode=disable}
WORKERS=${WORKERS:-$(nproc)}
POOL_TOTAL=${POOL_TOTAL:-32}
POOL_SIZE=$(( (POOL_TOTAL + WORKERS - 1) / WORKERS ))
CONNS=${CONNS:-64}
DURATION=${DURATION:-5s}
WARMUP=${WARMUP:-1s}
WORKLOADS=${WORKLOADS:-"user json db stream me upload download relay churn h2 overload"}
SERVERS=${SERVERS:-"garuda axum"}
SKEW_CONNS=${SKEW_CONNS:-8}
SPIN=${SPIN:-2000000}
ORIGIN_PORT=${ORIGIN_PORT:-3001}
ORIGIN_WORKERS=${ORIGIN_WORKERS:-2}
# "server_cpus:load_cpus" for taskset, as in frameworks.sh; empty runs both
# unpinned. The relay's origin runs with the load.
PIN=${PIN:-}
PIN_SERVER=()
PIN_LOAD=()
if [ -n "$PIN" ]; then
    PIN_SERVER=(taskset -c "${PIN%%:*}")
    PIN_LOAD=(taskset -c "${PIN#*:}")
fi
PORT=3000
BASE="http://127.0.0.1:$PORT"
ORDER='{"id":42,"name":"garuda","tags":["fast","small","swift"]}'
OUT=$(mktemp -d)
began=$(date +%s)

# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
server_require_port_free "$PORT" || exit 1

# The relay's origin, kept apart from the server under test.
ORIGIN_PID=""
stop_all() {
    server_stop
    if [ -n "$ORIGIN_PID" ]; then
        SERVER_PID=$ORIGIN_PID
        ORIGIN_PID=""
        server_stop
    fi
}
trap 'stop_all; exit 130' INT TERM
trap 'stop_all; rm -rf "$OUT"' EXIT

# The table both applications read: 1,000 rows, made once.
"$PSQL" -q -v ON_ERROR_STOP=1 "$DATABASE_URL" > "$OUT/psql.log" 2>&1 <<'SQL' || {
create table if not exists bench_items (id integer primary key, name text not null, price integer not null);
insert into bench_items select n, 'item ' || n, n * 7 % 1000 from generate_series(1, 1000) n
    on conflict (id) do nothing;
SQL
    echo "workloads: cannot set up the table at $DATABASE_URL:"
    cat "$OUT/psql.log"
    exit 1
}

# A token both applications accept: HS256 over the secret they share, for
# subject 42, expiring in 2100.
TOKEN=$(python3 - <<'PY'
import base64, hashlib, hmac, json
def part(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()
def claims(value):
    return part(json.dumps(value, separators=(",", ":")).encode())
signed = claims({"alg": "HS256", "typ": "JWT"}) + "." + claims({"sub": "42", "exp": 4102444800})
mac = hmac.new(b"workloads-benchmark-secret-0123456789abcdef", signed.encode(), hashlib.sha256)
print(signed + "." + part(mac.digest()))
PY
)
head -c 1048576 /dev/zero | tr '\0' 'u' > "$OUT/upload.bin"

start() {
    case "$1" in
    garuda|garuda:*)
        local balance=()
        case "$1" in garuda:*) balance=(--balance "${1#garuda:}") ;; esac
        DATABASE_URL=$DATABASE_URL POOL_SIZE=$POOL_SIZE ORIGIN_URL="http://127.0.0.1:$ORIGIN_PORT/stream" \
            server_start "${PIN_SERVER[@]}" "$GARUDA_APP" \
            --log-level error --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "${balance[@]}"             ${GARUDA_FLAGS:-} ;;
    axum)
        if [ ! -x "$AXUM_APP" ]; then
            (cd "$ROOT/benchmarks/workloads/axum" && "$CARGO" build --release) > "$OUT/cargo.log" 2>&1 \
                || { tail -20 "$OUT/cargo.log"; return 1; }
        fi
        DATABASE_URL=$DATABASE_URL POOL_SIZE=$((WORKERS * POOL_SIZE)) \
            ORIGIN_URL="http://127.0.0.1:$ORIGIN_PORT/stream" \
            server_start "${PIN_SERVER[@]}" "$AXUM_APP" ;;
    esac > "$OUT/$1.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$BASE/user/1" && return 0
        sleep 0.25
    done
    return 1
}

start_origin() {
    server_require_port_free "$ORIGIN_PORT" || return 1
    DATABASE_URL=$DATABASE_URL POOL_SIZE=1 server_start "${PIN_LOAD[@]}" "$GARUDA_APP" \
        --log-level error --host 127.0.0.1 --port "$ORIGIN_PORT" --workers "$ORIGIN_WORKERS" \
        > "$OUT/origin.log" 2>&1
    ORIGIN_PID=$SERVER_PID
    SERVER_PID=""
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$ORIGIN_PORT/user/1" && return 0
        sleep 0.25
    done
    return 1
}

# The oha arguments for a workload, one to a line.
request() {
    case "$1" in
    user|skew|spike) printf '%s\n' "$BASE/user/12345" ;;
    json) printf '%s\n' -m POST -T application/json -d "$ORDER" "$BASE/json" ;;
    db|overload) printf '%s\n' "$BASE/db/517" ;;
    stream) printf '%s\n' "$BASE/stream" ;;
    me) printf '%s\n' -H "Authorization: Bearer $TOKEN" "$BASE/me" ;;
    upload) printf '%s\n' -m POST -T application/octet-stream -D "$OUT/upload.bin" "$BASE/upload" ;;
    download) printf '%s\n' "$BASE/download" ;;
    relay) printf '%s\n' "$BASE/relay" ;;
    churn) printf '%s\n' --disable-keepalive "$BASE/user/12345" ;;
    h2) printf '%s\n' --http2 "$BASE/user/12345" ;;
    esac
}

# What each workload must answer, checked before it is measured, so a server
# that answers fast and wrong reads as FAILED rather than as a figure.
check() {
    local body
    case "$1" in
    user|churn) body=$(curl -s --max-time 2 "$BASE/user/12345"); [ "$body" = 12345 ] ;;
    skew|spike) body=$(curl -s --max-time 2 "$BASE/spin/1000"); [ "$body" = 10097022301462541763 ] ;;
    json) body=$(curl -s --max-time 2 -H 'content-type: application/json' -d "$ORDER" "$BASE/json")
          [ "$body" = '{"id":42,"name":"garuda","tags":["fast","small","swift"],"count":3}' ] ;;
    db|overload) body=$(curl -s --max-time 2 "$BASE/db/517"); [ "$body" = '{"id":517,"name":"item 517","price":619}' ] ;;
    stream) body=$(curl -s --max-time 2 "$BASE/stream" | wc -c); [ "$body" -eq 65536 ] ;;
    me) body=$(curl -s --max-time 2 -H "Authorization: Bearer $TOKEN" "$BASE/me"); [ "$body" = "user 42" ] ;;
    upload) body=$(curl -s --max-time 5 -H 'content-type: application/octet-stream' \
                   --data-binary "@$OUT/upload.bin" "$BASE/upload"); [ "$body" = 1048576 ] ;;
    download) body=$(curl -s --max-time 5 "$BASE/download" | wc -c); [ "$body" -eq 1048576 ] ;;
    relay) body=$(curl -s --max-time 5 "$BASE/relay" | wc -c); [ "$body" -eq 65536 ] ;;
    h2) body=$(curl -s --max-time 2 --http2-prior-knowledge "$BASE/user/12345"); [ "$body" = 12345 ] ;;
    esac || { echo "$body" | head -c 200; echo; return 1; }
}

# CPU the server has used, user and system, in clock ticks: every process it
# runs, which for Garuda is a supervisor and its workers.
cpu_ticks() {
    local total=0 p t
    for p in $(server_descendants "$SERVER_PID"); do
        t=$(awk '{ print $14 + $15 }' "/proc/$p/stat" 2>/dev/null) || continue
        total=$((total + ${t:-0}))
    done
    echo "$total"
}

# The server's memory, in KiB, over all its processes: proportional set size,
# which counts a page shared by several processes -- the Swift runtime, libssl
# -- as a share in each, rather than whole in every one of them as the
# resident set does. A server of eight processes is not charged eight times
# for its libraries.
mem_kib() {
    local total=0 p kb
    for p in $(server_descendants "$SERVER_PID"); do
        kb=$(awk '/^Pss:/ { print $2 }' "/proc/$p/smaps_rollup" 2>/dev/null) || continue
        total=$((total + ${kb:-0}))
    done
    echo "$total"
}

# One closed-loop run, as "req/s p50 p95 p99 cpu-us/req mem-MiB errors".
measure() {
    local workload=$1 duration=$2 conns=$3 json="$OUT/run.json"
    local args before after
    mapfile -t args < <(request "$workload")
    rm -f "$json"
    before=$(cpu_ticks)
    "${PIN_LOAD[@]}" "$OHA" -z "$duration" -c "$conns" --no-tui --output-format json \
        -o "$json" "${args[@]}" > /dev/null 2>&1
    after=$(cpu_ticks)
    python3 - "$json" "$((after - before))" "$(getconf CLK_TCK)" "$(mem_kib)" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0 0 0 -1")
    raise SystemExit
ticks, hz, mem = int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
pct = d.get("latencyPercentiles") or {}
codes = d.get("statusCodeDistribution") or {}
answered = sum(int(v) for v in codes.values())
errors = sum(int(v) for k, v in codes.items() if not k.startswith("2"))
# A timed run ends with a request in flight per connection; that is the run
# ending, not the server (frameworks.sh counts it the same way).
errors += sum(int(v) for k, v in (d.get("errorDistribution") or {}).items()
              if k != "aborted due to deadline")
ms = lambda key: (pct.get(key) or 0) * 1000.0
cpu = ticks / hz * 1e6 / answered if answered else 0
print("%.0f %.3f %.3f %.3f %.0f %.0f %d" % (d["summary"]["requestsPerSec"], ms("p50"), ms("p95"),
                                            ms("p99"), cpu, mem / 1024, errors))
PY
}

report() {
    awk -v w="$1" -v s="$2" '
        { printf "%-9s %-16s %9s req/s   p50 %8s   p95 %8s   p99 %9s ms   cpu %5s us/req   mem %5s MiB   errors %s\n",
                 w, s, $1, $2, $3, $4, $5, $6, $7
          fflush() }'
}

case " $WORKLOADS " in
*" relay "*)
    if ! start_origin; then
        echo "the relay's origin did not start:"
        tail -5 "$OUT/origin.log"
        exit 1
    fi ;;
esac

for server in $SERVERS; do
    server_stop
    if ! start "$server"; then
        echo "$server FAILED TO START"
        tail -5 "$OUT/$server.log"
        continue
    fi
    for workload in $WORKLOADS; do
        if ! check "$workload"; then
            printf '%-9s %-16s FAILED: the answer above is not the expected one\n' "$workload" "$server"
            continue
        fi
        if [ "$workload" = overload ]; then
            measure db "$WARMUP" "$CONNS" > /dev/null
            measure overload "$DURATION" $((CONNS * 16)) | report overload "$server"
            # Straight after, with nothing to settle: what a client arriving
            # once the surge has passed gets.
            measure user "$DURATION" "$CONNS" | report recovery "$server"
            continue
        fi
        if [ "$workload" = skew ]; then
            "${PIN_LOAD[@]}" "$OHA" -z 60s -c "$SKEW_CONNS" --no-tui "$BASE/spin/$SPIN" \
                > /dev/null 2>&1 &
            spinner=$!
            measure skew "$WARMUP" $((CONNS - SKEW_CONNS)) > /dev/null
            measure skew "$DURATION" $((CONNS - SKEW_CONNS)) | report skew "$server"
            kill "$spinner" 2>/dev/null
            wait "$spinner" 2>/dev/null
            continue
        fi
        if [ "$workload" = spike ]; then
            ( sleep 1; exec "${PIN_LOAD[@]}" "$OHA" -z 60s -c "$SKEW_CONNS" --no-tui \
                  "$BASE/spin/$SPIN" > /dev/null 2>&1 ) &
            spinner=$!
            measure spike "$DURATION" $((CONNS - SKEW_CONNS)) | report spike "$server"
            kill "$spinner" 2>/dev/null
            wait "$spinner" 2>/dev/null
            continue
        fi
        measure "$workload" "$WARMUP" "$CONNS" > /dev/null
        measure "$workload" "$DURATION" "$CONNS" | report "$workload" "$server"
    done
done
echo "$(($(date +%s) - began)) s"
