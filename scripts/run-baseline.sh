#!/bin/bash
# Control experiment: rt_probe alone on the emulated ARM64 board (no Xen, no Linux).
# Shows how much lateness the emulator itself adds.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-$ROOT/tools/qemu82/usr/bin/qemu-system-aarch64}
DUR=${1:-35}
LOG=$ROOT/build/native-run.log

timeout "$DUR" "$QEMU" -M virt,secure=on,gic-version=3 -cpu cortex-a53 -nographic \
  -kernel "$ROOT/build/zephyr-native/zephyr/zephyr.elf" < /dev/null > "$LOG" 2>&1 || true
# skip the first (partial) second, then summarise
grep -a '^STAT' "$LOG" | tail -n +2 | awk '{
  for (i = 1; i <= NF; i++) { split($i, a, "="); v[a[1]] = a[2] }
  n++; s += v["avg_us"]; if (v["max_us"] + 0 > mx) mx = v["max_us"] + 0
  ov += v["overruns"]; tot += v["n"]
} END { printf "BASELINE seconds=%d wakeups=%d avg_us=%.1f max_us=%d overruns=%d\n", n, tot, s / n, mx, ov }'
