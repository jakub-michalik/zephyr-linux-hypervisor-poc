#!/bin/bash
# Copy the Zephyr guest image and the Dom0 tools into the running Dom0 (/root/poc).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
"$ROOT/scripts/ssh-dom0.sh" 'mkdir -p /root/poc'
scp -q -i "$ROOT/images/poc_key" -P 2222 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$ROOT/build/zephyr/zephyr/zephyr.bin" "$ROOT/dom0/rtprobe.py" "$ROOT/dom0/run_scenarios.sh" \
  root@localhost:/root/poc/
"$ROOT/scripts/ssh-dom0.sh" 'sync; ls -la /root/poc'
