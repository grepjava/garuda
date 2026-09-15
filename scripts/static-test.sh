#!/usr/bin/env bash
# --static-dir: what it serves, what it refuses, and what it leaves alone.
#
#   bash scripts/static-test.sh [path-to-garuda]
#
# The interesting half is the refusals. A static route is a path from a URL to
# the filesystem, so the checks that matter are the ones where it must not
# reach: `..`, a symlink pointing out of the tree, a sibling directory that
# merely shares a prefix, and anything that is not a regular file. What is
# refused falls through to the built-in router, which answers 404 for anything
# it has no route for; /user/:id, which answers with the id, shows that a path
# outside the static prefix reaches it. The last section repeats the essentials
# over TLS and HTTP/2.
#
# Needs the release build (or GARUDA, or the path as the first argument), curl,
# openssl, and python3 for picking free ports and setting file times to the
# nanosecond. PORT and TLS_PORT override the ports.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

# N ports nothing is listening on, chosen by the kernel while all N sockets are
# held open, so no two of them can come back the same.
free_ports() {
    python3 -c 'import socket, sys
socks = [socket.socket() for _ in range(int(sys.argv[1]))]
for s in socks: s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])' "$1"
}

BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
read -r FREE_PORT FREE_TLS_PORT <<< "$(free_ports 2)"
PORT=${PORT:-$FREE_PORT}
TLS_PORT=${TLS_PORT:-$FREE_TLS_PORT}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

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
# Symlinks that stay inside the tree are served, whether they are written
# relative or absolute; one to a directory outside it is not.
ln -s deep/nested.txt        "$WORK/assets/inside-relative.txt"
ln -s "$WORK/assets/site.css" "$WORK/assets/inside-absolute.css"
ln -s ../secret              "$WORK/assets/up"
# A file big enough that sendfile has to loop and the socket buffer fills.
head -c 3000000 /dev/urandom > "$WORK/assets/big.bin"
# Either side of the size below which a file goes out with its head.
head -c 16384 /dev/urandom   > "$WORK/assets/inline.bin"
head -c 16385 /dev/urandom   > "$WORK/assets/sendfile.bin"

server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level error \
    --static-dir "/static=$WORK/assets" \
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
is "a file sent with its head is byte-identical" \
   "$(curl -sS --max-time 10 $H/static/inline.bin | cmp -s - "$WORK/assets/inline.bin" && echo same)" "same"
is "a file one byte too big for that is too" \
   "$(curl -sS --max-time 10 $H/static/sendfile.bin | cmp -s - "$WORK/assets/sendfile.bin" && echo same)" "same"
is "a relative symlink inside the tree is served" "$(body $H/static/inside-relative.txt)" "deep"
is "an absolute symlink inside the tree is served" \
   "$(body $H/static/inside-absolute.css)" "body { color: red }"

# --- conditional requests ------------------------------------------------
ETAG=$(curl -sS -I --max-time 10 $H/static/site.css | tr -d '\r' | awk '/^[Ee][Tt][Aa][Gg]:/ {print $2}')
if [ -n "$ETAG" ]; then ok "an ETag is sent ($ETAG)"; else bad "an ETag is sent" "a tag" "none"; fi
is "a matching ETag is 304"       "$(code -H "If-None-Match: $ETAG" $H/static/site.css)" "304"
is "a wildcard ETag is 304"       "$(code -H 'If-None-Match: *' $H/static/site.css)"     "304"
is "a stale ETag is 200"          "$(code -H 'If-None-Match: \"nope\"' $H/static/site.css)" "200"
is "a 304 carries no body"        "$(curl -sS -o /dev/null -w '%{size_download}' -H "If-None-Match: $ETAG" $H/static/site.css)" "0"
is "If-None-Match split over two lines still matches" \
   "$(code -H 'If-None-Match: "nope"' -H "If-None-Match: $ETAG" $H/static/site.css)" "304"
