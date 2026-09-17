#!/usr/bin/env bash
# --cache-size: repeated GETs answered from a cache every worker shares, for
# handler responses marked fresh, and nothing else.
#
#   bash scripts/cache-test.sh [path-to-garuda-conformance]
#
# The server defaults to the repo build, .build/release/garuda-conformance, whose
# /cache routes log every call they receive to CACHE_LOG. "Answered from the
# cache" is checked as "the handler was not called", not only as a header. It
# needs curl, gzip and openssl.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
BIN=${1:-${CONFORMANCE:-$ROOT/.build/release/garuda-conformance}}
PORT=${PORT:-19253}
MPORT=${MPORT:-19254}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
like() { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else bad "$1" "/$3/" "$2"; fi; }

# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
S="https://127.0.0.1:$PORT"
export CACHE_LOG="$WORK/calls.log"

start() {
    : > "$CACHE_LOG"
    server_start "$BIN" --port "$PORT" --workers 4 --log-level info \
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" "$@" > "$WORK/server.log" 2>&1
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "$S/cache/ready" && { : > "$CACHE_LOG"; return 0; }
        sleep 0.1
    done
    echo "server did not start:"
    cat "$WORK/server.log"
    exit 1
}

# fetch TARGET [curl options...]: head in $WORK/head.txt, body in $WORK/body.
fetch() {
    local target=$1
    shift
    curl -sk --max-time 5 -D "$WORK/head" -o "$WORK/body" "$@" "$S$target"
    tr -d '\r' < "$WORK/head" > "$WORK/head.txt"
}
header() { grep -i "^$1:" "$WORK/head.txt" | head -1 | sed 's/^[^:]*: *//'; }
status() { head -1 "$WORK/head.txt" | awk '{print $2}'; }
# How many times the handler received METHOD TARGET.
calls() { grep -cxF "$1 $2" "$CACHE_LOG"; }

server_require_port_free "$PORT" || exit 1

echo "a fresh response is answered from the cache"
start --cache-size 16 --compress --request-id --metrics-port "$MPORT"
fetch /cache/fresh --http1.1
first=$(cat "$WORK/body")
is "the first response is the handler's" "$(header cache-status)" ""
fetch /cache/fresh --http1.1
is "the second is the stored copy, byte for byte" "$(cat "$WORK/body")" "$first"
like "and says it came from the cache" "$(header cache-status)" '^garuda; hit; ttl=[0-9]+$'
like "with an Age" "$(header age)" '^[0-9]+$'
id1=$(header x-request-id)
fetch /cache/fresh --http1.1
id2=$(header x-request-id)
if [ -n "$id1" ] && [ "$id1" != "$id2" ]; then ok "every copy gets its own request ID"
else bad "every copy gets its own request ID" "two different IDs" "$id1 / $id2"; fi
for _ in $(seq 1 24); do curl -sk -o /dev/null "$S/cache/fresh"; done
is "two dozen more, on new connections to four workers, never reach the handler" \
    "$(calls GET /cache/fresh)" "1"
fetch /cache/fresh --http2
is "HTTP/2 is served the same copy" "$(cat "$WORK/body")" "$first"
like "and it says so" "$(header cache-status)" '^garuda; hit'

fetch /cache/fresh --http1.1
cp "$WORK/body" "$WORK/fresh.body"
# curl writes a HEAD response's headers where the body would go, so the body
# is measured by what curl counted, not by that file.
fetch /cache/fresh --http1.1 -I
like "HEAD is answered from the GET's copy" "$(header cache-status)" '^garuda; hit'
is "with the length of the body it withholds" "$(header content-length)" \
    "$(wc -c < "$WORK/fresh.body" | tr -d ' ')"
is "and no body" "$(curl -sk --http1.1 -I -o /dev/null -w '%{size_download}' "$S/cache/fresh")" "0"
codes=$(curl -sk --http1.1 -o /dev/null -o /dev/null -w '%{http_code}:%{num_connects} ' "$S/cache/fresh" "$S/cache/fresh")
is "a hit leaves the connection open for the next request" "$codes" "200:1 200:0 "
is "HEAD and keep-alive reached the handler no more than before" "$(calls GET /cache/fresh)" "1"

echo "compressed for each client"
fetch /cache/vary-ae --http1.1 -H "Accept-Encoding: gzip"
is "the handler's response is compressed for a client that asks" "$(header content-encoding)" "gzip"
plain=$(gzip -dc < "$WORK/body")
fetch /cache/vary-ae --http1.1
is "a client that does not ask gets the copy plain" "$(header content-encoding)" ""
is "the same bytes" "$(cat "$WORK/body")" "$plain"
fetch /cache/vary-ae --http2 -H "Accept-Encoding: gzip"
is "and one that does gets it compressed" "$(header content-encoding)" "gzip"
is "which decompresses to the same bytes" "$(gzip -dc < "$WORK/body")" "$plain"
is "all from one call" "$(calls GET /cache/vary-ae)" "1"

