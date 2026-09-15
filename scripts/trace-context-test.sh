#!/usr/bin/env bash
# --trace-context: a W3C traceparent recorded in the access log, and never made
# up.
#
#   bash scripts/trace-context-test.sh [path-to-garuda]
#
# Served by the built-in router over TLS, with a static file beside it, so the
# only requirements are the release binary, curl and openssl. Each request goes
# to its own GET /user/:id path so that its access line can be picked out.
# Whether the header reaches the application unchanged cannot be seen from
# here: the router does not echo request headers.
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--workers 4".
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
PORT=${PORT:-19321}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${GARUDA_EXTRA_ARGS:-})
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
mkdir -p "$WORK/static"
echo "body { color: red }" > "$WORK/static/site.css"

S="https://127.0.0.1:$PORT"
TRACE=4bf92f3577b34da6a3ce929d0e0e4736
PARENT=00f067aa0ba902b7
GOOD="00-$TRACE-$PARENT-01"

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

# get PATH [curl options...]: the body of PATH, left in $WORK/body.
get() {
    local path=$1
    shift
    curl -sk --max-time 5 -o "$WORK/body" "$@" "$S$path"
}
# The access line for PATH, once the log has caught up.
line_for() {
    local line=""
    for _ in $(seq 1 30); do
        line=$(grep -F "GET $1 " "$WORK/server.log" | head -1)
        [ -n "$line" ] && break
        line=$(grep -F "\"target\":\"$1\"" "$WORK/server.log" | head -1)
        [ -n "$line" ] && break
        sleep 0.1
    done
    printf '%s' "$line"
}
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "contains $3" "$2" ;; esac; }
# An empty line means the request was never logged, which proves nothing.
lacks() {
    if [ -z "$2" ]; then bad "$1" "an access line without $3" "no access line"; return; fi
    case "$2" in *"$3"*) bad "$1" "no $3" "$2" ;; *) ok "$1" ;; esac
}

server_require_port_free "$PORT" || exit 1

echo "a traceparent in the access log"
start --trace-context --access-log
get /user/good --http1.1 -H "traceparent: $GOOD"
has "the text line has the trace ID and the parent span" "$(line_for /user/good)" \
    "trace=$TRACE span=$PARENT"
get /user/good-h2 --http2 -H "traceparent: $GOOD"
has "over HTTP/2 as well" "$(line_for /user/good-h2)" "trace=$TRACE span=$PARENT"
get /static/site.css --http1.1 -H "traceparent: $GOOD"
has "a static file's line has it too" "$(line_for /static/site.css)" "trace=$TRACE"
get /user/later-version --http1.1 -H "traceparent: 01-$TRACE-$PARENT-01-future"
has "a later version with more fields is read" "$(line_for /user/later-version)" "trace=$TRACE"
get /user/none --http1.1
lacks "a request without one gets none" "$(line_for /user/none)" "trace="

get /user/upper --http1.1 -H "traceparent: 00-${TRACE^^}-$PARENT-01"
lacks "uppercase hex is not a traceparent" "$(line_for /user/upper)" "trace="
get /user/zero-trace --http1.1 -H "traceparent: 00-00000000000000000000000000000000-$PARENT-01"
lacks "an all-zero trace ID is ignored" "$(line_for /user/zero-trace)" "trace="
get /user/zero-parent --http1.1 -H "traceparent: 00-$TRACE-0000000000000000-01"
lacks "an all-zero parent ID is ignored" "$(line_for /user/zero-parent)" "trace="
get /user/version-ff --http1.1 -H "traceparent: ff-$TRACE-$PARENT-01"
lacks "version ff is ignored" "$(line_for /user/version-ff)" "trace="
get /user/long-00 --http1.1 -H "traceparent: $GOOD-extra"
lacks "version 00 with anything after the flags is ignored" "$(line_for /user/long-00)" "trace="
get /user/short --http1.1 -H "traceparent: 00-$TRACE-$PARENT"
lacks "a truncated one is ignored" "$(line_for /user/short)" "trace="
get /user/two --http1.1 -H "traceparent: $GOOD" -H "traceparent: 00-$TRACE-1111111111111111-01"
lacks "two traceparents are ignored" "$(line_for /user/two)" "trace="
server_stop

echo "JSON"
start --trace-context --access-log --access-log-format json --request-id
get /user/json --http1.1 -H "traceparent: $GOOD"
line=$(line_for /user/json)
has "the JSON line has trace_id" "$line" "\"trace_id\":\"$TRACE\""
has "and parent_id" "$line" "\"parent_id\":\"$PARENT\""
has "beside the request ID" "$line" "\"request_id\":"
get /user/json-none --http1.1
lacks "a JSON line without one has no trace_id" "$(line_for /user/json-none)" "trace_id"
server_stop

echo "without --trace-context"
start --access-log
get /user/off --http1.1 -H "traceparent: $GOOD"
lacks "nothing is recorded" "$(line_for /user/off)" "trace="
server_stop

echo
echo "trace context: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
