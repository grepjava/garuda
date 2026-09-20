#!/usr/bin/env bash
# The HTTPS sweep with the measurement order taken out of it.
#
#   OPENSSL_APP=/path/to/workloads-openssl \
#   BORING_APP=/path/to/workloads-boring \
#   bash benchmarks/tls-arms.sh
#
# Two ordering effects were measured on the bench box, and each has to be
# removed or it is charged to whatever is under test:
#
#   within an invocation  workloads.sh runs one server through every workload
#                         and then the next, and whichever goes second reads
#                         lower -- Garuda by about 17% on `user`, axum by
#                         about 1%. Because it is not the same for the two it
#                         does not cancel, and the default SERVERS order puts
#                         Garuda first, which flatters it. So each arm gets an
#                         invocation of its own and is always the server
#                         measured first.
#   within a session      whatever is measured first in a session reads
#                         highest; OpenSSL's `user` read 131k as a session's
#                         first measurement and 109k a round later, while the
#                         other arms held steady. So the arms rotate, and over
#                         three rounds each takes each position exactly once.
#
# Read the three rounds together. One round still carries the position it was
# measured in; only the set of them cancels it.
#
# ARMS names what runs. An arm is either `axum` or a Garuda binary named by
# <ARM>_APP in the environment, so `ARMS="openssl boring"` wants OPENSSL_APP
# and BORING_APP. Anything Garuda-side is run through SERVERS=garuda.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARMS=${ARMS:-"openssl boring axum"}
ROUNDS=${ROUNDS:-3}
WORKLOADS=${WORKLOADS:-"user json db stream me upload download relay churn h2 overload skew spike"}
# The relay's origin is a Garuda application whichever server is under test.
# It serves in the clear, so which TLS library it holds cannot matter, but it
# is pinned to one binary so that every arm relays through the same origin.
ORIGIN_APP=${ORIGIN_APP:-}

app_for() {
    local name=$1 var
    var=$(printf '%s_APP' "$(printf '%s' "$name" | tr '[:lower:]-' '[:upper:]_')")
    eval "printf '%s' \"\${$var:-}\""
}

# Rotate: round i starts at arm i.
set -- $ARMS
count=$#
[ "$count" -gt 0 ] || { echo "tls-arms: ARMS is empty" >&2; exit 1; }
all=("$@")

if [ -z "$ORIGIN_APP" ]; then
    for a in "${all[@]}"; do
        [ "$a" = axum ] && continue
        ORIGIN_APP=$(app_for "$a")
        [ -n "$ORIGIN_APP" ] && break
    done
fi
[ -n "$ORIGIN_APP" ] || { echo "tls-arms: no Garuda binary for the relay origin" >&2; exit 1; }

for i in $(seq 1 "$ROUNDS"); do
    for j in $(seq 0 $((count - 1))); do
        arm=${all[$(( (i - 1 + j) % count ))]}
        echo "===== round $i  arm=$arm ====="
        if [ "$arm" = axum ]; then
            GARUDA_APP=$ORIGIN_APP TLS=1 WORKLOADS="$WORKLOADS" SERVERS="axum" \
                bash "$ROOT/benchmarks/workloads.sh"
        else
            app=$(app_for "$arm")
            [ -n "$app" ] || { echo "tls-arms: no binary for arm $arm" >&2; exit 1; }
            GARUDA_APP=$app TLS=1 WORKLOADS="$WORKLOADS" SERVERS="garuda" \
                bash "$ROOT/benchmarks/workloads.sh"
        fi
    done
done