echo "what is never kept"
for route in private nostore cookie vary-ua plain broken big short-length; do
    fetch "/cache/$route" --http1.1
    fetch "/cache/$route" --http1.1
    is "/cache/$route reaches the handler every time" "$(calls GET "/cache/$route")" "2"
done
fetch /cache/stream/pieces --http1.1
fetch /cache/stream/pieces --http1.1
is "a body streamed in pieces is kept whole" "$(calls GET /cache/stream/pieces)" "1"
like "and served from the cache" "$(header cache-status)" '^garuda; hit'
fetch /cache/missing --http1.1
fetch /cache/missing --http1.1
is "a 404 marked fresh is kept" "$(calls GET /cache/missing)" "1"
is "and served with its status" "$(status)" "404"
fetch /cache/nothing --http1.1
fetch /cache/nothing --http1.1
is "a 204 is kept" "$(calls GET /cache/nothing)" "1"
like "and served without a body" "$(status):$(wc -c < "$WORK/body" | tr -d ' ')" '^204:0$'
curl -sk -o /dev/null -X POST "$S/cache/fresh?post"
curl -sk -o /dev/null -X POST "$S/cache/fresh?post"
is "a POST is never answered from the cache" "$(calls POST /cache/fresh?post)" "2"

echo "a change to a URL retires what was cached for it"
fetch /cache/item --http1.1
fetch /cache/item --http1.1
is "a GET for it is answered from the cache" "$(calls GET /cache/item)" "1"
curl -sk -o /dev/null -X POST "$S/cache/item"
fetch /cache/item --http1.1
is "until a POST to it succeeds" "$(calls GET /cache/item)" "2"
fetch /cache/item --http1.1
is "and the response after that is cached in its place" "$(calls GET /cache/item)" "2"
curl -sk -o /dev/null -X POST -H "X-Deny: 1" "$S/cache/item"
fetch /cache/item --http1.1
is "a POST the handler refuses changes nothing" "$(calls GET /cache/item)" "2"
curl -sk -o /dev/null --http2 -X DELETE "$S/cache/item"
fetch /cache/item --http1.1
is "a DELETE over HTTP/2 retires it too" "$(calls GET /cache/item)" "3"
fetch "/cache/item?other" --http1.1
curl -sk -o /dev/null -X PUT "$S/cache/item"
fetch "/cache/item?other" --http1.1
is "a different query string is a different URL" "$(calls GET /cache/item?other)" "1"
curl -sk -o /dev/null "$S/cache/slow-item" &
slow=$!
sleep 0.3
curl -sk -o /dev/null -X PUT "$S/cache/slow-item"
wait "$slow"
fetch /cache/slow-item --http1.1
is "a GET still being answered when a PUT succeeds is not cached" "$(calls GET /cache/slow-item)" "2"

echo "what a response's age uses up"
fetch /cache/aged --http1.1
fetch /cache/aged --http1.1
is "one already older than its max-age is not kept" "$(calls GET /cache/aged)" "2"
fetch /cache/dated --http1.1
fetch /cache/dated --http1.1
is "nor one whose Date is" "$(calls GET /cache/dated)" "2"
fetch /cache/half-aged --http1.1
fetch /cache/half-aged --http1.1
is "one with some of its lifetime left is" "$(calls GET /cache/half-aged)" "1"
like "served with the age it arrived with" "$(header age)" '^3[0-9]$'
ttl=$(header cache-status | sed -n 's/.*ttl=\([0-9]*\).*/\1/p')
if [ -n "$ttl" ] && [ "$ttl" -le 30 ]; then ok "and only what is left of its lifetime"
else bad "and only what is left of its lifetime" "a ttl of 30 or less" "${ttl:-none}"; fi

echo "conditional requests"
fetch /cache/etag --http1.1
fetch /cache/etag --http1.1
is "a copy with validators is cached" "$(calls GET /cache/etag)" "1"
fetch /cache/etag --http1.1 -H 'If-Match: "other"'
is "If-Match goes to the handler, which refuses it" "$(status)" "412"
is "and is called for it" "$(calls GET /cache/etag)" "2"
fetch /cache/etag --http1.1
is "the next plain request still gets the copy" "$(status):$(calls GET /cache/etag)" "200:2"
fetch /cache/etag --http1.1 -H 'If-None-Match: "v1"'
is "a matching If-None-Match is answered 304" "$(status)" "304"
like "from the copy" "$(header cache-status)" '^garuda; hit'
is "with its ETag" "$(header etag)" '"v1"'
is "no Content-Length" "$(header content-length)" ""
# curl leaves its output file alone when no body arrives, so the size is what
# it counted, not what that file still holds from the request before.
is "and no body" \
    "$(curl -sk --http1.1 -o /dev/null -w '%{size_download}' -H 'If-None-Match: "v1"' "$S/cache/etag")" "0"
