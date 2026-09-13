#!/usr/bin/env bash
# --request-id: an X-Request-ID for every request, given to the application,
# echoed on the response and written to the access log.
#
#   bash scripts/request-id-test.sh [path-to-peregrine]
#
# PEREGRINE_EXTRA_ARGS adds flags, e.g. "--free-threaded".
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8251}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${PEREGRINE_EXTRA_ARGS:-})
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
    local app=$1
    shift
    server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
        --static-dir "/static=$WORK/static" "${EXTRA[@]}" "$@" \
        --python-path "$HERE" "$app" > "$WORK/server.log" 2>&1
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
# What the application said it was handed: "n=1 id=...".
app_saw() { cat "$WORK/body"; }

server_require_port_free "$PORT" || exit 1

echo "an ID for every request"
start request_id_apps:asgi_app --request-id --access-log
fetch --http1.1 "$S/"
first=$(response_ids)
like "the response carries a UUID" "$first" "$UUID"
is "the application was handed the same one, once" "$(app_saw)" "n=1 id=$first"
fetch --http1.1 "$S/"
second=$(response_ids)
if [ -n "$second" ] && [ "$second" != "$first" ]; then
    ok "the next request gets a different one"
else
    bad "the next request gets a different one" "not $first" "$second"
fi
fetch --http2 "$S/"
h2=$(response_ids)
like "HTTP/2 responses carry one too" "$h2" "$UUID"
is "and the application sees it" "$(app_saw)" "n=1 id=$h2"
fetch --http1.1 "$S/static/site.css"
like "a static file carries one" "$(response_ids)" "$UUID"
fetch --http1.1 "$S/own-id"
is "an application's own X-Request-ID is kept, not doubled" "$(response_ids)" "from-the-app"
fetch --http1.1 -H "X-Request-ID: client-chosen-id" "$S/"
replaced=$(response_ids)
like "an ID from a client that is not a trusted proxy is replaced" "$replaced" "$UUID"
is "and the application sees only the replacement" "$(app_saw)" "n=1 id=$replaced"
sleep 0.3
if grep -q "$first" "$WORK/server.log"; then
    ok "the access log has the ID"
else
    bad "the access log has the ID" "$first in the log" "$(grep -m1 'GET /' "$WORK/server.log")"
fi
server_stop

echo "behind a trusted proxy"
start request_id_apps:asgi_app --request-id --forwarded-allow-ips 127.0.0.1
fetch --http1.1 -H "X-Request-ID: proxy-7f3a.42" "$S/"
is "the proxy's ID is kept" "$(response_ids)" "proxy-7f3a.42"
is "and reaches the application" "$(app_saw)" "n=1 id=proxy-7f3a.42"
fetch --http1.1 -H "X-Request-ID: has spaces in it" "$S/"
like "one with characters an ID should not have is replaced" "$(response_ids)" "$UUID"
long=$(printf 'a%.0s' $(seq 1 200))
fetch --http1.1 -H "X-Request-ID: $long" "$S/"
like "and so is one too long to be an ID" "$(response_ids)" "$UUID"
server_stop

echo "WSGI"
start request_id_apps:wsgi_app --request-id --access-log --access-log-format json
fetch --http1.1 "$S/"
wid=$(response_ids)
like "a WSGI response carries a UUID" "$wid" "$UUID"
is "and HTTP_X_REQUEST_ID matches it" "$(app_saw)" "n=1 id=$wid"
fetch --http2 -H "X-Request-ID: client-chosen-id" "$S/"
wid2=$(response_ids)
is "a client's ID is replaced in the environ too" "$(app_saw)" "n=1 id=$wid2"
fetch --http1.1 "$S/own-id"
is "a WSGI application's own X-Request-ID is kept" "$(response_ids)" "from-the-app"
sleep 0.3
if grep -q "\"request_id\":\"$wid\"" "$WORK/server.log"; then
    ok "the JSON access log has a request_id field"
else
    bad "the JSON access log has a request_id field" "\"request_id\":\"$wid\"" \
        "$(grep -m1 '"method"' "$WORK/server.log")"
fi
server_stop

start request_id_apps:wsgi_app --request-id --wsgi-threads 4
fetch --http1.1 "$S/"
pid=$(response_ids)
like "a pooled WSGI response carries one" "$pid" "$UUID"
is "and the pooled application sees it" "$(app_saw)" "n=1 id=$pid"
server_stop

echo "without --request-id"
start request_id_apps:asgi_app
fetch --http1.1 -H "X-Request-ID: client-chosen-id" "$S/"
is "nothing is added to the response" "$(response_ids)" ""
is "and the client's header reaches the application untouched" "$(app_saw)" "n=1 id=client-chosen-id"
server_stop

echo
echo "request id: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
