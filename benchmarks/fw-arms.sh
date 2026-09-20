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

for i in $(seq 1 "$ROUNDS"); do
    for j in $(seq 0 $((count - 1))); do
        arm=${all[$(( (i - 1 + j) % count ))]}
        printf '===== round %s  position %s  arm=%s =====\n' "$i" "$((j + 1))" "$arm"
        FRAMEWORKS="$(framework_of "$arm")" SERVERS="$arm" \
            bash "$ROOT/benchmarks/frameworks.sh" || echo "arm $arm failed"
    done
done
