#!/usr/bin/env bash
# --compress and --compress-static: what is compressed, what is left alone,
# what the response says about it, and that what arrives decodes to what the
# handler or the file holds.
#
#   bash scripts/compress-test.sh [path-to-garuda] [path-to-garuda-conformance]
#
# The servers default to the repo builds in .build/release. It needs curl, gzip,
# python3 and openssl. --compress acts on garuda-conformance's /compress routes,
# one per case; --compress-static on files and the copies made beside them.
#
# Most of the checks are about the decision rather than the codec. A server that
# ignores a q-value, sends a copy the client refused, reuses one ETag for two
# representations, or forgets Vary is wrong in ways a browser rarely shows and a
# cache in front of it always will.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
CONFORMANCE=${2:-${CONFORMANCE:-$ROOT/.build/release/garuda-conformance}}
PORT=${PORT:-19461}
TLS_PORT=${TLS_PORT:-19462}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

awk 'BEGIN { for (i = 0; i < 2000; i++) printf "line %d of a compressible response\n", i }' \
    > "$WORK/expected.txt"
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

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/s.key" -out "$WORK/s.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
HS="https://127.0.0.1:$TLS_PORT"

# -------------------------------------------------------------------------
# --compress, on handler responses
# -------------------------------------------------------------------------

server_require_port_free "$PORT" || exit 1
server_start "$CONFORMANCE" --port "$PORT" --log-level error --compress > "$WORK/h1.log" 2>&1
wait_up "http://127.0.0.1:$PORT/compress/text" || { echo "server did not start"; cat "$WORK/h1.log"; exit 1; }
H="http://127.0.0.1:$PORT/compress"

echo "--compress, HTTP/1.1"
is "curl --compressed decodes the body" "$(fetch $H/text $WORK/h --compressed | digest)" "$EXPECTED"
is "brotli is preferred when nothing is rated" "$(header $WORK/h content-encoding)" "br"
is "a whole body states its compressed length" "$(header $WORK/h content-length)" \
   "$(curl -sS --max-time 10 -H 'Accept-Encoding: br' $H/text | wc -c | tr -d ' ')"
is "and is not chunked" "$(header $WORK/h transfer-encoding)" ""
is "it says Vary: Accept-Encoding" "$(header $WORK/h vary)" "Accept-Encoding"
is "gzip on request decodes with gzip(1)" \
   "$(fetch $H/text $WORK/h -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
is "and is labelled gzip" "$(header $WORK/h content-encoding)" "gzip"
is "zstd on request is labelled zstd" \
   "$(fetch $H/text $WORK/h -H 'Accept-Encoding: zstd' -o /dev/null; header $WORK/h content-encoding)" "zstd"
is "q-values beat server preference" \
   "$(fetch $H/text $WORK/h -H 'Accept-Encoding: br;q=0.2, gzip;q=0.9' | gzip -dc | digest)" "$EXPECTED"
is "q=0 refuses a coding" \
   "$(fetch $H/text $WORK/h -H 'Accept-Encoding: br;q=0, zstd;q=0, gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"
is "Accept-Encoding split over two lines is one list" \
   "$(fetch $H/text $WORK/h -H 'Accept-Encoding: identity' -H 'Accept-Encoding: gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"

fetch $H/text $WORK/h -o $WORK/b > /dev/null
is "no Accept-Encoding, no encoding" "$(header $WORK/h content-encoding)" ""
is "no Accept-Encoding, still Vary" "$(header $WORK/h vary)" "Accept-Encoding"
is "no Accept-Encoding, body is plain" "$(digest < $WORK/b)" "$EXPECTED"

is "a declared length is compressed too" "$(fetch $H/declared $WORK/h --compressed | digest)" "$EXPECTED"
is "and the length stated is the compressed one" "$(header $WORK/h content-length)" \
   "$(curl -sS --max-time 10 -H 'Accept-Encoding: br' $H/declared | wc -c | tr -d ' ')"
fetch $H/small $WORK/h --compressed -o $WORK/b > /dev/null
is "a small body is left alone" "$(header $WORK/h content-encoding)" ""
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
curl -sS --max-time 10 -I --compressed $H/text > $WORK/h
is "HEAD is not encoded" "$(header $WORK/h content-encoding)" ""
is "but says Vary as the GET does" "$(header $WORK/h vary)" "Accept-Encoding"

