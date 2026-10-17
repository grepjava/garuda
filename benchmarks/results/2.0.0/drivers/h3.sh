#!/usr/bin/env bash
# p7b_h3.sh [ROUNDS] [SERVERS]: on the box, GET /user/12345 over HTTPS/1.1,
# HTTP/2 (ALPN) and HTTP/3, one oha binary (built with --features http3) for all
# three, 64 connections, closed loop, server on CPUs 0,1,4,5 and oha on 2,3,6,7.
# Servers alternate by round and the protocol order rotates. h2x8 and h3x8 put
# 8 streams on each connection (oha -p 8). The rate is requests over -z, not
# oha's requestsPerSec: over HTTP/3 oha waits several seconds after the deadline
# for its QUIC connections to close and divides by that too. busy (requests x
# mean latency / concurrency) shows the load filled the run.
ROUNDS=${1:-3}
SERVERS=${2:-"garuda2 garuda"}
DUR=${DUR:-5s}
CONNS=${CONNS:-64}
OHA=$HOME/oha-h3/bin/oha
OUTD=$HOME/g2bench/${OUTD:-p7h3}
mkdir -p "$OUTD"
export LD_LIBRARY_PATH=$HOME/g2bench/lib
cd "$OUTD"
[ -f cert.pem ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 -subj /CN=localhost \
    -keyout key.pem -out cert.pem > /dev/null 2>&1
URL=https://127.0.0.1:3000/user/12345
desc() { local p=$1 kids; echo "$p"; for k in $(pgrep -P "$p"); do desc "$k"; done; }
ticks() { local t=0 p v; for p in $(desc "$SPID"); do v=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null) || continue; t=$((t+${v:-0})); done; echo $t; }
start() {
  case $1 in
  garuda)  taskset -c 0,1,4,5 $HOME/g2bench/garuda1-workloads --log-level error --host 127.0.0.1 --port 3000 --workers 4 \
             --tls-cert cert.pem --tls-key key.pem --http3 > srv-$1.log 2>&1 & ;;
  garuda2) taskset -c 0,1,4,5 $HOME/g2bench/garuda2 --log-level error --host 127.0.0.1 --port 3000 \
             --tls-cert cert.pem --tls-key key.pem --http3 > srv-$1.log 2>&1 & ;;
  esac
  SPID=$!
  for _ in $(seq 60); do curl -sk -o /dev/null --max-time 1 $URL && break; sleep 0.25; done
  sleep 1
}
stop() { kill -TERM $SPID 2>/dev/null; wait $SPID 2>/dev/null; sleep 1; }
flag() { case $1 in h1) echo "--http-version 1.1";; h2) echo "--http-version 2";; h3) echo "--http-version 3";;
  h2x8) echo "--http-version 2 -p 8";; h3x8) echo "--http-version 3 -p 8";; esac; }
measure() { # server proto round
  local f=$OUTD/$1-$2-r$3.json b a
  taskset -c 2,3,6,7 $OHA -z 1s -c $CONNS --no-tui --insecure $(flag $2) $URL > /dev/null 2>&1
  b=$(ticks); rm -f $f
  /usr/bin/time -f %P -o $f.time taskset -c 2,3,6,7 $OHA -z $DUR -c $CONNS --no-tui --insecure --output-format json -o $f $(flag $2) $URL > /dev/null 2>&1
  a=$(ticks)
  local mult=1; case $2 in *x8) mult=8;; esac
  python3 - $f $((a-b)) $(getconf CLK_TCK) $1 $2 $3 "$(tail -1 $f.time)" ${DUR%s} $(( CONNS * mult )) <<'PY'
import json, sys
f, ticks, hz, srv, proto, r, ohacpu, dur, workers = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), *sys.argv[4:]
dur, workers = float(dur), int(workers)
try: d = json.load(open(f))
except Exception as e: print("%-8s %s r%s  no result (%s)" % (srv, proto, r, e)); raise SystemExit
codes = d.get("statusCodeDistribution") or {}
ok = sum(int(v) for k, v in codes.items() if k.startswith("2"))
n = sum(int(v) for v in codes.values())
errs = (n - ok) + sum(int(v) for k, v in (d.get("errorDistribution") or {}).items() if k != "aborted due to deadline")
p = d.get("latencyPercentiles") or {}
cpu = ticks / hz * 1e6 / n if n else 0
busy = n * (d["summary"].get("average") or 0) / workers
print("%-8s %-4s r%s %9.0f req/s  p50 %6.3f  p99 %7.3f ms  cpu %4.0f us/req  oha %5s  busy %.2fs total %.1fs oha-rps %.0f  errors %d %s" % (srv, proto, r,
      n / dur, (p.get("p50") or 0)*1e3, (p.get("p99") or 0)*1e3, cpu, ohacpu, busy, d["summary"]["total"], d["summary"]["requestsPerSec"], errs,
      "" if errs == 0 else str(d.get("errorDistribution"))[:120]))
PY
}
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
set -- $SERVERS
for r in $(seq 1 $ROUNDS); do
  if [ $((r % 2)) = 1 ]; then order="$*"; else order=$(echo "$@" | awk '{for(i=NF;i>0;i--) printf "%s ", $i}'); fi
  case $((r % 3)) in 1) protos="h1 h2 h3 h2x8 h3x8";; 2) protos="h3x8 h2x8 h3 h2 h1";; 0) protos="h3 h1 h3x8 h2 h2x8";; esac
  for s in $order; do
    start $s
    for pr in $protos; do measure $s $pr $r; done
    stop
  done
done
