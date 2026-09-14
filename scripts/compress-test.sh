#!/usr/bin/env bash
# --compress and --compress-static: what is compressed, what is left alone, and
# that what arrives decodes to what the application sent.
#
#   bash scripts/compress-test.sh [path-to-peregrine]
#
# Most of the checks are about the decision rather than the codec. A server that
# compresses a PNG, compresses a body the application already encoded, strips a
# Content-Length it should have kept, or forgets Vary is wrong in ways a browser
# rarely shows and a cache in front of it always will.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8361}
TLS_PORT=${TLS_PORT:-8362}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
skip() { printf '  skip %s (%s)\n' "$1" "$2"; }

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

# A Python that can decode zstd, for the check that asks for zstd by name.
# 3.14 has it in the standard library; nothing older does.
ZPY=""
for candidate in python3.14 "$HOME"/.local/share/uv/python/cpython-3.14*-linux-x86_64-gnu/bin/python3.14; do
    if command -v "$candidate" >/dev/null 2>&1 \
        && "$candidate" -c 'import compression.zstd' 2>/dev/null; then
        ZPY=$candidate
        break
    fi
done

python3 "$HERE/compress_apps.py" > "$WORK/expected.txt"
EXPECTED=$(sha256sum < "$WORK/expected.txt" | cut -d' ' -f1)
digest() { sha256sum | cut -d' ' -f1; }

# Header value, lower-cased name match, CR stripped. Empty when absent.
header() { tr -d '\r' < "$1" | awk -v want="$2" 'BEGIN{IGNORECASE=1} tolower($0) ~ "^"want":" {sub(/^[^:]*: */, ""); print; exit}'; }
count_header() { tr -d '\r' < "$1" | grep -ci "^$2:"; }

wait_up() {
    for _ in $(seq 1 80); do
        curl -sS -k --max-time 1 -o /dev/null "$1" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

# fetch URL HEADERS-FILE [curl args...] -> body on stdout, raw
fetch() {
    local url=$1 hdr=$2
    shift 2
    curl -sS -k --max-time 20 -D "$hdr" "$@" "$url"
}

# -------------------------------------------------------------------------
# ASGI
# -------------------------------------------------------------------------
server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --log-level error --compress \
    --python-path "$HERE" compress_apps:asgi > "$WORK/asgi.log" 2>&1
wait_up "http://127.0.0.1:$PORT/" || { echo "server did not start"; cat "$WORK/asgi.log"; exit 1; }
H="http://127.0.0.1:$PORT"

echo "ASGI, HTTP/1.1"
is "curl --compressed decodes the body" "$(fetch $H/ $WORK/h --compressed | digest)" "$EXPECTED"
is "brotli is preferred when nothing is rated" "$(header $WORK/h content-encoding)" "br"
is "a compressed body has no Content-Length" "$(header $WORK/h content-length)" ""
is "a compressed body is chunked" "$(header $WORK/h transfer-encoding)" "chunked"
is "it says Vary: Accept-Encoding" "$(header $WORK/h vary)" "Accept-Encoding"

is "gzip on request decodes with gzip(1)" \
   "$(fetch $H/ $WORK/h -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
is "and is labelled gzip" "$(header $WORK/h content-encoding)" "gzip"

if [ -n "$ZPY" ]; then
    is "zstd on request decodes" \
       "$(fetch $H/ $WORK/h -H 'Accept-Encoding: zstd' \
          | "$ZPY" -c 'import sys, compression.zstd as z; sys.stdout.buffer.write(z.decompress(sys.stdin.buffer.read()))' \
          | digest)" "$EXPECTED"
    is "and is labelled zstd" "$(header $WORK/h content-encoding)" "zstd"
else
    skip "zstd on request decodes" "no Python with compression.zstd"
fi

is "q-values beat server preference" \
   "$(fetch $H/ $WORK/h -H 'Accept-Encoding: br;q=0.2, gzip;q=0.9' | gzip -dc | digest)" "$EXPECTED"
is "q=0 refuses a coding" \
   "$(fetch $H/ $WORK/h -H 'Accept-Encoding: br;q=0, zstd;q=0, gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"
is "Accept-Encoding split over two lines is one list" \
   "$(fetch $H/ $WORK/h -H 'Accept-Encoding: identity' -H 'Accept-Encoding: gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"

fetch $H/ $WORK/h -o $WORK/b > /dev/null
is "no Accept-Encoding, no encoding" "$(header $WORK/h content-encoding)" ""
is "no Accept-Encoding, still Vary" "$(header $WORK/h vary)" "Accept-Encoding"
is "no Accept-Encoding, body is plain" "$(digest < $WORK/b)" "$EXPECTED"

is "a declared length is compressed too" "$(fetch $H/declared $WORK/h --compressed | digest)" "$EXPECTED"
is "and its Content-Length is dropped" "$(header $WORK/h content-length)" ""

fetch $H/small $WORK/h --compressed -o $WORK/b > /dev/null
is "a small declared body is left alone" "$(header $WORK/h content-encoding)" ""
is "and keeps its Content-Length" "$(header $WORK/h content-length)" "4"

fetch $H/png $WORK/h --compressed -o /dev/null > /dev/null
is "an image is not compressed" "$(header $WORK/h content-encoding)" ""
is "and does not Vary" "$(header $WORK/h vary)" ""

is "an already encoded body passes through untouched" \
   "$(fetch $H/encoded $WORK/h -H 'Accept-Encoding: gzip, br' | gzip -dc | digest)" "$EXPECTED"
is "with the application's own Content-Encoding" "$(header $WORK/h content-encoding)" "gzip"

fetch $H/no-transform $WORK/h --compressed -o /dev/null > /dev/null
is "no-transform is honoured" "$(header $WORK/h content-encoding)" ""

fetch $H/events $WORK/h --compressed -o /dev/null > /dev/null
is "an event stream is not compressed" "$(header $WORK/h content-encoding)" ""

fetch $H/vary $WORK/h --compressed -o /dev/null > /dev/null
is "the application's own Vary is not repeated" "$(count_header $WORK/h vary)" "1"

# A strong ETag names the application's bytes, and compressed bytes are others.
fetch $H/etag $WORK/h -H 'Accept-Encoding: gzip' -o /dev/null > /dev/null
is "a compressed body's strong ETag is sent weak" "$(header $WORK/h etag)" 'W/"v1"'
is "once" "$(count_header $WORK/h etag)" "1"
fetch $H/etag $WORK/h -o /dev/null > /dev/null
is "a body sent plain keeps it strong" "$(header $WORK/h etag)" '"v1"'
fetch $H/weak-etag $WORK/h -H 'Accept-Encoding: gzip' -o /dev/null > /dev/null
is "a weak ETag is left as it is" "$(header $WORK/h etag)" 'W/"v1"'

curl -sS --max-time 10 -I --compressed $H/ > $WORK/h
is "HEAD is not encoded" "$(header $WORK/h content-encoding)" ""

is "a body sent in pieces decodes" "$(fetch $H/pieces $WORK/h --compressed | digest)" "$EXPECTED"

# Each message is flushed through the compressor, so the first piece arrives
# while the application is still asleep rather than when the response ends.
FIRST=$(python3 - "$PORT" <<'PY'
import http.client, sys, time, zlib
conn = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=10)
start = time.monotonic()
conn.request("GET", "/stream", headers={"Accept-Encoding": "gzip"})
resp = conn.getresponse()
d = zlib.decompressobj(16 + zlib.MAX_WBITS)
seen = b""
while b"line 0 " not in seen:
    chunk = resp.read1(65536)
    if not chunk:
        break
    seen += d.decompress(chunk)
print("early" if b"line 0 " in seen and time.monotonic() - start < 1.2 else "late")
PY
)
is "a streamed piece is readable before the stream ends" "$FIRST" "early"
is "and the whole stream decodes" "$(fetch $H/stream $WORK/h --compressed | digest)" "$EXPECTED"

