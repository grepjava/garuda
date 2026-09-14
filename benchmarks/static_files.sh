#!/usr/bin/env bash
# Static files (--static-dir) over plain HTTP, HTTPS/1.1 and HTTP/2: requests
# a second, bytes a second, and the server CPU each gibibyte costs.
#
#   bash benchmarks/static_files.sh > static.tsv
#
# The baseline for changing how files are sent. Plain HTTP uses sendfile(2);
# HTTPS and HTTP/2 read the file into a buffer and encrypt it, which is what
# kernel TLS or a mapped file would change. Measure before and after on the
# same machine, in the same session.
#
# One worker, so the CPU figure is one process's and the comparison is per
# core. The files are random bytes, so nothing about them compresses, and
# they are read once first, so the page cache is warm and the disk is out of
# it.
#
# Output, one TSV line per cell:
#   mode size req/s MiB/s server_cpu_s cpu_ms_per_GiB
#
# Needs oha (github.com/hatoo/oha) and openssl.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GARUDA=${GARUDA:-$ROOT/scripts/garuda-ext}
export GARUDA_PYTHON=${GARUDA_PYTHON:-python3}
OHA=${OHA:-oha}
PORT=${PORT:-8460}
DURATION=${DURATION:-10s}
CONNS=${CONNS:-16}
SIZES=${SIZES:-"65536 1048576 16777216"}
MODES=${MODES:-"http https h2"}
EXTRA=${GARUDA_EXTRA_ARGS:-}
WORK=${WORK:-$HOME/pgbench-static}

rm -rf "$WORK"
mkdir -p "$WORK/files"
for size in $SIZES; do
    head -c "$size" /dev/urandom > "$WORK/files/f$size.bin"
    cat "$WORK/files/f$size.bin" > /dev/null
done
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

SID=""
cleanup() {
    if [ -n "$SID" ]; then
        pkill -TERM -s "$SID" 2>/dev/null
        for _ in $(seq 1 50); do
            pgrep -s "$SID" > /dev/null || break
            sleep 0.1
        done
        pkill -KILL -s "$SID" 2>/dev/null
    fi
    SID=""
}
trap cleanup EXIT

# Server CPU so far, in clock ticks, over every process in its session.
server_ticks() {
    local total=0 pid fields
    for pid in $(pgrep -s "$SID"); do
        fields=$(cut -d' ' -f14,15 "/proc/$pid/stat" 2>/dev/null) || continue
        set -- $fields
        total=$((total + $1 + $2))
    done
    echo "$total"
}

start() {
    local tls=()
    [ "$1" != http ] && tls=(--tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem")
    # shellcheck disable=SC2086 -- EXTRA is deliberately split into words.
    setsid "$GARUDA" --host 127.0.0.1 --port "$PORT" --workers 1 --log-level error \
        "${tls[@]}" --static-dir "/f=$WORK/files" $EXTRA \
        --python-path "$ROOT/scripts" request_id_apps:asgi_app > "$WORK/server.log" 2>&1 &
    SID=$!
    local scheme=http
    [ "$1" != http ] && scheme=https
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "$scheme://127.0.0.1:$PORT/" && return 0
        sleep 0.1
    done
    echo "server did not start" >&2
    cat "$WORK/server.log" >&2
    exit 1
}

load() {
    local mode=$1 url=$2 duration=$3
    local args=(-z "$duration" --no-tui --insecure --output-format json)
    if [ "$mode" = h2 ]; then
        args+=(--http2 -c 4 -p $((CONNS / 4)))
    else
        args+=(-c "$CONNS")
    fi
    "$OHA" "${args[@]}" "$url"
}

HZ=$(getconf CLK_TCK)
printf 'mode\tsize\treq/s\tMiB/s\tserver_cpu_s\tcpu_ms_per_GiB\n'
for mode in $MODES; do
    start "$mode"
    scheme=http
    [ "$mode" != http ] && scheme=https
    for size in $SIZES; do
        url="$scheme://127.0.0.1:$PORT/f/f$size.bin"
        load "$mode" "$url" 2s > /dev/null
        before=$(server_ticks)
        load "$mode" "$url" "$DURATION" > "$WORK/run.json"
        after=$(server_ticks)
        python3 - "$WORK/run.json" "$mode" "$size" $((after - before)) "$HZ" <<'PY'
import json, sys
path, mode, size, ticks, hz = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
s = json.load(open(path))["summary"]
rps = s.get("requestsPerSec") or 0.0
bps = s.get("sizePerSec") or 0.0
duration = s.get("total") or 1.0
cpu = ticks / hz
gib = bps * duration / 2**30
per_gib = cpu * 1000 / gib if gib else 0.0
print("%s\t%d\t%.0f\t%.1f\t%.2f\t%.0f" % (mode, size, rps, bps / 2**20, cpu, per_gib))
PY
    done
    cleanup
done
