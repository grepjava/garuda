#!/usr/bin/env bash
# FastAPI (ASGI), Flask (WSGI) and BlackSheep (ASGI) on peregrine, uvicorn,
# granian and fastpysgi, and Elysia on Bun as a reference, with the load command
# and applications of the-benchmarker/web-frameworks at ac364e9 (master,
# 2026-09-11). The results are not comparable with the figures that site
# publishes; BENCHMARKS.md says why.
#
#   bash benchmarks/frameworks.sh > results.tsv
#   FRAMEWORKS=blacksheep SERVERS=peregrine-ext bash benchmarks/frameworks.sh
#   LOAD=closed PIN=0:1-3 FRAMEWORKS=elysia SERVERS=elysia-bun bash benchmarks/frameworks.sh
#
# The load is the upstream collect command, flag for flag (.tasks/config.rake
# line 152 at that revision; the --closed in the comment above it is not in the
# command):
#
#   warm-up    zrk -c 50 -d 5s --plain URL
#   per level  zrk --plain -c N -d 15s -m GET --format json -R1000:100000
#                  --interval 1s --timeout 8s --latency URL
#
# That is an open-loop ramp from 1,000 to 100,000 requests a second over the
# run, keep-alive on, latency corrected for coordinated omission, and the
# figure reported is zrk's achieved_rate -- the number the results site
# ranks by. The applications are the upstream python/fastapi, python/flask and
# python/blacksheep sources, byte for byte (benchmarks/contract/).
#
# LOAD=closed replaces the ramp with closed-loop oha, `oha -c N -z DURATION`,
# which measures capacity instead. The ramp offers at most about 96,500 req/s
# over a run, so a server that keeps up with it -- Elysia on Bun, or a cached
# response -- shows that ceiling and nothing more. PIN="0:1-3" runs the server
# on CPU 0 and the load generator on CPUs 1-3, so the two do not take turns on
# a core; it applies to either load.
#
# Differences from upstream; BENCHMARKS.md lists them all:
#   WORKERS=1  upstream starts every server with $(nproc) workers. One worker
#              compares what each server does with a core.
#   RUNS=3     upstream's published figures are means of three runs. Each level
#              here runs three times and the median by achieved_rate is kept,
#              because a shared developer machine is noisier than a dedicated
#              benchmark host.
#   the rest   Python, host and some servers are whatever VENV and this machine
#              provide; upstream is Python 3.14 on 16 CPUs, with gunicorn for
#              Flask, uvicorn for BlackSheep, and raw applications, not
#              frameworks, for fastpysgi.
#
# Output, one TSV line per cell:
#   framework server workers connections req/s p50_ms p75_ms p90_ms p99_ms errors [every run]
#
# Needs zrk >= 2.4 (github.com/zoxy-io/zrk), or oha for LOAD=closed, and a
# virtualenv with fastapi flask blacksheep uvicorn[standard] granian fastpysgi.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VENV=${VENV:-$HOME/fastapi-bench-venv}
PEREGRINE=${PEREGRINE:-$HOME/pgbuild/release/peregrine}
ZRK=${ZRK:-zrk}
OHA=${OHA:-oha}
LOAD=${LOAD:-ramp}
PORT=${PORT:-3000}
WORKERS=${WORKERS:-1}
CONNS=${CONNS:-"64 256 512"}
RUNS=${RUNS:-3}
DURATION=${DURATION:-15s}
FRAMEWORKS=${FRAMEWORKS:-"fastapi flask"}
SERVERS=${SERVERS:-"peregrine-ext peregrine uvicorn granian fastpysgi"}
# FRAMEWORKS=elysia SERVERS=elysia-bun measures upstream's javascript/elysia-bun
# (benchmarks/elysia-bun/, byte for byte) as a non-Python reference. The app
# listens on 3000 itself, so PORT must be 3000. Needs bun on PATH or in ~/.bun.
BUN=${BUN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
# "server_cpus:load_cpus" for taskset, e.g. 0:1-3; empty runs both unpinned.
PIN=${PIN:-}
PIN_SERVER=()
PIN_LOAD=()
if [ -n "$PIN" ]; then
    PIN_SERVER=(taskset -c "${PIN%%:*}")
    PIN_LOAD=(taskset -c "${PIN#*:}")
fi
# The applications. benchmarks/cached is the same pair marking their responses
# fresh, for measuring --cache-size.
CONTRACT=${CONTRACT:-$ROOT/benchmarks/contract}
# Where peregrine-ext loads peregrine._native from: another checkout, built
# with scripts/build-extension.sh, to compare two versions in one session.
EXT_ROOT=${EXT_ROOT:-$ROOT}
# Extra flags for both peregrine servers, e.g. "--cache-size 64".
# shellcheck disable=SC2206 -- deliberately split into words.
PEREGRINE_ARGS=(${PEREGRINE_EXTRA_ARGS:-})
URL="http://127.0.0.1:$PORT/"
OUT=$(mktemp -d)
export PYTHONPATH="$CONTRACT${PYTHONPATH:+:$PYTHONPATH}"

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
    fastapi)    app=fastapi_app:app;    interface=asgi ;;
    flask)      app=flask_app:app;      interface=wsgi ;;
    blacksheep) app=blacksheep_app:app; interface=asgi ;;
    esac
    case "$server" in
    peregrine)
        server_start "${PIN_SERVER[@]}" "$PEREGRINE" --log-level error --protocol "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "${PEREGRINE_ARGS[@]}" \
            --venv "$VENV" --python-path "$CONTRACT" "$app" ;;
    peregrine-ext)
        # The same server as an extension module, run by the virtualenv python:
        # peregrine._native, from scripts/build-extension.sh -- what a wheel
        # installs, measured beside the executable above.
        PYTHONPATH="$EXT_ROOT/python:$PYTHONPATH" server_start "${PIN_SERVER[@]}" "$VENV/bin/python" -m peregrine \
            --log-level error --protocol "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "${PEREGRINE_ARGS[@]}" \
            --venv "$VENV" --python-path "$CONTRACT" "$app" ;;
    uvicorn)
        # uvicorn[standard] picks uvloop and httptools by itself. uvicorn spells
        # ASGI 3 as asgi3. WSGI goes through uvicorn's own --interface wsgi
        # adapter, since upstream has no uvicorn engine for Flask.
        local uv_interface=$interface
        [ "$interface" = asgi ] && uv_interface=asgi3
        server_start "${PIN_SERVER[@]}" "$VENV/bin/uvicorn" --log-level critical --interface "$uv_interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "$app" ;;
    granian)
        server_start "${PIN_SERVER[@]}" "$VENV/bin/granian" --log-level critical --interface "$interface" \
            --host 127.0.0.1 --port "$PORT" --workers "$WORKERS" "$app" ;;
    fastpysgi)
        # The suite's fastpysgi-asgi and fastpysgi-wsgi entries start the server
        # from server.py with fastpysgi.run(app, host, port, workers=N), which
        # tells ASGI from WSGI by itself. The same call serves the FastAPI and
        # Flask applications here.
        server_start "${PIN_SERVER[@]}" "$VENV/bin/python" -c \
            'import importlib, sys, fastpysgi