is "keep-alive carries several compressed responses" \
   "$(curl -sS --max-time 20 --compressed \
        -o /dev/null -w '%{http_code}' $H/ \
        -o /dev/null -w '%{http_code}' $H/pieces \
        -o /dev/null -w '%{http_code}' $H/small)" "200200200"

is "HTTP/1.0 is compressed and delimited by the close" \
   "$(fetch $H/ $WORK/h -0 --compressed | digest)" "$EXPECTED"

server_stop

# -------------------------------------------------------------------------
# WSGI, inline and on a thread pool
# -------------------------------------------------------------------------
for mode in inline pool; do
    extra=""
    [ "$mode" = pool ] && extra="--wsgi-threads 4"
    # shellcheck disable=SC2086 -- deliberate word splitting of $extra.
    server_start "$BIN" --port "$PORT" --log-level error --compress $extra \
        --python-path "$HERE" compress_apps:wsgi > "$WORK/wsgi-$mode.log" 2>&1
    wait_up "http://127.0.0.1:$PORT/" || { echo "server did not start"; cat "$WORK/wsgi-$mode.log"; exit 1; }
    echo "WSGI, $mode"
    is "$mode: a list decodes" "$(fetch $H/list $WORK/h --compressed | digest)" "$EXPECTED"
    is "$mode: and is brotli" "$(header $WORK/h content-encoding)" "br"
    is "$mode: a generator decodes" "$(fetch $H/gen $WORK/h -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
    is "$mode: write() then a return value decodes" "$(fetch $H/write $WORK/h --compressed | digest)" "$EXPECTED"
    fetch $H/small $WORK/h --compressed -o /dev/null > /dev/null
    is "$mode: a short list keeps its computed length" "$(header $WORK/h content-length)" "4"
    fetch $H/png $WORK/h --compressed -o /dev/null > /dev/null
    is "$mode: an image is left alone" "$(header $WORK/h content-encoding)" ""
    fetch $H/etag $WORK/h -H 'Accept-Encoding: gzip' -o /dev/null > /dev/null
    is "$mode: a compressed body's strong ETag is sent weak" "$(header $WORK/h etag)" 'W/"v1"'
    is "$mode: keep-alive carries compressed responses" \
       "$(curl -sS --max-time 20 --compressed \
            -o /dev/null -w '%{http_code}' $H/list \
            -o /dev/null -w '%{http_code}' $H/gen \
            -o /dev/null -w '%{http_code}' $H/write)" "200200200"
    server_stop
