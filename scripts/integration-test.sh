#!/usr/bin/env bash
# End-to-end checks against a running server, for both protocols.
#
#   bash scripts/integration-test.sh [path-to-peregrine]
#
# Exercises framing, keep-alive, pipelining, chunked transfer in both
# directions, large bodies, error paths and the request-smuggling defences.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/release/peregrine}}
# Extra server flags, so the same suite can be pointed at a different execution
# model without a second copy of it:
#   PEREGRINE_EXTRA_ARGS="--workers 4 --free-threaded" bash scripts/integration-test.sh
EXTRA=${PEREGRINE_EXTRA_ARGS:-}
WSGI_PORT=8301
ASGI_PORT=8302
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "contains $3" "$2";; esac; }

# The server this script started, and nothing else: matching by name would take
# down another peregrine that happens to be running on the machine.
SERVER_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] || return 0
    kill -TERM "$SERVER_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.2
    done
    kill -KILL "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
}
trap 'cleanup; exit 130' INT TERM
trap cleanup EXIT

start() {
    local port=$1 app=$2
    cleanup
    # shellcheck disable=SC2086 -- EXTRA is a deliberate word-split flag list.
    "$BIN" --port "$port" --log-level error --python-path examples $EXTRA "$app" \
        > "/tmp/peregrine-it-$port.log" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 50); do
        curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server failed to start: $app"
    cat "/tmp/peregrine-it-$port.log"
    exit 1
}

raw() {  # raw request bytes -> response
    printf '%b' "$2" | timeout 5 nc 127.0.0.1 "$1"
}

# ---------------------------------------------------------------- WSGI ------
echo "WSGI ($BIN)"
start $WSGI_PORT wsgi_app:application
H="http://127.0.0.1:$WSGI_PORT"

is "GET / body" "$(curl -sS --max-time 5 $H/)" "hello from peregrine"
is "404 status" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $H/nope)" "404"
is "500 on app exception" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $H/boom)" "500"
is "POST echo" "$(curl -sS --max-time 5 -d 'round trip' $H/echo)" "round trip"
is "chunked request" \
   "$(curl -sS --max-time 5 -H 'Transfer-Encoding: chunked' --data-binary 'chunky' $H/echo)" \
   "chunky"
is "100-continue" "$(curl -sS --max-time 5 -H 'Expect: 100-continue' -d 'continued' $H/echo)" \
   "continued"
is "legacy write() plus iterable" "$(curl -sS --max-time 5 $H/write)" "written and returned"
# write() sends the head before the application returns, so there is no return
# value to measure and the framing has to be chunked.
is "legacy write() forces chunked framing" \
   "$(curl -sS -i --max-time 5 $H/write | grep -ci '^transfer-encoding: chunked')" "1"
is "legacy write() streams both blocks" \
   "$(curl -sS --max-time 8 $H/slowwrite?0.2 | tr -d '\n')" "firstsecond"
is "exactly one Content-Length" \
   "$(curl -sS -i --max-time 5 $H/ | grep -ci '^content-length')" "1"
is "chunked response for a generator" \
   "$(curl -sS -i --max-time 5 $H/stream | grep -ci '^transfer-encoding: chunked')" "1"
is "generator body" "$(curl -sS --max-time 5 $H/stream | tr '\n' ' ')" \
   "chunk-0 chunk-1 chunk-2 chunk-3 chunk-4 "
is "large response size" \
   "$(curl -sS --max-time 10 -o /dev/null -w '%{size_download}' "$H/big?250000")" "250000"
is "HEAD sends no body but keeps the length" \
   "$(curl -sS -I --max-time 5 $H/ | grep -i '^content-length' | tr -d '\r' | awk '{print $2}')" "21"
is "keep-alive reuses the connection" \
   "$(curl -sS --max-time 5 -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects}' $H/ $H/ $H/)" \
   "100"
is "pipelined requests all answered" \
   "$(raw $WSGI_PORT 'GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | grep -c 'hello from peregrine')" \
   "3"
# Regression: per-request state must not leak into the next pipelined request.
is "pipelined POSTs keep their own bodies" \
   "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nAAAPOST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nBBB' | tr -d '\r' | grep -c -e AAA -e BBB)" \
   "2"

# megabyte round trips
head -c 1048576 /dev/urandom > /tmp/pg-upload.bin
curl -sS --max-time 30 --data-binary @/tmp/pg-upload.bin -o /tmp/pg-dl1.bin $H/echo
if cmp -s /tmp/pg-upload.bin /tmp/pg-dl1.bin; then ok "1 MiB Content-Length round trip"
else bad "1 MiB Content-Length round trip" "identical" "differs"; fi
curl -sS --max-time 30 -H 'Transfer-Encoding: chunked' --data-binary @/tmp/pg-upload.bin \
     -o /tmp/pg-dl2.bin $H/echo
