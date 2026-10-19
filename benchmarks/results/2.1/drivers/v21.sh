#!/usr/bin/env bash
# v21.sh [parts]: runs ON the box. Garuda 2.1 against 2.0.0 (fresh builds:
# tag 2.0.0, and 2.1.0 with 2.1.1's Linux fixes) with axum as the fixed reference, the 2.0.0
# final benchmark's drivers and settings, clock capped at 2.4 GHz throughout,
# logs in ~/g2bench/v21/.
#   wl     workloads.sh, 2.0.0 / 2.1.0 / axum, 6 rounds, the order rotating so
#          each server is first, second and last twice
#   h3     the 2.0.0 HTTP/3 driver, 2.0.0 and 2.1.0, 4 rounds
#   hello  vs-axum.sh with 2.0.0 and with 2.1.0, 4 rounds each, which of
#          Garuda and axum leads alternating
PARTS=${1:-"wl h3 hello"}
G200=$HOME/g2bench/garuda2-v200
G210=$HOME/g2bench/garuda2-v210
ln -sf $HOME/g2bench/garuda-200 $G200
ln -sf $HOME/g2bench/garuda-210 $G210
AXW=$HOME/v27/gh/benchmarks/workloads/axum/target/release/workloads
AXS=$HOME/garuda/benchmarks/axum/target/release/server
OUT=$HOME/g2bench/v21; mkdir -p $OUT/workloads $OUT/h3 $OUT/vs-axum
restore() { for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do sudo cp $c/cpuinfo_max_freq $c/scaling_max_freq; done; echo "clock restored $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"; }
trap restore EXIT
for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do echo 2400000 | sudo tee $c >/dev/null; done
cd ~/g2bench
export LD_LIBRARY_PATH=$HOME/g2bench/lib OHA=$HOME/.cargo/bin/oha
echo "clock $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq) $(date -Is)"
for b in $G200 $G210 $AXW $AXS; do ls -la $b >/dev/null || exit 1; ldd $b | grep "not found"; done

if [[ " $PARTS " == *" wl "* ]]; then
  orders=("v200 v210 axum" "v210 axum v200" "axum v200 v210" "v200 axum v210" "v210 v200 axum" "axum v210 v200")
  for r in 1 2 3 4 5 6; do
    for s in ${orders[$((r-1))]}; do
      echo "== workloads round $r $s"
      case $s in
        axum) app=$G210; srv=axum ;;
        v200) app=$G200; srv=garuda2 ;;
        v210) app=$G210; srv=garuda2 ;;
      esac
      GARUDA2_APP=$app AXUM_APP=$AXW WORKERS=4 PIN="0,1,4,5:2,3,6,7" \
        WORKLOADS="user json churn skew spike h2 stream download upload db" SERVERS=$srv \
        bash benchmarks/workloads.sh 2>&1 | tee $OUT/workloads/wl-r$r-$s.txt
    done
  done
fi

if [[ " $PARTS " == *" h3 "* ]]; then
  sed -e 's#\$HOME/g2bench/garuda2 #$HOME/g2bench/$1 #' -e 's#^  garuda2) #  garuda2*) #' \
    ~/v27/gh/benchmarks/results/2.0.0/drivers/h3.sh > $OUT/h3.sh
  grep -c 'garuda2\*)' $OUT/h3.sh
  OUTD=v21/h3 bash $OUT/h3.sh 4 "garuda2-v200 garuda2-v210" 2>&1 | tee $OUT/h3/h3.log
fi

if [[ " $PARTS " == *" hello "* ]]; then
  sed 's/FRAMEWORKS="swift rust" SERVERS="garuda axum"/FRAMEWORKS="rust swift" SERVERS="axum garuda"/' benchmarks/vs-axum.sh > benchmarks/vs-axum-rev.sh
  for r in 1 2 3 4; do
    if [ $((r % 2)) = 1 ]; then runs="v210:fwd v200:rev"; else runs="v200:fwd v210:rev"; fi
    for x in $runs; do
      g=${x%%:*} d=${x#*:}
      bin=$G210; [ $g = v200 ] && bin=$G200
      s=benchmarks/vs-axum.sh; lead=garuda-first
      [ $d = rev ] && { s=benchmarks/vs-axum-rev.sh; lead=axum-first; }
      echo "== hello round $r $g $lead"
      GARUDA=$bin AXUM=$AXS bash $s 2>&1 | tee $OUT/vs-axum/$g-$lead-r$r.txt
    done
  done
  rm -f benchmarks/vs-axum-rev.sh
fi
echo "done $(date -Is)"
