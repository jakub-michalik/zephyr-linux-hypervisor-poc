#!/bin/bash
# Build rt_probe for:
#   xenvm//gicv3     Zephyr as Xen guest (build/zephyr/zephyr/zephyr.bin)
#   qemu_cortex_a53  Zephyr alone on emulated ARM64, control experiment (build/zephyr-native)
# Needs a Zephyr workspace: source <workspace>/zephyr/zephyr-env.sh first (tested with Zephyr 4.1, SDK 0.17).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
: "${ZEPHYR_BASE:?source zephyr/zephyr-env.sh from your Zephyr workspace first}"
export ZEPHYR_TOOLCHAIN_VARIANT=${ZEPHYR_TOOLCHAIN_VARIANT:-zephyr}
APP=$ROOT/zephyr-app/rt_probe

west build -p -b xenvm//gicv3 "$APP" -d "$ROOT/build/zephyr" --no-sysbuild
west build -p -b qemu_cortex_a53 "$APP" -d "$ROOT/build/zephyr-native" --no-sysbuild
ls -la "$ROOT/build/zephyr/zephyr/zephyr.bin" "$ROOT/build/zephyr-native/zephyr/zephyr.elf"
