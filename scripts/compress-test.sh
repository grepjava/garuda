#!/usr/bin/env bash
# --compress-static: which pre-compressed copy of a --static-dir file a client
# is sent, what the response says about it, and that what arrives decodes to
# the file.
#
#   bash scripts/compress-test.sh [path-to-garuda]
#
# The server defaults to the repo build, .build/release/garuda. It needs curl,
# gzip and openssl. Every body here is a file and every encoding a copy made
# beside it: the built-in router answers with nothing a compressor would take,
# so --compress has no response of its own to act on.
#
# Most of the checks are about the decision rather than the codec. A server that
# ignores a q-value, sends a copy the client refused, reuses one ETag for two
# representations, or forgets Vary is wrong in ways a browser rarely shows and a
# cache in front of it always will.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
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