is "a matching If-Match is 200"   "$(code -H "If-Match: $ETAG" $H/static/site.css)" "200"
is "If-Match: * is 200"           "$(code -H 'If-Match: *' $H/static/site.css)" "200"
is "a stale If-Match is 412"      "$(code -H 'If-Match: "nope"' $H/static/site.css)" "412"
is "a weak If-Match never matches" "$(code -H "If-Match: W/$ETAG" $H/static/site.css)" "412"
is "If-Match split over two lines still matches" \
   "$(code -H 'If-Match: "nope"' -H "If-Match: $ETAG" $H/static/site.css)" "200"
is "a failed If-Match wins over a matching If-None-Match" \
   "$(code -H 'If-Match: "nope"' -H "If-None-Match: $ETAG" $H/static/site.css)" "412"
is "a 412 has no body and keeps the connection" \
   "$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}:%{size_download} ' -H 'If-Match: "nope"' $H/static/site.css \
        --next -o /dev/null -w '%{http_code}:%{num_connects}' $H/static/app.js)" "412:0 200:0"

# A file rewritten in place at the same size, within the same second, is a
# different file. With the tag built from whole seconds it kept the old tag,
# and a client holding that tag was told 304 for bytes it had never seen.
# The times are set explicitly (python, since touch's fractional -d is GNU's).
etag_of() { curl -sS -I --max-time 10 "$1" | tr -d '\r' | awk '/^[Ee][Tt][Aa][Gg]:/ {print $2}'; }
set_mtime_ns() { python3 -c 'import os, sys; os.utime(sys.argv[1], ns=(int(sys.argv[2]),) * 2)' "$1" "$2"; }
printf 'aaaa' > "$WORK/assets/rewritten.txt"
set_mtime_ns "$WORK/assets/rewritten.txt" 1700000000100000000
ETAG_BEFORE=$(etag_of $H/static/rewritten.txt)
printf 'bbbb' > "$WORK/assets/rewritten.txt"
set_mtime_ns "$WORK/assets/rewritten.txt" 1700000000600000000
ETAG_AFTER=$(etag_of $H/static/rewritten.txt)
if [ -n "$ETAG_BEFORE" ] && [ "$ETAG_BEFORE" != "$ETAG_AFTER" ]; then
    ok "a same-size rewrite within a second gets a new ETag"
else
    bad "a same-size rewrite within a second gets a new ETag" "two different tags" "$ETAG_BEFORE then $ETAG_AFTER"
fi
is "and the old ETag no longer matches" \
   "$(code -H "If-None-Match: $ETAG_BEFORE" $H/static/rewritten.txt)" "200"

# --- refusals ------------------------------------------------------------
# Each of these must fall through to the router, which has no route for them
# and answers 404, rather than being served from disk.
is "dot-dot does not escape"         "$(code --path-as-is $H/static/../secret/passwd)" "404"
is "encoded dot-dot does not escape" "$(code --path-as-is $H/static/%2e%2e/secret/passwd)" "404"
is "a symlink out of the tree is refused" "$(code $H/static/escape.txt)" "404"
is "a symlinked directory out of the tree is refused" "$(code $H/static/up/passwd)" "404"
is "a sibling sharing the prefix is refused" "$(code $H/staticky/leak.txt)" "404"
is "a directory is not served"       "$(code $H/static/deep)"        "404"
is "the route root is not served"    "$(code $H/static/)"            "404"
is "a missing file reaches the router" "$(code $H/static/nothing.css)" "404"
is "another path reaches the router" "$(body $H/user/42)" "42"
is "POST to a real file reaches the router" "$(code -X POST $H/static/site.css)" "404"

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
server_require_port_free "$TLS_PORT" || exit 1
server_start "$BIN" --port "$TLS_PORT" --workers 2 --log-level error \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
    --static-dir "/static=$WORK/assets" \
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
is "a stale If-Match over HTTP/2 is 412" \
   "$(curl -sS -k --http2 -o /dev/null -w '%{http_code}' --max-time 10 -H 'If-Match: "nope"' $HS/static/site.css)" "412"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
