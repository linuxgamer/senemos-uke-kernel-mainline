#!/usr/bin/env bash
# Execute native LMH callbacks with a counted IRQ-disable reference.
set -euo pipefail
source_file=${1:?Pass the prepared qcom-cpufreq-hw.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <stdbool.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define U32_MAX UINT32_MAX
#define HZ_PER_KHZ 1000
#define BIT(n) (1U << (n))
#define IRQ_HANDLED 1
#define IS_ERR(p) false
#define PTR_ERR(p) 0
#define dev_warn(...) ((void)0)
#define dev_err(...) ((void)0)
typedef int irqreturn_t;
struct mutex { bool held; };
struct delayed_work { int unused; };
struct device { int unused; };
struct platform_device { struct device dev; };
struct dev_pm_opp { int unused; };
struct qcom_cpufreq_data;
struct cpufreq_policy {
 void *related_cpus, *cpus;
 struct qcom_cpufreq_data *driver_data;
};
struct qcom_cpufreq_data {
 struct cpufreq_policy *policy;
 unsigned char *base;
 struct mutex throttle_lock;
 int throttle_irq;
 char irq_name[15];
 bool cancel_throttle, throttle_irq_disabled;
 struct delayed_work throttle_work;
};
struct soc_data { unsigned int reg_intr_clr; };
static struct soc_data soc = { .reg_intr_clr=0x308 };
static struct { struct soc_data *soc_data; } qcom_cpufreq = { &soc };
static struct qcom_cpufreq_data data;
static struct cpufreq_policy policy;
static struct platform_device pdev;
static struct dev_pm_opp opp;
static unsigned char registers[0x1000];
static unsigned long cap, requested, pressure;
static unsigned int checks, pressure_writes, irq_enables, irq_disables, acks;
static int depth, queued, affinity_error, affinity_calls;
static void *system_highpri_wq;
#define CHECK(expr) do { ++checks; if (!(expr)) { \
 fprintf(stderr,"LMH lifecycle check %u failed: %s\n",checks,#expr); exit(1); \
} } while (0)
static void mutex_lock(struct mutex *lock) { CHECK(!lock->held); lock->held=true; }
static void mutex_unlock(struct mutex *lock) { CHECK(lock->held); lock->held=false; }
static int cpumask_first(void *mask) { (void)mask; return 0; }
static struct device *get_cpu_device(int cpu) { (void)cpu; return &pdev.dev; }
static struct platform_device *cpufreq_get_driver_data(void) { return &pdev; }
static struct cpufreq_policy *cpufreq_cpu_get_raw(int cpu) { (void)cpu; return &policy; }
static unsigned long qcom_cpufreq_get_freq(struct cpufreq_policy *p) { CHECK(p==&policy); return requested; }
static unsigned long qcom_lmh_get_throttle_freq(struct qcom_cpufreq_data *p) { CHECK(p==&data); return cap*1000; }
static struct dev_pm_opp *dev_pm_opp_find_freq_floor(struct device *dev, unsigned long *freq) { (void)dev; (void)freq; return &opp; }
static struct dev_pm_opp *dev_pm_opp_find_freq_ceil(struct device *dev, unsigned long *freq) { (void)dev; (void)freq; return &opp; }
static void dev_pm_opp_put(struct dev_pm_opp *p) { CHECK(p==&opp); }
static void arch_update_hw_pressure(void *mask, unsigned long freq) { CHECK(mask==policy.related_cpus); pressure=freq; ++pressure_writes; }
static void enable_irq(int irq) { CHECK(irq==42); CHECK(depth>0); --depth; ++irq_enables; }
static void disable_irq_nosync(int irq) { CHECK(irq==42); ++depth; ++irq_disables; }
static void writel_relaxed(unsigned int value, void *address) { (void)value; CHECK(address==registers+0x308); ++acks; }
static unsigned int msecs_to_jiffies(unsigned int ms) { return ms; }
static int schedule_delayed_work(struct delayed_work *work, unsigned int delay) { (void)delay; CHECK(work==&data.throttle_work); queued=1; return 1; }
static int mod_delayed_work(void *queue, struct delayed_work *work, unsigned int delay) { (void)queue; return schedule_delayed_work(work,delay); }
static int cancel_delayed_work_sync(struct delayed_work *work) { CHECK(work==&data.throttle_work); queued=0; return 1; }
static int irq_set_affinity_and_hint(int irq, void *mask) { CHECK(irq==42); ++affinity_calls; return mask ? affinity_error : 0; }
C
awk '/^#define GT_IRQ_STATUS[[:space:]]/ { print }
 /^static (void|int|irqreturn_t) (qcom_lmh_dcvs_notify|qcom_lmh_dcvs_handle_irq|qcom_cpufreq_hw_cpu_online|qcom_cpufreq_hw_cpu_offline)\(/ { emit=1; count++ }
 emit { print } emit && /^}/ { emit=0 }
 END { if(count!=4) exit 1 }' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(void) {
 memset(&data,0,sizeof(data));
 data.policy=&policy; data.base=registers; data.throttle_irq=42;
 policy.driver_data=&data; policy.related_cpus=&policy; policy.cpus=&data;
 cap=2000000; requested=2000000; pressure=UINT32_MAX;
 depth=queued=affinity_error=affinity_calls=0;
 pressure_writes=irq_enables=irq_disables=acks=0;
}
static void poll(void) { CHECK(queued); queued=0; qcom_lmh_dcvs_notify(&data); }
int main(void) {
 reset();
 CHECK(qcom_cpufreq_hw_cpu_offline(&policy)==0);
 CHECK(data.cancel_throttle && depth==1 && !queued);
 CHECK(qcom_cpufreq_hw_cpu_online(&policy)==0);
 if (queued) poll();
 CHECK(depth==0 && !queued && !data.cancel_throttle && pressure==U32_MAX);
 for (int iteration=0; iteration<128; ++iteration) {
  cap=iteration%2 ? 1000000 : 1500000; requested=2000000;
  CHECK(qcom_lmh_dcvs_handle_irq(42,&data)==IRQ_HANDLED);
  CHECK(depth==1 && data.throttle_irq_disabled && queued);
  poll(); CHECK(depth==1 && queued && pressure==cap);
  /* A queued threaded callback must not nest the disable reference. */
  qcom_lmh_dcvs_handle_irq(42,&data); CHECK(depth==1 && queued);
  qcom_cpufreq_hw_cpu_offline(&policy);
  CHECK(depth==1 && !queued && data.cancel_throttle && pressure==U32_MAX);
  unsigned int writes=pressure_writes;
  qcom_lmh_dcvs_notify(&data); CHECK(pressure_writes==writes && depth==1 && !queued);
  qcom_lmh_dcvs_handle_irq(42,&data); CHECK(depth==1 && !queued);
  affinity_error=-5;
  CHECK(qcom_cpufreq_hw_cpu_online(&policy)==-5);
  CHECK(data.cancel_throttle && depth==1 && !queued);
  affinity_error=0;
  CHECK(qcom_cpufreq_hw_cpu_online(&policy)==0);
  CHECK(!data.cancel_throttle && depth==1 && queued);
  poll(); CHECK(depth==1 && queued);
  cap=requested; poll();
  CHECK(depth==0 && !queued && !data.throttle_irq_disabled && pressure==U32_MAX);
 }
 CHECK(irq_enables==irq_disables);
 /* Reduced demand ends clipping too: do not retain a sampled low frequency. */
 cap=1000000; requested=2000000;
 qcom_lmh_dcvs_handle_irq(42,&data); poll(); CHECK(pressure==cap && queued);
 requested=500000; poll(); CHECK(depth==0 && !queued && pressure==U32_MAX);
 /* Completed recovery before offline and repeated offline are also balanced. */
 qcom_cpufreq_hw_cpu_offline(&policy); qcom_cpufreq_hw_cpu_offline(&policy);
 CHECK(depth==1 && !queued);
 qcom_cpufreq_hw_cpu_online(&policy); poll(); CHECK(depth==0);
 reset(); data.throttle_irq=-6;
 CHECK(qcom_cpufreq_hw_cpu_online(&policy)==0);
 CHECK(qcom_cpufreq_hw_cpu_offline(&policy)==0);
 CHECK(!depth && !queued && !affinity_calls && !pressure_writes);
 printf("%u native LMH callback checks passed, including 128 clipping/offline/online/recovery cycles.\n",checks);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-variable -Wno-unused-parameter \
 -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
