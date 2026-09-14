#!/usr/bin/env bash
# A/B two builds of garuda._native on one worker -- a raw ASGI app and
# FastAPI, closed-loop oha, rounds interleaved in one session -- with the
# server CPU each request costs. For deciding whether a change on the ASGI path
# is kept.
#
#   BUILD_A=/mnt/d/code/garuda-main BUILD_B=/mnt/d/code/garuda \
#       bash benchmarks/turbo_ab.sh
#
# BUILD_A and BUILD_B are checkouts whose python/garuda holds a built
# _native (scripts/build-extension.sh). Before the rounds, A runs twice: the
# difference between those two runs is this session's noise, and a change
# smaller than it is not a result. With BUILD_A and BUILD_B the same, the whole
# run is an A/A.
#
# The server is pinned to one CPU and oha to the others, so the two do not take
# turns on a core. The CPU figure is the server's own -- every thread of every
# process in its tree, from /proc/<pid>/task/*/schedstat -- divided by the
# requests oha completed. It moves less than req/s when what is short of CPU
# is the load generator.
#
# Rounds alternate the order, A B then B A, so neither build always runs first.
# The zrk ramp in frameworks.sh is not used: it offers at most ~96,500 req/s,
# and a raw app on one worker can reach that.
#
# Output: one TSV line per run, then per app the median of each build, how
# many rounds B won, and the A/A spread.
#   app run build req/s p50_ms p99_ms cpu_us_per_req
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_A=${BUILD_A:?set BUILD_A to a checkout with a built extension}
BUILD_B=${BUILD_B:?set BUILD_B to a checkout with a built extension}
VENV=${VENV:-$HOME/pgvenv}
OHA=${OHA:-oha}
PORT=${PORT:-8212}
DURATION=${DURATION:-15s}
CONNS=${CONNS:-64}
ROUNDS=${ROUNDS:-6}
APPS=${APPS:-"asgi fastapi"}
SERVER_CPU=${SERVER_CPU:-0}
LOAD_CPUS=${LOAD_CPUS:-1-3}
# Extra server flags for each side, e.g. EXTRA_B="--no-uvloop".
EXTRA_A=${EXTRA_A:-}
EXTRA_B=${EXTRA_B:-}
URL="http://127.0.0.1:$PORT/"
OUT=$(mktemp -d)
RESULTS="$OUT/results.tsv"

# shellcheck source=scripts/serverlib.sh
. "$ROOT/scripts/serverlib.sh"
trap 'server_stop; exit 130' INT TERM
trap 'server_stop; rm -rf "$OUT"' EXIT
server_require_port_free "$PORT" || exit 1

