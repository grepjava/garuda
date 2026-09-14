#!/usr/bin/env bash
# --redirect-http and --hsts.
#
#   bash scripts/redirect-test.sh [path-to-garuda]
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--free-threaded".
set -u

BIN=${1:-${GARUDA:-$HOME/pgbuild/debug/garuda}}
PORT=${PORT:-8243}
RPORT=${RPORT:-8280}
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

start() {
    local app=$1
    shift
    server_start "$BIN" --port "$PORT" --workers 2 --log-level warning \
        --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
        --static-dir "/static=$WORK/static" "${EXTRA[@]}" "$@" \
        --python-path "$HERE" "$app" > "$WORK/server.log" 2>&1
    for _ in $(seq 1 100); do
        curl -sk -o /dev/null "https://127.0.0.1:$PORT/" && return 0
        sleep 0.1
    done
    echo "server did not start:"
    cat "$WORK/server.log"
    exit 1
}

# The value of one response header, lower-cased name, from a plain request.
redirect() {
    curl -s -o /dev/null -w '%{http_code} %header{location}' --max-time 5 "$@"
}
# How many Strict-Transport-Security headers a TLS response carried, and the
# first one's value: "1 max-age=31536000".
hsts() {
    local head
    head=$(curl -sk --max-time 5 -D - -o /dev/null "$@" | tr -d '\r')
    printf '%s %s' "$(echo "$head" | grep -ci '^strict-transport-security:')" \
        "$(echo "$head" | grep -i '^strict-transport-security:' | head -1 | sed 's/^[^:]*: *//')"
}

server_require_port_free "$PORT" || exit 1
server_require_port_free "$RPORT" || exit 1

echo "redirecting plain HTTP"
start hsts_apps:asgi_app --redirect-http "$RPORT" --hsts 31536000
R="http://127.0.0.1:$RPORT"
is "a GET is sent to https, path and query kept" \
   "$(redirect -H 'Host: example.com' "$R/a/b?x=1&y=%20")" \
   "301 https://example.com:$PORT/a/b?x=1&y=%20"
is "a HEAD is a 301 too" "$(redirect -I -H 'Host: example.com' "$R/")" "301 https://example.com:$PORT/"
is "a POST is a 308, so the method and body survive" \
   "$(redirect -X POST -d 'x=1' -H 'Host: example.com' "$R/form")" "308 https://example.com:$PORT/form"
is "the port in Host is replaced by the TLS port" \
   "$(redirect -H 'Host: example.com:80' "$R/")" "301 https://example.com:$PORT/"
is "an IPv6 literal keeps its brackets" \
   "$(redirect -H 'Host: [2001:db8::1]:80' "$R/")" "301 https://[2001:db8::1]:$PORT/"
is "a request with no Host is refused" "$(redirect -0 -H 'Host:' "$R/")" "400 "
is "a Host that is not a host name is refused" "$(redirect -H 'Host: evil.com/x' "$R/")" "400 "
is "an absolute-form target supplies the host" \
   "$(curl -s -o /dev/null -w '%{http_code} %header{location}' --max-time 5 \
        --request-target 'http://example.org/p?q' "$R/")" "301 https://example.org:$PORT/p?q"
head=$(curl -s -D - -o /dev/null -H 'Host: example.com' "$R/" | tr -d '\r')
is "the redirect closes the connection" "$(echo "$head" | grep -ci '^connection: close')" 1
is "and has an empty body" "$(echo "$head" | grep -i '^content-length:' | sed 's/^[^:]*: *//')" 0
is "and carries no HSTS, which a browser ignores over plain HTTP" \
   "$(echo "$head" | grep -ci '^strict-transport-security:')" 0

exec 3<>"/dev/tcp/127.0.0.1/$RPORT"
printf 'GET /slow HTTP/1.1\r\n' >&3
sleep 0.4
printf 'Host: example.com\r\n\r\n' >&3
line=$(head -1 <&3 | tr -d '\r')
exec 3<&-
is "a request that arrives in two pieces is answered whole" "$line" "HTTP/1.1 301 Moved Permanently"

echo "HSTS on TLS responses"
S="https://127.0.0.1:$PORT"
is "an ASGI response over HTTP/1.1 carries it" "$(hsts --http1.1 "$S/")" "1 max-age=31536000"
is "over HTTP/2 too" "$(hsts --http2 "$S/")" "1 max-age=31536000"
is "an application's own value is kept, not doubled" "$(hsts --http1.1 "$S/own-hsts")" "1 max-age=60"
is "and not doubled over HTTP/2" "$(hsts --http2 "$S/own-hsts")" "1 max-age=60"
is "a static file carries it" "$(hsts --http1.1 "$S/static/site.css")" "1 max-age=31536000"
is "a static file over HTTP/2 carries it" "$(hsts --http2 "$S/static/site.css")" "1 max-age=31536000"
server_stop

start hsts_apps:wsgi_app --hsts 600
is "a WSGI response over HTTP/1.1 carries it" "$(hsts --http1.1 "$S/")" "1 max-age=600"
is "over HTTP/2 too" "$(hsts --http2 "$S/")" "1 max-age=600"
is "a WSGI application's own value is kept, not doubled" "$(hsts --http1.1 "$S/own-hsts")" "1 max-age=60"
is "and not doubled over HTTP/2" "$(hsts --http2 "$S/own-hsts")" "1 max-age=60"
server_stop

start hsts_apps:wsgi_app --hsts 600 --wsgi-threads 4
is "a pooled WSGI response carries it" "$(hsts --http1.1 "$S/")" "1 max-age=600"
is "and a pooled one over HTTP/2" "$(hsts --http2 "$S/own-hsts")" "1 max-age=60"
server_stop

start hsts_apps:asgi_app
is "without --hsts there is none" "$(hsts --http1.1 "$S/")" "0 "
server_stop

echo "refused configurations"
"$BIN" --port "$PORT" --redirect-http "$RPORT" hsts_apps:asgi_app > "$WORK/bad.log" 2>&1
is "--redirect-http without TLS is refused" "$?" 2
"$BIN" --port "$PORT" --hsts 600 hsts_apps:asgi_app > "$WORK/bad.log" 2>&1
is "--hsts without TLS is refused" "$?" 2
"$BIN" --port "$PORT" --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
    --redirect-http "$PORT" hsts_apps:asgi_app > "$WORK/bad.log" 2>&1
is "--redirect-http on the TLS port itself is refused" "$?" 2

echo
echo "redirect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
