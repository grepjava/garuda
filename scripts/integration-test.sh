#!/usr/bin/env bash
# End-to-end checks against the built-in router over HTTP/1.1.
#
#   bash scripts/integration-test.sh [path-to-garuda]
#
# Exercises framing, keep-alive, pipelining, request bodies both by length and
# chunked, 100-continue, concurrent timed requests, the health check path and
# the request-smuggling defences. Every check is answered by the router's fixed
# routes (GET /, GET /user/:id, POST /user, GET /delay/:ms, 404 for the rest),
# so nothing beyond the release binary is needed. Needs curl and nc.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
# Extra server flags, so the same suite can be pointed at a different
# configuration without a second copy of it:
#   GARUDA_EXTRA_ARGS="--workers 4" bash scripts/integration-test.sh
EXTRA=${GARUDA_EXTRA_ARGS:-}
PORT=${PORT:-19301}
PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "contains $3" "$2";; esac; }

# Only the server this script started is stopped, and it is stopped as a process
# group so that `--workers N` leaves nothing behind.
# shellcheck source=scripts/serverlib.sh
. "$(dirname "$0")/serverlib.sh"
cleanup() { server_stop; }
server_trap_cleanup

start() {
    local port=$1
    cleanup
    # shellcheck disable=SC2086 -- EXTRA is a deliberate word-split flag list.
    server_start "$BIN" --port "$port" --log-level error $EXTRA \
        > "/tmp/garuda-it-$port.log" 2>&1
    for _ in $(seq 1 50); do
        curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server failed to start"
    cat "/tmp/garuda-it-$port.log"
    exit 1
}

# macOS ships no timeout(1) -- it is GNU coreutils, installed there as
# gtimeout if at all. Without one these requests still run; they just have no
# ceiling, which is only a problem for a server that hangs.
if command -v timeout > /dev/null 2>&1; then
    TIMEOUT=timeout
elif command -v gtimeout > /dev/null 2>&1; then
    TIMEOUT=gtimeout
else
    TIMEOUT=""
fi

raw() {  # raw request bytes -> response
    # shellcheck disable=SC2086 -- TIMEOUT is empty when there is no timeout(1).
    printf '%b' "$2" | $TIMEOUT ${TIMEOUT:+5} nc 127.0.0.1 "$1"
}

server_require_port_free "$PORT" || exit 1

# -------------------------------------------------------------- HTTP/1.1 ----
echo "HTTP/1.1 ($BIN)"
start "$PORT"
H="http://127.0.0.1:$PORT"

is "GET / is 200 with an empty body" \
   "$(curl -sS -o /dev/null -w '%{http_code}:%{size_download}' --max-time 5 $H/)" "200:0"
is "GET /user/:id answers the id" "$(curl -sS --max-time 5 $H/user/round-trip)" "round-trip"
is "404 status" "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 $H/nope)" "404"
is "POST with a Content-Length body" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -d 'round trip' $H/user)" "200"
is "chunked request" \
   "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H 'Transfer-Encoding: chunked' --data-binary 'chunky' $H/user)" \
   "200"
# curl sends the body anyway after a second without an interim response, so the
# status alone would pass against a server that ignores Expect; the 100 has to
# be on the wire.
is "100-continue" \
   "$(curl -sS -i --max-time 5 -H 'Expect: 100-continue' -d 'continued' $H/user | tr -d '\r' | grep '^HTTP/' | tr '\n' ' ')" \
   "HTTP/1.1 100 Continue HTTP/1.1 200 OK "
is "exactly one Content-Length" \
   "$(curl -sS -i --max-time 5 $H/user/one | grep -ci '^content-length')" "1"
# HEAD is answered wherever GET is: its head has to describe the body a GET
# would get, and no body may follow it.
is "HEAD sends no body but keeps the length" \
   "$(raw $PORT 'HEAD /user/abc HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | tr -d '\r' | awk 'BEGIN{h=1} h&&tolower($1)=="content-length:"{l=$2} h&&$0==""{h=0;next} !h{b=b $0} END{print l ":" length(b)}')" \
   "3:0"
is "keep-alive reuses the connection" \
   "$(curl -sS --max-time 5 -o /dev/null -o /dev/null -o /dev/null -w '%{num_connects}' $H/ $H/user/1 $H/)" \
   "100"
is "pipelined requests all answered, in order" \
   "$(raw $PORT 'GET /user/pipe-1 HTTP/1.1\r\nHost: x\r\n\r\nGET /user/pipe-2 HTTP/1.1\r\nHost: x\r\n\r\nGET /user/pipe-3 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | grep -o 'pipe-[0-9]' | tr '\n' ' ')" \
   "pipe-1 pipe-2 pipe-3 "
# Regression: per-request state must not leak into the next pipelined request.
# A body read short or long leaves the next request line misframed, so the
# request after the bodies is the one that shows it.
is "pipelined POSTs consume exactly their own bodies" \
   "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nAAAPOST /user HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nBBBGET /user/third HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | tr -d '\r' | grep -o -e '^HTTP/1.1 [0-9]*' -e 'third$' | tr '\n' ' ')" \
   "HTTP/1.1 200 HTTP/1.1 200 HTTP/1.1 200 third "
is "and so does a pipelined chunked POST" \
   "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nchunky\r\n0\r\n\r\nGET /user/after HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | tr -d '\r' | grep -o -e '^HTTP/1.1 [0-9]*' -e 'after$' | tr '\n' ' ')" \
   "HTTP/1.1 200 HTTP/1.1 200 after "

