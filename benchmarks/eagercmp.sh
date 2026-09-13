#!/usr/bin/env bash
# Two peregrine extension builds on the same app: server CPU per request and
# p50/p99 under closed-loop oha at several connection counts, and system calls
# per request under strace at 64, so a change's per-request cost can be told
# from a change in how requests batch.
#
#   BUILD_A=/mnt/d/code/peregrine-turbo-a BUILD_B=/mnt/d/code/peregrine-eager \
#       APPS="asgi fastapi" CONNS="1 8 64" bash benchmarks/eagercmp.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV=$HOME/pgvenv
BUILD_A=${BUILD_A:?}
BUILD_B=${BUILD_B:?}
APPS=${APPS:-"asgi fastapi"}
CONNS=${CONNS:-"1 8 64"}
SECS=${SECS:-8}
N=${N:-60000}
TRACE=${TRACE:-1}
PORT=${PORT:-8216}
OUT=${OUT:-$HOME/eagercmp}
SERVER_CPUS=${SERVER_CPUS:-0}
LOAD_CPUS=${LOAD_CPUS:-1-3}
URL="http://127.0.0.1:$PORT/"
mkdir -p "$OUT"
. "$ROOT/scripts/serverlib.sh"
trap 'server_stop; exit 130' INT TERM
server_require_port_free "$PORT" || exit 1

target() {
    case $1 in
    asgi) echo asgi:app ;;
    fastapi) echo fastapi_app:app ;;
    esac
}

start() {
    local build=$1 app=$2 traced=$3 tag=$4
    local pre=()
    [ "$traced" = 1 ] && pre=(strace -f -c -o "$OUT/$tag.strace")
    PYTHONPATH="$build/python:$ROOT/benchmarks/contract" server_start \
        taskset -c "$SERVER_CPUS" "${pre[@]}" \
        "$VENV/bin/python" -m peregrine --host 127.0.0.1 --port "$PORT" \
        --workers 1 --log-level error --venv "$VENV" \
        --python-path "$ROOT/benchmarks/contract" "$(target "$app")" \
        > "$OUT/$tag.log" 2>&1
    for _ in $(seq 1 120); do
        if curl -s -o /dev/null --max-time 1 "$URL"; then return 0; fi
        sleep 0.25
    done
    echo "$tag: the server did not start" >&2
    tail -5 "$OUT/$tag.log" >&2
    server_stop
    return 1
}

cpu_ns() {
    local total=0 p t v
    for p in $1; do
        for t in /proc/"$p"/task/*/schedstat; do
            [ -r "$t" ] || continue
            v=$(cut -d' ' -f1 "$t" 2>/dev/null) || continue
            total=$(( total + v ))
        done
    done
    echo "$total"
}

cpu_run() {
    local side=$1 build=$2 app=$3 conns=$4
    local tag="$side-$app-c$conns"
    start "$build" "$app" 0 "$tag" || return 1
    taskset -c "$LOAD_CPUS" oha -z 2s -c "$conns" --no-tui "$URL" > /dev/null 2>&1
    local tree before after
    tree=$(server_descendants "$SERVER_PID")
    before=$(cpu_ns "$tree")
    taskset -c "$LOAD_CPUS" oha -z "${SECS}s" -c "$conns" --no-tui \
        --output-format json -o "$OUT/$tag.oha.json" "$URL" > /dev/null 2>&1
    after=$(cpu_ns "$tree")
    server_stop
    python3 - "$OUT/$tag.oha.json" "$before" "$after" "$tag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
reqs = sum(int(v) for v in (d.get("statusCodeDistribution") or {}).values())
ns = int(sys.argv[3]) - int(sys.argv[2])
p = d["latencyPercentiles"]
print(f"{sys.argv[4]:<22} {d['summary']['requestsPerSec']:9.0f} req/s  "
      f"{ns / max(reqs, 1) / 1000:6.2f} us/req  "
      f"p50 {p['p50']*1000:6.3f}  p90 {p['p90']*1000:6.3f}  p99 {p['p99']*1000:6.3f} ms")
PY
}

trace_run() {
    local side=$1 build=$2 app=$3 conns=$4
    local idle="$side-$app-idle" tag="$side-$app-t$conns"
    start "$build" "$app" 1 "$idle" || return 1
    server_stop
    start "$build" "$app" 1 "$tag" || return 1
    taskset -c "$LOAD_CPUS" oha -n "$N" -c "$conns" --no-tui \
        --output-format json -o "$OUT/$tag.oha.json" "$URL" > /dev/null 2>&1
    server_stop
    python3 - "$OUT/$idle.strace" "$OUT/$tag.strace" "$OUT/$tag.oha.json" "$tag" <<'PY'
import json, sys
def calls(path):
    out = {}
    for line in open(path):
        f = line.split()
        if len(f) < 5 or f[-1] == "total":
            continue
        try:
            float(f[0]); out[f[-1]] = int(f[3])
        except ValueError:
            continue
    return out
idle, load = calls(sys.argv[1]), calls(sys.argv[2])
d = json.load(open(sys.argv[3]))
reqs = sum(int(v) for v in (d.get("statusCodeDistribution") or {}).values())
rows = []
for k in set(idle) | set(load):
    extra = load.get(k, 0) - idle.get(k, 0)
    if extra > 0:
        rows.append((extra / max(reqs, 1), k))
rows.sort(reverse=True)
parts = "  ".join(f"{k} {per:.3f}" for per, k in rows if per >= 0.005)
print(f"{sys.argv[4]:<22} {reqs} requests under strace: {parts}  total {sum(r[0] for r in rows):.3f}")
PY
}

for app in $APPS; do
    for conns in $CONNS; do
        for side in A B A B; do
            build=$BUILD_A; [ "$side" = B ] && build=$BUILD_B
            cpu_run "$side" "$build" "$app" "$conns"
        done
    done
    if [ "$TRACE" = 1 ]; then
        trace_run A "$BUILD_A" "$app" 64
        trace_run B "$BUILD_B" "$app" 64
    fi
done
