#!/usr/bin/env bash
# FastAPI (ASGI) and Flask (WSGI) on peregrine, uvicorn, granian and
# fastpysgi, measured the way the-benchmarker/web-frameworks measures them.
#
#   bash benchmarks/frameworks.sh > results.tsv
#
# The load is the upstream collect command, flag for flag (.tasks/config.rake
# in the-benchmarker/web-frameworks):
#
#   warm-up    zrk -c 50 -d 5s --plain URL
#   per level  zrk --plain -c N -d 15s -m GET --format json -R1000:100000
#                  --interval 1s --timeout 8s --latency URL
#
# That is an open-loop ramp from 1,000 to 100,000 requests a second over the
# run, keep-alive on, latency corrected for coordinated omission, and the
# figure reported is zrk's achieved_rate -- the number the results site
# ranks by. The applications are the upstream python/fastapi and python/flask
# sources, byte for byte (benchmarks/contract/).
#
# Two deliberate differences, both overridable:
#   WORKERS=1  upstream starts every server with $(nproc) workers. One worker
#              compares what each server does with a core.
#   RUNS=3     upstream takes one run per level. Each level here is run three
#              times and the median by achieved_rate is kept, because a shared
#              developer machine is noisier than a dedicated benchmark host.
#
# Output, one TSV line per cell:
#   framework server workers connections req/s p50_ms p75_ms p90_ms p99_ms errors [every run]
#
# Needs zrk >= 2.4 (github.com/zoxy-io/zrk) and a virtualenv with
# fastapi flask uvicorn[standard] granian fastpysgi.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV=${VENV:-$HOME/fastapi-bench-venv}
PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
ZRK=${ZRK:-zrk}
PORT=${PORT:-3000}
WORKERS=${WORKERS:-1}
CONNS=${CONNS:-"64 256 512"}
RUNS=${RUNS:-3}
DURATION=${DURATION:-15s}
FRAMEWORKS=${FRAMEWORKS:-"fastapi flask"}
SERVERS=${SERVERS:-"peregrine uvicorn granian fastpysgi"}
URL="http://127.0.0.1:$PORT/"
OUT=$(mktemp -d)
export PYTHONPATH="$ROOT/benchmarks/contract${PYTHONPATH:+:$PYTHONPATH}"

# Only the server this script started is stopped, and as a process group, so
# the workers it forked go with it and no unrelated server is touched.
# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
server_trap_cleanup
server_require_port_free "$PORT" || exit 1

# The server commands are the upstream engines' (python/config.yaml), with
# --workers taken from WORKERS rather than $(nproc).
start() {
    local server=$1 framework=$2 app interface
    case "$framework" in
    fastapi) app=fastapi_app:app; interface=asgi ;;
    flask)   app=flask_app:app;   interface=wsgi ;;
    esac
    case "$server" in
    peregrine)
        server_start "$PEREGRINE" --log-level error --protocol "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" \
            --venv "$VENV" --python-path "$ROOT/benchmarks/contract" "$app" ;;
    peregrine-ext)
        # The same server as an extension module, run by the virtualenv python:
        # peregrine._native, from scripts/build-extension.sh. Not in the default
        # SERVERS; it is how the two builds are compared.
        PYTHONPATH="$ROOT/python:$PYTHONPATH" server_start "$VENV/bin/python" -m peregrine \
            --log-level error --protocol "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" \
            --venv "$VENV" --python-path "$ROOT/benchmarks/contract" "$app" ;;
    uvicorn)
        # uvicorn[standard] picks uvloop and httptools by itself. uvicorn spells
        # ASGI 3 as asgi3. WSGI goes through uvicorn's own --interface wsgi
        # adapter, since upstream has no uvicorn engine for Flask.
        local uv_interface=$interface
        [ "$interface" = asgi ] && uv_interface=asgi3
        server_start "$VENV/bin/uvicorn" --log-level critical --interface "$uv_interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "$app" ;;
    granian)
        server_start "$VENV/bin/granian" --log-level critical --interface "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "$app" ;;
    fastpysgi)
        # The suite's fastpysgi-asgi and fastpysgi-wsgi entries start the server
        # from server.py with fastpysgi.run(app, host, port, workers=N), which
        # tells ASGI from WSGI by itself. The same call serves the FastAPI and
        # Flask applications here.
        server_start "$VENV/bin/python" -c \
            'import importlib, sys, fastpysgi
module, attr = sys.argv[1].split(":")
app = getattr(importlib.import_module(module), attr)
fastpysgi.run(app, sys.argv[2], int(sys.argv[3]), workers=int(sys.argv[4]))' \
            "$app" 127.0.0.1 "$PORT" "$WORKERS" ;;
    esac > "$OUT/$server-$framework.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$URL" && return 0
        sleep 0.25
    done
    return 1
}

# One run at $1 connections: "req/s p50 p75 p90 p99 errors", latencies in ms.
one_run() {
    local json="$OUT/run.json"
    rm -f "$json"
    "$ZRK" --plain -c "$1" -d "$DURATION" -m GET --format json --output "$json" \
        -R1000:100000 --interval 1s --timeout 8s --latency "$URL" > /dev/null 2>&1
    python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0 0 -1")
    raise SystemExit
lat = d.get("latency_us") or {}
errors = sum(int(v or 0) for v in (d.get("errors") or {}).values())
ms = lambda key: (lat.get(key) or 0) / 1000.0
print("%.0f %.3f %.3f %.3f %.3f %d" % (d.get("achieved_rate") or 0, ms("p50"), ms("p75"),
                                       ms("p90"), ms("p99"), errors))
PY
}

printf 'framework\tserver\tworkers\tconnections\treq/s p50_ms p75_ms p90_ms p99_ms errors\truns\n'
for framework in $FRAMEWORKS; do
    for server in $SERVERS; do
        server_stop
        if ! start "$server" "$framework"; then
            printf '%s\t%s\t%s\tFAILED TO START\n' "$framework" "$server" "$WORKERS"
            tail -5 "$OUT/$server-$framework.log"
            continue
        fi
        "$ZRK" -c 50 -d 5s --plain "$URL" > /dev/null 2>&1
        for c in $CONNS; do
            runs=""
            for _ in $(seq 1 "$RUNS"); do
                runs="$runs$(one_run "$c")"$'\n'
            done
            median=$(printf '%s' "$runs" | grep -v '^$' | sort -n -k1,1 \
                | sed -n "$(( (RUNS + 1) / 2 ))p")
            all=$(printf '%s' "$runs" | grep -v '^$' | awk '{printf "%s ", $1}')
            printf '%s\t%s\t%s\t%s\t%s\t[%s]\n' "$framework" "$server" "$WORKERS" "$c" \
                "$median" "$all"
        done
    done
done
server_stop
rm -rf "$OUT"
