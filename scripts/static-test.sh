#!/usr/bin/env bash
# --static-dir: what it serves, what it refuses, and what it leaves alone.
#
#   bash scripts/static-test.sh [path-to-peregrine]
#
# The interesting half is the refusals. A static route is a path from a URL to
# the filesystem, so the checks that matter are the ones where it must not
# reach: `..`, a symlink pointing out of the tree, a sibling directory that
# merely shares a prefix, and anything that is not a regular file.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8351}
TLS_PORT=${TLS_PORT:-8352}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

mkdir -p "$WORK/assets/deep" "$WORK/secret" "$WORK/assets-sibling"
echo "body { color: red }"   > "$WORK/assets/site.css"
echo "console.log(1)"        > "$WORK/assets/app.js"
echo "deep"                  > "$WORK/assets/deep/nested.txt"
echo "TOP SECRET"            > "$WORK/secret/passwd"
echo "sibling"               > "$WORK/assets-sibling/leak.txt"
printf 'binary\0data'        > "$WORK/assets/blob.bin"
ln -s "$WORK/secret/passwd"  "$WORK/assets/escape.txt"
# A file big enough that sendfile has to loop and the socket buffer fills.
head -c 3000000 /dev/urandom > "$WORK/assets/big.bin"

server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level error \
    --static-dir "/static=$WORK/assets" \
    --python-path "$ROOT/examples" wsgi_app:application \
    > "$WORK/server.log" 2>&1

for _ in $(seq 1 60); do
    curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.2
done
H="http://127.0.0.1:$PORT"

code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }
body() { curl -sS --max-time 10 "$@"; }
ctype() { curl -sS -o /dev/null -w '%{content_type}' --max-time 10 "$@"; }

# --- serving -------------------------------------------------------------
is "a file is served"             "$(body $H/static/site.css)"  "body { color: red }"
is "a nested file is served"      "$(body $H/static/deep/nested.txt)" "deep"
is "css gets its media type"      "$(ctype $H/static/site.css)" "text/css; charset=utf-8"
is "js gets its media type"       "$(ctype $H/static/app.js)"   "text/javascript; charset=utf-8"
is "an unknown type is a download" "$(ctype $H/static/blob.bin)" "application/octet-stream"
is "HEAD gets the headers only"   "$(curl -sS -I -o /dev/null -w '%{http_code}:%{size_download}' $H/static/site.css)" "200:0"

# A response larger than any socket buffer: sendfile has to be resumed on
# writability, which is the part that a single small file never exercises.
is "a 3MB file arrives whole"     "$(curl -sS --max-time 30 $H/static/big.bin | wc -c)" "3000000"
is "a 3MB file is byte-identical" \
   "$(curl -sS --max-time 30 $H/static/big.bin | cmp -s - "$WORK/assets/big.bin" && echo same)" "same"

# --- conditional requests ------------------------------------------------
ETAG=$(curl -sS -I --max-time 10 $H/static/site.css | tr -d '\r' | awk '/^[Ee][Tt][Aa][Gg]:/ {print $2}')
if [ -n "$ETAG" ]; then ok "an ETag is sent ($ETAG)"; else bad "an ETag is sent" "a tag" "none"; fi
is "a matching ETag is 304"       "$(code -H "If-None-Match: $ETAG" $H/static/site.css)" "304"
is "a wildcard ETag is 304"       "$(code -H 'If-None-Match: *' $H/static/site.css)"     "304"
is "a stale ETag is 200"          "$(code -H 'If-None-Match: \"nope\"' $H/static/site.css)" "200"
is "a 304 carries no body"        "$(curl -sS -o /dev/null -w '%{size_download}' -H "If-None-Match: $ETAG" $H/static/site.css)" "0"

# --- refusals ------------------------------------------------------------
# Each of these must reach the application, which answers 404, rather than
# being served from disk.
is "dot-dot does not escape"         "$(code --path-as-is $H/static/../secret/passwd)" "404"
is "encoded dot-dot does not escape" "$(code --path-as-is $H/static/%2e%2e/secret/passwd)" "404"
is "a symlink out of the tree is refused" "$(code $H/static/escape.txt)" "404"
is "a sibling sharing the prefix is refused" "$(code $H/staticky/leak.txt)" "404"
is "a directory is not served"       "$(code $H/static/deep)"        "404"
is "the route root is not served"    "$(code $H/static/)"            "404"
is "a missing file reaches the app"  "$(code $H/static/nothing.css)" "404"
is "another path reaches the app"    "$(body $H/)"  "hello from peregrine"
is "POST to a real file reaches the app" "$(code -X POST $H/static/site.css)" "404"

# --- keep-alive ----------------------------------------------------------
is "keep-alive survives a static file" \
   "$(curl -sS --max-time 10 \
        -o /dev/null -w '%{http_code} ' $H/static/site.css \
        -o /dev/null -w '%{http_code} ' $H/static/app.js \
        -o /dev/null -w '%{http_code}'  $H/)" \
   "200200200"

server_stop

# --- over TLS ------------------------------------------------------------
# sendfile cannot encrypt, so TLS takes the read-and-buffer path. It has to
# produce the same bytes.
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/s.key" -out "$WORK/s.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
server_start "$BIN" --port "$TLS_PORT" --workers 2 --log-level error \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
    --static-dir "/static=$WORK/assets" \
    --python-path "$ROOT/examples" wsgi_app:application \
    > "$WORK/tls.log" 2>&1
for _ in $(seq 1 60); do
    curl -sS -k --max-time 1 -o /dev/null "https://127.0.0.1:$TLS_PORT/" 2>/dev/null && break
    sleep 0.2
done
HS="https://127.0.0.1:$TLS_PORT"
is "a file is served over TLS" "$(curl -sS -k --max-time 10 $HS/static/site.css)" "body { color: red }"
is "a 3MB file over TLS is byte-identical" \
   "$(curl -sS -k --max-time 60 $HS/static/big.bin | cmp -s - "$WORK/assets/big.bin" && echo same)" "same"
is "a 3MB file over HTTP/2 is byte-identical" \
   "$(curl -sS -k --http2 --max-time 60 $HS/static/big.bin | cmp -s - "$WORK/assets/big.bin" && echo same)" "same"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
