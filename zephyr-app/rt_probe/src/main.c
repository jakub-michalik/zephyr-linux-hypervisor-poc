/*
 * rt_probe - real-time quality probe for Zephyr running as a Xen guest.
 *
 * 1. Periodic real-time task: wakes every PERIOD_US and measures how late it
 *    was woken compared to the ideal schedule (timer latency / jitter).
 *    Once per second it prints a machine-readable STAT line.
 * 2. Command channel over the Xen PV console (Linux side writes lines):
 *      PING <seq>  -> replies PONG <seq>   (Linux<->Zephyr round-trip latency)
 *      FAULT       -> deliberately crashes Zephyr (fault-isolation test)
 *      PERIOD <us> -> changes the RT task period
 * 3. Prints a BOOT line as early as possible (boot-time measurement).
 */
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/printk.h>
#include <zephyr/fatal.h>
#ifdef CONFIG_XEN
#include <zephyr/arch/arm64/hypercall.h>
#include <zephyr/xen/public/sched.h>
#endif
#include <stdlib.h>
#include <string.h>

#define DEFAULT_PERIOD_US 1000
#define RT_PRIO K_PRIO_COOP(0)
#define CMD_PRIO K_PRIO_COOP(2)
#define STAT_PRIO K_PRIO_PREEMPT(5)

static const struct device *const uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));

/* histogram buckets of wake-up latency, in microseconds (upper bounds) */
static const uint32_t bucket_us[] = {10, 50, 100, 500, 1000, UINT32_MAX};
#define NBUCKETS ARRAY_SIZE(bucket_us)

struct stats {
	uint64_t n;
	uint64_t sum_ns;
	uint64_t min_ns;
	uint64_t max_ns;
	uint64_t overruns; /* timer expired more than once before we ran */
	uint32_t hist[NBUCKETS];
};

static struct stats cur;
static struct k_spinlock stat_lock;
static volatile uint32_t period_us = DEFAULT_PERIOD_US;
static volatile bool period_changed;

K_TIMER_DEFINE(rt_timer, NULL, NULL);
K_MSGQ_DEFINE(cmd_q, 32, 4, 4);

static inline uint64_t cyc_to_ns(uint64_t cyc)
{
	return (cyc * 1000000000ULL) / sys_clock_hw_cycles_per_sec();
}

static void stats_reset(struct stats *s)
{
	memset(s, 0, sizeof(*s));
	s->min_ns = UINT64_MAX;
}

/* ---------------- real-time periodic task ---------------- */
static void rt_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);

	for (;;) {
		uint32_t p = period_us;
		uint64_t period_cyc = (uint64_t)p * sys_clock_hw_cycles_per_sec() / 1000000ULL;

		period_changed = false;
		k_timer_start(&rt_timer, K_USEC(p), K_USEC(p));
		uint64_t expected = k_cycle_get_64() + period_cyc;

		while (!period_changed) {
			uint32_t expirations = k_timer_status_sync(&rt_timer);
			uint64_t now = k_cycle_get_64();
			uint64_t late_ns = now > expected ? cyc_to_ns(now - expected) : 0;

			expected += (uint64_t)expirations * period_cyc;

			k_spinlock_key_t key = k_spin_lock(&stat_lock);
			cur.n++;
			cur.sum_ns += late_ns;
			cur.min_ns = MIN(cur.min_ns, late_ns);
			cur.max_ns = MAX(cur.max_ns, late_ns);
			if (expirations > 1) {
				cur.overruns += expirations - 1;
			}
			for (int i = 0; i < NBUCKETS; i++) {
				if (late_ns / 1000 < bucket_us[i]) {
					cur.hist[i]++;
					break;
				}
			}
			k_spin_unlock(&stat_lock, key);
		}
		k_timer_stop(&rt_timer);
	}
}

