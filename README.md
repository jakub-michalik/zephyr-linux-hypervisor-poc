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

## Requirements

**Host**

- x86-64 Linux with `apt-get` (tested on Ubuntu 24.04). `scripts/setup.sh` downloads the
  QEMU 8.2 packages with `apt-get download` and unpacks them into `tools/`, so QEMU does
  not have to be installed system-wide. On other distributions install QEMU >= 8.2 and
  pass its path in `QEMU=/path/to/qemu-system-aarch64`.
- 4+ CPU cores, 8 GB RAM (the emulated board uses 4 GB), about 5 GB free disk.
- Internet access during setup (Debian image ~430 MB, Xen packages inside the guest).
- Free TCP port 2222 on localhost (SSH into Dom0).

**Host packages** (one-time, the only step that needs root):

```bash
sudo apt install qemu-utils e2fsprogs fdisk device-tree-compiler curl openssh-client python3
```

| Tool | Package | Used for |
|---|---|---|
| `qemu-img` | qemu-utils | convert and resize the Dom0 disk |
| `debugfs` | e2fsprogs | copy kernel, initrd and Xen out of the disk image without mounting |
| `sfdisk` | fdisk | find the root partition |
| `dtc` | device-tree-compiler | add Xen boot nodes to the board device tree |
| `ssh`, `scp` | openssh-client | access Dom0 |

**Zephyr**

- A Zephyr workspace at v4.1 (upstream Zephyr 4.1, or nRF Connect SDK 3.1 which contains it).
- Zephyr SDK 0.17.x with the `aarch64-zephyr-elf` toolchain.

