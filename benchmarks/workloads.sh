#!/usr/bin/env bash
# Garuda and axum on requests that do work, quickly: closed-loop oha at 64
# connections for 10 s a workload, one run each, under two minutes in all. The
# same four requests, answered with the same bytes by two applications written
# the way each framework's own documentation writes them:
#
#   user    GET  /user/12345   a path parameter, answered as text
#   json    POST /json         a 60-byte JSON body decoded, and a Receipt encoded
#   db      GET  /db/517       one row from PostgreSQL by primary key, as JSON
#   stream  GET  /stream       64 KiB streamed as 16 chunks of 4 KiB
#
# benchmarks/workloads/garuda-app is the Garuda side and
# benchmarks/workloads/axum the axum side. Garuda runs WORKERS workers, one
# per CPU unless told otherwise, the number of threads Tokio runs by default.
# The database gets POOL_TOTAL connections either way: one pool of them for
# axum, and an equal share of them in each Garuda worker's own pool.
#
#   (cd benchmarks/workloads/garuda-app && swift build -c release)
#   createdb bench      # once; the script makes and fills the table
#   bash benchmarks/workloads.sh
#
# Needs oha, python3, curl, psql, cargo for the first axum build, a PostgreSQL
# that DATABASE_URL reaches, and port 3000.
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
DURATION=${DURATION:-10s}
WARMUP=${WARMUP:-2s}
WORKLOADS=${WORKLOADS:-"user json db stream"}
SERVERS=${SERVERS:-"garuda axum"}
# "server_cpus:load_cpus" for taskset, as in frameworks.sh; empty runs both
# unpinned.
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
server_trap_cleanup
server_require_port_free "$PORT" || exit 1

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

start() {
    case "$1" in
    garuda)
        DATABASE_URL=$DATABASE_URL POOL_SIZE=$POOL_SIZE server_start "${PIN_SERVER[@]}" "$GARUDA_APP" \
            --log-level error --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" ;;
    axum)
        if [ ! -x "$AXUM_APP" ]; then
            (cd "$ROOT/benchmarks/workloads/axum" && "$CARGO" build --release) > "$OUT/cargo.log" 2>&1 \
                || { tail -20 "$OUT/cargo.log"; return 1; }
        fi
        DATABASE_URL=$DATABASE_URL POOL_SIZE=$((WORKERS * POOL_SIZE)) \
            server_start "${PIN_SERVER[@]}" "$AXUM_APP" ;;
    esac > "$OUT/$1.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$BASE/user/1" && return 0
        sleep 0.25
    done
    return 1
}

# The oha arguments for a workload.
request() {
    case "$1" in
    user) printf '%s\n' "$BASE/user/12345" ;;
    json) printf '%s\n' -m POST -T application/json -d "$ORDER" "$BASE/json" ;;
    db) printf '%s\n' "$BASE/db/517" ;;
    stream) printf '%s\n' "$BASE/stream" ;;
    esac
}

# What each workload must answer, checked before it is measured, so a server
# that answers fast and wrong reads as FAILED rather than as a figure.
check() {
    local body
    case "$1" in
    user) body=$(curl -s --max-time 2 "$BASE/user/12345"); [ "$body" = 12345 ] ;;
    json) body=$(curl -s --max-time 2 -H 'content-type: application/json' -d "$ORDER" "$BASE/json")
          [ "$body" = '{"id":42,"name":"garuda","tags":["fast","small","swift"],"count":3}' ] ;;
    db) body=$(curl -s --max-time 2 "$BASE/db/517"); [ "$body" = '{"id":517,"name":"item 517","price":619}' ] ;;
    stream) body=$(curl -s --max-time 2 "$BASE/stream" | wc -c); [ "$body" -eq 65536 ] ;;
    esac || { echo "$body" | head -c 200; echo; return 1; }
}

# One closed-loop run: "req/s p50 p99 errors", latencies in ms.
measure() {
    local workload=$1 duration=$2 json="$OUT/run.json"
    local args
    mapfile -t args < <(request "$workload")
    rm -f "$json"
    "${PIN_LOAD[@]}" "$OHA" -z "$duration" -c "$CONNS" --no-tui --output-format json \
        -o "$json" "${args[@]}" > /dev/null 2>&1
    python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 -1")
    raise SystemExit
pct = d.get("latencyPercentiles") or {}
codes = d.get("statusCodeDistribution") or {}
errors = sum(int(v) for k, v in codes.items() if not k.startswith("2"))
# A timed run ends with a request in flight per connection; that is the run
# ending, not the server (frameworks.sh counts it the same way).
errors += sum(int(v) for k, v in (d.get("errorDistribution") or {}).items()
              if k != "aborted due to deadline")
ms = lambda key: (pct.get(key) or 0) * 1000.0
print("%.0f %.3f %.3f %d" % (d["summary"]["requestsPerSec"], ms("p50"), ms("p99"), errors))
PY
}

for server in $SERVERS; do
    server_stop
    if ! start "$server"; then
        echo "$server FAILED TO START"
        tail -5 "$OUT/$server.log"
        continue
    fi
    for workload in $WORKLOADS; do
        if ! check "$workload"; then
            printf '%-7s %-7s FAILED: the answer above is not the expected one\n' "$workload" "$server"
            continue
        fi
        measure "$workload" "$WARMUP" > /dev/null
        measure "$workload" "$DURATION" | awk -v w="$workload" -v s="$server" '
            { printf "%-7s %-7s %9s req/s   p50 %8s ms   p99 %9s ms   errors %s\n", w, s, $1, $2, $3, $4
              fflush() }'
    done
done
server_stop
rm -rf "$OUT"
echo "$(($(date +%s) - began)) s"
