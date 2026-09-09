#!/usr/bin/env bash
# Checks peregrine against the frameworks people actually deploy.
#
#   bash scripts/framework-test.sh [path-to-peregrine] [path-to-venv]
#
# Small example applications prove the protocol; a real framework proves the
# parts of it that only show up in anger -- middleware stacks, lifespan
# managers, response classes that stream, and a framework running its own
# thread pool inside ours.
#
# The virtualenv needs: fastapi starlette django websockets
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/release/peregrine}}
VENV=${2:-${PEREGRINE_VENV:-$HOME/pgvenv}}
PY="$VENV/bin/python"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ASGI_PORT=8410
WSGI_PORT=8411
MARKER="${TMPDIR:-/tmp}/peregrine-fw-shutdown.$$"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$3" "$2"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "$2" "contains $3";; esac; }

cleanup() { pkill -9 -x peregrine 2>/dev/null; rm -f "$MARKER"; sleep 0.3; }
trap cleanup EXIT

if [ ! -x "$PY" ]; then
    echo "no interpreter at $PY; create one and install fastapi starlette django websockets"
    exit 2
fi
if ! "$PY" -c 'import fastapi, starlette, django, websockets' 2>/dev/null; then
    echo "the virtualenv at $VENV is missing one of: fastapi starlette django websockets"
    echo "  $VENV/bin/pip install fastapi starlette django websockets"
    exit 2
fi

start() {  # port app extra-args...
    local port=$1 app=$2
    shift 2
    cleanup
    PEREGRINE_SHUTDOWN_MARKER="$MARKER" "$BIN" --port "$port" --log-level error \
        --venv "$VENV" --python-path "$HERE/examples" --python-path "$HERE/python" \
        --forwarded-allow-ips 127.0.0.1 "$@" "$app" \
        > "${TMPDIR:-/tmp}/peregrine-fw-$port.log" 2>&1 &
    for _ in $(seq 1 100); do
        curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server failed to start: $app"
    cat "${TMPDIR:-/tmp}/peregrine-fw-$port.log"
    exit 1
}

# ------------------------------------------------------------- FastAPI ------
echo "FastAPI / Starlette (ASGI)"
start $ASGI_PORT fastapi_app:app
H="http://127.0.0.1:$ASGI_PORT"

has "routing and JSON responses" "$(curl -sS --max-time 10 $H/)" '"hello":"peregrine"'
has "lifespan startup ran before the first request" \
    "$(curl -sS --max-time 10 $H/)" '"started":true'
has "a trusted proxy sets the scheme Starlette reports" \
    "$(curl -sS --max-time 10 -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.5' $H/headers)" \
    '"scheme":"https"'
has "a trusted proxy sets the client Starlette reports" \
    "$(curl -sS --max-time 10 -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-For: 203.0.113.5' $H/headers)" \
    '"client":"203.0.113.5"'
has "request bodies reach the endpoint" \
    "$(curl -sS --max-time 10 -d 'framework body' $H/echo)" '"len":14'
is "an unhandled exception is a 500" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 $H/boom)" "500"
is "StreamingResponse is chunked" \
   "$(curl -sS -i --max-time 10 $H/stream | grep -ci '^transfer-encoding: chunked')" "1"
is "StreamingResponse body" "$(curl -sS --max-time 10 $H/stream | tr '\n' ' ')" \
   "chunk-0 chunk-1 chunk-2 chunk-3 chunk-4 "
is "the generated OpenAPI document is served" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 $H/openapi.json)" "200"
is "the docs page is served" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 $H/docs)" "200"

# The websockets library is a far stricter client than a hand-rolled one.
WS=$("$PY" - "$ASGI_PORT" <<'PYEOF'
import asyncio, sys
import websockets

async def main():
    port = sys.argv[1]
    async with websockets.connect("ws://127.0.0.1:%s/ws" % port) as ws:
        await ws.send("hello")
        first = await ws.recv()
        await ws.send("x" * 100000)
        big = await ws.recv()
    print("%s %d" % (first, len(big)))

asyncio.run(main())
PYEOF
)
is "a real websockets client round-trips through Starlette" "$WS" "echo:hello 100005"

# Graceful shutdown must run the FastAPI lifespan teardown.
rm -f "$MARKER"
pkill -x peregrine
sleep 2
if [ -f "$MARKER" ]; then ok "the FastAPI lifespan shutdown ran"
else bad "the FastAPI lifespan shutdown ran" "no marker written" "a marker file"; fi

# -------------------------------------------------------------- Django ------
echo
echo "Django (WSGI, 8 application threads)"
start $WSGI_PORT django_app:application --wsgi-threads 8
H="http://127.0.0.1:$WSGI_PORT"

has "routing and JSON responses" "$(curl -sS --max-time 10 $H/)" '"hello": "peregrine"'
has "wsgi.multithread is reported to the application" \
    "$(curl -sS --max-time 10 $H/)" '"multithread": true'
has "a trusted proxy makes request.is_secure() true" \
    "$(curl -sS --max-time 10 -H 'X-Forwarded-Proto: https' $H/)" '"secure": true'
has "a trusted proxy sets REMOTE_ADDR" \
    "$(curl -sS --max-time 10 -H 'X-Forwarded-For: 198.51.100.2' $H/)" '"remote": "198.51.100.2"'
is "request bodies reach the view" "$(curl -sS --max-time 10 -d 'django body' $H/echo)" \
   "django body"
is "an unhandled exception is a 500" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 $H/boom)" "500"
is "StreamingHttpResponse is chunked" \
   "$(curl -sS -i --max-time 10 $H/stream | grep -ci '^transfer-encoding: chunked')" "1"
is "StreamingHttpResponse body" "$(curl -sS --max-time 10 $H/stream | tr '\n' ' ')" \
   "chunk-0 chunk-1 chunk-2 chunk-3 chunk-4 "

# The whole point of the pool: blocking views should overlap.
start_ms=$(date +%s%N)
pids=""
for _ in $(seq 1 8); do
    curl -sS --max-time 20 -o /dev/null "$H/sleep?s=0.5" &
    pids="$pids $!"
done
for p in $pids; do wait "$p"; done
elapsed=$(( ($(date +%s%N) - start_ms) / 1000000 ))
if [ "$elapsed" -lt 2000 ]; then
    ok "8 blocking Django views overlap on the pool (${elapsed}ms)"
else
    bad "8 blocking Django views overlap on the pool" "${elapsed}ms" "under 2000ms"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
