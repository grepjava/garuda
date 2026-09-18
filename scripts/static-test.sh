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

# --- byte ranges ---------------------------------------------------------
# A range has to be right on every path the bytes can take out of the server:
# read into the head for a small file, sendfile for a big one, and the write
# buffer for TLS and HTTP/2 further down.
range_of() { curl -sS --max-time 10 -H "Range: $1" "$2"; }
range_head() { curl -sS -I --max-time 10 -H "Range: $1" "$2" | tr -d '\r'; }

is "a range is 206"            "$(code -H 'Range: bytes=0-3' $H/static/site.css)" "206"
is "and carries those bytes"   "$(range_of 'bytes=0-3' $H/static/site.css)" "body"
is "a range in the middle"     "$(range_of 'bytes=7-11' $H/static/site.css)" "color"
is "an open range is the rest" "$(range_of 'bytes=7-' $H/static/site.css)" "color: red }"
is "a suffix is the end"       "$(range_of 'bytes=-8' $H/static/site.css)" ": red }"
is "Content-Range says where it came from" \
   "$(range_head 'bytes=0-3' $H/static/site.css | awk '/^[Cc]ontent-[Rr]ange:/ {print $2, $3}')" \
   "bytes 0-3/20"
is "Content-Length is the range" \
   "$(range_head 'bytes=0-3' $H/static/site.css | awk '/^[Cc]ontent-[Ll]ength:/ {print $2}')" "4"
is "Accept-Ranges is advertised" \
   "$(curl -sS -I --max-time 10 $H/static/site.css | tr -d '\r' | awk '/^[Aa]ccept-[Rr]anges:/ {print $2}')" "bytes"
is "a range past the end is 416" "$(code -H 'Range: bytes=9999-' $H/static/site.css)" "416"
is "and says how big the file is" \
   "$(range_head 'bytes=9999-' $H/static/site.css | awk '/^[Cc]ontent-[Rr]ange:/ {print $2, $3}')" "bytes */20"
is "a range that is not one is the whole file" \
   "$(range_of 'bytes=nonsense' $H/static/site.css)" "body { color: red }"
is "several ranges are answered whole" \
   "$(range_of 'bytes=0-3,7-11' $H/static/site.css)" "body { color: red }"
is "a HEAD with a range is 206 with no body" \
   "$(curl -sS -I --max-time 10 -o /dev/null -w '%{http_code}:%{size_download}' -H 'Range: bytes=0-3' $H/static/site.css)" \
   "206:0"

# The two paths a body takes in the clear, byte for byte against the file.
is "a range of a file sent with its head" \
   "$(range_of 'bytes=100-199' $H/static/inline.bin | cmp -s - <(dd if="$WORK/assets/inline.bin" bs=1 skip=100 count=100 2>/dev/null) && echo same)" "same"
is "a range of a file sent with sendfile" \
   "$(range_of 'bytes=1000-1999' $H/static/sendfile.bin | cmp -s - <(dd if="$WORK/assets/sendfile.bin" bs=1 skip=1000 count=1000 2>/dev/null) && echo same)" "same"
is "a range at the very end of a big file" \
   "$(range_of 'bytes=-16' $H/static/big.bin | cmp -s - <(tail -c 16 "$WORK/assets/big.bin") && echo same)" "same"

# If-Range: the range, but only while the client's copy is still current.
is "If-Range with the current tag is 206" \
   "$(code -H "If-Range: $ETAG" -H 'Range: bytes=0-3' $H/static/site.css)" "206"
is "If-Range with a stale tag is the whole file" \
   "$(code -H 'If-Range: "nope"' -H 'Range: bytes=0-3' $H/static/site.css)" "200"
is "and a stale If-Range sends every byte" \
   "$(curl -sS --max-time 10 -H 'If-Range: "nope"' -H 'Range: bytes=0-3' $H/static/site.css)" "body { color: red }"
is "a weak If-Range never matches" \
   "$(code -H "If-Range: W/$ETAG" -H 'Range: bytes=0-3' $H/static/site.css)" "200"
is "a 304 wins over a range" \
   "$(code -H "If-None-Match: $ETAG" -H 'Range: bytes=0-3' $H/static/site.css)" "304"

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

# --- directories ---------------------------------------------------------
# Off by default: a directory falls through to the router, as it always has.
# With --static-index it is answered by its index.html, and with
# --static-listing one without an index is listed.
mkdir -p "$WORK/assets/pages/inner" "$WORK/assets/listed/sub"
echo "<h1>Index</h1>"     > "$WORK/assets/pages/index.html"
echo "inner"              > "$WORK/assets/pages/inner/deep.txt"
echo "one"                > "$WORK/assets/listed/one.txt"
printf 'x%.0s' $(seq 1 2048) > "$WORK/assets/listed/two.bin"
echo "hidden"             > "$WORK/assets/listed/.hidden"
ln -s "$WORK/secret"      "$WORK/assets/listed/out"

