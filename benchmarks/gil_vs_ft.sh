#!/usr/bin/env bash
# GIL (worker processes) vs --free-threaded (worker threads) on the six
# the-benchmarker contract apps. Columns are concurrent connections.
#
#   bash benchmarks/gil_vs_ft.sh
#
# Override binaries / venvs / duration with the environment. Two peregrine
# builds are required: one linked against a GIL CPython, one against a
# free-threaded CPython (python3.13t / 3.14t). They are not interchangeable.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONPATH="$ROOT/benchmarks/contract${PYTHONPATH:+:$PYTHONPATH}"

GIL_BIN=${GIL_BIN:-$HOME/pgbuild/release/peregrine}
FT_BIN=${FT_BIN:-$HOME/pgbuild-ft/release/peregrine}
GIL_VENV=${GIL_VENV:-$HOME/pgvenv}
FT_VENV=${FT_VENV:-$HOME/pgvenv-ft}
PORT=${PORT:-8210}
DURATION=${DURATION:-15s}
CONNS="${CONNS:-64 256 512}"
URL="http://127.0.0.1:$PORT/"

stop() {
    pkill -9 -x peregrine 2>/dev/null || true
    sleep 1
}

start_server() {
    stop
    "$@" > /tmp/bench-server.log 2>&1 &
    local i
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        if curl -sS --max-time 1 -o /dev/null "$URL" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
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
        printf '%-36s  FAILED TO START\n' "$name"
        head -16 /tmp/bench-server.log
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
    printf '%-36s%s\n' "$name" "$cols"
}

run_matrix() {
    local label="$1" bin="$2" venv="$3" extra="$4" workers="$5"
    local hdr="" c
    for c in $CONNS; do
        hdr="$hdr$(printf ' %10s' "$c")"
    done
    echo
    echo "=== $label  ${workers}W  ${DURATION}  columns = connections ==="
    echo
    printf '%-36s%s\n' "app" "$hdr"

    row "raw ASGI" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" asgi:app
    row "raw WSGI" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" wsgi:application
    row "FastAPI" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" fastapi_app:app
    row "Django" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" django_app:application
    row "Sanic" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" sanic_app:app
    row "BlackSheep" \
        "$bin" --port "$PORT" --workers "$workers" --log-level error \
        $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" blacksheep_app:app
}

trap stop EXIT

echo "GIL binary: $($GIL_BIN --version | tr -d '\n')"
echo "FT  binary: $($FT_BIN --version | tr -d '\n')"
echo "GIL venv:   $GIL_VENV  ($("$GIL_VENV/bin/python" -c 'import sys; print(sys.version.split()[0])'))"
echo "FT  venv:   $FT_VENV  ($("$FT_VENV/bin/python" -c 'import sys,sysconfig; print(sys.version.split()[0] + ("t" if sysconfig.get_config_var("Py_GIL_DISABLED") else ""))'))"
echo "load:       oha closed-loop GET /  $CONNS connections  $DURATION"

run_matrix "GIL (processes)" "$GIL_BIN" "$GIL_VENV" "" 1
run_matrix "GIL (processes)" "$GIL_BIN" "$GIL_VENV" "" 4
run_matrix "FT (threads)"    "$FT_BIN"  "$FT_VENV"  "--free-threaded" 1
run_matrix "FT (threads)"    "$FT_BIN"  "$FT_VENV"  "--free-threaded" 4

stop
echo
echo "done"