fetch /cache/etag --http2 -H 'If-None-Match: W/"v1"'
is "a weak one matches, over HTTP/2 too" "$(status)" "304"
fetch /cache/etag --http1.1 -H 'If-None-Match: "v0"' -H 'If-None-Match: "v1"'
is "one split over two lines still matches" "$(status)" "304"
fetch /cache/etag --http1.1 -H 'If-None-Match: "v0"'
like "a different ETag gets the whole copy" "$(status):$(header cache-status)" '^200:garuda; hit'
fetch /cache/etag --http1.1 -H 'If-Modified-Since: Mon, 07 Nov 1994 00:00:00 GMT'
is "If-Modified-Since no earlier than Last-Modified is 304" "$(status)" "304"
fetch /cache/etag --http1.1 -H 'If-Modified-Since: Sat, 05 Nov 1994 00:00:00 GMT'
is "and earlier is 200" "$(status)" "200"
fetch /cache/etag --http1.1 -H 'If-Unmodified-Since: Sat, 05 Nov 1994 00:00:00 GMT'
is "If-Unmodified-Since goes to the handler" "$(calls GET /cache/etag)" "3"
fetch /cache/etag --http1.1 -H 'If-Range: "v1"'
is "and so does If-Range" "$(calls GET /cache/etag)" "4"
fetch /cache/etag --http1.1 -H 'Accept-Encoding: gzip'
like "a copy compressed for the client" "$(header content-encoding):$(header cache-status)" '^gzip:garuda; hit'
is "sends its strong ETag weak" "$(header etag)" 'W/"v1"'
fetch /cache/etag --http1.1 -H 'Accept-Encoding: gzip' -H 'If-None-Match: W/"v1"'
is "which revalidates" "$(status)" "304"
is "a 304 repeats the Vary its 200 has" "$(header vary)" "Accept-Encoding"
is "and the ETag" "$(header etag)" 'W/"v1"'
is "with no Content-Encoding" "$(header content-encoding)" ""
fetch /cache/etag --http1.1 -H 'If-None-Match: "v1"'
is "a 304 for a client that takes the body plain says Vary too" "$(header vary)" "Accept-Encoding"
is "with the strong ETag" "$(header etag)" '"v1"'
fetch /cache/etag --http2 -H 'Accept-Encoding: gzip' -H 'If-None-Match: W/"v1"'
is "and so does a 304 over HTTP/2" "$(status):$(header vary):$(header etag)" '304:accept-encoding:W/"v1"'
is "all without calling the handler" "$(calls GET /cache/etag)" "4"

echo "requests that keep out of the cache"
fetch "/cache/fresh?auth" --http1.1 -H "Authorization: Bearer secret"
fetch "/cache/fresh?auth" --http1.1
is "a response to a request with credentials is not stored" "$(calls GET /cache/fresh?auth)" "2"
fetch "/cache/fresh?auth" --http1.1 -H "Authorization: Bearer secret"
is "and such a request is not answered from what is" "$(calls GET /cache/fresh?auth)" "3"
fetch "/cache/fresh?cookie" --http1.1
fetch "/cache/fresh?cookie" --http1.1 -H "Cookie: session=abc"
is "a request with a cookie reaches the handler" "$(calls GET /cache/fresh?cookie)" "2"
fetch /cache/fresh --http1.1 -H "Cache-Control: no-cache"
is "so does a reload asking for a fresh copy" "$(calls GET /cache/fresh)" "2"
fetch /cache/fresh --http1.1 -H "Cache-Control: max-age=0"
is "and a browser's reload" "$(calls GET /cache/fresh)" "3"

echo "expiry, metrics and reloads"
fetch /cache/short --http1.1
fetch /cache/short --http1.1
is "a copy is served while it is fresh" "$(calls GET /cache/short)" "1"
sleep 1.6
fetch /cache/short --http1.1
is "and not after" "$(calls GET /cache/short)" "2"
hits=$(curl -s "http://127.0.0.1:$MPORT/metrics" | awk '/^garuda_cache_hits_total/ {print $2}')
like "hits are counted" "${hits:-0}" '^[1-9][0-9]*$'
stores=$(curl -s "http://127.0.0.1:$MPORT/metrics" | awk '/^garuda_cache_stores_total/ {print $2}')
like "and stores" "${stores:-0}" '^[1-9][0-9]*$'
fetch /cache/maxage --http1.1
fetch /cache/maxage --http1.1
is "max-age is enough to be kept" "$(calls GET /cache/maxage)" "1"
kill -HUP "$SERVER_PID"
for _ in $(seq 1 60); do
    grep -q "reloading workers" "$WORK/server.log" && break
    sleep 0.1
done
sleep 2
fetch /cache/maxage --http1.1
is "a reload discards what was cached" "$(calls GET /cache/maxage)" "2"
server_stop

echo "without --cache-size"
start
fetch /cache/fresh --http1.1
fetch /cache/fresh --http1.1
is "every request reaches the handler" "$(calls GET /cache/fresh)" "2"
is "and nothing says otherwise" "$(header cache-status)" ""
server_stop

echo
echo "cache: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
