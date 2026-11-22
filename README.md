# zephyr-linux-hypervisor-poc

Proof of concept running Zephyr RTOS next to Linux on one ARM64 SoC under the Xen hypervisor, with tooling to measure real-time latency, inter-OS communication, boot time and fault isolation.

## Architecture

```
┌───────────────────────────────┬────────────────────────────┐
│ Dom0: Debian 13, Linux 6.12   │ DomU: Zephyr 4.1, rt_probe │
│ vCPUs pinned to cores 0-2     │ 1 vCPU pinned to core 3    │
│ xl, load generators, tooling  │ 16 MB RAM                  │
├───────────────────────────────┴────────────────────────────┤
│ Xen 4.20 (EL2): stage-2 MMU, vGICv3, credit2 scheduler      │
├────────────────────────────────────────────────────────────┤
│ QEMU virt: 4x Cortex-A72, GICv3, EL2 enabled                │
│ (stand-in for i.MX8M Plus / i.MX93)                         │
└────────────────────────────────────────────────────────────┘
```

QEMU loads Xen, the Dom0 kernel and initrd directly and passes a device tree with
`multiboot,module` nodes, the same flow U-Boot uses on real boards. No UEFI or GRUB.

## rt_probe

Zephyr application (`zephyr-app/rt_probe`) that measures its own real-time behaviour:

- **Periodic RT task**: highest-priority cooperative thread woken by a 1 ms `k_timer`.
  On every wake-up it reads the ARM generic timer counter and records how late it
  is compared to the ideal schedule. Periods that expired while the thread could not
  run are counted as overruns (missed periods).
- **Report**: once per second a machine-readable line
  `STAT t= n= period_us= min_us= avg_us= max_us= overruns= hist=`.
- **Command channel** over the Xen PV console:
  `PING <seq>` → `PONG <seq>`, `FAULT` (crash on purpose), `PERIOD <us>`.
- **Crash reporting**: the fatal error handler calls `SCHEDOP_shutdown(SHUTDOWN_crash)`,
  so Xen marks the domain crashed and Dom0 can restart it.

`dom0/rtprobe.py` drives it from Linux; `dom0/run_scenarios.sh` runs all scenarios,
with `cyclictest` measuring Linux latency at the same time.

## Results (emulated platform)

30 s per run, rt_probe at 1 kHz, Xen credit2. Compare rows with each other, not with hardware.

| Zephyr placement | Linux load | Avg late | Max late | Missed 1 ms periods |
|---|---|---|---|---|
| Dedicated core | idle | 3 µs | 1.3 ms | 1 (0.003%) |
| Dedicated core | CPU stress | 4 µs | 3.6 ms | 6 (0.02%) |
| Dedicated core | memory stress | 8 µs | 3.2 ms | 7 (0.02%) |
| Shared with Dom0 | idle | 168 µs | 10.2 ms | 1,950 (6.5%) |
| Shared with Dom0 | CPU stress | 8.5 ms | 10.2 ms | 26,761 (89%) |
| Shared with Dom0 | memory stress | 8.3 ms | 10.4 ms | 26,776 (89%) |

Control experiment, rt_probe alone on the same emulator without Xen or Linux:
7 missed periods, 7.3 ms max in 33 s. The rare misses on the dedicated core come
from the emulator, not from Xen.

| Scenario | Result |
|---|---|
| Boot, unpause to first output (5 runs) | 152 ms median, 0.82 s including `xl create` |
| Linux ↔ Zephyr round trip, PV console (200 pings) | 1.9 ms median idle, 1.8 ms under CPU load, no loss |
| Fault isolation | crash detected in 0.2 s, Zephyr restarted in 1.35 s, Linux kept running |

Raw data: `results/`.

**Key finding:** a real-time guest needs its own core. Sharing a core with Linux
lets the hypervisor scheduler hand Linux full ~10 ms time slices, and Zephyr misses
most deadlines.

## Quick start

Host: x86-64 Ubuntu/Debian, no root needed. Requires `qemu-img`, `debugfs`, `sfdisk`,
`dtc`, `curl`, `ssh`, and a Zephyr workspace with Zephyr SDK.

```bash
scripts/setup.sh                       # QEMU 8.2, Debian Dom0 image, Xen (one time, ~15 min)
source <zephyr-workspace>/zephyr/zephyr-env.sh
scripts/build-zephyr.sh                # rt_probe for xenvm//gicv3 and qemu_cortex_a53
HEADLESS=1 scripts/run-xen.sh &        # boot Xen + Dom0 (serial log: build/xen-console.log)
scripts/deploy.sh                      # copy Zephyr image and tools into Dom0
scripts/ssh-dom0.sh 'cd /root/poc && ./run_scenarios.sh 30 && cat results/summary.txt'
scripts/run-baseline.sh                # control experiment without Xen
```

Interactive console: `scripts/run-xen.sh` (Ctrl-a three times switches between Dom0 and Xen).

## Layout

```
zephyr-app/rt_probe/   Zephyr measurement app
dom0/                  rtprobe.py, run_scenarios.sh, cloud-init template
scripts/               setup, provisioning, boot, deploy, baseline
results/               measured data
```

## Versions

Xen 4.20 (Debian 13 package), Linux 6.12, Zephyr 4.1, Zephyr SDK 0.17, QEMU 8.2.

QEMU 7.0 shipped with Zephyr SDK 0.17 hangs the emulated board as soon as a Xen guest
starts (main loop at 100%, all vCPUs idle). Use QEMU 8.2 or newer.

## Limitations

- QEMU emulates the CPU in software (TCG) on a non-real-time host. Absolute latencies
  are not representative; relative effects (dedicated vs shared core) are.
- QEMU does not model caches, so memory-interference effects of real hardware
  (shared L2) are not visible here.
- The PV console is a debug-grade channel; production IPC would use shared memory
  with event channels.

## Next steps

- Run on i.MX8M Plus / i.MX93 hardware, GPIO toggling + oscilloscope for external timing
- Xen tuned for real time: null scheduler cpupool, `vwfi=native`, LLC cache coloring
- Jailhouse variant with the same app and scripts
- Dom0less boot, shared-memory IPC
- Zephyr natively on the Cortex-A cores
