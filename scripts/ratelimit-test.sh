#!/usr/bin/env bash
# --rate-limit: who counts as a client, and that the count is the server's
# rather than each worker's.
#
#   bash scripts/ratelimit-test.sh [path-to-peregrine]
#
# The check that matters most is the multi-worker one. Each worker has its own
# accept queue and a client's connections are spread across them by the
# kernel, so a limit kept per worker lets a client through N times over. The
# rates here are per minute, so nothing refills while a check is running and
# the counts come out exact.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8381}
TLS_PORT=${TLS_PORT:-8382}
METRICS_PORT=${METRICS_PORT:-8383}
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

H="http://127.0.0.1:$PORT"

start() {
    server_start "$BIN" --port "$PORT" --log-level error "$@" \
        --python-path "$ROOT/examples" wsgi_app:application > "$WORK/server.log" 2>&1
    for _ in $(seq 1 80); do
        # The probe path is exempt, so waiting on it spends nothing.
        curl -sS --max-time 1 -o /dev/null "$H/healthz" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server did not start"; cat "$WORK/server.log"; exit 1
}

# N requests, each on its own connection; prints the status codes run together.
codes() {
    local n=$1
    shift
    local out=""
    for _ in $(seq 1 "$n"); do
        out="$out$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$@")"
    done
    echo "$out"
}
count_of() { echo "$1" | grep -o "$2" | wc -l | tr -d ' '; }

server_require_port_free "$PORT" || exit 1

# --- one worker ----------------------------------------------------------
echo "one worker"
start --rate-limit 1/m --rate-limit-burst 5 --health-check-path /healthz
is "the burst is allowed, then refused" "$(codes 8 $H/)" "200200200200200429429429"
curl -sS --max-time 5 -D "$WORK/h" -o "$WORK/b" $H/
RETRY=$(tr -d '\r' < "$WORK/h" | awk 'tolower($1)=="retry-after:" {print $2}')
if [ -n "$RETRY" ] && [ "$RETRY" -ge 1 ] && [ "$RETRY" -le 60 ]; then
    ok "Retry-After says when ($RETRY s)"
else
    bad "Retry-After says when" "1..60" "${RETRY:-none}"
fi
is "the body says why" "$(cat "$WORK/b")" "Too Many Requests"
is "the health probe is never refused" "$(codes 3 $H/healthz)" "200200200"
is "a refused client keeps its connection" \
   "$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}%{num_connects}' $H/ \
        -o /dev/null -w '%{http_code}%{num_connects}' $H/)" "42914290"
server_stop

# --- several workers share one count -------------------------------------
echo "four workers"
start --workers 4 --rate-limit 1/m --rate-limit-burst 10 --health-check-path /healthz
RESULT=$(codes 30 $H/)
is "ten allowed across four workers, not forty" "$(count_of "$RESULT" 200)" "10"
is "the rest refused" "$(count_of "$RESULT" 429)" "20"
server_stop

# --- who the client is ---------------------------------------------------
echo "behind a trusted proxy"
start --rate-limit 1/m --rate-limit-burst 3 --forwarded-allow-ips 127.0.0.1 \
      --health-check-path /healthz
is "one forwarded client is limited" \
   "$(codes 4 -H 'X-Forwarded-For: 203.0.113.1' $H/)" "200200200429"
is "another forwarded client is not" \
   "$(codes 1 -H 'X-Forwarded-For: 203.0.113.2' $H/)" "200"
is "IPv6 clients in one /64 share a count" \
   "$(codes 3 -H 'X-Forwarded-For: 2001:db8::1' $H/)$(codes 1 -H 'X-Forwarded-For: 2001:db8::2' $H/)" \
   "200200200429"
is "a different /64 is a different client" \
   "$(codes 1 -H 'X-Forwarded-For: 2001:db8:0:1::1' $H/)" "200"
is "an IPv4-mapped address is the IPv4 client" \
   "$(codes 1 -H 'X-Forwarded-For: ::ffff:203.0.113.1' $H/)" "429"
server_stop

echo "with no proxy trusted"
start --rate-limit 1/m --rate-limit-burst 2 --health-check-path /healthz
is "X-Forwarded-For is not a way to a new count" \
   "$(codes 1 -H 'X-Forwarded-For: 198.51.100.1' $H/)$(codes 1 -H 'X-Forwarded-For: 198.51.100.2' $H/)$(codes 1 -H 'X-Forwarded-For: 198.51.100.3' $H/)" \
   "200200429"
server_stop

# --- HTTP/2 and the metric -----------------------------------------------
echo "HTTP/2 and metrics"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/s.key" -out "$WORK/s.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null
server_start "$BIN" --port "$TLS_PORT" --log-level error --rate-limit 1/m --rate-limit-burst 1 \
    --tls-cert "$WORK/s.pem" --tls-key "$WORK/s.key" --metrics-port "$METRICS_PORT" \
    --python-path "$ROOT/examples" wsgi_app:application > "$WORK/tls.log" 2>&1
for _ in $(seq 1 80); do
    curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$METRICS_PORT/metrics" 2>/dev/null && break
    sleep 0.2
done
HS="https://127.0.0.1:$TLS_PORT"
is "HTTP/2: the first request is allowed" "$(codes 1 -k --http2 $HS/)" "200"
curl -sS -k --http2 --max-time 5 -D "$WORK/h2" -o /dev/null $HS/
is "HTTP/2: the next is refused" "$(head -1 "$WORK/h2" | awk '{print $1, $2}')" "HTTP/2 429"
if tr -d '\r' < "$WORK/h2" | grep -qi '^retry-after: [0-9]'; then
    ok "HTTP/2: with retry-after"
else
    bad "HTTP/2: with retry-after" "a retry-after header" "$(tr -d '\r' < "$WORK/h2" | tr '\n' '|')"
fi
is "the refusals are counted" \
   "$(curl -sS --max-time 5 "http://127.0.0.1:$METRICS_PORT/metrics" | awk '$1=="peregrine_requests_rate_limited_total" {print $2}')" "1"
server_stop

echo
echo "rate limiting: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
