#!/usr/bin/env bash
# --request-id: an X-Request-ID for every request, echoed on the response and
# written to the access log.
#
#   bash scripts/request-id-test.sh [path-to-garuda]
#
# Served by the built-in router over TLS, with a static file beside it, so the
# only requirements are the release binary, curl and openssl. What the
# application is handed cannot be seen from here: the router does not echo
# request headers.
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--workers 4".
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
PORT=${PORT:-19311}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${GARUDA_EXTRA_ARGS:-})
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
like() { if echo "$2" | grep -Eq "$3"; then ok "$1"; else bad "$1" "/$3/" "$2"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
mkdir -p "$WORK/static"
echo "body { color: red }" > "$WORK/static/site.css"

UUID='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
S="https://127.0.0.1:$PORT"

start() {
    server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
        --static-dir "/static=$WORK/static" "${EXTRA[@]}" "$@" \
        > "$WORK/server.log" 2>&1
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "$S/" && return 0
        sleep 0.1
    done
    echo "server did not start:"
    cat "$WORK/server.log"
    exit 1
}

# Fetches a URL and leaves the response head in $WORK/head and the body in
# $WORK/body.
fetch() {
    curl -sk --max-time 5 -D "$WORK/head" -o "$WORK/body" "$@"
    tr -d '\r' < "$WORK/head" > "$WORK/head.txt"
}
# The X-Request-ID values on the last response, one per line.
response_ids() { grep -i '^x-request-id:' "$WORK/head.txt" | sed 's/^[^:]*: *//'; }

server_require_port_free "$PORT" || exit 1

echo "an ID for every request"
start --request-id --access-log
fetch --http1.1 "$S/"
first=$(response_ids)
like "the response carries a UUID" "$first" "$UUID"
fetch --http1.1 "$S/"
second=$(response_ids)
if [ -n "$second" ] && [ "$second" != "$first" ]; then
    ok "the next request gets a different one"
else
    bad "the next request gets a different one" "not $first" "$second"
fi
fetch --http2 "$S/user/7"
like "HTTP/2 responses carry one too" "$(response_ids)" "$UUID"
fetch --http1.1 "$S/static/site.css"
like "a static file carries one" "$(response_ids)" "$UUID"
fetch --http1.1 -H "X-Request-ID: client-chosen-id" "$S/"
like "an ID from a client that is not a trusted proxy is replaced" "$(response_ids)" "$UUID"
sleep 0.3
if grep -q "$first" "$WORK/server.log"; then
    ok "the access log has the ID"
else
    bad "the access log has the ID" "$first in the log" "$(grep -m1 'GET /' "$WORK/server.log")"
fi
server_stop

echo "behind a trusted proxy"
start --request-id --forwarded-allow-ips 127.0.0.1
fetch --http1.1 -H "X-Request-ID: proxy-7f3a.42" "$S/"
is "the proxy's ID is kept" "$(response_ids)" "proxy-7f3a.42"
fetch --http1.1 -H "X-Request-ID: has spaces in it" "$S/"
like "one with characters an ID should not have is replaced" "$(response_ids)" "$UUID"
long=$(printf 'a%.0s' $(seq 1 200))
fetch --http1.1 -H "X-Request-ID: $long" "$S/"
like "and so is one too long to be an ID" "$(response_ids)" "$UUID"
server_stop

echo "JSON access log"
start --request-id --access-log --access-log-format json
fetch --http2 -H "X-Request-ID: client-chosen-id" "$S/user/json"
jid=$(response_ids)
like "a client's ID is replaced over HTTP/2 as well" "$jid" "$UUID"
sleep 0.3
if grep -q "\"request_id\":\"$jid\"" "$WORK/server.log"; then
    ok "the JSON access log has a request_id field"
else
    bad "the JSON access log has a request_id field" "\"request_id\":\"$jid\"" \
        "$(grep -m1 '"method"' "$WORK/server.log")"
fi
server_stop

echo "without --request-id"
start
fetch --http1.1 -H "X-Request-ID: client-chosen-id" "$S/"
is "nothing is added to the response" "$(response_ids)" ""
server_stop

echo
echo "request id: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
