#!/bin/bash
# Runs all quality scenarios in Dom0 and writes results/summary.txt
# Usage: ./run_scenarios.sh [seconds_per_run]
set -u
cd "$(dirname "$0")"
DUR=${1:-30}
R=results
mkdir -p $R
: > $R/summary.txt
log() { echo "$*" | tee -a $R/summary.txt; }

load_start() {
  case $1 in
    idle) LOADPID= ;;
    cpu)  stress-ng --cpu 3 --timeout $((DUR + 5))s >/dev/null 2>&1 & LOADPID=$! ;;
    mem)  stress-ng --vm 3 --vm-bytes 128M --timeout $((DUR + 5))s >/dev/null 2>&1 & LOADPID=$! ;;
  esac
  sleep 2
}
load_stop() { [ -n "${LOADPID:-}" ] && kill $LOADPID 2>/dev/null; wait 2>/dev/null; LOADPID=; }

log "# Zephyr-on-Xen PoC results  $(date -Is)"
log "# xen: $(xl info | awk -F': ' '/xen_version/{print $2}')  sched: $(xl info | awk -F': ' '/xen_scheduler/{print $2}')  dom0: $(uname -r)"
log "# run length: ${DUR}s per scenario"

# placement: dedicated = Zephyr alone on pCPU3 (Dom0 vCPUs pinned to 0-2)
#            shared    = Zephyr on pCPU0, competing with a Dom0 vCPU
for placement in dedicated shared; do
  cpus=3; [ $placement = shared ] && cpus=0
  ./rtprobe.py create --cpus $cpus >/dev/null
  sleep 3
  for load in idle cpu mem; do
    load_start $load
    cyclictest -q -m -t1 -p90 -i1000 -D${DUR}s > $R/cyclictest_${placement}_${load}.txt 2>&1 &
    CT=$!
    res=$(./rtprobe.py collect $DUR $R/zephyr_${placement}_${load}.csv)
    wait $CT
    ct=$(awk '/T: 0/{for(i=1;i<=NF;i++){if($i=="Min:")mn=$(i+1);if($i=="Avg:")av=$(i+1);if($i=="Max:")mx=$(i+1)}} END{print "min_us="mn" avg_us="av" max_us="mx}' $R/cyclictest_${placement}_${load}.txt)
    load_stop
    log "LATENCY placement=$placement load=$load zephyr: $res | linux cyclictest: $ct"
  done
done

./rtprobe.py create --cpus 3 >/dev/null; sleep 3
log "IPC load=idle $(./rtprobe.py ping 200 10)"
load_start cpu
log "IPC load=cpu  $(./rtprobe.py ping 200 10)"
load_stop

log "BOOT $(./rtprobe.py boot 5 --cpus 3)"
log "FAULT $(./rtprobe.py fault)"
log "# done"
