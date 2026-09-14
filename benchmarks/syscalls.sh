#!/usr/bin/env bash
# System calls per request for one Garuda worker, counted with strace.
#
#   bash benchmarks/syscalls.sh
#   RUNS="asgi:64 fastapi:256" N=200000 bash benchmarks/syscalls.sh
#
# Each run starts the server under `strace -f -c`, answers N requests from
# closed-loop oha at the given concurrency, and stops it. strace launches the
# server rather than attaching to it, because with yama ptrace_scope=1 a tracer
# only reaches its own descendants, so start-up and shutdown are counted too.
# A second run of the same application that answers a single request is
# subtracted from it, which leaves what the requests cost.
#
# strace makes every system call far slower, so a loaded worker collects more
# events per wait than it would untraced: the epoll figures at high
# concurrency are a floor. One connection shows the case with no batching at
# all. read, write and epoll_ctl per request do not depend on timing.
#
# BUILD is a checkout whose python/garuda holds a built _native
# (scripts/build-extension.sh). EXTRA adds server flags.
#
# Output, per run: system calls per request by name, then the total.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT}
VENV=${VENV:-$HOME/pgvenv}
OHA=${OHA:-oha}
PORT=${PORT:-8215}
N=${N:-100000}
RUNS=${RUNS:-"asgi:64 asgi:1 fastapi:64"}
SERVER_CPU=${SERVER_CPU:-0}
LOAD_CPUS=${LOAD_CPUS:-1-3}
EXTRA=${EXTRA:-}
URL="http://127.0.0.1:$PORT/"
OUT=$(mktemp -d)

command -v strace > /dev/null || { echo "strace is not installed" >&2; exit 1; }

# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
trap 'server_stop; exit 130' INT TERM
trap 'server_stop; rm -rf "$OUT"' EXIT
server_require_port_free "$PORT" || exit 1

# Starts the server under strace, optionally loads it, and stops it, leaving
# the counts in $OUT/$tag.strace.
traced() {
    local tag=$1 target=$2 conns=$3
    # shellcheck disable=SC2086 -- extra is deliberately split into flags.
    PYTHONPATH="$BUILD/python:$ROOT/benchmarks/contract" server_start \
        taskset -c "$SERVER_CPU" strace -f -c -o "$OUT/$tag.strace" \
        "$VENV/bin/python" -m garuda --host 127.0.0.1 --port "$PORT" \
        --workers 1 --log-level error $EXTRA --venv "$VENV" \
        --python-path "$ROOT/benchmarks/contract" "$target" \
        > "$OUT/server.log" 2>&1
    local up=0
    for _ in $(seq 1 120); do
        if curl -s -o /dev/null --max-time 1 "$URL"; then up=1; break; fi
        sleep 0.25
    done
    if [ "$up" != 1 ]; then
        echo "$tag: the server did not start" >&2
        tail -5 "$OUT/server.log" >&2
        server_stop
        return 1
    fi
    if [ "$conns" != 0 ]; then
        taskset -c "$LOAD_CPUS" "$OHA" -n "$N" -c "$conns" --no-tui \
            --output-format json -o "$OUT/$tag.oha.json" "$URL" > /dev/null 2>&1
    fi
    server_stop
}

for run in $RUNS; do
    app=${run%%:*}
    conns=${run##*:}
    case "$app" in
    asgi)    target=asgi:app ;;
    fastapi) target=fastapi_app:app ;;
    *) echo "unknown app: $app" >&2; continue ;;
    esac
    traced "$app-idle" "$target" 0 || continue
    traced "$app-c$conns" "$target" "$conns" || continue
    python3 - "$OUT/$app-idle.strace" "$OUT/$app-c$conns.strace" \
        "$OUT/$app-c$conns.oha.json" "$app, c=$conns" <<'PY'
import json, sys

def calls(path):
    # strace -c columns: % time, seconds, usecs/call, calls, [errors], syscall
    counts = {}
    for line in open(path):
        f = line.split()
        if len(f) < 5 or f[-1] == "total":
            continue
        try:
            float(f[0])
            counts[f[-1]] = int(f[3])
        except ValueError:
            continue
    return counts

idle, loaded = calls(sys.argv[1]), calls(sys.argv[2])
d = json.load(open(sys.argv[3]))
requests = sum(int(v) for v in (d.get("statusCodeDistribution") or {}).values())
rows = []
for name in set(idle) | set(loaded):
    extra = loaded.get(name, 0) - idle.get(name, 0)
    if extra > 0:
        rows.append((extra / max(requests, 1), name))
rows.sort(reverse=True)
print(f"{sys.argv[4]}: {requests} requests, {d['summary']['requestsPerSec']:.0f} req/s under strace")
for per, name in rows:
    if per >= 0.001:
        print(f"  {name:<14} {per:7.3f}")
print(f"  {'total':<14} {sum(r[0] for r in rows):7.3f}")
PY
done
