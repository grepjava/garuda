#!/usr/bin/env bash
# The Python logging bridge: application records in the server's own log.
#
#   bash scripts/logging-test.sh [path-to-peregrine]
#
# What matters is that the two logs become one: same format, same level filter,
# same stream. So the checks are about shape (a peregrine line, not a logging
# one), about the level mapping, and about --log-level actually silencing the
# application -- which is the thing two separate log configurations get wrong.
set -u

BIN=${1:-${PEREGRINE:-$HOME/pgbuild/debug/peregrine}}
PORT=${PORT:-8371}
WORK=$(mktemp -d)
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$3" "$2"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "contains $3" "$2";; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "no $3" "$2";; *) ok "$1";; esac; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=scripts/serverlib.sh
. "$HERE/serverlib.sh"
trap 'server_stop; rm -rf "$WORK"' EXIT

cat > "$WORK/logapp.py" <<'PY'
import logging
from peregrine.logging import configure, server_level

configure()
logging.getLogger("boot").info("imported at module level")

log = logging.getLogger("shop")


def application(environ, start_response):
    path = environ["PATH_INFO"]
    if path == "/debug":
        log.debug("a debug record")
    elif path == "/warn":
        log.warning("a warning record")
    elif path == "/error":
        log.error("an error record")
    elif path == "/multi":
        log.info("first line\nsecond line")
    elif path == "/boom":
        try:
            raise ValueError("deliberate")
        except ValueError:
            log.exception("caught it")
    elif path == "/level":
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [str(server_level()).encode()]
    else:
        log.info("an info record")
    start_response("200 OK", [("Content-Type", "text/plain")])
    return [b"ok"]
PY

start_server() {  # $1 = log level
    server_stop
    server_start "$BIN" --port "$PORT" --workers 1 --log-level "$1" \
        --python-path "$WORK" --python-path "$ROOT/python" logapp:application \
        > "$WORK/log-$1.txt" 2>&1
    for _ in $(seq 1 60); do
        curl -sS --max-time 1 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && return 0
        sleep 0.2
    done
    echo "server failed to start at level $1"
    cat "$WORK/log-$1.txt"
    exit 1
}

# --- at info ---------------------------------------------------------------
start_server info
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/debug"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/warn"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/error"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/multi"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/boom"
LEVEL=$(curl -sS --max-time 5 "http://127.0.0.1:$PORT/level")
server_stop
INFO_LOG=$(cat "$WORK/log-info.txt")

has "a module-level record is logged"   "$INFO_LOG" "boot: imported at module level"
has "an info record wears the server format" "$INFO_LOG" "[info]  "
has "an info record carries its logger"  "$INFO_LOG" "shop: an info record"
has "a warning maps to warn" \
    "$(printf '%s\n' "$INFO_LOG" | grep 'a warning record' | head -1)" "[warn]"
has "an error maps to error" \
    "$(printf '%s\n' "$INFO_LOG" | grep 'an error record' | head -1)" "[error]"
hasnt "debug is below the server level"  "$INFO_LOG" "a debug record"
# A traceback must not become several records of unknown level.
has "a multi-line record stays one line" "$INFO_LOG" "first line | second line"
has "an exception is logged"             "$INFO_LOG" "caught it"
has "its traceback comes with it"        "$INFO_LOG" "ValueError: deliberate"
is  "the application sees the server level" "$LEVEL" "20"

# --- at warning ------------------------------------------------------------
# The point of one level rather than two: turning the server down turns the
# application down with it, without a second setting to keep in step.
start_server warning
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"
curl -sS --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/warn"
LEVEL=$(curl -sS --max-time 5 "http://127.0.0.1:$PORT/level")
server_stop
WARN_LOG=$(cat "$WORK/log-warning.txt")

hasnt "info is silenced with the server" "$WARN_LOG" "an info record"
has   "warnings still come through"      "$WARN_LOG" "shop: a warning record"
is    "the level the application sees follows" "$LEVEL" "30"

# --- outside peregrine -----------------------------------------------------
# A dictConfig naming the handler should not have to be conditional.
OUT=$(cd "$WORK" && PYTHONPATH="$ROOT/python" python3 -c '
import logging
from peregrine.logging import PeregrineHandler, server_level
h = PeregrineHandler()
h.setFormatter(logging.Formatter("%(name)s: %(message)s"))
log = logging.getLogger("outside")
log.addHandler(h)
log.setLevel(logging.INFO)
log.info("still works")
print("level", server_level())
' 2>&1)
has "the handler works outside peregrine" "$OUT" "outside: still works"
has "and reports a usable level"          "$OUT" "level 10"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
