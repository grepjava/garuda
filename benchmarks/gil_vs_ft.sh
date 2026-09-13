#!/usr/bin/env bash
# GIL (worker processes) vs --free-threaded (worker threads) on the
# the-benchmarker contract apps. Columns are concurrent connections.
#
#   bash benchmarks/gil_vs_ft.sh
#   APPS="fastapi flask asgi wsgi" bash benchmarks/gil_vs_ft.sh
#   EXTENSION=1 bash benchmarks/gil_vs_ft.sh
#
# APPS picks the applications, FastAPI and Flask by default. Every app in
# benchmarks/contract/ is available: fastapi flask asgi wsgi django sanic
# blacksheep.
#
# Two builds are required, one for a GIL CPython and one for a free-threaded
# CPython (python3.13t / 3.14t); they are not interchangeable. By default they
# are the executables GIL_BIN and FT_BIN. With EXTENSION=1 they are
# peregrine._native, run by each venv's own python -- build one for each
# interpreter with scripts/build-extension.sh.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXTENSION=${EXTENSION:-0}
export PYTHONPATH="$ROOT/benchmarks/contract${PYTHONPATH:+:$PYTHONPATH}"
[ "$EXTENSION" = 1 ] && export PYTHONPATH="$ROOT/python:$PYTHONPATH"

GIL_BIN=${GIL_BIN:-$HOME/pgbuild/release/peregrine}
FT_BIN=${FT_BIN:-$HOME/pgbuild-ft/release/peregrine}
GIL_VENV=${GIL_VENV:-$HOME/pgvenv}
FT_VENV=${FT_VENV:-$HOME/pgvenv-ft}
PORT=${PORT:-8210}
DURATION=${DURATION:-15s}
CONNS="${CONNS:-64 256 512}"
# fastapi flask asgi wsgi django sanic blacksheep
APPS="${APPS:-fastapi flask}"
URL="http://127.0.0.1:$PORT/"

# Only the server this script started is stopped, and as a process group, so
# the workers it forked go with it and no unrelated server is touched.
# shellcheck source=scripts/serverlib.sh
. "$(dirname "$0")/../scripts/serverlib.sh"
stop() { server_stop; }
server_trap_cleanup

# Nothing here will clear the port for itself: a listener that is already
# there belongs to somebody else, and killing it is not this script's call.
server_require_port_free "$PORT" || exit 1

start_server() {
    stop
    server_start "$@" > /tmp/bench-server.log 2>&1
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

# The command that starts the server for one build: the binary, or with
# EXTENSION=1 the venv's python running peregrine._native.
server_command() {
    local bin="$1" venv="$2"
    if [ "$EXTENSION" = 1 ]; then
        echo "$venv/bin/python -m peregrine"
    else
        echo "$bin"
    fi
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

    local -a server
    read -r -a server <<< "$(server_command "$bin" "$venv")"

    local app
    for app in $APPS; do
        local name target
        case "$app" in
        fastapi)    name="FastAPI";    target=fastapi_app:app ;;
        flask)      name="Flask";      target=flask_app:app ;;
        asgi)       name="raw ASGI";   target=asgi:app ;;
        wsgi)       name="raw WSGI";   target=wsgi:application ;;
        django)     name="Django";     target=django_app:application ;;
        sanic)      name="Sanic";      target=sanic_app:app ;;
        blacksheep) name="BlackSheep"; target=blacksheep_app:app ;;
        *) echo "unknown app: $app"; continue ;;
        esac
        row "$name" \
            "${server[@]}" --port "$PORT" --workers "$workers" --log-level error \
            $extra --venv "$venv" --python-path "$ROOT/benchmarks/contract" "$target"
    done
}

trap stop EXIT

if [ "$EXTENSION" = 1 ]; then
    echo "server:     peregrine._native (EXTENSION=1)"
    echo "GIL:        $("$GIL_VENV/bin/python" -m peregrine --version | tr -d '\n')"
    echo "FT:         $("$FT_VENV/bin/python" -m peregrine --version | tr -d '\n')"
else
    echo "GIL binary: $($GIL_BIN --version | tr -d '\n')"
    echo "FT  binary: $($FT_BIN --version | tr -d '\n')"
fi
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
