#!/usr/bin/env bash
# --acme-domain: a certificate from a real ACME server, end to end.
#
#   bash scripts/acme-test.sh [path-to-garuda]
#
# Runs Let's Encrypt's own test CA, pebble, with pebble-challtestsrv answering
# DNS so that every test domain resolves to 127.0.0.1. Nothing here is mocked:
# the server registers an account, answers tls-alpn-01 on its own port, gets a
# certificate signed by pebble, and reloads onto it -- and the checks are made
# by clients that trust only pebble's root, asking the built-in router for
# /user/:id so that the id coming back shows the request was answered.
#
# PEBBLE_DIR points at the unpacked release binaries (default ~/pebble). Pebble
# rejects a tenth of nonces here on purpose, which is what exercises the
# client's retry. Needs no network: pebble, its DNS and the server all run on
# 127.0.0.1, on ports the kernel picks (python3 does the picking). Also needs
# the release build (or GARUDA, or the path as the first argument), curl and
# openssl.
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
# The server's port is also where pebble sends its tls-alpn-01 validation, so
# pebble is told it; the rest are pebble's and challtestsrv's own.
read -r FREE_PORT ACME_PORT ACME_MGMT_PORT ACME_HTTP_PORT DNS_PORT DNS_MGMT_PORT <<< "$(free_ports 6)"
PORT=${PORT:-$FREE_PORT}
PEBBLE_DIR=${PEBBLE_DIR:-$HOME/pebble}
PEBBLE=$(find "$PEBBLE_DIR" -type f -name pebble | head -1)
CHALLTESTSRV=$(find "$PEBBLE_DIR" -type f -name pebble-challtestsrv | head -1)
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }

# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"

PIDS=""
cleanup() {
    server_stop
    # shellcheck disable=SC2086 -- a deliberate list of pids.
    [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
    wait 2>/dev/null
    # KEEP=1 leaves the logs, the cache and pebble's output for a look.
    if [ "${KEEP:-0}" = 1 ]; then
        echo "kept $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

if [ -z "$PEBBLE" ] || [ -z "$CHALLTESTSRV" ]; then
    echo "pebble not found under $PEBBLE_DIR; download it from"
    echo "https://github.com/letsencrypt/pebble/releases and set PEBBLE_DIR"
    exit 1
fi
# The release archives do not keep the execute bit.
if [ ! -x "$PEBBLE" ] || [ ! -x "$CHALLTESTSRV" ]; then
    echo "pebble binaries are not executable: chmod +x $PEBBLE $CHALLTESTSRV"
    exit 1
fi

# --- pebble's own HTTPS, from a CA made here --------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=test ca" \
    -keyout "$WORK/ca.key" -out "$WORK/ca.pem" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" \
    -keyout "$WORK/pebble.key" -out "$WORK/pebble.csr" 2>/dev/null
printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\n' > "$WORK/san.ext"
openssl x509 -req -in "$WORK/pebble.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
    -CAcreateserial -days 2 -extfile "$WORK/san.ext" -out "$WORK/pebble.pem" 2>/dev/null

cat > "$WORK/pebble.json" <<JSON
{
  "pebble": {
    "listenAddress": "127.0.0.1:$ACME_PORT",
    "managementListenAddress": "127.0.0.1:$ACME_MGMT_PORT",
    "certificate": "$WORK/pebble.pem",
    "privateKey": "$WORK/pebble.key",
    "httpPort": $ACME_HTTP_PORT,
    "tlsPort": $PORT,
    "ocspResponderURL": "",
    "externalAccountBindingRequired": false
  }
}
JSON

"$CHALLTESTSRV" -defaultIPv4 127.0.0.1 -defaultIPv6 "" -dnsserver "127.0.0.1:$DNS_PORT" \
    -http01 "" -https01 "" -tlsalpn01 "" -doh "" -management "127.0.0.1:$DNS_MGMT_PORT" \
    > "$WORK/challtestsrv.log" 2>&1 &
PIDS="$PIDS $!"
PEBBLE_VA_NOSLEEP=1 PEBBLE_WFE_NONCEREJECT=10 "$PEBBLE" -config "$WORK/pebble.json" \
    -dnsserver "127.0.0.1:$DNS_PORT" > "$WORK/pebble.log" 2>&1 &
PIDS="$PIDS $!"
for _ in $(seq 1 50); do
    curl -s --cacert "$WORK/ca.pem" -o /dev/null "https://127.0.0.1:$ACME_PORT/dir" && break
    sleep 0.2
done

CACHE="$WORK/acme"
start() {
    server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
        --acme-domain app.test --acme-domain www.app.test \
        --acme-email ops@app.test --acme-cache "$CACHE" \
        --acme-directory "https://127.0.0.1:$ACME_PORT/dir" --acme-ca-bundle "$WORK/ca.pem" \
        > "$1" 2>&1
}
wait_for_log() {
    for _ in $(seq 1 "$3"); do
        grep -q "$2" "$1" && return 0
        sleep 0.25
    done
    return 1
}
issuer() {
    echo | openssl s_client -connect "127.0.0.1:$PORT" -servername "$1" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null
}

server_require_port_free "$PORT" || exit 1

echo "first start: no certificate yet"
start "$WORK/first.log"
if wait_for_log "$WORK/first.log" "workers reloaded" 240; then
    ok "a certificate was obtained and the workers reloaded onto it"
else
    bad "a certificate was obtained and the workers reloaded onto it" "workers reloaded" \
        "$(tail -5 "$WORK/first.log" | tr '\n' '|')"
fi

curl -s --cacert "$WORK/ca.pem" "https://127.0.0.1:$ACME_MGMT_PORT/roots/0" > "$WORK/root.pem"
curl -s --cacert "$WORK/ca.pem" "https://127.0.0.1:$ACME_MGMT_PORT/intermediates/0" >> "$WORK/root.pem"

case "$(issuer app.test)" in
    *Pebble*) ok "app.test is served a certificate pebble issued" ;;
    *) bad "app.test is served a certificate pebble issued" "issuer=...Pebble..." "$(issuer app.test)" ;;