module, attr = sys.argv[1].split(":")
app = getattr(importlib.import_module(module), attr)
fastpysgi.run(app, sys.argv[2], int(sys.argv[3]), workers=int(sys.argv[4]))' \
            "$app" 127.0.0.1 "$PORT" "$WORKERS" ;;
    elysia-bun)
        # Upstream runs cluster.ts, which spawns one `bun ./app.ts` per CPU.
        # One worker is app.ts itself; cluster.ts only when WORKERS is every CPU.
        [ "$PORT" = 3000 ] || { echo "elysia-bun listens on 3000; PORT=$PORT"; return 1; }
        # server_start runs here, not in a subshell, so SERVER_PID survives.
        cd "$ROOT/benchmarks/elysia-bun" || return 1
        [ -d node_modules/elysia ] || "$BUN" install --production || { cd "$ROOT"; return 1; }
        if [ "$WORKERS" = 1 ]; then
            NODE_ENV=production server_start "${PIN_SERVER[@]}" "$BUN" ./app.ts
        else
            NODE_ENV=production PATH="$(dirname "$BUN"):$PATH" server_start "${PIN_SERVER[@]}" "$BUN" run cluster.ts
        fi
        cd "$ROOT" ;;
    esac > "$OUT/$server-$framework.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$URL" && return 0
        sleep 0.25
    done
    return 1
}

warm_up() {
    if [ "$LOAD" = closed ]; then
        "${PIN_LOAD[@]}" "$OHA" -z 5s -c 50 --no-tui "$URL" > /dev/null 2>&1
    else
        "${PIN_LOAD[@]}" "$ZRK" -c 50 -d 5s --plain "$URL" > /dev/null 2>&1
    fi
}

# One run at $1 connections: "req/s p50 p75 p90 p99 errors", latencies in ms.
one_run() {
    local json="$OUT/run.json"
    rm -f "$json"
    if [ "$LOAD" = closed ]; then
        "${PIN_LOAD[@]}" "$OHA" -z "$DURATION" -c "$1" --no-tui --output-format json \
            -o "$json" "$URL" > /dev/null 2>&1
        python3 - "$json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0 0 0 0 0 -1")
    raise SystemExit
pct = d.get("latencyPercentiles") or {}
codes = d.get("statusCodeDistribution") or {}
errors = sum(int(v) for k, v in codes.items() if not k.startswith("2"))
# oha stops a timed run with one request in flight per connection and counts
# those as "aborted due to deadline"; they are the run ending, not the server.
errors += sum(int(v) for k, v in (d.get("errorDistribution") or {}).items()
              if k != "aborted due to deadline")
ms = lambda key: (pct.get(key) or 0) * 1000.0
print("%.0f %.3f %.3f %.3f %.3f %d" % (d["summary"]["requestsPerSec"], ms("p50"), ms("p75"),
                                       ms("p90"), ms("p99"), errors))
PY
        return
    fi
    "${PIN_LOAD[@]}" "$ZRK" --plain -c "$1" -d "$DURATION" -m GET --format json --output "$json" \
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
        # Elysia is its own server; the Python servers don't run it.
        [ "$framework" = elysia ] && [ "$server" != elysia-bun ] && continue
        [ "$framework" != elysia ] && [ "$server" = elysia-bun ] && continue
        server_stop
        if ! start "$server" "$framework"; then
            printf '%s\t%s\t%s\tFAILED TO START\n' "$framework" "$server" "$WORKERS"
            tail -5 "$OUT/$server-$framework.log"
            continue
        fi
        warm_up
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
