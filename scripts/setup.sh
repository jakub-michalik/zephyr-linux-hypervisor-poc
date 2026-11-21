#!/bin/bash
# One-time host setup, no root needed:
#   1. QEMU 8.2 (extracted locally from Ubuntu/Debian packages)
#   2. Debian 13 arm64 cloud image as Dom0 disk, kernel + initrd extracted
#   3. SSH key and cloud-init seed
#   4. first boot without Xen: installs Xen, stress-ng, rt-tests (scripts/provision.sh)
#   5. Xen hypervisor binary extracted from the provisioned disk
# Set QEMU=/path/to/qemu-system-aarch64 to skip step 1 (QEMU >= 8.2 recommended;
# QEMU 7.0 from Zephyr SDK 0.17 hangs as soon as a Xen guest starts).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$ROOT/images
B=$ROOT/build
mkdir -p "$IMG" "$B" "$ROOT/tools"
DEBIAN_URL=${DEBIAN_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-arm64.qcow2}

step() { echo; echo "=== $*"; }

# --- 1. QEMU
if [ -z "${QEMU:-}" ] && [ ! -x "$ROOT/tools/qemu82/usr/bin/qemu-system-aarch64" ]; then
  step "Fetching QEMU (qemu-system-arm) packages"
  mkdir -p "$ROOT/tools/debs" && cd "$ROOT/tools/debs"
  apt-get download qemu-system-arm qemu-system-common qemu-system-data
  for d in *.deb; do dpkg-deb -x "$d" "$ROOT/tools/qemu82"; done
  cd "$ROOT"
fi
QEMU=${QEMU:-$ROOT/tools/qemu82/usr/bin/qemu-system-aarch64}
"$QEMU" --version | head -1

# --- 2. Dom0 disk, kernel, initrd
if [ ! -f "$IMG/dom0.qcow2" ]; then
  step "Downloading Debian arm64 image"
  curl -fL -o "$IMG/debian-arm64.qcow2" "$DEBIAN_URL"
  cp "$IMG/debian-arm64.qcow2" "$IMG/dom0.qcow2"
  qemu-img resize -q "$IMG/dom0.qcow2" 12G
fi

# extract the root partition (GPT partition 1) to a raw ext4 file for debugfs
extract_root() {
  qemu-img convert -O raw "$IMG/dom0.qcow2" "$B/disk.raw"
  local start size
  read -r start size < <(sfdisk -d "$B/disk.raw" | awk -F'[=,]' '/disk.raw1 :/{gsub(/ /,"");print $2, $4}')
  dd if="$B/disk.raw" of="$B/root.ext4" bs=512 skip="$start" count="$size" status=none
  rm -f "$B/disk.raw"
}

if [ ! -f "$IMG/vmlinuz" ]; then
  step "Extracting Dom0 kernel and initrd"
  extract_root
  KVER=$(debugfs -R "ls /boot" "$B/root.ext4" 2>/dev/null | tr ' ' '\n' | sed -n 's/^vmlinuz-//p' | head -1)
  debugfs -R "dump /boot/vmlinuz-$KVER $IMG/vmlinuz" "$B/root.ext4" 2>/dev/null
  debugfs -R "dump /boot/initrd.img-$KVER $IMG/initrd.img" "$B/root.ext4" 2>/dev/null
  rm -f "$B/root.ext4"
  echo "kernel $KVER"
fi

# --- 3. SSH key + cloud-init seed
[ -f "$IMG/poc_key" ] || ssh-keygen -q -t ed25519 -N "" -f "$IMG/poc_key" -C zephyr-poc
mkdir -p "$IMG/seed"
sed "s|@SSH_KEY@|$(cat "$IMG/poc_key.pub")|" "$ROOT/dom0/cloud-init/user-data.in" > "$IMG/seed/user-data"
cp "$ROOT/dom0/cloud-init/meta-data" "$IMG/seed/meta-data"
touch "$IMG/seed/vendor-data"

# --- 4. first boot: install Xen and test tools
if [ ! -f "$IMG/xen" ]; then
  step "First boot without Xen: installing packages (several minutes, powers off by itself)"
  QEMU="$QEMU" "$ROOT/scripts/provision.sh" > "$B/provision.log" 2>&1 < /dev/null
  grep -a "Setting up xen-hypervisor" "$B/provision.log" || { echo "Xen install not found, see build/provision.log"; exit 1; }

  # --- 5. Xen binary
  step "Extracting Xen hypervisor"
  extract_root
  XEN=$(debugfs -R "ls /boot" "$B/root.ext4" 2>/dev/null | tr ' ' '\n' | grep -E '^xen-[0-9.]+-arm64$' | head -1)
  debugfs -R "dump /boot/$XEN $IMG/xen" "$B/root.ext4" 2>/dev/null
  rm -f "$B/root.ext4"
  echo "$XEN"
fi

step "Done. Next: scripts/build-zephyr.sh, HEADLESS=1 scripts/run-xen.sh &, scripts/deploy.sh"