esac
is "a client trusting only pebble has its request answered" \
   "$(curl -sS --max-time 10 --cacert "$WORK/root.pem" --resolve "app.test:$PORT:127.0.0.1" \
        "https://app.test:$PORT/user/acme")" "acme"
is "and so does the second name" \
   "$(curl -sS --max-time 10 --cacert "$WORK/root.pem" --resolve "www.app.test:$PORT:127.0.0.1" \
        -o /dev/null -w '%{http_code}' "https://www.app.test:$PORT/")" "200"
is "HTTP/2 still negotiates on the new certificate" \
   "$(curl -sS --max-time 10 --http2 --cacert "$WORK/root.pem" --resolve "app.test:$PORT:127.0.0.1" \
        -o /dev/null -w '%{http_version}' "https://app.test:$PORT/")" "2"
is "the challenge certificates are cleaned up" "$(ls "$CACHE/alpn" 2>/dev/null | wc -l | tr -d ' ')" "0"
is "the certificate key is private" "$(stat -c %a "$CACHE/key.pem")" "600"
is "the account key is private" "$(stat -c %a "$CACHE/account.key")" "600"
if grep -q "badNonce\|rejected three nonces" "$WORK/first.log"; then
    bad "rejected nonces were retried quietly" "no nonce errors" "$(grep -m1 -i nonce "$WORK/first.log")"
else
    ok "rejected nonces were retried quietly"
fi
is "a connection asking only for acme-tls/1 with nothing pending is refused" \
   "$(echo | openssl s_client -connect "127.0.0.1:$PORT" -servername app.test -alpn acme-tls/1 2>&1 \
        | grep -c 'ALPN protocol: acme-tls/1')" "0"
server_stop

echo "second start: the certificate is kept"
start "$WORK/second.log"
sleep 4
if grep -q "requesting a certificate" "$WORK/second.log"; then
    bad "a valid certificate is not requested again" "no request" "$(grep -m1 requesting "$WORK/second.log")"
else
    ok "a valid certificate is not requested again"
fi
case "$(issuer app.test)" in
    *Pebble*) ok "and it is served straight away" ;;
    *) bad "and it is served straight away" "issuer=...Pebble..." "$(issuer app.test)" ;;
esac
server_stop

echo
echo "acme: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
