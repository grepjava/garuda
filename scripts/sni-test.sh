#!/usr/bin/env bash
# SNI: the certificate served must follow the name the client asked for.
#
#   bash scripts/sni-test.sh [path-to-peregrine]
#
# Three certificates on one port -- two exact names and one wildcard -- plus the
# rule for a name nothing claims, which is to answer with the first certificate
# and let the client decide. Refusing the connection instead would replace a
# browser warning the user can read with a failure they cannot.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8341}
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
server_trap_cleanup
cleanup_work() { rm -rf "$WORK"; }
trap 'server_stop; cleanup_work' EXIT

# One certificate per name. The names live in the subject alternative name,
# which is where the server reads them from.
make_cert() {
    local name=$1 san=$2
    openssl req -x509 -newkey rsa:2048 -keyout "$WORK/$name.key" -out "$WORK/$name.pem" \
        -days 2 -nodes -subj "/CN=$name" -addext "subjectAltName=$san" 2>/dev/null
}

make_cert alpha "DNS:alpha.example"
make_cert beta  "DNS:beta.example"
make_cert star  "DNS:*.wild.example"

server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
    --tls-cert "$WORK/alpha.pem" --tls-key "$WORK/alpha.key" \
    --tls-cert "$WORK/beta.pem"  --tls-key "$WORK/beta.key" \
    --tls-cert "$WORK/star.pem"  --tls-key "$WORK/star.key" \
    --python-path "$ROOT/examples" wsgi_app:application \
    > "$WORK/server.log" 2>&1

for _ in $(seq 1 60); do
    curl -sS -k --max-time 1 -o /dev/null "https://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.2
done
if ! curl -sS -k --max-time 2 -o /dev/null "https://127.0.0.1:$PORT/" 2>/dev/null; then
    echo "server failed to start"
    cat "$WORK/server.log"
    exit 1
fi

# The CN of whatever certificate came back for this SNI name.
served_for() {
    openssl s_client -connect "127.0.0.1:$PORT" -servername "$1" </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -e 's/.*CN *= *//' -e 's/ *$//'
}

is "an exact name gets its own certificate"   "$(served_for alpha.example)"      "alpha"
is "a second exact name gets its own"         "$(served_for beta.example)"       "beta"
is "a wildcard covers one label"              "$(served_for a.wild.example)"     "star"
is "a wildcard does not cross a dot"          "$(served_for a.b.wild.example)"   "alpha"
is "a wildcard does not match the bare domain" "$(served_for wild.example)"      "alpha"
is "an unknown name gets the default"         "$(served_for nothing.example)"    "alpha"
is "no SNI at all gets the default" \
   "$(openssl s_client -connect "127.0.0.1:$PORT" -noservername </dev/null 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null | sed -e 's/.*CN *= *//' -e 's/ *$//')" \
   "alpha"
is "matching is case-insensitive"             "$(served_for BETA.Example)"       "beta"

# The point of all this is that the server still serves.
is "requests are still answered" \
   "$(curl -sS -k --max-time 5 "https://127.0.0.1:$PORT/")" "hello from peregrine"

# ALPN has to survive the context swap: SSL_set_SSL_CTX carries almost nothing
# over, so a certificate chosen by SNI must still negotiate HTTP/2.
is "HTTP/2 is negotiated on a name chosen by SNI" \
   "$(curl -sS -k --max-time 5 --resolve "beta.example:$PORT:127.0.0.1" \
        -o /dev/null -w '%{http_version}' "https://beta.example:$PORT/")" "2"

if grep -q "certificate 1 (default) serves alpha.example" "$WORK/server.log"; then
    ok "start-up logs what each certificate serves"
else
    bad "start-up logs what each certificate serves" "a line naming alpha.example" "none"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
