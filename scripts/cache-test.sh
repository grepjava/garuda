#!/usr/bin/env bash
# --cache-size: repeated GETs answered from a cache every worker shares, for
# responses the application marks fresh, and nothing else.
#
#   bash scripts/cache-test.sh [path-to-garuda]
#
# The application logs every call it receives, so "answered from the cache"
# is checked as "the application was not called", not only as a header.
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--free-threaded".
set -u

BIN=${1:-${GARUDA:-$HOME/pgbuild/debug/garuda}}
PORT=${PORT:-8253}
MPORT=${MPORT:-8254}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${GARUDA_EXTRA_ARGS:-})
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
like() { if printf '%s' "$2" | grep -Eq "$3"; then ok "$1"; else bad "$1" "/$3/" "$2"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
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
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" "${EXTRA[@]}" "$@" \
        --python-path "$HERE" "${APP:-cache_apps:asgi_app}" > "$WORK/server.log" 2>&1
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "$S/ready" && { : > "$CACHE_LOG"; return 0; }
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
# How many times the application received METHOD TARGET.
calls() { grep -cxF "$1 $2" "$CACHE_LOG"; }

server_require_port_free "$PORT" || exit 1

echo "a fresh response is answered from the cache"
start --cache-size 16 --compress --request-id --metrics-port "$MPORT"
fetch /fresh --http1.1
first=$(cat "$WORK/body")
is "the first response is the application's" "$(header cache-status)" ""
fetch /fresh --http1.1
is "the second is the stored copy, byte for byte" "$(cat "$WORK/body")" "$first"
like "and says it came from the cache" "$(header cache-status)" '^garuda; hit; ttl=[0-9]+$'
like "with an Age" "$(header age)" '^[0-9]+$'
id1=$(header x-request-id)
fetch /fresh --http1.1
id2=$(header x-request-id)
if [ -n "$id1" ] && [ "$id1" != "$id2" ]; then ok "every copy gets its own request ID"
else bad "every copy gets its own request ID" "two different IDs" "$id1 / $id2"; fi
for _ in $(seq 1 24); do curl -sk -o /dev/null "$S/fresh"; done
is "two dozen more, on new connections to four workers, never reach the application" \
    "$(calls GET /fresh)" "1"
fetch /fresh --http2
is "HTTP/2 is served the same copy" "$(cat "$WORK/body")" "$first"
like "and it says so" "$(header cache-status)" '^garuda; hit'
fetch /fresh --http1.1
cp "$WORK/body" "$WORK/fresh.body"
# curl writes a HEAD response's headers where the body would go, so the body
# is measured by what curl counted, not by that file.
fetch /fresh --http1.1 -I
like "HEAD is answered from the GET's copy" "$(header cache-status)" '^garuda; hit'
is "with the length of the body it withholds" "$(header content-length)" \
    "$(wc -c < "$WORK/fresh.body" | tr -d ' ')"
is "and no body" "$(curl -sk --http1.1 -I -o /dev/null -w '%{size_download}' "$S/fresh")" "0"
codes=$(curl -sk --http1.1 -o /dev/null -o /dev/null -w '%{http_code}:%{num_connects} ' "$S/fresh" "$S/fresh")
is "a hit leaves the connection open for the next request" "$codes" "200:1 200:0 "
is "HEAD and keep-alive reached the application no more than before" "$(calls GET /fresh)" "1"

echo "compressed for each client"
fetch /vary-ae --http1.1 -H "Accept-Encoding: gzip"
is "the application's response is compressed for a client that asks" "$(header content-encoding)" "gzip"
plain=$(gzip -dc < "$WORK/body")
fetch /vary-ae --http1.1
is "a client that does not ask gets the copy plain" "$(header content-encoding)" ""
is "the same bytes" "$(cat "$WORK/body")" "$plain"
fetch /vary-ae --http2 -H "Accept-Encoding: gzip"
is "and one that does gets it compressed" "$(header content-encoding)" "gzip"
is "which decompresses to the same bytes" "$(gzip -dc < "$WORK/body")" "$plain"
is "all from one call" "$(calls GET /vary-ae)" "1"

echo "what is never kept"
for route in /private /nostore /cookie /vary-ua /plain /broken /big; do
    fetch "$route" --http1.1
    fetch "$route" --http1.1
    is "$route reaches the application every time" "$(calls GET "$route")" "2"
done
fetch /stream --http1.1
fetch /stream --http1.1
is "a body sent in pieces is kept whole" "$(calls GET /stream)" "1"
fetch /missing --http1.1
fetch /missing --http1.1
is "a 404 marked fresh is kept" "$(calls GET /missing)" "1"
is "and served with its status" "$(status)" "404"
fetch /nothing --http1.1
fetch /nothing --http1.1
is "a 204 is kept" "$(calls GET /nothing)" "1"
like "and served without a body" "$(status):$(wc -c < "$WORK/body" | tr -d ' ')" '^204:0$'
curl -sk -o /dev/null -X POST "$S/fresh?post"
curl -sk -o /dev/null -X POST "$S/fresh?post"
is "a POST is never answered from the cache" "$(calls POST /fresh?post)" "2"

echo "a change to a URL retires what was cached for it"
fetch /item --http1.1
fetch /item --http1.1
is "a GET for it is answered from the cache" "$(calls GET /item)" "1"
curl -sk -o /dev/null -X POST "$S/item"
fetch /item --http1.1
is "until a POST to it succeeds" "$(calls GET /item)" "2"
fetch /item --http1.1
is "and the response after that is cached in its place" "$(calls GET /item)" "2"
curl -sk -o /dev/null -X POST -H "X-Deny: 1" "$S/item"
fetch /item --http1.1
is "a POST the application refuses changes nothing" "$(calls GET /item)" "2"
curl -sk -o /dev/null --http2 -X DELETE "$S/item"
fetch /item --http1.1
is "a DELETE over HTTP/2 retires it too" "$(calls GET /item)" "3"
fetch "/item?other" --http1.1
curl -sk -o /dev/null -X PUT "$S/item"
fetch "/item?other" --http1.1
is "a different query string is a different URL" "$(calls GET /item?other)" "1"
curl -sk -o /dev/null "$S/slow-item" &
slow=$!
sleep 0.3
curl -sk -o /dev/null -X PUT "$S/slow-item"
wait "$slow"
fetch /slow-item --http1.1
is "a GET still being answered when a PUT succeeds is not cached" "$(calls GET /slow-item)" "2"

echo "what a response's age uses up"
fetch /aged --http1.1
fetch /aged --http1.1
is "one already older than its max-age is not kept" "$(calls GET /aged)" "2"
fetch /dated --http1.1
fetch /dated --http1.1
is "nor one whose Date is" "$(calls GET /dated)" "2"
fetch /half-aged --http1.1
fetch /half-aged --http1.1
is "one with some of its lifetime left is" "$(calls GET /half-aged)" "1"
like "served with the age it arrived with" "$(header age)" '^3[0-9]$'
ttl=$(header cache-status | sed -n 's/.*ttl=\([0-9]*\).*/\1/p')
if [ -n "$ttl" ] && [ "$ttl" -le 30 ]; then ok "and only what is left of its lifetime"
else bad "and only what is left of its lifetime" "a ttl of 30 or less" "${ttl:-none}"; fi

echo "conditional requests"
fetch /etag --http1.1
fetch /etag --http1.1
is "a copy with validators is cached" "$(calls GET /etag)" "1"
fetch /etag --http1.1 -H 'If-Match: "other"'
is "If-Match goes to the application, which refuses it" "$(status)" "412"
is "and is called for it" "$(calls GET /etag)" "2"
fetch /etag --http1.1
is "the next plain request still gets the copy" "$(status):$(calls GET /etag)" "200:2"
fetch /etag --http1.1 -H 'If-None-Match: "v1"'
is "a matching If-None-Match is answered 304" "$(status)" "304"
like "from the copy" "$(header cache-status)" '^garuda; hit'
is "with its ETag" "$(header etag)" '"v1"'
is "no Content-Length" "$(header content-length)" ""
# curl leaves its output file alone when no body arrives, so the size is what
# it counted, not what that file still holds from the request before.
is "and no body" \
    "$(curl -sk --http1.1 -o /dev/null -w '%{size_download}' -H 'If-None-Match: "v1"' "$S/etag")" "0"
fetch /etag --http2 -H 'If-None-Match: W/"v1"'
is "a weak one matches, over HTTP/2 too" "$(status)" "304"
fetch /etag --http1.1 -H 'If-None-Match: "v0"' -H 'If-None-Match: "v1"'
is "one split over two lines still matches" "$(status)" "304"
fetch /etag --http1.1 -H 'If-None-Match: "v0"'
like "a different ETag gets the whole copy" "$(status):$(header cache-status)" '^200:garuda; hit'
fetch /etag --http1.1 -H 'If-Modified-Since: Mon, 07 Nov 1994 00:00:00 GMT'
is "If-Modified-Since no earlier than Last-Modified is 304" "$(status)" "304"
fetch /etag --http1.1 -H 'If-Modified-Since: Sat, 05 Nov 1994 00:00:00 GMT'
is "and earlier is 200" "$(status)" "200"
fetch /etag --http1.1 -H 'If-Unmodified-Since: Sat, 05 Nov 1994 00:00:00 GMT'
is "If-Unmodified-Since goes to the application" "$(calls GET /etag)" "3"
fetch /etag --http1.1 -H 'If-Range: "v1"'
is "and so does If-Range" "$(calls GET /etag)" "4"
fetch /etag --http1.1 -H 'Accept-Encoding: gzip'
like "a copy compressed for the client" "$(header content-encoding):$(header cache-status)" '^gzip:garuda; hit'
is "sends its strong ETag weak" "$(header etag)" 'W/"v1"'
fetch /etag --http1.1 -H 'Accept-Encoding: gzip' -H 'If-None-Match: W/"v1"'
is "which revalidates" "$(status)" "304"
is "a 304 repeats the Vary its 200 has" "$(header vary)" "Accept-Encoding"
is "and the ETag" "$(header etag)" 'W/"v1"'
is "with no Content-Encoding" "$(header content-encoding)" ""
fetch /etag --http1.1 -H 'If-None-Match: "v1"'
is "a 304 for a client that takes the body plain says Vary too" "$(header vary)" "Accept-Encoding"
is "with the strong ETag" "$(header etag)" '"v1"'
fetch /etag --http2 -H 'Accept-Encoding: gzip' -H 'If-None-Match: W/"v1"'
is "and so does a 304 over HTTP/2" "$(status):$(header vary):$(header etag)" '304:accept-encoding:W/"v1"'
is "all without calling the application" "$(calls GET /etag)" "4"

echo "requests that keep out of the cache"
fetch "/fresh?auth" --http1.1 -H "Authorization: Bearer secret"
fetch "/fresh?auth" --http1.1
is "a response to a request with credentials is not stored" "$(calls GET /fresh?auth)" "2"
fetch "/fresh?auth" --http1.1 -H "Authorization: Bearer secret"
is "and such a request is not answered from what is" "$(calls GET /fresh?auth)" "3"
fetch "/fresh?cookie" --http1.1
fetch "/fresh?cookie" --http1.1 -H "Cookie: session=abc"
is "a request with a cookie reaches the application" "$(calls GET /fresh?cookie)" "2"
fetch /fresh --http1.1 -H "Cache-Control: no-cache"
is "so does a reload asking for a fresh copy" "$(calls GET /fresh)" "2"
fetch /fresh --http1.1 -H "Cache-Control: max-age=0"
is "and a browser's reload" "$(calls GET /fresh)" "3"

echo "expiry, metrics and reloads"
fetch /short --http1.1
fetch /short --http1.1
is "a copy is served while it is fresh" "$(calls GET /short)" "1"
sleep 1.6
fetch /short --http1.1
is "and not after" "$(calls GET /short)" "2"
hits=$(curl -s "http://127.0.0.1:$MPORT/metrics" | awk '/^garuda_cache_hits_total/ {print $2}')
like "hits are counted" "${hits:-0}" '^[1-9][0-9]*$'
fetch /maxage --http1.1
fetch /maxage --http1.1
is "max-age is enough to be kept" "$(calls GET /maxage)" "1"
kill -HUP "$SERVER_PID"
for _ in $(seq 1 60); do
    grep -q "reloading workers" "$WORK/server.log" && break
    sleep 0.1
done
sleep 2
fetch /maxage --http1.1
is "a reload discards what was cached" "$(calls GET /maxage)" "2"
server_stop

for model in inline pooled; do
    echo "WSGI, $model"
    if [ "$model" = pooled ]; then
        APP=cache_apps:wsgi_app start --cache-size 16 --compress --wsgi-threads 4
    else
        APP=cache_apps:wsgi_app start --cache-size 16 --compress
    fi
    fetch /fresh --http1.1
    first=$(cat "$WORK/body")
    fetch /fresh --http1.1
    is "a fresh WSGI response is served from the cache" "$(cat "$WORK/body")" "$first"
    like "and says so" "$(header cache-status)" '^garuda; hit'
    for _ in $(seq 1 12); do curl -sk -o /dev/null "$S/fresh"; done
    is "the application was called once" "$(calls GET /fresh)" "1"
    fetch /fresh --http2
    is "HTTP/2 gets the same copy" "$(cat "$WORK/body")" "$first"
    fetch /fresh --http1.1 -H "Accept-Encoding: gzip"
    is "compressed on the way out when asked" "$(gzip -dc < "$WORK/body")" "$first"
    fetch /stream --http1.1
    fetch /stream --http1.1
    is "an iterator's blocks are kept whole" "$(calls GET /stream)" "1"
    fetch /item --http1.1
    fetch /item --http1.1
    curl -sk -o /dev/null -X POST "$S/item"
    fetch /item --http1.1
    is "a POST retires the cached GET" "$(calls GET /item)" "2"
    for route in /write /short-length /cookie /big; do
        fetch "$route" --http1.1
        fetch "$route" --http1.1
        is "$route is not kept" "$(calls GET "$route")" "2"
    done
    server_stop
done

echo "without --cache-size"
start
fetch /fresh --http1.1
fetch /fresh --http1.1
is "every request reaches the application" "$(calls GET /fresh)" "2"
is "and nothing says otherwise" "$(header cache-status)" ""
server_stop

echo
echo "cache: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