is "a body streamed in pieces decodes" "$(fetch $H/pieces $WORK/h --compressed | digest)" "$EXPECTED"
is "and is brotli, chunked, with no length" "$(header $WORK/h content-encoding):$(header $WORK/h transfer-encoding):$(header $WORK/h content-length)" "br:chunked:"
# Each write is flushed through the compressor, so the first piece arrives
# while the handler still sleeps rather than when the response ends.
FIRST=$(python3 - "$PORT" <<'PY'
import http.client, sys, time, zlib
conn = http.client.HTTPConnection("127.0.0.1", int(sys.argv[1]), timeout=10)
start = time.monotonic()
conn.request("GET", "/compress/stream", headers={"Accept-Encoding": "gzip"})
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
is "and the whole stream decodes" "$(fetch $H/stream $WORK/h -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
is "keep-alive carries several compressed responses" \
   "$(curl -sS --max-time 20 --compressed \
        -o /dev/null -w '%{http_code}' $H/text \
        -o /dev/null -w '%{http_code}' $H/pieces \
        -o /dev/null -w '%{http_code}' $H/small \
        -o /dev/null -w '%{http_code}' $H/text)" "200200200200"
is "HTTP/1.0 is compressed" "$(fetch $H/text $WORK/h -0 --compressed | digest)" "$EXPECTED"
is "HTTP/1.0 streamed is delimited by the close" "$(fetch $H/pieces $WORK/h -0 --compressed | digest)" "$EXPECTED"
is "and is still compressed" "$(header $WORK/h content-encoding)" "br"
server_stop

server_start "$CONFORMANCE" --port "$PORT" --log-level error > "$WORK/off.log" 2>&1
wait_up "http://127.0.0.1:$PORT/compress/text" || { echo "server did not start"; cat "$WORK/off.log"; exit 1; }
fetch $H/text $WORK/h --compressed -o /dev/null > /dev/null
is "without --compress nothing is encoded" "$(header $WORK/h content-encoding)" ""
is "and nothing says Vary" "$(header $WORK/h vary)" ""
server_stop

server_require_port_free "$TLS_PORT" || exit 1
server_start "$CONFORMANCE" --port "$TLS_PORT" --log-level error --compress \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" > "$WORK/h2.log" 2>&1
wait_up "$HS/compress/text" || { echo "server did not start"; cat "$WORK/h2.log"; exit 1; }
echo "--compress, HTTP/2"
is "h2: the body decodes" "$(fetch $HS/compress/text $WORK/h --http2 --compressed | digest)" "$EXPECTED"
is "h2: it went over HTTP/2" "$(head -1 $WORK/h | tr -d '\r' | cut -d' ' -f1)" "HTTP/2"
is "h2: and is brotli" "$(header $WORK/h content-encoding)" "br"
is "h2: with its compressed length" "$(header $WORK/h content-length)" \
   "$(curl -sS -k --http2 --max-time 10 -H 'Accept-Encoding: br' $HS/compress/text | wc -c | tr -d ' ')"
fetch $HS/compress/etag $WORK/h --http2 -H 'Accept-Encoding: gzip' -o /dev/null > /dev/null
is "h2: a compressed body's strong ETag is sent weak" "$(header $WORK/h etag)" 'W/"v1"'
is "h2: pieces decode" "$(fetch $HS/compress/pieces $WORK/h --http2 --compressed | digest)" "$EXPECTED"
is "h2: compressed, with no content-length" "$(header $WORK/h content-encoding):$(header $WORK/h content-length)" "br:"
server_stop

mkdir -p "$WORK/assets"
cp "$WORK/expected.txt" "$WORK/assets/site.css"
gzip -9 -c "$WORK/expected.txt" > "$WORK/assets/site.css.gz"
# The server does not read what it serves, so markers stand in for brotli and
# zstd, and which copy was chosen is plain from the body.
printf 'BROTLI-SIDECAR' > "$WORK/assets/site.css.br"
printf 'ZSTD-SIDECAR' > "$WORK/assets/site.css.zst"
cp "$WORK/expected.txt" "$WORK/assets/plain.css"
printf 'png' > "$WORK/assets/logo.png"

server_require_port_free "$TLS_PORT" || exit 1
server_start "$BIN" --port "$TLS_PORT" --log-level error --compress-static \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" \
    --static-dir "/static=$WORK/assets" > "$WORK/static.log" 2>&1
wait_up "$HS/" || { echo "server did not start"; cat "$WORK/static.log"; exit 1; }

echo "pre-compressed static files"
for proto in http1.1 http2; do
    is "$proto: brotli copy is served" \
       "$(fetch $HS/static/site.css $WORK/h --$proto -H 'Accept-Encoding: gzip, br')" "BROTLI-SIDECAR"
    # curl falls back to HTTP/1.1 without a word when h2 is not agreed, which
    # would make the second pass a copy of the first.
    [ "$proto" = http2 ] && \
        is "http2: it went over HTTP/2" "$(head -1 $WORK/h | tr -d '\r' | cut -d' ' -f1)" "HTTP/2"
    is "$proto: labelled br" "$(header $WORK/h content-encoding)" "br"
    is "$proto: with Vary" "$(header $WORK/h vary | tr 'A-Z' 'a-z')" "accept-encoding"
    is "$proto: gzip copy decodes" \
       "$(fetch $HS/static/site.css $WORK/h --$proto -H 'Accept-Encoding: gzip' | gzip -dc | digest)" "$EXPECTED"
    is "$proto: and has the copy's length" "$(header $WORK/h content-length)" "$(stat -c %s "$WORK/assets/site.css.gz")"
done

echo "negotiation"
is "brotli is preferred when nothing is rated" \
   "$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: gzip, zstd, br' -o /dev/null; header $WORK/h content-encoding)" "br"
is "zstd on request is the zstd copy" \
   "$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: zstd')" "ZSTD-SIDECAR"
is "and is labelled zstd" "$(header $WORK/h content-encoding)" "zstd"
is "q-values beat server preference" \
   "$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: br;q=0.2, gzip;q=0.9' | gzip -dc | digest)" "$EXPECTED"
is "q=0 refuses a coding" \
   "$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: br;q=0, zstd;q=0, gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"
is "Accept-Encoding split over two lines is one list" \
   "$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: identity' -H 'Accept-Encoding: gzip' -o /dev/null; header $WORK/h content-encoding)" "gzip"

fetch $HS/static/site.css $WORK/h -o $WORK/b > /dev/null
is "no Accept-Encoding, no encoding" "$(header $WORK/h content-encoding)" ""
is "no Accept-Encoding, still Vary" "$(header $WORK/h vary | tr 'A-Z' 'a-z')" "accept-encoding"
is "no Accept-Encoding, body is plain" "$(digest < $WORK/b)" "$EXPECTED"

is "keep-alive carries several pre-compressed responses" \
   "$(curl -sS -k --max-time 20 -H 'Accept-Encoding: gzip, br' \
        -o /dev/null -w '%{http_code}' $HS/static/site.css \
        -o /dev/null -w '%{http_code}' $HS/static/plain.css \
        -o /dev/null -w '%{http_code}' $HS/static/site.css)" "200200200"

echo "validators"
ETAG_BR=$(fetch $HS/static/site.css $WORK/h -H 'Accept-Encoding: br' -o /dev/null; header $WORK/h etag)
ETAG_PLAIN=$(fetch $HS/static/site.css $WORK/h -o /dev/null; header $WORK/h etag)
case "$ETAG_BR" in *-br\") ok "the brotli copy has its own ETag ($ETAG_BR)";; *) bad "the brotli copy has its own ETag" '"...-br"' "$ETAG_BR";; esac
is "the plain file still says Vary" "$(header $WORK/h vary | tr 'A-Z' 'a-z')" "accept-encoding"
is "the brotli ETag revalidates" \
   "$(curl -sS -k -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: br' -H "If-None-Match: $ETAG_BR" $HS/static/site.css)" "304"
is "the plain ETag does not match the brotli copy" \
   "$(curl -sS -k -o /dev/null -w '%{http_code}' -H 'Accept-Encoding: br' -H "If-None-Match: $ETAG_PLAIN" $HS/static/site.css)" "200"

echo "files with no copy"
fetch $HS/static/plain.css $WORK/h -H 'Accept-Encoding: br, gzip' -o $WORK/b > /dev/null
is "a file with no copy is served plain" "$(header $WORK/h content-encoding)" ""
is "and whole" "$(digest < $WORK/b)" "$EXPECTED"
fetch $HS/static/logo.png $WORK/h -H 'Accept-Encoding: br, gzip' -o /dev/null > /dev/null
is "an image with no copy does not Vary" "$(header $WORK/h vary)" ""
server_stop

echo
echo "compression: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
