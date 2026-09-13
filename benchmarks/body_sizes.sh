#!/usr/bin/env bash
# What moving an ASGI response body costs Peregrine, by size.
#
#   bash benchmarks/body_sizes.sh > bodies.tsv
#   BUILD=../peregrine-other bash benchmarks/body_sizes.sh
#
# A raw ASGI application (benchmarks/bodies_app.py) answers with a prebuilt body
# of each size, so the application's own work is the same at every size and
# what grows is the server's: the body is copied from the application's
# `bytes` into the connection's write buffer, then written to the socket. One
# worker, pinned to one CPU; closed-loop oha on the others.
#
# The figure to compare before and after changing that path is server CPU per
# KiB of body, from /proc/<pid>/task/*/schedstat for every process in the
# server's tree. On loopback, write() also delivers into the load generator's
# socket, so the kernel's share here is larger than over a network.
#
# BUILD is a checkout whose python/peregrine holds a built _native
# (scripts/build-extension.sh). EXTRA adds server flags.
#
# Output, one TSV line per size:
#   bytes req/s MiB/s server_cpu_us_per_req server_cpu_us_per_KiB
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-$ROOT}
VENV=${VENV:-$HOME/pgvenv}
OHA=${OHA:-oha}
PORT=${PORT:-8214}
DURATION=${DURATION:-10s}
CONNS=${CONNS:-64}
SIZES=${SIZES:-"1024 16384 65536 262144 1048576"}
SERVER_CPU=${SERVER_CPU:-0}
LOAD_CPUS=${LOAD_CPUS:-1-3}
EXTRA=${EXTRA:-}
OUT=$(mktemp -d)

# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
trap 'server_stop; exit 130' INT TERM
trap 'server_stop; rm -rf "$OUT"' EXIT
server_require_port_free "$PORT" || exit 1

server_cpu_ns() {
    local pid total=0 ns
    for pid in $(server_descendants "$SERVER_PID"); do
        for ns in $(cat /proc/"$pid"/task/*/schedstat 2>/dev/null | awk '{print $1}'); do
            total=$((total + ns))
        done
    done
    echo "$total"
}

# shellcheck disable=SC2086 -- EXTRA is deliberately split into flags.
PYTHONPATH="$BUILD/python:$ROOT/benchmarks" server_start \
    taskset -c "$SERVER_CPU" "$VENV/bin/python" -m peregrine \
    --host 127.0.0.1 --port "$PORT" --workers 1 --log-level error $EXTRA \
    --venv "$VENV" --python-path "$ROOT/benchmarks" bodies_app:app \
    > "$OUT/server.log" 2>&1
for _ in $(seq 1 60); do
    curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/0" && break
    sleep 0.25
done

echo "# build $BUILD  python $("$VENV/bin/python" -c 'import sys; print(sys.version.split()[0])')  oha -c $CONNS -z $DURATION  server CPU $SERVER_CPU, oha $LOAD_CPUS"
printf 'bytes\treq/s\tMiB/s\tcpu_us_per_req\tcpu_us_per_KiB\n'
for size in $SIZES; do
    url="http://127.0.0.1:$PORT/$size"
    taskset -c "$LOAD_CPUS" "$OHA" -z 2s -c "$CONNS" --no-tui "$url" > /dev/null 2>&1
    before=$(server_cpu_ns)
    taskset -c "$LOAD_CPUS" "$OHA" -z "$DURATION" -c "$CONNS" --no-tui \
        --output-format json -o "$OUT/oha.json" "$url" > /dev/null 2>&1
    after=$(server_cpu_ns)
    python3 - "$OUT/oha.json" "$before" "$after" "$size" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
size = int(sys.argv[4])
requests = sum(int(v) for k, v in (d.get("statusCodeDistribution") or {}).items() if k == "200")
rps = d["summary"]["requestsPerSec"]
cpu_us = (int(sys.argv[3]) - int(sys.argv[2])) / 1000.0 / max(requests, 1)
print("%d\t%.0f\t%.1f\t%.2f\t%.3f" % (size, rps, rps * size / 1048576, cpu_us, cpu_us / (size / 1024)))
PY
done