# Megabyte uploads. The router discards the body, so what shows it was read to
# the end is the next request on the same connection being answered.
head -c 1048576 /dev/urandom > /tmp/pg-upload.bin
is "1 MiB Content-Length upload, then the connection carries on" \
   "$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}:%{num_connects} ' --data-binary @/tmp/pg-upload.bin $H/user \
        --next -o /dev/null -w '%{http_code}:%{num_connects} ' $H/user/after)" \
   "200:1 200:0 "
is "1 MiB chunked upload, then the connection carries on" \
   "$(curl -sS --max-time 30 -o /dev/null -w '%{http_code}:%{num_connects} ' -H 'Transfer-Encoding: chunked' --data-binary @/tmp/pg-upload.bin $H/user \
        --next -o /dev/null -w '%{http_code}:%{num_connects} ' $H/user/after)" \
   "200:1 200:0 "
rm -f /tmp/pg-upload.bin

# Concurrency: 20 requests that each wait 250ms must overlap.
start_ms=$(ms)
pids=""
for _ in $(seq 1 20); do
    curl -sS --max-time 10 -o /dev/null $H/delay/250 &
    pids="$pids $!"
done
# Wait only on the clients: a bare `wait` would also block on the server, which
# this script started in the background and stops from the EXIT trap.
for p in $pids; do wait "$p"; done
elapsed=$(( $(ms) - start_ms ))
if [ "$elapsed" -lt 2000 ]; then ok "20 concurrent 250ms requests overlap (${elapsed}ms)"
else bad "concurrency" "<2000ms" "${elapsed}ms"; fi

echo "hardening"
has "missing Host is rejected" "$(raw $PORT 'GET / HTTP/1.1\r\n\r\n')" "400"
has "Content-Length + Transfer-Encoding is rejected" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "space before colon is rejected" \
    "$(raw $PORT 'GET / HTTP/1.1\r\nHost: x\r\nFoo : bar\r\n\r\n')" "400"
has "obs-fold is rejected" \
    "$(raw $PORT 'GET / HTTP/1.1\r\nHost: x\r\nA: 1\r\n  folded\r\n\r\n')" "400"
# A lone `gzip` leaves chunked out of the list, so the body cannot be framed at
# all: RFC 9112 6.3 asks for 400 there, and reserves 501 for the case where
# chunked is final but wraps a coding the server cannot remove.
has "unknown transfer coding is rejected" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n')" "400"
has "chunked under an unknown coding is a 501" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n')" \
    "501"
has "a coding that merely ends in chunked is rejected" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: xchunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "chunked before another coding is rejected" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked, gzip\r\n\r\n0\r\n\r\n')" \
    "400"
has "a repeated Transfer-Encoding is rejected" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n')" \
    "400"
has "a second Host header is rejected" \
    "$(raw $PORT 'GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n')" "400"
has "a chunked trailer section is accepted" \
    "$(raw $PORT 'POST /user HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\nX-Trailer: 1\r\n\r\n')" \
    "HTTP/1.1 200 OK"
# Trailers decode to no body, so the body limit never grows while they arrive:
# without a ceiling of their own a peer could stream them for as long as it
# liked and hold a connection, a slot and a read buffer for free.
TRAILERS=""
for _ in $(seq 1 1000); do
    TRAILERS="${TRAILERS}X-Pad: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\r\n"
done
has "a trailer section past the head limit is rejected" \
    "$(raw $PORT "POST /user HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n1\r\na\r\n0\r\n${TRAILERS}\r\n")" \
    "431"

# ------------------------------------------------- health check path --------
# Answered in the worker, so the interesting cases are the ones where it must
# NOT answer: a different path, and a method that is not a read. Both have to
# reach the router, which has no such route and says 404; a 200 would mean the
# flag had quietly taken the path over.
EXTRA="$EXTRA --health-check-path /healthz"
start "$PORT"
HB="http://127.0.0.1:$PORT"

is "health path answers 200"          "$(curl -sS -o /dev/null -w '%{http_code}' $HB/healthz)"      "200"
is "health path has an empty body"    "$(curl -sS -o /dev/null -w '%{size_download}' $HB/healthz)"  "0"
is "health path ignores the query"    "$(curl -sS -o /dev/null -w '%{http_code}' "$HB/healthz?probe=1")" "200"
is "health path answers HEAD"         "$(curl -sS -I -o /dev/null -w '%{http_code}' $HB/healthz)"   "200"
is "POST to it reaches the router"    "$(curl -sS -X POST -o /dev/null -w '%{http_code}' $HB/healthz)" "404"
is "a longer path reaches the router" "$(curl -sS -o /dev/null -w '%{http_code}' $HB/healthzz)"     "404"
is "a prefix of it reaches the router" "$(curl -sS -o /dev/null -w '%{http_code}' $HB/health)"      "404"
is "the router still answers"         "$(curl -sS $HB/user/still-here)"  "still-here"
# Answering without dispatching must not break the connection for what follows.
is "keep-alive survives a probe" \
   "$(raw $PORT 'GET /healthz HTTP/1.1\r\nHost: x\r\n\r\nGET /user/after-probe HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' | grep -c 'after-probe')" \
   "1"

# ------------------------------------------------------------- summary ------
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
