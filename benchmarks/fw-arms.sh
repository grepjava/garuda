#!/usr/bin/env bash
# frameworks.sh with the measurement order taken out of it.
#
#   ARMS="garuda axum ntex vapor hummingbird elysia-bun" bash benchmarks/fw-arms.sh
#
# Why this exists rather than one invocation naming every server: whichever
# server is measured later in a sweep reads lower, and not by the same amount
# for every server, so the order is charged to whatever is under test. On this
# box the effect has been as large as 17%, which is bigger than most of the
# differences anyone wants to read out of these tables.
#
# So each arm gets an invocation of its own, and the arms rotate by one each
# round. With N arms and N+1 rounds, discarding round 1 leaves N rounds in
# which every arm has taken every position exactly once. Round 1 is discarded
# because whatever is measured first in a session reads highest of all.
#
# Read the rounds together, and print them: a mean hides a round that ran
# while something else was on the machine, and the per-round values show it.
#
# Each arm's binary comes from the variable frameworks.sh names for it --
# GARUDA, HUMMINGBIRD, VAPOR, AXUM, NTEX -- whose defaults assume every server
# is built inside this checkout. Where they are not, give the paths, and give
# LD_LIBRARY_PATH too if the Swift binaries were built against a toolchain the
# loader will not find on its own. Keep them in a launcher rather than on a
# command line: a sweep started without them runs to the end and measures
# nothing, which the check below now turns into a stop.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARMS=${ARMS:-"garuda axum ntex vapor hummingbird elysia-bun"}
ROUNDS=${ROUNDS:-0}          # 0 means one more than the number of arms.

framework_of() {
    case "$1" in
    garuda|hummingbird|vapor) printf 'swift' ;;
    axum|actix|ntex) printf 'rust' ;;
    vertx) printf 'java' ;;
    elysia-bun) printf 'elysia' ;;
    esac
}

set -- $ARMS
count=$#
[ "$count" -gt 0 ] || { echo "fw-arms: ARMS is empty" >&2; exit 1; }
all=("$@")
[ "$ROUNDS" -gt 0 ] || ROUNDS=$((count + 1))

echo "# $count arms, $ROUNDS rounds, round 1 discarded as warm-up."
echo "# Rounds 2-$ROUNDS give every arm every position exactly once."

# An arm whose binary is missing, or which is built against a runtime the
# loader cannot find, does not stop frameworks.sh: it prints FAILED TO START
# and the sweep carries on. That is right for a single invocation and wrong
# here, because a rotation missing an arm balances nothing -- and a sweep that
# fails this way runs *faster* than a working one, which reads like progress.
# So the first arm that does not start ends the sweep.
log=$(mktemp)
trap 'rm -f "$log"' EXIT

for i in $(seq 1 "$ROUNDS"); do
    for j in $(seq 0 $((count - 1))); do
        arm=${all[$(( (i - 1 + j) % count ))]}
        printf '===== round %s  position %s  arm=%s =====\n' "$i" "$((j + 1))" "$arm"
        FRAMEWORKS="$(framework_of "$arm")" SERVERS="$arm" \
            bash "$ROOT/benchmarks/frameworks.sh" 2>&1 | tee "$log"
        if grep -q "FAILED TO START" "$log"; then
            printf '\nfw-arms: %s did not start, so this sweep cannot be balanced.\n' "$arm"
            printf 'fw-arms: stopping at round %s position %s.\n' "$i" "$((j + 1))"
            exit 1
        fi
    done
done