If you have neither, follow the
[Zephyr Getting Started Guide](https://docs.zephyrproject.org/latest/develop/getting_started/index.html),
in short:

```bash
pip install west
west init -m https://github.com/zephyrproject-rtos/zephyr --mr v4.1.0 ~/zephyrproject
cd ~/zephyrproject && west update && west zephyr-export
pip install -r zephyr/scripts/requirements.txt
# install Zephyr SDK 0.17.x (at least the aarch64 toolchain) as described in the guide
```

## Setup (one time)

```bash
scripts/setup.sh
```

Takes about 15 minutes and runs without root:

1. unpacks QEMU 8.2 into `tools/qemu82`,
2. downloads the Debian 13 arm64 cloud image into `images/dom0.qcow2` and copies the
   kernel and initrd out of it,
3. creates an SSH key (`images/poc_key`) and a cloud-init seed,
4. boots Debian once without Xen; cloud-init installs `xen-system-arm64`, `stress-ng`,
   `rt-tests` and powers off (log: `build/provision.log`),
5. copies the Xen hypervisor binary out of the disk (`images/xen`).

Running it again skips steps that are already done.

Then build the Zephyr app:

```bash
source ~/zephyrproject/zephyr/zephyr-env.sh    # your Zephyr workspace
scripts/build-zephyr.sh
```

This builds `rt_probe` twice: for the Xen guest (`build/zephyr/zephyr/zephyr.bin`) and
for the bare emulated board used in the control experiment (`build/zephyr-native`).

## Run

```bash
HEADLESS=1 scripts/run-xen.sh &     # boot Xen + Dom0 in the background
tail -f build/xen-console.log       # optional: wait for "dom0 login:" (~30 s)
scripts/deploy.sh                   # copy zephyr.bin and the tools to /root/poc in Dom0
scripts/ssh-dom0.sh                 # shell in Dom0 (user root, key-based)
```

The serial console of the board is also reachable through `scripts/serial.py`
(e.g. `scripts/serial.py 'xen:q'` sends Xen debug key `q`). For an interactive serial
console run `scripts/run-xen.sh` in the foreground instead; press Ctrl-a three times to
switch input between Dom0 and Xen.

Stop the board:

```bash
kill $(pgrep -f 'qemu-system-aarch64.*virt-xen')
```

## Test

**Smoke test** (about 1 minute), from the host:

```bash
scripts/ssh-dom0.sh 'cd /root/poc && ./rtprobe.py create --cpus 3 && xl list \
  && ./rtprobe.py collect 5 /tmp/smoke.csv && ./rtprobe.py ping 20 10 && ./rtprobe.py fault'
```

Expected output (numbers vary):

```
BOOT uptime_ms=3 timer_hz=62500000 create+boot_ms=895 boot_ms=152
Name                                        ID   Mem VCPUs	State	Time(s)
Domain-0                                     0  1024     3     r-----      76.3
zephyr                                       1    16     1     -b----       0.0
samples_s=5 min_us=0 avg_us=0 max_us=172 overruns=0
pings=20 lost=0 min_us=1681 median_us=1886 p99_us=19270 max_us=19270
crashed_domid=1 new_domid=2 recovered=yes detect_ms=175 restart_ms=1272 linux_uptime_s=52->54 (Linux kept running)
```

What each line checks:

| Command | Passes when |
|---|---|
| `create --cpus 3` | a `BOOT` line arrives: Zephyr runs as a Xen guest on core 3 |
| `xl list` | Dom0 and `zephyr` are both listed |
| `collect 5` | `samples_s=5`: Zephyr reports latency every second |
| `ping 20 10` | `lost=0`: Linux ↔ Zephyr channel works |
| `fault` | `recovered=yes` and Linux uptime keeps increasing |

**Full measurement** (about 5 minutes with 30 s runs):

```bash
scripts/ssh-dom0.sh 'cd /root/poc && ./run_scenarios.sh 30 && cat results/summary.txt'
scp -i images/poc_key -P 2222 -o IdentitiesOnly=yes -r root@localhost:/root/poc/results .
```

Runs the dedicated and shared core placements with Linux idle, under CPU load and under
memory load, then the IPC, boot time and fault tests. Per-second Zephyr data goes to
`results/zephyr_*.csv`, Linux `cyclictest` output to `results/cyclictest_*.txt`.

**Control experiment** without Xen and Linux (the board does not need to be running):

```bash
scripts/run-baseline.sh 35
# BASELINE seconds=33 wakeups=33008 avg_us=0.2 max_us=7269 overruns=7
```

Individual `rtprobe.py` commands, run in Dom0 under `/root/poc`:

```
./rtprobe.py create [--cpus N]        start Zephyr pinned to physical core N
./rtprobe.py collect SECONDS OUT.csv  record latency statistics
./rtprobe.py ping COUNT [INTERVAL_MS] Linux -> Zephyr -> Linux round trip
./rtprobe.py boot RUNS                boot time over several restarts
./rtprobe.py fault                    crash Zephyr, detect and restart it
```

## Troubleshooting

- **Whole board freezes when Zephyr starts**: QEMU older than 8.2 (e.g. 7.0 from Zephyr
  SDK 0.17). Use the QEMU unpacked by `setup.sh` or another QEMU >= 8.2.
- **`ssh: Too many authentication failures`**: your SSH agent offers other keys first.
  `scripts/ssh-dom0.sh` already uses `IdentitiesOnly=yes`; add it to manual `scp`/`ssh` calls.
- **`Failed to get "write" lock` on `dom0.qcow2`**: another QEMU instance still uses the
  disk; stop it first.
- **Port 2222 in use**: change `hostfwd=tcp::2222-:22` in `scripts/run-xen.sh` and the port
  in `scripts/ssh-dom0.sh` and `scripts/deploy.sh`.
- **No `BOOT` line**: check that `zephyr.bin` was built for `xenvm//gicv3` and copied with
  `scripts/deploy.sh`.

## Layout

```
zephyr-app/rt_probe/   Zephyr measurement app
dom0/                  rtprobe.py, run_scenarios.sh, cloud-init template
scripts/               setup, provisioning, boot, deploy, baseline
results/               measured data
docs/                  presentation (HTML: arrow keys to navigate, N for notes; PDF)
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
