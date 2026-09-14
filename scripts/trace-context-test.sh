#!/usr/bin/env bash
# --trace-context: a W3C traceparent recorded in the access log, never made up
# and never changed on its way to the application.
#
#   bash scripts/trace-context-test.sh [path-to-garuda]
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--free-threaded".
set -u

BIN=${1:-${GARUDA:-$HOME/pgbuild/debug/garuda}}
PORT=${PORT:-8252}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${GARUDA_EXTRA_ARGS:-})
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

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
mkdir -p "$WORK/static"
echo "body { color: red }" > "$WORK/static/site.css"

S="https://127.0.0.1:$PORT"
TRACE=4bf92f3577b34da6a3ce929d0e0e4736
PARENT=00f067aa0ba902b7
GOOD="00-$TRACE-$PARENT-01"

start() {
    local app=$1
    shift
    server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
        --static-dir "/static=$WORK/static" "${EXTRA[@]}" "$@" \
        --python-path "$HERE" "$app" > "$WORK/server.log" 2>&1
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "$S/ready" && return 0
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
start trace_context_apps:asgi_app --trace-context --access-log
get /good --http1.1 -H "traceparent: $GOOD"
has "the text line has the trace ID and the parent span" "$(line_for /good)" \
    "trace=$TRACE span=$PARENT"
is "the application sees the header unchanged" "$(cat "$WORK/body")" "n=1 tp=$GOOD"
get /good-h2 --http2 -H "traceparent: $GOOD"
has "over HTTP/2 as well" "$(line_for /good-h2)" "trace=$TRACE span=$PARENT"
get /static/site.css --http1.1 -H "traceparent: $GOOD"
has "a static file's line has it too" "$(line_for /static/site.css)" "trace=$TRACE"
get /later-version --http1.1 -H "traceparent: 01-$TRACE-$PARENT-01-future"
has "a later version with more fields is read" "$(line_for /later-version)" "trace=$TRACE"
get /none --http1.1
lacks "a request without one gets none" "$(line_for /none)" "trace="

get /upper --http1.1 -H "traceparent: 00-${TRACE^^}-$PARENT-01"
lacks "uppercase hex is not a traceparent" "$(line_for /upper)" "trace="
get /zero-trace --http1.1 -H "traceparent: 00-00000000000000000000000000000000-$PARENT-01"
lacks "an all-zero trace ID is ignored" "$(line_for /zero-trace)" "trace="
get /zero-parent --http1.1 -H "traceparent: 00-$TRACE-0000000000000000-01"
lacks "an all-zero parent ID is ignored" "$(line_for /zero-parent)" "trace="
get /version-ff --http1.1 -H "traceparent: ff-$TRACE-$PARENT-01"
lacks "version ff is ignored" "$(line_for /version-ff)" "trace="
get /long-00 --http1.1 -H "traceparent: $GOOD-extra"
lacks "version 00 with anything after the flags is ignored" "$(line_for /long-00)" "trace="
get /short --http1.1 -H "traceparent: 00-$TRACE-$PARENT"
lacks "a truncated one is ignored" "$(line_for /short)" "trace="
get /two --http1.1 -H "traceparent: $GOOD" -H "traceparent: 00-$TRACE-1111111111111111-01"
lacks "two traceparents are ignored" "$(line_for /two)" "trace="
is "and the application still gets both, as sent" "$(cat "$WORK/body")" \
    "n=2 tp=$GOOD,00-$TRACE-1111111111111111-01"
server_stop

echo "JSON and WSGI"
start trace_context_apps:wsgi_app --trace-context --access-log --access-log-format json \
    --request-id
get /json --http1.1 -H "traceparent: $GOOD"
line=$(line_for /json)
has "the JSON line has trace_id" "$line" "\"trace_id\":\"$TRACE\""
has "and parent_id" "$line" "\"parent_id\":\"$PARENT\""
has "beside the request ID" "$line" "\"request_id\":"
is "the WSGI application sees the header unchanged" "$(cat "$WORK/body")" "n=1 tp=$GOOD"
get /json-none --http1.1
lacks "a JSON line without one has no trace_id" "$(line_for /json-none)" "trace_id"
server_stop

echo "without --trace-context"
start trace_context_apps:asgi_app --access-log
get /off --http1.1 -H "traceparent: $GOOD"
lacks "nothing is recorded" "$(line_for /off)" "trace="
is "and the header still reaches the application" "$(cat "$WORK/body")" "n=1 tp=$GOOD"
server_stop

echo
echo "trace context: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
