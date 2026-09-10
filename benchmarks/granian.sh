#!/usr/bin/env bash
# the-benchmarker/web-frameworks contract, Peregrine vs Granian.
#
# GET / for 15s, closed-loop (oha, like wrk): same three apps the suite uses —
# FastAPI, a raw ASGI app, a raw WSGI app — on both servers.
#
#   bash benchmarks/granian.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONPATH="$ROOT/benchmarks/contract${PYTHONPATH:+:$PYTHONPATH}"
PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
VENV=${VENV:-$HOME/pgvenv}
PORT=${PORT:-8210}
DURATION=${DURATION:-15s}
CONNECTIONS=${CONNECTIONS:-64}
WORKERS=${WORKERS:-1}
URL="http://127.0.0.1:$PORT/"

# Only the server this script started is stopped, and as a process group, so
# the workers it forked go with it and no unrelated server is touched.
# shellcheck source=scripts/serverlib.sh
. "$(dirname "$0")/../scripts/serverlib.sh"
# The port too: a third-party server may put its workers in a session of
# their own, where signalling the group cannot reach them.
stop() { server_stop "$PORT"; }
server_trap_cleanup

bench() {
    local name="$1"
    shift
    stop
    server_start "$@" > /tmp/bench-server.log 2>&1
    local pid=$SERVER_PID
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if curl -sS --max-time 1 -o /dev/null "$URL" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
    if ! curl -sS --max-time 3 -o /dev/null "$URL"; then
        printf '%-32s FAILED TO START\n' "$name"
        head -8 /tmp/bench-server.log
        kill -9 "$pid" 2>/dev/null
        return
    fi
    oha -z 3s -c "$CONNECTIONS" --no-tui "$URL" > /dev/null 2>&1
    local out rps p50 p99
    out=$(oha -z "$DURATION" -c "$CONNECTIONS" --no-tui "$URL" 2>/dev/null)
    rps=$(echo "$out" | awk '/Requests\/sec:/ {print $2}')
    p50=$(echo "$out" | awk '/50.00% in/ {print $3}')
    p99=$(echo "$out" | awk '/99.00% in/ {print $3}')
    printf '%-32s %12s req/s   p50 %-10s p99 %s\n' "$name" "$rps" "$p50" "$p99"
}

trap stop EXIT

echo "=== the-benchmarker contract  GET /  ${WORKERS} worker(s)  ${CONNECTIONS} conn  ${DURATION} ==="
echo

echo "-- FastAPI --"
bench "peregrine + FastAPI" \
    "$PEREGRINE" --port "$PORT" --workers "$WORKERS" --log-level error \
    --venv "$VENV" --python-path "$ROOT/benchmarks/contract" fastapi_app:app
bench "granian + FastAPI" \
    "$VENV/bin/granian" --log-level critical --interface asgi \
    --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" fastapi_app:app

echo
echo "-- ASGI (no framework) --"
bench "peregrine ASGI" \
    "$PEREGRINE" --port "$PORT" --workers "$WORKERS" --log-level error \
    --venv "$VENV" --python-path "$ROOT/benchmarks/contract" asgi:app
bench "granian ASGI" \
    "$VENV/bin/granian" --log-level critical --interface asgi \
    --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" asgi:app

echo
echo "-- WSGI (no framework) --"
bench "peregrine WSGI" \
    "$PEREGRINE" --port "$PORT" --workers "$WORKERS" --log-level error \
    --venv "$VENV" --python-path "$ROOT/benchmarks/contract" wsgi:application
bench "granian WSGI" \
    "$VENV/bin/granian" --log-level critical --interface wsgi \
    --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" wsgi:application
