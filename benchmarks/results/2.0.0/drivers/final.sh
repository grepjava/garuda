#!/usr/bin/env bash
# box-final.sh [parts]: runs ON the box. The final three-way benchmark, clock
# capped at 2.4 GHz throughout, logs in ~/g2bench/final/.
#   wl     workloads.sh, Garuda 1 / Garuda 2 / axum, 6 rounds, the order rotating
#          so each server is first, second and last twice
#   h3     drivers/h3.sh, Garuda 1 and Garuda 2 (axum's app has no HTTP/3), 4 rounds
#   hello  vs-axum.sh with Garuda 2 and with Garuda 1, 4 rounds each, which of
#          Garuda and axum leads alternating
PARTS=${1:-"wl h3 hello"}
G2=$HOME/g2bench/garuda2-final
G1W=$HOME/g2bench/garuda1-workloads
G1S=$HOME/g2bench/garuda1-server
AXW=$HOME/v27/gh/benchmarks/workloads/axum/target/release/workloads
AXS=$HOME/garuda/benchmarks/axum/target/release/server
OUT=$HOME/g2bench/final; mkdir -p $OUT/workloads $OUT/h3 $OUT/vs-axum
restore() { for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do sudo cp $c/cpuinfo_max_freq $c/scaling_max_freq; done; echo "clock restored $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"; }
trap restore EXIT
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do echo 2400000 | sudo tee $c >/dev/null; done
cd ~/g2bench
export LD_LIBRARY_PATH=$HOME/g2bench/lib OHA=$HOME/.cargo/bin/oha
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date -Is)"
for b in $G2 $G1W $G1S; do ldd $b | grep "not found"; done

if [[ " $PARTS " == *" wl "* ]]; then
  orders=("garuda garuda2 axum" "garuda2 axum garuda" "axum garuda garuda2" "garuda axum garuda2" "garuda2 garuda axum" "axum garuda2 garuda")
  for r in 1 2 3 4 5 6; do
    for s in ${orders[$((r-1))]}; do
      echo "== workloads round $r $s"
      GARUDA_APP=$G1W GARUDA2_APP=$G2 AXUM_APP=$AXW WORKERS=4 PIN="0,1,4,5:2,3,6,7" \
        WORKLOADS="user json churn skew spike h2 stream download upload db" SERVERS=$s \
        bash benchmarks/workloads.sh 2>&1 | tee $OUT/workloads/wl-r$r-$s.txt
    done
  done
fi

if [[ " $PARTS " == *" h3 "* ]]; then
  sed -e "s#\$HOME/g2bench/garuda2 #$G2 #" ~/v27/gh/benchmarks/results/2.0.0/drivers/h3.sh > $OUT/h3.sh
  OUTD=final/h3 bash $OUT/h3.sh 4 "garuda2 garuda" 2>&1 | tee $OUT/h3/h3.log
fi

if [[ " $PARTS " == *" hello "* ]]; then
  sed 's/FRAMEWORKS="swift rust" SERVERS="garuda axum"/FRAMEWORKS="rust swift" SERVERS="axum garuda"/' benchmarks/vs-axum.sh > benchmarks/vs-axum-rev.sh
  for r in 1 2 3 4; do
    if [ $((r % 2)) = 1 ]; then runs="g2:fwd g1:rev"; else runs="g1:fwd g2:rev"; fi
    for x in $runs; do
      g=${x%%:*} d=${x#*:}
      bin=$G2; [ $g = g1 ] && bin=$G1S
      s=benchmarks/vs-axum.sh; lead=garuda-first
      [ $d = rev ] && { s=benchmarks/vs-axum-rev.sh; lead=axum-first; }
      echo "== hello round $r $g $lead"
      GARUDA=$bin AXUM=$AXS bash $s 2>&1 | tee $OUT/vs-axum/$g-$lead-r$r.txt
    done
  done
  rm -f benchmarks/vs-axum-rev.sh
fi
echo "done $(date -Is)"
