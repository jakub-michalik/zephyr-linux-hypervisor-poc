#!/bin/bash
# First boot of the Debian arm64 image WITHOUT Xen: cloud-init installs Xen,
# stress-ng and rt-tests, then powers off. Run once.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-$ROOT/tools/qemu82/usr/bin/qemu-system-aarch64}
IMG=$ROOT/images

# serve cloud-init NoCloud seed to the guest (host is 10.0.2.2 from QEMU user net)
python3 -m http.server 8765 --bind 127.0.0.1 --directory "$IMG/seed" >/dev/null 2>&1 &
HTTP=$!
trap 'kill $HTTP' EXIT

"$QEMU" -M virt,gic-version=3 -cpu cortex-a72 -smp 4 -m 4G -nographic \
  -kernel "$IMG/vmlinuz" -initrd "$IMG/initrd.img" \
  -append "root=/dev/vda1 rw console=ttyAMA0 ds=nocloud;s=http://10.0.2.2:8765/" \
  -drive if=none,file="$IMG/dom0.qcow2",id=hd0,format=qcow2 -device virtio-blk-device,drive=hd0 \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=n0
