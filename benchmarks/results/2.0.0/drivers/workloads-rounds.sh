#!/usr/bin/env bash
# p7b_rounds.sh [ROUNDS] [WORKLOADS]: on the box, G1 and G2 each in its own
# workloads.sh invocation, the order alternating by round. Logs in ~/g2bench/p7.
ROUNDS=${1:-4}
W=${2:-"user json churn skew spike h2 stream download upload db"}
OUTD=${OUTD:-p7}; mkdir -p ~/g2bench/$OUTD
cd ~/g2bench
export LD_LIBRARY_PATH=$HOME/g2bench/lib OHA=$HOME/.cargo/bin/oha \
  GARUDA_APP=$HOME/g2bench/garuda1-workloads GARUDA2_APP=$HOME/g2bench/garuda2 \
  WORKERS=4 PIN="0,1,4,5:2,3,6,7" DURATION=${DURATION:-5s} WORKLOADS="$W"
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
for r in $(seq 1 "$ROUNDS"); do
  if [ $((r % 2)) = 1 ]; then order="garuda garuda2"; else order="garuda2 garuda"; fi
  for s in $order; do
    echo "== round $r $s"
    SERVERS=$s bash benchmarks/workloads.sh 2>&1 | tee ~/g2bench/$OUTD/wl-r$r-$s.txt
  done
done
