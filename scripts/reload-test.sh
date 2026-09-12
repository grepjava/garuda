#!/usr/bin/env bash
# A reload must not cost a client anything.
#
#   bash scripts/reload-test.sh [path-to-peregrine]
#
# Hammers the server with short-lived connections, sends SIGHUP underneath the
# load, and fails if a single connection was refused, reset, truncated or timed
# out. The workers are checked to have actually been replaced, because a reload
# that quietly did nothing would otherwise pass.
#
# What it is guarding: workers used to be signalled all at once, and a draining
# worker stopped polling its listener while still holding it open. The socket
# stayed in the SO_REUSEPORT group, so the kernel kept handing it a share of new
# connections, which queued on it unserved until the worker exited and reset
# them. On this test that was 56 connections lost out of 40,000 and a worst case
# of just over a second.
#
# Now the supervisor owns the listeners and a replacement inherits the same
# socket its predecessor had, so a slot's accept queue is never orphaned, and
# the replacement is spawned before the worker it replaces is asked to stop.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
EXTRA=${PEREGRINE_EXTRA_ARGS:-}
PORT=${PORT:-8311}
WORKERS=${WORKERS:-4}
SECONDS_OF_LOAD=${SECONDS_OF_LOAD:-12}
CLIENTS=${CLIENTS:-16}
RELOADS=${RELOADS:-3}

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
LOG=${TMPDIR:-/tmp}/peregrine-reload-$PORT.log
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
server_trap_cleanup

server_require_port_free "$PORT" || exit 1

# shellcheck disable=SC2086 -- EXTRA is a deliberate word-split flag list.
server_start "$BIN" --port "$PORT" --workers "$WORKERS" --log-level info \
    --python-path "$ROOT/examples" $EXTRA wsgi_app:application \
    > "$LOG" 2>&1

for _ in $(seq 1 60); do
    curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break
    sleep 0.2
done
if ! curl -sS --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    echo "server failed to start"
    cat "$LOG"
    exit 1
fi

# The workers serving before the reload. Sampled rather than read from the log
# so that this measures what a client can actually reach.
sample_pids() {
    local n=$1 i=0 seen=""
    while [ "$i" -lt "$n" ]; do
        seen="$seen $(curl -sS --max-time 2 "http://127.0.0.1:$PORT/pid" 2>/dev/null)"
        i=$((i + 1))
    done
    echo "$seen" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | xargs
}

BEFORE=$(sample_pids $((WORKERS * 8)))
echo "  workers before: $BEFORE"

# Load first, reloads underneath it.
RESULT=${TMPDIR:-/tmp}/peregrine-reload-result-$PORT.json
python3 "$HERE/reload_load.py" 127.0.0.1 "$PORT" "$SECONDS_OF_LOAD" "$CLIENTS" \
    > "$RESULT" &
LOAD_PID=$!

gap=$((SECONDS_OF_LOAD / (RELOADS + 1)))
i=0
while [ "$i" -lt "$RELOADS" ]; do
    sleep "$gap"
    echo "  SIGHUP"
    kill -HUP "$SERVER_PID" 2>/dev/null
    i=$((i + 1))
done

wait "$LOAD_PID"

AFTER=$(sample_pids $((WORKERS * 8)))
echo "  workers after:  $AFTER"

python3 - "$RESULT" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
print("  requests: %d ok, %d refused, %d reset, %d timeout, %d truncated, other=%s"
      % (data["ok"], data["refused"], data["reset"], data["timeout"],
         data["truncated"], data["other"] or "{}"))
print("  latency:  p50 %sms  p99 %sms  p99.9 %sms  max %sms"
      % (data["p50_ms"], data["p99_ms"], data["p999_ms"], data["max_ms"]))
print("  served by %d distinct workers" % len(data["pids"]))
PY

BAD=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["refused"]+d["reset"]+d["timeout"]+d["truncated"]+sum(d["other"].values()))' "$RESULT")
SERVED=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["ok"])' "$RESULT")
DISTINCT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["pids"]))' "$RESULT")

if [ "$SERVED" -lt 100 ]; then
    bad "the load actually ran" "only $SERVED requests completed"
else
    ok "the load actually ran ($SERVED requests)"
fi

if [ "$BAD" -eq 0 ]; then
    ok "no connection was refused, reset, truncated or timed out across $RELOADS reloads"
else
    bad "no connection was lost across the reloads" "$BAD of $((SERVED + BAD)) failed"
fi

# Disjoint sets: every worker serving at the end is one the reloads created.
OVERLAP=""
for p in $AFTER; do
    case " $BEFORE " in *" $p "*) OVERLAP="$OVERLAP $p";; esac
done
if [ -z "$OVERLAP" ] && [ -n "$AFTER" ]; then
    ok "every worker was replaced"
else
    bad "every worker was replaced" "still serving from before the reload:$OVERLAP"
fi

# More distinct pids over the run than were serving at the start is the overlap
# itself showing up: old and new were both taking requests.
#
# Counted from what was observed rather than from $WORKERS, because the two
# execution models answer "how many processes" differently: --free-threaded
# serves every worker from threads of one process, so a generation is one pid
# there and $WORKERS of them otherwise.
BEFORE_COUNT=$(echo "$BEFORE" | wc -w)
if [ "$DISTINCT" -gt "$BEFORE_COUNT" ]; then
    ok "old and new workers both served during the handover ($DISTINCT distinct pids)"
else
    bad "the reload replaced workers while serving" \
        "only $DISTINCT distinct pids, having started with $BEFORE_COUNT"
fi

if grep -q "reloading workers" "$LOG"; then
    ok "the supervisor logged the reload"
else
    bad "the supervisor logged the reload" "no reload line in $LOG"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
