#!/usr/bin/env python3
"""Dom0-side driver for the Zephyr rt_probe guest.

Talks to Zephyr over its Xen PV console (the pty that xenconsoled exposes).

  rtprobe.py create [--cpus N]          start the Zephyr domain
  rtprobe.py collect SECONDS OUT.csv    record STAT lines (timer latency)
  rtprobe.py ping COUNT [INTERVAL_MS]   Linux->Zephyr->Linux round trip
  rtprobe.py boot RUNS [--cpus N]       destroy/create, time to first BOOT line
  rtprobe.py fault                      crash Zephyr, time until it is back
"""
import argparse, csv, os, re, select, statistics, subprocess, sys, termios, time, tty

DOMAIN = "zephyr"
HERE = os.path.dirname(os.path.abspath(__file__))
CFG_TEMPLATE = """kernel="{kernel}"
name="{name}"
vcpus=1
cpus="{cpus}"
memory=16
gic_version="v3"
on_crash="{on_crash}"
"""
STAT_RE = re.compile(r"STAT t=(\d+) n=(\d+) period_us=(\d+) min_us=(\d+) avg_us=(\d+) "
                     r"max_us=(\d+) overruns=(\d+) hist=([\d,]+)")


def sh(cmd, check=True):
    return subprocess.run(cmd, shell=True, check=check, capture_output=True, text=True).stdout.strip()


def domid():
    out = sh(f"xl domid {DOMAIN}", check=False)
    return int(out) if out.isdigit() else None


def write_cfg(cpus, on_crash="preserve"):
    path = os.path.join(HERE, "zephyr.cfg")
    with open(path, "w") as f:
        f.write(CFG_TEMPLATE.format(kernel=os.path.join(HERE, "zephyr.bin"), name=DOMAIN,
                                    cpus=cpus, on_crash=on_crash))
    return path