/* ---------------- once-per-second report ---------------- */
static void stat_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	struct stats snap;
	uint32_t sec = 0;

	for (;;) {
		k_sleep(K_SECONDS(1));
		k_spinlock_key_t key = k_spin_lock(&stat_lock);
		snap = cur;
		stats_reset(&cur);
		k_spin_unlock(&stat_lock, key);

		sec++;
		if (snap.n == 0) {
			printk("STAT t=%u n=0 period_us=%u\n", sec, period_us);
			continue;
		}
		printk("STAT t=%u n=%llu period_us=%u min_us=%llu avg_us=%llu max_us=%llu "
		       "overruns=%llu hist=%u,%u,%u,%u,%u,%u\n",
		       sec, snap.n, period_us, snap.min_ns / 1000,
		       snap.sum_ns / snap.n / 1000, snap.max_ns / 1000, snap.overruns,
		       snap.hist[0], snap.hist[1], snap.hist[2], snap.hist[3],
		       snap.hist[4], snap.hist[5]);
	}
}

/* ---------------- command channel (Xen PV console) ---------------- */
static char rx_line[32];
static size_t rx_len;

static void uart_isr(const struct device *dev, void *user_data)
{
	ARG_UNUSED(user_data);
	uint8_t c;

	while (uart_irq_update(dev) && uart_irq_rx_ready(dev)) {
		while (uart_fifo_read(dev, &c, 1) == 1) {
			if (c == '\n' || c == '\r') {
				if (rx_len > 0) {
					rx_line[rx_len] = '\0';
					k_msgq_put(&cmd_q, rx_line, K_NO_WAIT);
					rx_len = 0;
				}
			} else if (rx_len < sizeof(rx_line) - 1) {
				rx_line[rx_len++] = c;
			}
		}
	}
}

static void cmd_thread(void *a, void *b, void *c)
{
	ARG_UNUSED(a); ARG_UNUSED(b); ARG_UNUSED(c);
	char cmd[32];

	for (;;) {
		k_msgq_get(&cmd_q, cmd, K_FOREVER);
		if (strncmp(cmd, "PING ", 5) == 0) {
			printk("PONG %s\n", cmd + 5);
		} else if (strcmp(cmd, "FAULT") == 0) {
			printk("FAULT injected, crashing on purpose\n");
			k_panic();
		} else if (strncmp(cmd, "PERIOD ", 7) == 0) {
			uint32_t p = strtoul(cmd + 7, NULL, 10);

			if (p >= 50 && p <= 1000000) {
				period_us = p;
				period_changed = true;
				printk("PERIOD set %u us\n", p);
			}
		}
	}
}

/* On a fatal error, report the crash to Xen so the domain enters the
 * "crashed" state; a supervisor in Linux (Dom0) can then detect and restart it.
 */
void k_sys_fatal_error_handler(unsigned int reason, const struct arch_esf *esf)
{
	ARG_UNUSED(esf);
	printk("FATAL reason=%u\n", reason);
#ifdef CONFIG_XEN
	struct sched_shutdown sd = { .reason = SHUTDOWN_crash };

	printk("reporting crash to Xen\n");
	HYPERVISOR_sched_op(SCHEDOP_shutdown, &sd);
#endif
	for (;;) {
	}
}

K_THREAD_DEFINE(rt_tid, 2048, rt_thread, NULL, NULL, NULL, RT_PRIO, 0, 0);
K_THREAD_DEFINE(stat_tid, 2048, stat_thread, NULL, NULL, NULL, STAT_PRIO, 0, 0);
K_THREAD_DEFINE(cmd_tid, 2048, cmd_thread, NULL, NULL, NULL, CMD_PRIO, 0, 0);

int main(void)
{
	printk("BOOT uptime_ms=%lld timer_hz=%u\n", k_uptime_get(),
	       sys_clock_hw_cycles_per_sec());
	stats_reset(&cur);

	if (device_is_ready(uart)) {
		uart_irq_callback_set(uart, uart_isr);
		uart_irq_rx_enable(uart);
	} else {
		printk("WARN console uart not ready, command channel disabled\n");
	}
	return 0;
}
