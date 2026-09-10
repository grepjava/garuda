#!/usr/bin/env bash
# Throughput comparison against the reference Python servers.
#
# Same application, same machine, same load generator, one worker each so the
# numbers reflect per-core efficiency rather than how many cores were thrown at
# the problem. Run from the repository root:
#
#   bash benchmarks/run.sh
#
set -u

PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
VENV=${VENV:-$HOME/bench-venv}
PORT=8210
DURATION=${DURATION:-10s}
CONNECTIONS=${CONNECTIONS:-64}
URL="http://127.0.0.1:$PORT/"

# Only the server this script started is stopped, and as a process group, so the
# workers gunicorn and uvicorn fork go with it.
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
    sleep 3
    if ! curl -sS --max-time 3 -o /dev/null "$URL"; then
        echo "$name: FAILED TO START"
        cat /tmp/bench-server.log | head -5
        return
    fi
    # Warm up so the comparison is steady-state, not import time.
    oha -z 3s -c "$CONNECTIONS" --no-tui "$URL" > /dev/null 2>&1
    local out
    out=$(oha -z "$DURATION" -c "$CONNECTIONS" --no-tui "$URL" 2>/dev/null)
    local rps p50 p99
    rps=$(echo "$out" | awk '/Requests\/sec:/ {print $2}')
    p50=$(echo "$out" | awk '/50.00% in/ {print $3}')
    p99=$(echo "$out" | awk '/99.00% in/ {print $3}')
    printf '%-28s %12s req/s   p50 %-10s p99 %s\n' "$name" "$rps" "$p50" "$p99"
}

echo "=== WSGI, 1 worker, $CONNECTIONS connections, $DURATION ==="
bench "peregrine (wsgi)" \
    "$PEREGRINE" --port $PORT --log-level error --python-path examples wsgi_app:application
bench "gunicorn (sync)" \
    "$VENV/bin/gunicorn" -b "127.0.0.1:$PORT" -w 1 --chdir examples \
    --log-level error wsgi_app:application
bench "gunicorn (gthread x8)" \
    "$VENV/bin/gunicorn" -b "127.0.0.1:$PORT" -w 1 -k gthread --threads 8 \
    --chdir examples --log-level error wsgi_app:application

echo
echo "=== ASGI, 1 worker, $CONNECTIONS connections, $DURATION ==="
bench "peregrine (asgi)" \
    "$PEREGRINE" --port $PORT --log-level error --python-path examples asgi_app:app
bench "uvicorn (uvloop+httptools)" \
    "$VENV/bin/uvicorn" --host 127.0.0.1 --port $PORT --app-dir examples \
    --log-level error --loop uvloop --http httptools asgi_app:app
bench "uvicorn (asyncio+h11)" \
    "$VENV/bin/uvicorn" --host 127.0.0.1 --port $PORT --app-dir examples \
    --log-level error --loop asyncio --http h11 asgi_app:app

stop
