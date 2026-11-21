#!/bin/bash
# Boot Xen + Linux Dom0 on an emulated ARM64 board (QEMU virt, EL2 enabled).
# QEMU loads Xen as the "kernel" and places the Dom0 kernel/initrd in RAM;
# a patched device tree tells Xen where they are (multiboot modules).
#   scripts/run-xen.sh           -> interactive serial console (Xen + Dom0)
#   HEADLESS=1 scripts/run-xen.sh -> no stdin, log to build/xen-console.log
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
QEMU=${QEMU:-$ROOT/tools/qemu82/usr/bin/qemu-system-aarch64}
IMG=$ROOT/images
B=$ROOT/build
mkdir -p "$B"

SMP=4
MEM=4G
MACHINE="virt,virtualization=on,gic-version=3"
KERNEL_ADDR=0x50000000
INITRD_ADDR=0x54000000

XEN_ARGS=${XEN_ARGS:-"console=dtuart dtuart=/pl011@9000000 dom0_mem=1024M dom0_max_vcpus=3 dom0_vcpus_pin sched=credit2 bootscrub=0"}
DOM0_ARGS=${DOM0_ARGS:-"console=hvc0 earlycon=xen root=/dev/vda1 rw clk_ignore_unused"}

KSIZE=$(printf '0x%x' "$(stat -c %s "$IMG/vmlinuz")")
ISIZE=$(printf '0x%x' "$(stat -c %s "$IMG/initrd.img")")

# 1. dump the board's device tree, 2. add Xen boot info, 3. recompile
"$QEMU" -M "$MACHINE,dumpdtb=$B/virt.dtb" -cpu cortex-a72 -smp $SMP -m $MEM -nographic >/dev/null 2>&1
dtc -q -I dtb -O dts "$B/virt.dtb" > "$B/virt.dts"
cat >> "$B/virt.dts" <<EOF

/ {
	chosen {
		#address-cells = <0x2>;
		#size-cells = <0x2>;
		xen,xen-bootargs = "$XEN_ARGS";
		xen,dom0-bootargs = "$DOM0_ARGS";
		stdout-path = "/pl011@9000000";
		module@${KERNEL_ADDR#0x} {
			compatible = "multiboot,kernel", "multiboot,module";
			reg = <0x0 $KERNEL_ADDR 0x0 $KSIZE>;
		};
		module@${INITRD_ADDR#0x} {
			compatible = "multiboot,ramdisk", "multiboot,module";
			reg = <0x0 $INITRD_ADDR 0x0 $ISIZE>;
		};
	};
};
EOF
dtc -q -I dts -O dtb "$B/virt.dts" -o "$B/virt-xen.dtb"

QARGS=(-M "$MACHINE" -cpu cortex-a72 -smp $SMP -m $MEM
  -dtb "$B/virt-xen.dtb" -kernel "$IMG/xen"
  -device loader,file="$IMG/vmlinuz",addr=$KERNEL_ADDR,force-raw=on
  -device loader,file="$IMG/initrd.img",addr=$INITRD_ADDR,force-raw=on
  -drive if=none,file="$IMG/dom0.qcow2",id=hd0,format=qcow2 -device virtio-blk-device,drive=hd0
  -netdev user,id=n0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=n0)

if [ "${HEADLESS:-0}" = 1 ]; then
  # serial console on a unix socket (scripts/serial.py talks to it), logged to file
  rm -f "$B/serial.sock" "$B/xen-console.log"
  exec "$QEMU" "${QARGS[@]}" -display none -monitor none \
    -chardev socket,id=ser0,path="$B/serial.sock",server=on,wait=off,logfile="$B/xen-console.log" \
    -serial chardev:ser0 < /dev/null > "$B/qemu.log" 2>&1
else
  exec "$QEMU" "${QARGS[@]}" -nographic
fi