if cmp -s /tmp/pg-upload.bin /tmp/pg-dl2.bin; then ok "1 MiB chunked round trip"
else bad "1 MiB chunked round trip" "identical" "differs"; fi

echo "WSGI hardening"
has "missing Host is rejected" "$(raw $WSGI_PORT 'GET / HTTP/1.1\r\n\r\n')" "400"
has "Content-Length + Transfer-Encoding is rejected" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "space before colon is rejected" \
    "$(raw $WSGI_PORT 'GET / HTTP/1.1\r\nHost: x\r\nFoo : bar\r\n\r\n')" "400"
has "obs-fold is rejected" \
    "$(raw $WSGI_PORT 'GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\n  folded\r\n\r\n')" "400"
# A lone `gzip` leaves chunked out of the list, so the body cannot be framed at
# all: RFC 9112 6.3 asks for 400 there, and reserves 501 for the case where
# chunked is final but wraps a coding the server cannot remove.
has "unknown transfer coding is rejected" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n')" "400"
has "chunked under an unknown coding is a 501" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n')" \
    "501"
has "a coding that merely ends in chunked is rejected" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "chunked before another coding is rejected" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n')" \
    "400"
has "a repeated Transfer-Encoding is rejected" \
    "$(raw $WSGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "a second Host header is rejected" \
    "$(raw $WSGI_PORT 'GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n')" "400"
is "underscore headers are dropped (HTTP_X_A spoofing)" \
   "$(curl -sS --max-time 5 -H 'X_Spoofed: 1' $H/env | grep -c 'X_SPOOFED')" "0"

# ---------------------------------------------------------------- ASGI ------
echo
echo "ASGI"
start $ASGI_PORT asgi_app:app
H="http://127.0.0.1:$ASGI_PORT"

is "GET / body" "$(curl -sS --max-time 5 $H/)" "hello from peregrine asgi"
is "404 status" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $H/nope)" "404"
is "500 on app exception" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $H/boom)" "500"
is "POST echo" "$(curl -sS --max-time 5 -d 'asgi round trip' $H/echo)" "asgi round trip"
is "chunked request" \
   "$(curl -sS --max-time 5 -H 'Transfer-Encoding: chunked' --data-binary 'chunky asgi' $H/echo)" \
   "chunky asgi"
is "lifespan startup ran" \
   "$(curl -sS --max-time 5 $H/scope | python3 -c 'import json,sys; print(json.load(sys.stdin)["startup_ran"])')" \
   "True"
is "lifespan state reaches the request scope" \
   "$(curl -sS --max-time 5 $H/scope | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"]["shared"])')" \
   "from-lifespan"
is "scope headers are lowercased bytes" \
   "$(curl -sS --max-time 5 -H 'X-Mixed-Case: v' $H/scope | python3 -c 'import json,sys; print("x-mixed-case" in json.load(sys.stdin)["headers"])')" \
   "True"
is "explicit content-length is not duplicated" \
   "$(curl -sS -i --max-time 5 $H/fixed | grep -ci '^content-length')" "1"
is "streaming response" "$(curl -sS --max-time 5 $H/stream | tr '\n' ' ')" \
   "chunk-0 chunk-1 chunk-2 chunk-3 chunk-4 "
is "large response size" \
   "$(curl -sS --max-time 10 -o /dev/null -w '%{size_download}' "$H/big?500000")" "500000"
is "pipelined requests all answered" \
   "$(raw $ASGI_PORT 'GET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\n\r\nGET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | grep -c 'hello from peregrine asgi')" \
   "3"
# Regression: an ASGI connection must reset bodyDelivered between requests, or
# the second receive() on a reused connection parks forever.
is "pipelined POSTs keep their own bodies" \
   "$(raw $ASGI_PORT 'POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nAAAPOST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nBBB' | tr -d '\r' | grep -c -e AAA -e BBB)" \
   "2"

curl -sS --max-time 30 --data-binary @/tmp/pg-upload.bin -o /tmp/pg-dl3.bin $H/echo
if cmp -s /tmp/pg-upload.bin /tmp/pg-dl3.bin; then ok "1 MiB Content-Length round trip"
else bad "1 MiB Content-Length round trip" "identical" "differs"; fi

# Concurrency: 20 requests that each sleep 250ms must overlap.
start_ms=$(date +%s%N)
pids=""
for _ in $(seq 1 20); do
    curl -sS --max-time 10 -o /dev/null $H/sleep &
    pids="$pids $!"
done
# Wait only on the clients: a bare `wait` would also block on the server, which
# this script started in the background and stops from the EXIT trap.
for p in $pids; do wait "$p"; done
elapsed=$(( ($(date +%s%N) - start_ms) / 1000000 ))
if [ "$elapsed" -lt 2000 ]; then ok "20 concurrent 250ms requests overlap (${elapsed}ms)"
else bad "concurrency" "<2000ms" "${elapsed}ms"; fi

# ------------------------------------------------------------- summary ------
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
