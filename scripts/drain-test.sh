#!/usr/bin/env bash
# --drain-delay: SIGTERM fails the health check and keeps serving, then drains.
#
#   bash scripts/drain-test.sh [path-to-garuda]
#
# GARUDA_EXTRA_ARGS adds flags, e.g. "--free-threaded".
set -u

BIN=${1:-${GARUDA:-$HOME/pgbuild/debug/garuda}}
PORT=${PORT:-8231}
# shellcheck disable=SC2206 -- deliberately split into words.
EXTRA=(${GARUDA_EXTRA_ARGS:-})
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

ms() { echo $(( $(date +%s%N) / 1000000 )); }
code() { curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }

start() {
    local log=$1
    shift
    server_start "$BIN" --port "$PORT" --workers 2 --log-level info \
        --health-check-path /healthz "${EXTRA[@]}" "$@" \
        --python-path "$ROOT/examples" asgi_app:app > "$log" 2>&1
    for _ in $(seq 1 100); do
        [ "$(code /healthz)" = 200 ] && return 0
        sleep 0.1
    done
    echo "server did not start:"
    cat "$log"
    exit 1
}

# Milliseconds until the server process is gone, or 99999.
exit_after() {
    local since=$1
    for _ in $(seq 1 150); do
        kill -0 "$SERVER_PID" 2>/dev/null || { echo $(( $(ms) - since )); return; }
        sleep 0.1
    done
    echo 99999
}

# Every one of N probes answers $1: with two workers behind SO_REUSEPORT, a
# handful of fresh connections reaches both.
all_probes() {
    local want=$1 got
    for _ in 1 2 3 4 5 6 7 8; do
        got=$(code /healthz)
        [ "$got" = "$want" ] || { echo "$got"; return; }
    done
    echo "$want"
}

server_require_port_free "$PORT" || exit 1

echo "SIGTERM to the supervisor, --drain-delay 2000"
start "$WORK/term.log" --drain-delay 2000 --graceful-timeout 3000
is "the health check passes before" "$(code /healthz)" 200
t0=$(ms)
kill -TERM "$SERVER_PID"
sleep 0.4
is "every worker fails its health check at once" "$(all_probes 503)" 503
is "and the application is still served" "$(code /)" 200
is "on a connection the server closes after the response" \
   "$(curl -si --max-time 5 "http://127.0.0.1:$PORT/" | tr -d '\r' | grep -ci '^connection: close')" 1
sleep 1
is "a new connection a second later is still served" "$(code /)" 200
took=$(exit_after "$t0")
if [ "$took" -ge 1900 ] && [ "$took" -lt 5000 ]; then
    ok "the server exits once the delay is up (${took}ms)"
else
    bad "the server exits once the delay is up" "2000-5000ms" "${took}ms"
fi
server_stop

echo "SIGTERM to the whole process group, as systemd sends it"
start "$WORK/group.log" --drain-delay 2000 --graceful-timeout 3000
t0=$(ms)
kill -TERM -- "-$SERVER_PID"
sleep 0.6
is "the workers keep the delay when signalled directly" "$(code /)" 200
is "and fail their health check" "$(all_probes 503)" 503
took=$(exit_after "$t0")
if [ "$took" -ge 1900 ] && [ "$took" -lt 5000 ]; then
    ok "and the server exits once the delay is up (${took}ms)"
else
    bad "and the server exits once the delay is up" "2000-5000ms" "${took}ms"
fi
server_stop

echo "SIGINT does not wait"
start "$WORK/int.log" --drain-delay 5000
t0=$(ms)
kill -INT "$SERVER_PID"
took=$(exit_after "$t0")
if [ "$took" -lt 2500 ]; then
    ok "SIGINT exits without the delay (${took}ms)"
else
    bad "SIGINT exits without the delay" "under 2500ms" "${took}ms"
fi
server_stop

echo "SIGQUIT cuts a running delay short"
start "$WORK/quit.log" --drain-delay 8000
t0=$(ms)
kill -TERM "$SERVER_PID"
sleep 0.5
kill -QUIT "$SERVER_PID"
took=$(exit_after "$t0")
if [ "$took" -lt 3000 ]; then
    ok "the server exits well inside the delay (${took}ms)"
else
    bad "the server exits well inside the delay" "under 3000ms" "${took}ms"
fi
server_stop

echo "a reload is not delayed"
start "$WORK/reload.log" --drain-delay 8000
t0=$(ms)
kill -HUP "$SERVER_PID"
reloaded=99999
for _ in $(seq 1 60); do
    if grep -q "workers reloaded" "$WORK/reload.log"; then reloaded=$(( $(ms) - t0 )); break; fi
    sleep 0.1
done
if [ "$reloaded" -lt 5000 ]; then
    ok "SIGHUP replaces every worker without waiting out the delay (${reloaded}ms)"
else
    bad "SIGHUP replaces every worker without waiting out the delay" "under 5000ms" "${reloaded}ms"
fi
is "and the new workers pass their health check" "$(all_probes 200)" 200
server_stop

echo "a signal that arrives while the workers are still starting"
for sig in TERM INT; do
    server_start "$BIN" --port "$PORT" --workers 2 --log-level warning "${EXTRA[@]}" \
        --python-path "$HERE" slow_import_app:app > "$WORK/boot.log" 2>&1
    # Well inside the import's 1.5s sleep: the workers have forked and have not
    # reached their poll loops.
    sleep 0.5
    t0=$(ms)
    kill -"$sig" "$SERVER_PID"
    took=$(exit_after "$t0")
    if [ "$took" -lt 5000 ]; then
        ok "SIG$sig during start-up is not lost (${took}ms)"
    else
        bad "SIG$sig during start-up is not lost" "under 5000ms, not the kill deadline" "${took}ms"
    fi
    server_stop
done

echo "without --drain-delay nothing changes"
start "$WORK/plain.log"
t0=$(ms)
kill -TERM "$SERVER_PID"
took=$(exit_after "$t0")
if [ "$took" -lt 2500 ]; then
    ok "SIGTERM drains at once (${took}ms)"
else
    bad "SIGTERM drains at once" "under 2500ms" "${took}ms"
fi
server_stop

echo
echo "drain: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
