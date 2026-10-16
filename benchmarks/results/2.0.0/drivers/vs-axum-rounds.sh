#!/usr/bin/env bash
# p7b_axum.sh [ROUNDS]: vs-axum.sh with Garuda 2, the order within each pass
# alternating by round (odd: garuda first, even: axum first).
cd ~/g2bench
export LD_LIBRARY_PATH=$HOME/g2bench/lib GARUDA=$HOME/g2bench/garuda2 OHA=$HOME/.cargo/bin/oha \
  AXUM=$HOME/garuda/benchmarks/axum/target/release/server
sed 's/FRAMEWORKS="swift rust" SERVERS="garuda axum"/FRAMEWORKS="rust swift" SERVERS="axum garuda"/' benchmarks/vs-axum.sh > benchmarks/vs-axum-rev.sh
mkdir -p p7
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
for r in $(seq 1 ${1:-4}); do
  s=benchmarks/vs-axum-rev.sh
  echo "== round $r $s"
  bash $s 2>&1 | tee p7/axum-rev-r$r.txt
done
rm -f benchmarks/vs-axum-rev.sh
