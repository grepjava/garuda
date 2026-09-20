#!/usr/bin/env bash
# TLS session resumption: a ticket handed out on one connection must shorten
# the next one.
#
#   bash scripts/resumption-test.sh [path-to-garuda]
#
# Why this file exists. BoringSSL, which is the record layer now, holds its
# TLS 1.3 NewSessionTicket back until the first application write, so that the
# ticket rides out with the response rather than costing a write of its own.
# That is deliberate, and it is invisible under OpenSSL, which sends the
# ticket at the end of the handshake. It has already cost this project once:
# Garuda's own TLS *client* handshakes and then waits, so it was handed no
# ticket at all, and `av_tls_flush_control` exists to make it ask.
#
# What that does NOT mean here, stated because the obvious inference is wrong.
# Garuda's server does not call `av_tls_flush_control`, and measured against
# it the session file is **1,628 bytes whether or not the saving connection
# makes a request**, with `-ign_eof` held constant across both arms. The
# deferral does not show on this path, so the request below is not what makes
# these checks assert anything.
#
# The variable that decides whether a session file is written at all appears
# to be `-ign_eof` -- whether `s_client` stays open rather than tearing down
# on stdin EOF -- and not the request. That is reported from another codebase
# and is not verified here; what is verified here is the line above.
#
# The request stays because the third check needs one -- a server can resume a
# session and still fail to serve on it -- and because a saving connection
# that behaves like a real client is the case worth testing.
#
# Which check catches what, established by constructing each failure rather
# than by reasoning about it:
#
#   a server that issues no ticket    the non-empty-file check catches it
#                                     first. Fed an empty session file the
#                                     other two fail as well: s_client prints
#                                     neither New nor Reused and the request
#                                     gets no 200.
#   a server that claims Reused for   the last check catches it, and only
#   every connection                  that one -- a connection offering no
#                                     ticket must report New.
#
# So there is no single load-bearing assertion; there are two guards for two
# different failures. Removing either leaves a real way for this file to go
# green against a broken server.
#
# Needs the release build (or GARUDA, or the path as the first argument),
# curl, openssl, and python3 for picking a free port; PORT overrides it.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")

# A port nothing is listening on, chosen by the kernel while the socket is
# held open.
free_ports() {
    python3 -c 'import socket, sys
socks = [socket.socket() for _ in range(int(sys.argv[1]))]
for s in socks: s.bind(("127.0.0.1", 0))
print(*[s.getsockname()[1] for s in socks])' "$1"
}

BIN=${1:-${GARUDA:-$ROOT/.build/release/garuda}}
PORT=${PORT:-$(free_ports 1)}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }

# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop_all; rm -rf "$WORK"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 2 -nodes -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" 2>/dev/null

server_require_port_free "$PORT" || exit 1
server_start "$BIN" --port "$PORT" --workers 1 --log-level error \
    --tls-cert "$WORK/cert.pem" --tls-key "$WORK/key.pem" \
    > "$WORK/server.log" 2>&1

for _ in $(seq 1 60); do
    curl -sS -k --max-time 1 -o /dev/null "https://127.0.0.1:$PORT/user/1" 2>/dev/null && break
    sleep 0.2
done
if ! curl -sS -k --max-time 2 -o /dev/null "https://127.0.0.1:$PORT/user/1" 2>/dev/null; then
    echo "server failed to start"
    cat "$WORK/server.log"
    exit 1
fi

req() { printf 'GET /user/1 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n'; }

# A connection that makes a real request -- see the note at the top -- and
# saves whatever session it ends up with.
save_session() {
    local out=$1; shift
    req | timeout 10 openssl s_client -connect "127.0.0.1:$PORT" -servername localhost \
        -sess_out "$out" -ign_eof "$@" > "$WORK/save.log" 2>&1
}

# Reconnect with that session and report what the handshake did.
use_session() {
    local in=$1; shift
    req | timeout 10 openssl s_client -connect "127.0.0.1:$PORT" -servername localhost \
        -sess_in "$in" -ign_eof "$@" 2>&1
}

# The three checks that make a version's resumption real: a ticket was issued
# at all, it resumes, and a resumed connection still answers. The third is
# what catches a server that resumes the session and then cannot serve on it.
version() {
    local label=$1 flag=$2 file=$WORK/sess-$1
    echo "$label"

    save_session "$file" "$flag"
    if [ -s "$file" ]; then
        ok "a request draws a session ticket"
    else
        bad "a request draws a session ticket" "a non-empty session file" "empty"
    fi

    local out
    out=$(use_session "$file" "$flag")
    case "$out" in
        *Reused*) ok "the ticket resumes the session" ;;
        *)        bad "the ticket resumes the session" "Reused" \
                      "$(printf '%s' "$out" | grep -E '^(New|Reused)' | head -1)" ;;
    esac
    case "$out" in
        *"200 OK"*) ok "a resumed connection still serves the request" ;;
        *)          bad "a resumed connection still serves the request" "200 OK" "no 200 in the response" ;;
    esac
}

version "TLS 1.3" -tls1_3
version "TLS 1.2" -tls1_2

# A connection offering no ticket must be a full handshake. Without this the
# other checks cannot tell resumption from a server that reports Reused for
# everything.
echo "no ticket"
fresh=$(req | timeout 10 openssl s_client -connect "127.0.0.1:$PORT" -servername localhost \
        -ign_eof -tls1_3 2>&1)
case "$fresh" in
    *Reused*) bad "a connection with no ticket is a full handshake" "New" "Reused" ;;
    *New*)    ok "a connection with no ticket is a full handshake" ;;
    *)        bad "a connection with no ticket is a full handshake" "New" "neither New nor Reused" ;;
esac

printf '\nresumption: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
