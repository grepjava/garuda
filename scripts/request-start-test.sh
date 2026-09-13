#!/usr/bin/env bash
# --request-start-header: the application is told when its request arrived.
#
#   bash scripts/request-start-test.sh [path-to-peregrine]
#
# The value that matters is the one for a request that waited. With one worker
# and no threads, a request sent while another is being served sits unread
# until the worker is free; its X-Request-Start has to be from when it arrived,
# not from when the worker got round to it -- that difference is the queue
# time the header exists to report.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8391}
TLS_PORT=${TLS_PORT:-8392}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

H="http://127.0.0.1:$PORT"
now_us() { python3 -c 'import time; print(int(time.time() * 1e6))'; }

start() {
    server_start "$BIN" --port "$PORT" --log-level error "$@" > "$WORK/server.log" 2>&1
    for _ in $(seq 1 80); do
        curl -sS --max-time 1 -o /dev/null "$H/" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server did not start"; cat "$WORK/server.log"; exit 1
}

# Passes when $2 is t=<microseconds> within $3 microseconds of $4.
near() {
    local name=$1 value=$2 slack=$3 reference=$4
    case "$value" in
        t=[0-9]*) ;;
        *) bad "$name" "t=<microseconds>" "$value"; return ;;
    esac
    local stamp=${value#t=}
    local diff=$(( stamp > reference ? stamp - reference : reference - stamp ))
    if [ "$diff" -le "$slack" ]; then ok "$name"; else bad "$name" "within $slack us of $reference" "$stamp (off by $diff)"; fi
}

server_require_port_free "$PORT" || exit 1

echo "off by default"
start --python-path "$HERE" timing_apps:wsgi
is "no header without the flag" "$(curl -sS --max-time 5 $H/)" "none"
server_stop

for app in wsgi asgi; do
    echo "$app"
    start --request-start-header --python-path "$HERE" timing_apps:$app
    near "$app: the header is now, in microseconds" "$(curl -sS --max-time 5 $H/)" 2000000 "$(now_us)"
    is "$app: a proxy's own value is kept" \
       "$(curl -sS --max-time 5 -H 'X-Request-Start: t=1234567890123456' $H/)" "t=1234567890123456"
    is "$app: keep-alive stamps every request" \
       "$(curl -sS --max-time 5 $H/ $H/ | grep -o 't=[0-9]*' | wc -l | tr -d ' ')" "2"
    server_stop
done

# A request that queued behind a slow one. The first takes 300 ms; the second
# is sent 50 ms into it and cannot be read until it finishes, so its stamp has
# to be about 250 ms earlier than the moment the application saw it.
echo "queueing"
start --request-start-header --python-path "$HERE" timing_apps:wsgi
curl -sS --max-time 5 -o /dev/null $H/slow &
SLOW=$!
sleep 0.05
SENT=$(now_us)
QUEUED=$(curl -sS --max-time 5 $H/)
wait $SLOW
near "a queued request is stamped when it arrived, not when it was read" "$QUEUED" 100000 "$SENT"
server_stop

echo "HTTP/2"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/s.key" -out "$WORK/s.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
server_start "$BIN" --port "$TLS_PORT" --log-level error --request-start-header \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
    --python-path "$HERE" timing_apps:asgi > "$WORK/tls.log" 2>&1
for _ in $(seq 1 80); do
    curl -sSk --max-time 1 -o /dev/null "https://127.0.0.1:$TLS_PORT/" 2>/dev/null && break
    sleep 0.2
done
near "HTTP/2: the header is stamped" "$(curl -sSk --http2 --max-time 5 https://127.0.0.1:$TLS_PORT/)" 2000000 "$(now_us)"
server_stop

echo
echo "request start: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
