#!/usr/bin/env bash
# Does --free-threaded actually use the other cores?
#
# The question only has a meaningful answer for CPU-bound work: I/O-bound
# requests overlap under a GIL too, because CPython releases it around every
# blocking syscall. So the application here burns pure-Python CPU per request,
# and the comparison is between the three shapes a server can take:
#
#   1 worker                      -- the floor
#   N workers as processes        -- what Python servers have always done
#   N workers as threads          -- --free-threaded
#
# On a free-threaded interpreter (2) and (3) should land close together and well
# above (1). On a standard interpreter (3) refuses to start, which is the point.
#
# usage: benchmarks/free_threaded.sh [/path/to/peregrine] [workers]
set -u

BIN="${1:-${PEREGRINE:-$HOME/pgbuild/release/peregrine}}"
WORKERS="${2:-$(nproc)}"
PORT=8231
APP_DIR="$(cd "$(dirname "$0")/contract" && pwd)"
DURATION="${DURATION:-10s}"
CONNECTIONS="${CONNECTIONS:-64}"

if ! command -v oha >/dev/null 2>&1; then
    echo "this needs oha (https://github.com/hatoo/oha) on PATH" >&2
    exit 1
fi

"$BIN" --version

run() {
    local label="$1"; shift
    "$BIN" --port "$PORT" --python-path "$APP_DIR" --log-level warning \
           "$@" ft_app:app &
    local pid=$!
    # Wait for the port rather than sleeping for a guess.
    for _ in $(seq 1 50); do
        curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
        sleep 0.2
    done
    if ! curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
        echo "$label: server did not come up"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return
    fi

    local rps
    rps=$(oha -z "$DURATION" -c "$CONNECTIONS" --no-tui \
              "http://127.0.0.1:$PORT/burn" 2>/dev/null \
          | awk '/Requests\/sec/ {print $2}')
    printf '%-34s %10.1f req/s\n' "$label" "${rps:-0}"

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sleep 1
}

echo
echo "CPU-bound ASGI, ${DURATION} at ${CONNECTIONS} connections"
echo "----------------------------------------------------------"
run "1 worker"                       --workers 1
run "$WORKERS workers (processes)"   --workers "$WORKERS"
run "$WORKERS workers (threads)"     --workers "$WORKERS" --free-threaded
echo