class Console:
    """Raw access to the guest PV console pty."""

    def __init__(self, timeout=30):
        t0 = time.time()
        while True:
            d = domid()
            tty_path = sh(f"xenstore-read /local/domain/{d}/console/tty", check=False) if d else ""
            if tty_path.startswith("/dev/"):
                break
            if time.time() - t0 > timeout:
                raise RuntimeError("Zephyr console pty not found")
            time.sleep(0.05)
        self.fd = os.open(tty_path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        tty.setraw(self.fd)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buf = b""

    def lines(self, timeout):
        """Yield complete lines until timeout (seconds) expires."""
        end = time.time() + timeout
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                yield line.decode(errors="replace").strip()
            left = end - time.time()
            if left <= 0:
                return
            r, _, _ = select.select([self.fd], [], [], left)
            if r:
                try:
                    self.buf += os.read(self.fd, 4096)
                except BlockingIOError:
                    pass

    def send(self, text):
        os.write(self.fd, text.encode() + b"\n")

    def close(self):
        os.close(self.fd)


def create(cpus, on_crash="preserve"):
    """Create paused, attach to the console, unpause, wait for the BOOT line.
    Returns (boot_line, total_ms from xl create, boot_ms from unpause)."""
    if domid() is not None:
        sh(f"xl destroy {DOMAIN}")
    cfg = write_cfg(cpus, on_crash)
    t0 = time.monotonic()
    sh(f"xl create -p {cfg}")
    con = Console()
    t1 = time.monotonic()
    sh(f"xl unpause {DOMAIN}")
    line = wait_for(con, "BOOT", 30)
    t2 = time.monotonic()
    con.close()
    return line, (t2 - t0) * 1000, (t2 - t1) * 1000


def wait_for(con, prefix, timeout):
    for line in con.lines(timeout):
        if line.startswith(prefix):
            return line
    return None


def cmd_collect(seconds, out):
    con = Console()
    rows = []
    for line in con.lines(seconds):
        m = STAT_RE.search(line)
        if m:
            rows.append([int(x) for x in m.groups()[:7]] + [m.group(8)])
    con.close()
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t", "n", "period_us", "min_us", "avg_us", "max_us", "overruns", "hist"])
        w.writerows(rows)
    if rows:
        print(f"samples_s={len(rows)} min_us={min(r[3] for r in rows)} "
              f"avg_us={round(statistics.mean(r[4] for r in rows))} "
              f"max_us={max(r[5] for r in rows)} overruns={sum(r[6] for r in rows)}")
    else:
        print("no STAT lines received")


def cmd_ping(count, interval_ms):
    con = Console()
    rtts = []
    lost = 0
    for seq in range(count):
        t0 = time.perf_counter()
        con.send(f"PING {seq}")
        got = False
        for line in con.lines(1.0):
            if line == f"PONG {seq}":
                rtts.append((time.perf_counter() - t0) * 1e6)
                got = True
                break
        lost += 0 if got else 1
        time.sleep(interval_ms / 1000)
    con.close()
    if rtts:
        rtts.sort()
        p99 = rtts[min(len(rtts) - 1, int(len(rtts) * 0.99))]
        print(f"pings={count} lost={lost} min_us={rtts[0]:.0f} median_us={statistics.median(rtts):.0f} "
              f"p99_us={p99:.0f} max_us={rtts[-1]:.0f}")
    else:
        print(f"pings={count} lost={lost} no replies")


def cmd_boot(runs, cpus):
    total, boot = [], []
    for _ in range(runs):
        line, t_total, t_boot = create(cpus)
        if line:
            total.append(t_total); boot.append(t_boot)
    if total:
        print(f"runs={runs} ok={len(total)} create+boot_median_ms={statistics.median(total):.0f} "
              f"boot_after_unpause_median_ms={statistics.median(boot):.0f} "
              f"boot_after_unpause_max_ms={max(boot):.0f}")
    else:
        print("no BOOT line seen")


def cmd_fault(cpus):
    """Crash Zephyr on purpose; a Linux-side supervisor detects it and restarts it.
    Shows that Linux keeps running and how fast the RT domain is back."""
    old = domid()
    up_before = float(sh("cut -d' ' -f1 /proc/uptime"))
    con = Console()
    t0 = time.monotonic()
    con.send("FAULT")
    con.close()
    while "c" not in sh(f"xl list {DOMAIN} | awk 'NR==2{{print $5}}'", check=False):
        if time.monotonic() - t0 > 30:
            print("crash not detected"); return
        time.sleep(0.01)
    t_detect = time.monotonic()
    line, _, _ = create(cpus)
    t_back = time.monotonic()
    up_after = float(sh("cut -d' ' -f1 /proc/uptime"))
    print(f"crashed_domid={old} new_domid={domid()} recovered={'yes' if line else 'no'} "
          f"detect_ms={(t_detect - t0) * 1000:.0f} restart_ms={(t_back - t_detect) * 1000:.0f} "
          f"linux_uptime_s={up_before:.0f}->{up_after:.0f} (Linux kept running)")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create"); c.add_argument("--cpus", default="3")
    c = sub.add_parser("collect"); c.add_argument("seconds", type=float); c.add_argument("out")
    c = sub.add_parser("ping"); c.add_argument("count", type=int); c.add_argument("interval_ms", type=float, nargs="?", default=20)
    c = sub.add_parser("boot"); c.add_argument("runs", type=int); c.add_argument("--cpus", default="3")
    c = sub.add_parser("fault"); c.add_argument("--cpus", default="3")
    a = p.parse_args()
    if a.cmd == "create":
        line, t_total, t_boot = create(a.cpus); print(f"{line} create+boot_ms={t_total:.0f} boot_ms={t_boot:.0f}")
    elif a.cmd == "collect":
        cmd_collect(a.seconds, a.out)
    elif a.cmd == "ping":
        cmd_ping(a.count, a.interval_ms)
    elif a.cmd == "boot":
        cmd_boot(a.runs, a.cpus)
    elif a.cmd == "fault":
        cmd_fault(a.cpus)


if __name__ == "__main__":
    sys.exit(main())