done

# -------------------------------------------------------------------------
# HTTP/2 over TLS, both protocols
# -------------------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/s.key" -out "$WORK/s.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
HS="https://127.0.0.1:$TLS_PORT"
for app in asgi wsgi; do
    server_start "$BIN" --port "$TLS_PORT" --log-level error --compress \
        --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
        --python-path "$HERE" compress_apps:$app > "$WORK/h2-$app.log" 2>&1
    wait_up "$HS/" || { echo "server did not start"; cat "$WORK/h2-$app.log"; exit 1; }
    echo "$app over HTTP/2"
    path=/
    [ "$app" = wsgi ] && path=/gen
    is "$app h2: the body decodes" "$(fetch $HS$path $WORK/h --http2 --compressed | digest)" "$EXPECTED"
    is "$app h2: it went over HTTP/2" "$(head -1 $WORK/h | tr -d '\r' | cut -d' ' -f1)" "HTTP/2"
    is "$app h2: and is brotli" "$(header $WORK/h content-encoding)" "br"
    is "$app h2: with no content-length" "$(header $WORK/h content-length)" ""
    fetch $HS/etag $WORK/h --http2 -H 'Accept-Encoding: gzip' -o /dev/null > /dev/null
    is "$app h2: a compressed body's strong ETag is sent weak" "$(header $WORK/h etag)" 'W/"v1"'
    if [ "$app" = asgi ]; then
        is "asgi h2: pieces decode" "$(fetch $HS/pieces $WORK/h --http2 --compressed | digest)" "$EXPECTED"
    fi
    server_stop
done

# -------------------------------------------------------------------------
# --compress-static
# -------------------------------------------------------------------------
mkdir -p "$WORK/assets"
cp "$WORK/expected.txt" "$WORK/assets/site.css"
gzip -9 -c "$WORK/expected.txt" > "$WORK/assets/site.css.gz"
# The server does not read what it serves, so a marker stands in for brotli.
printf 'BROTLI-SIDECAR' > "$WORK/assets/site.css.br"
cp "$WORK/expected.txt" "$WORK/assets/plain.css"
printf 'png' > "$WORK/assets/logo.png"

server_start "$BIN" --port "$TLS_PORT" --log-level error --compress-static \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
    --static-dir "/static=$WORK/assets" \
    --python-path "$HERE" compress_apps:wsgi > "$WORK/static.log" 2>&1
wait_up "$HS/" || { echo "server did not start"; cat "$WORK/static.log"; exit 1; }
echo "pre-compressed static files"

for proto in http1.1 http2; do
    is "$proto: brotli copy is served" \
       "$(fetch $HS/static/site.css $WORK/h --$proto -H 'Accept-Encoding: gzip, br')" "BROTLI-SIDECAR"
    is "$proto: labelled br" "$(header $WORK/h content-encoding)" "br"
    is "$proto: with Vary" "$(header $WORK/h vary | tr 'A-Z' 'a-z')" "accept-encoding"
    is "$proto: gzip copy decodes" \
       "$(fetch $HS/static/site.css $WORK/h --$proto -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
    is "$proto: and has the copy's length" "$(header $WORK/h content-length)" "$(stat -c %s "$WORK/assets/site.css.gz")"
done

ETAG_BR=$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: br' -o /dev/null; header $WORK/h etag)
ETAG_PLAIN=$(fetch $HS/static/site.css $WORK/h -o /dev/null; header $WORK/h etag)
case "$ETAG_BR" in *-br\") ok "the brotli copy has its own ETag ($ETAG_BR)";; *) bad "the brotli copy has its own ETag" '"...-br"' "$ETAG_BR";; esac
is "the plain file still says Vary" "$(header $WORK/h vary | tr 'A-Z' 'a-z')" "accept-encoding"
is "the brotli ETag revalidates" \
   "$(curl -sS -k -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: br' -H "If-None-Match: $ETAG_BR" $HS/static/site.css)" "304"
is "the plain ETag does not match the brotli copy" \
   "$(curl -sS -k -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: br' -H "If-None-Match: $ETAG_PLAIN" $HS/static/site.css)" "200"

fetch $HS/static/plain.css $WORK/h -H 'Accept-Encoding: br, gzip' -o $WORK/b > /dev/null
is "a file with no copy is served plain" "$(header $WORK/h content-encoding)" ""
is "and whole" "$(digest < $WORK/b)" "$EXPECTED"
fetch $HS/static/logo.png $WORK/h -H 'Accept-Encoding: br, gzip' -o /dev/null > /dev/null
is "an image with no copy does not Vary" "$(header $WORK/h vary)" ""
is "without --compress the application is not compressed" \
   "$(fetch $HS/list $WORK/h --compressed -o /dev/null; header $WORK/h content-encoding)" ""
server_stop

echo
echo "compression: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
