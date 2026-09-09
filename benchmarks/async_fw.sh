#!/usr/bin/env bash
# the-benchmarker contract: Sanic and BlackSheep on Peregrine vs Granian.
#
# Same columns as the dashboard: wrk-style closed-loop GET / at 64, 256, 512
# connections, 15s each. Server stays up across the three loads.
#
#   bash benchmarks/async_fw.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONPATH="$ROOT/benchmarks/contract${PYTHONPATH:+:$PYTHONPATH}"
PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
VENV=${VENV:-$HOME/pgvenv}
PORT=${PORT:-8210}
DURATION=${DURATION:-15s}
WORKERS=${WORKERS:-1}
CONNS="${CONNS:-64 256 512}"
URL="http://127.0.0.1:$PORT/"

stop() {
    pkill -9 -x peregrine 2>/dev/null
    pkill -9 -f "/granian --" 2>/dev/null
    sleep 1
}

start_server() {
    stop
    "$@" > /tmp/bench-server.log 2>&1 &
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl -sS --max-time 1 -o /dev/null "$URL" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    if curl -sS --max-time 3 -o /dev/null "$URL"; then
        return 0
    fi
    return 1
}

rps_at() {
    local c="$1"
    oha -z "$DURATION" -c "$c" --no-tui "$URL" 2>/dev/null \
        | awk '/Requests\/sec:/ {printf "%d", $2+0.5}'
}

row() {
    local name="$1"
    shift
    if ! start_server "$@"; then
        printf '%-28s  FAILED TO START\n' "$name"
        head -12 /tmp/bench-server.log
        return
    fi
    local first
    first=$(echo $CONNS | awk '{print $1}')
    oha -z 3s -c "$first" --no-tui "$URL" > /dev/null 2>&1
    local cols="" c rps
    for c in $CONNS; do
        rps=$(rps_at "$c")
        [ -n "$rps" ] || rps="—"
        cols="$cols$(printf ' %10s' "$rps")"
    done
    printf '%-28s%s\n' "$name" "$cols"
}

trap stop EXIT

hdr=""
for c in $CONNS; do
    hdr="$hdr$(printf ' %10s' "$c")"
done
echo "=== GET /  ${WORKERS} worker(s)  ${DURATION}  columns = connections ==="
echo
printf '%-28s%s\n' "server + framework" "$hdr"

row "peregrine + sanic" \
    "$PEREGRINE" --port "$PORT" --workers "$WORKERS" --log-level error \
    --venv "$VENV" --python-path "$ROOT/benchmarks/contract" sanic_app:app
row "granian + sanic" \
    "$VENV/bin/granian" --log-level critical --interface asgi \
    --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" sanic_app:app
row "peregrine + blacksheep" \
    "$PEREGRINE" --port "$PORT" --workers "$WORKERS" --log-level error \
    --venv "$VENV" --python-path "$ROOT/benchmarks/contract" blacksheep_app:app
row "granian + blacksheep" \
    "$VENV/bin/granian" --log-level critical --interface asgi \
    --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" blacksheep_app:app