server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level error \
    --static-dir "/static=$WORK/assets" --static-listing \
    > "$WORK/dir.log" 2>&1
H="http://127.0.0.1:$PORT"

is "a directory with an index serves it"   "$(body $H/static/pages/)" "<h1>Index</h1>"
is "and without the slash redirects to it" "$(code $H/static/pages)" "301"
is "the redirect points at the slash" \
   "$(curl -sS -I --max-time 10 $H/static/pages | tr -d '\r' | awk '/^[Ll]ocation:/ {print $2}')" \
   "/static/pages/"
is "a query survives the redirect" \
   "$(curl -sS -I --max-time 10 "$H/static/pages?a=1" | tr -d '\r' | awk '/^[Ll]ocation:/ {print $2}')" \
   "/static/pages/?a=1"

is "a directory with no index is listed" "$(code $H/static/listed/)" "200"
is "the listing is HTML" \
   "$(curl -sS -I --max-time 10 $H/static/listed/ | tr -d '\r' | awk '/^[Cc]ontent-[Tt]ype:/ {print $2, $3}')" \
   "text/html; charset=utf-8"
is "it names the files"      "$(body $H/static/listed/ | grep -c 'one.txt')" "1"
is "it names the directories" "$(body $H/static/listed/ | grep -c 'sub/')" "1"
is "it says how big a file is" "$(body $H/static/listed/ | grep -c '2.0 kB')" "1"
is "it has a link to the parent" "$(body $H/static/listed/ | grep -c 'href="../"')" "1"
is "a dotfile is not listed"  "$(body $H/static/listed/ | grep -c 'hidden')" "0"
is "a symlink out of the tree is not listed" "$(body $H/static/listed/ | grep -c '>out<')" "0"
is "and is not served through the listing" "$(code $H/static/listed/out/passwd)" "404"
is "a listing is not cached" \
   "$(curl -sS -I --max-time 10 $H/static/listed/ | tr -d '\r' | awk '/^[Cc]ache-[Cc]ontrol:/ {print $2}')" \
   "no-store"
is "a HEAD of a listing has no body" \
   "$(curl -sS -I --max-time 10 -o /dev/null -w '%{http_code}:%{size_download}' $H/static/listed/)" "200:0"
is "dot-dot cannot walk out of a listing" "$(code --path-as-is $H/static/listed/../../secret/)" "404"
is "a file is still served with listings on" "$(body $H/static/site.css)" "body { color: red }"
is "a missing directory still reaches the router" "$(code $H/static/nothing/)" "404"
is "a listing over HTTP/2 is the same" \
   "$(curl -sS --http2-prior-knowledge --max-time 10 $H/static/listed/ | grep -c 'one.txt')" "1"

server_stop

# --- an index without listings -------------------------------------------
server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level error \
    --static-dir "/static=$WORK/assets" --static-index \
    > "$WORK/index.log" 2>&1
is "an index is served"                  "$(body $H/static/pages/)" "<h1>Index</h1>"
is "a directory without one is not listed" "$(code $H/static/listed/)" "404"

server_stop

# --- neither flag --------------------------------------------------------
server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level error \
    --static-dir "/static=$WORK/assets" \
    > "$WORK/plain.log" 2>&1
is "a directory is not served by default"    "$(code $H/static/pages/)" "404"
is "not even one with an index"              "$(code $H/static/pages)" "404"
is "and the route root is still not served"  "$(code $H/static/)" "404"

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
is "a range over TLS is 206 with the right bytes" \
   "$(curl -sS -k --max-time 10 -H 'Range: bytes=7-11' $HS/static/site.css)" "color"
is "a range of a big file over TLS is byte-identical" \
   "$(curl -sS -k --max-time 60 -H 'Range: bytes=1048576-2097151' $HS/static/big.bin | cmp -s - <(dd if="$WORK/assets/big.bin" bs=1048576 skip=1 count=1 2>/dev/null) && echo same)" "same"
is "a range over HTTP/2 is 206" \
   "$(curl -sS -k --http2 -o /dev/null -w '%{http_code}' --max-time 10 -H 'Range: bytes=7-11' $HS/static/site.css)" "206"
is "and carries the right bytes" \
   "$(curl -sS -k --http2 --max-time 10 -H 'Range: bytes=7-11' $HS/static/site.css)" "color"
is "a range of a big file over HTTP/2 is byte-identical" \
   "$(curl -sS -k --http2 --max-time 60 -H 'Range: bytes=1048576-2097151' $HS/static/big.bin | cmp -s - <(dd if="$WORK/assets/big.bin" bs=1048576 skip=1 count=1 2>/dev/null) && echo same)" "same"
is "a range past the end over HTTP/2 is 416" \
   "$(curl -sS -k --http2 -o /dev/null -w '%{http_code}' --max-time 10 -H 'Range: bytes=99999999-' $HS/static/site.css)" "416"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
