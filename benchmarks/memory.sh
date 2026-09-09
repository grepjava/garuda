#!/usr/bin/env bash
# Resident memory at idle and under load, for the same application.
#
# RSS is read from /proc and summed over the whole process tree, so a
# supervisor-plus-worker server is counted fairly against a single-process one.
set -u

PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
VENV=${VENV:-$HOME/bench-venv}
PORT=8211
CONNS=${CONNS:-500}
URL="http://127.0.0.1:$PORT/"

stop() {
    pkill -9 -x peregrine 2>/dev/null
    pkill -9 -f uvicorn 2>/dev/null
    pkill -9 -f gunicorn 2>/dev/null
    sleep 1
}

# Every descendant of $1, plus $1 itself.
tree_pids() {
    local root=$1
    local out=$root
    local frontier=$root
    while [ -n "$frontier" ]; do
        local next=""
        for p in $frontier; do
            local kids
            kids=$(pgrep -P "$p" 2>/dev/null | tr '\n' ' ')
            next="$next $kids"
        done
        frontier=$(echo "$next" | xargs 2>/dev/null)
        out="$out $frontier"
    done
    echo "$out" | xargs
}

tree_rss_kb() {
    local total=0
    for p in $(tree_pids "$1"); do
        if [ -r "/proc/$p/status" ]; then
            local v
            v=$(awk '/^VmRSS:/ {print $2}' "/proc/$p/status" 2>/dev/null)
            total=$(( total + ${v:-0} ))
        fi
    done
    echo "$total"
}

measure() {
    local name="$1"
    shift
    stop
    "$@" > /dev/null 2>&1 &
    local root=$!
    sleep 4
    if ! curl -sS --max-time 3 -o /dev/null "$URL"; then
        echo "$name: failed to start"
        return
    fi
    local idle loaded
    idle=$(tree_rss_kb "$root")
    oha -z 6s -c "$CONNS" --no-tui "$URL" > /dev/null 2>&1
    loaded=$(tree_rss_kb "$root")
    printf '%-28s idle %7s KB   under %s conns %7s KB\n' \
        "$name" "$idle" "$CONNS" "$loaded"
}

echo "=== resident memory, 1 worker, $CONNS concurrent connections ==="
measure "peregrine (wsgi)" \
    "$PEREGRINE" --port $PORT --log-level error --python-path examples wsgi_app:application
measure "gunicorn (sync)" \
    "$VENV/bin/gunicorn" -b "127.0.0.1:$PORT" -w 1 --chdir examples \
    --log-level error wsgi_app:application
measure "peregrine (asgi)" \
    "$PEREGRINE" --port $PORT --log-level error --python-path examples asgi_app:app
measure "uvicorn (uvloop)" \
    "$VENV/bin/uvicorn" --host 127.0.0.1 --port $PORT --app-dir examples \
    --log-level error --loop uvloop --http httptools asgi_app:app

stop