# Nanoseconds on CPU so far, over every thread of the server and its children.
server_cpu_ns() {
    local pid total=0 ns
    for pid in $(server_descendants "$SERVER_PID"); do
        for ns in $(cat /proc/"$pid"/task/*/schedstat 2>/dev/null | awk '{print $1}'); do
            total=$((total + ns))
        done
    done
    echo "$total"
}

start() {
    local build=$1 extra=$2 target=$3
    server_stop
    # shellcheck disable=SC2086 -- extra is deliberately split into flags.
    PYTHONPATH="$build/python:$ROOT/benchmarks/contract" server_start \
        taskset -c "$SERVER_CPU" "$VENV/bin/python" -m garuda \
        --host 127.0.0.1 --port "$PORT" --workers 1 --log-level error $extra \
        --venv "$VENV" --python-path "$ROOT/benchmarks/contract" "$target" \
        > "$OUT/server.log" 2>&1
    for _ in $(seq 1 60); do
        curl -s -o /dev/null --max-time 1 "$URL" && return 0
        sleep 0.25
    done
    return 1
}

# One measured run against whatever start() left running.
measure() {
    local before after
    taskset -c "$LOAD_CPUS" "$OHA" -z 3s -c "$CONNS" --no-tui "$URL" > /dev/null 2>&1
    before=$(server_cpu_ns)
    taskset -c "$LOAD_CPUS" "$OHA" -z "$DURATION" -c "$CONNS" --no-tui \
        --output-format json -o "$OUT/oha.json" "$URL" > /dev/null 2>&1
    after=$(server_cpu_ns)
    python3 - "$OUT/oha.json" "$before" "$after" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("0\t0\t0\t0")
    raise SystemExit
requests = sum(int(v) for v in (d.get("statusCodeDistribution") or {}).values())
pct = d.get("latencyPercentiles") or {}
cpu_us = (int(sys.argv[3]) - int(sys.argv[2])) / 1000.0 / max(requests, 1)
print("%.0f\t%.3f\t%.3f\t%.2f" % (d["summary"]["requestsPerSec"],
                                   (pct.get("p50") or 0) * 1000,
                                   (pct.get("p99") or 0) * 1000, cpu_us))
PY
}

run() {
    local app=$1 target=$2 label=$3 side=$4 build extra
    if [ "$side" = A ]; then build=$BUILD_A; extra=$EXTRA_A; else build=$BUILD_B; extra=$EXTRA_B; fi
    if ! start "$build" "$extra" "$target"; then
        printf '%s\t%s\t%s\tFAILED TO START\n' "$app" "$label" "$side" >&2
        tail -5 "$OUT/server.log" >&2
        return 1
    fi
    printf '%s\t%s\t%s\t%s\n' "$app" "$label" "$side" "$(measure)" | tee -a "$RESULTS"
}

echo "A: $BUILD_A $EXTRA_A"
echo "B: $BUILD_B $EXTRA_B"
echo "python: $("$VENV/bin/python" -c 'import sys; print(sys.version.split()[0])')" \
    "  load: oha -c $CONNS -z $DURATION, server on CPU $SERVER_CPU, oha on $LOAD_CPUS"
printf 'app\trun\tbuild\treq/s\tp50_ms\tp99_ms\tcpu_us_per_req\n'
for app in $APPS; do
    case "$app" in
    asgi)    target=asgi:app ;;
    fastapi) target=fastapi_app:app ;;
    *) echo "unknown app: $app" >&2; continue ;;
    esac
    run "$app" "$target" aa1 A
    run "$app" "$target" aa2 A
    for r in $(seq 1 "$ROUNDS"); do
        if [ $((r % 2)) = 1 ]; then
            run "$app" "$target" "r$r" A; run "$app" "$target" "r$r" B
        else
            run "$app" "$target" "r$r" B; run "$app" "$target" "r$r" A
        fi
    done
done
server_stop

python3 - "$RESULTS" <<'PY'
import statistics, sys
rows = [l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l.strip()]
for app in dict.fromkeys(r[0] for r in rows):
    mine = [r for r in rows if r[0] == app]
    def pick(run, side):
        return next((r for r in mine if r[1] == run and r[2] == side), None)
    aa = [pick(x, "A") for x in ("aa1", "aa2")]
    rounds = sorted({r[1] for r in mine if r[1].startswith("r")}, key=lambda s: int(s[1:]))
    a = [pick(x, "A") for x in rounds]
    b = [pick(x, "B") for x in rounds]
    med = lambda rs, i: statistics.median(float(r[i]) for r in rs)
    rps_a, rps_b, cpu_a, cpu_b = med(a, 3), med(b, 3), med(a, 6), med(b, 6)
    faster = sum(float(y[3]) > float(x[3]) for x, y in zip(a, b))
    cheaper = sum(float(y[6]) < float(x[6]) for x, y in zip(a, b))
    both = sum(float(y[3]) > float(x[3]) and float(y[6]) < float(x[6]) for x, y in zip(a, b))
    aa_rps = abs(float(aa[0][3]) - float(aa[1][3])) / statistics.mean(float(r[3]) for r in aa) * 100
    aa_cpu = abs(float(aa[0][6]) - float(aa[1][6])) / statistics.mean(float(r[6]) for r in aa) * 100
    print()
    print(f"{app}: A {rps_a:,.0f} req/s {cpu_a:.2f} us/req   B {rps_b:,.0f} req/s {cpu_b:.2f} us/req")
    print(f"  B vs A: req/s {100 * (rps_b / rps_a - 1):+.1f}%  cpu/req {100 * (cpu_b / cpu_a - 1):+.1f}%")
    print(f"  rounds B faster {faster}/{len(rounds)}, cheaper {cheaper}/{len(rounds)}, both {both}/{len(rounds)}")
    print(f"  A/A spread: req/s {aa_rps:.1f}%  cpu/req {aa_cpu:.1f}%")
PY
