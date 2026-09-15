#!/usr/bin/env bash
# Garuda against the-benchmarker/web-frameworks' axum entry, quickly: one run
# per pass at 64 connections, under two minutes in all. A quick read between
# changes, not a figure to publish; for that, frameworks.sh with RUNS=3 and
# every level.
#
#   swift build -c release --product garuda && bash benchmarks/vs-axum.sh
#
# Passes, each Garuda then axum:
#   ramp    the suite's zrk command for 15 s; Garuda's 4 workers, Tokio's 4 threads
#   closed  closed-loop oha for 10 s, the same processes: capacity, not the ramp
#   pinned  closed-loop oha for 10 s, server on CPU 0 and load on CPUs 1-3,
#           one Garuda worker against one Tokio thread
#
# Needs what frameworks.sh needs for garuda and axum: zrk, oha, python3, curl,
# cargo for the first axum build, and port 3000.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GARUDA=${GARUDA:-$ROOT/.build/release/garuda}
began=$(date +%s)

pass() {
    local name=$1
    shift
    env CONNS=64 RUNS=1 WARMUP=2s GARUDA="$GARUDA" FRAMEWORKS="swift rust" SERVERS="garuda axum" "$@" \
        bash "$ROOT/benchmarks/frameworks.sh" | grep -v '^framework' | awk -F'\t' -v pass="$name" '
            NF < 5 { print; fflush(); next }
            { split($5, f, " ")
              printf "%-7s %-7s %9s req/s   p50 %8s ms   p99 %9s ms   errors %s\n",
                     pass, $2, f[1], f[2], f[5], f[6]
              fflush() }'
}

pass ramp WORKERS=4 DURATION=15s
pass closed WORKERS=4 DURATION=10s LOAD=closed
pass pinned WORKERS=1 DURATION=10s LOAD=closed PIN=0:1-3
echo "$(($(date +%s) - began)) s"
