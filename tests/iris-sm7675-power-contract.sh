#!/usr/bin/env bash
# Execute the actual Cliffs power owner against reset/clock/PM/MMIO failures.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
#define BIT(n) (1u << (n))
#define fallthrough __attribute__((fallthrough))
#define IRIS_CTRL_POWER_DOMAIN 0
#define IRIS_HW_POWER_DOMAIN 1
#define IRIS_AXI_CLK 0
#define IRIS_CTRL_CLK 1
#define IRIS_HW_CLK 2
#define MSK_SIGNAL_FROM_TENSILICA 1
#define MSK_CORE_POWER_ON 2
#define CTL_AXI_CLK_HALT 1
#define CTL_CLK_HALT 2
#define RESET_HIGH 1
C
awk '/^#define (AON_BASE_OFFS|CPU_BASE_OFFS|CPU_CS_BASE_OFFS|WRAPPER_BASE_OFFS|WRAPPER_TZ_BASE_OFFS|CPU_CS_X2RPMH|WRAPPER_IRIS_CPU_NOC_LPI_|WRAPPER_DEBUG_BRIDGE_LPI_|WRAPPER_TZ_CTL_AXI_CLOCK_CONFIG|WRAPPER_TZ_QNS4PDXFIFO_RESET)/ {print}' \
    "$iris/iris_vpu_register_defines.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct iris_fw_memory { u32 power, off_step; int power_error; };
struct reset { int *rstc; };
struct pmdomains { void *pd_devs[2]; };
struct iris_core {
    void *dev; unsigned char *reg_base;
    struct iris_fw_memory *fw_memory;
    struct pmdomains *pmdomain_tbl;
    struct reset *resets, *controller_resets;
};
static unsigned char regs[0xf0000];
static int ids[] = {0, 1, 2, 3};
static struct reset resets[] = {{ids}, {ids+1}, {ids+2}}, xo[] = {{ids+3}};
static struct pmdomains domains = {{ids, ids+1}};
static struct iris_fw_memory memory;
static struct iris_core core = {NULL, regs, &memory, &domains, resets, xo};
static int fault, nth, calls, pm_puts[2], refs[2], clocks[3];
static int polls, resets_done, writes, hwm_calls, retain_calls, quiesce_calls;
static bool collapsed, retained, asserted[4];
static char trace[512];
static void record(char c) { size_t n = strlen(trace); assert(n+1 < sizeof(trace)); trace[n] = c; trace[n+1] = 0; }
static int fail(int type) { if (fault != type) return 0; return ++calls == nth ? -EREMOTEIO : 0; }
static int iris_enable_power_domains(struct iris_core *c, void *pd) {
    (void)c; int id = pd == domains.pd_devs[1]; int ret = fail(1);
    record(id ? 'H' : 'P'); if (!ret) ++refs[id]; return ret;
}
static int pm_runtime_put_sync(void *pd) {
    int id = pd == domains.pd_devs[1]; record(id ? 'h' : 'p');
    assert(refs[id] == 1); --refs[id]; ++pm_puts[id]; return fail(2);
}
static int iris_prepare_enable_clock(struct iris_core *c, int id) {
    (void)c; int ret = fail(3); record("ACH"[id]); if (!ret) ++clocks[id]; return ret;
}
static int iris_disable_unprepare_clock(struct iris_core *c, int id) {
    (void)c; record("ach"[id]); assert(clocks[id] == 1); --clocks[id]; return 0;
}
static int reset_control_assert(int *id) {
    record("BKVX"[*id]); int ret = fail(4); ++resets_done;
    if (!ret) asserted[*id] = true; return ret;
}
static int reset_control_deassert(int *id) {
    record("bkvx"[*id]); int ret = fail(4); ++resets_done;
    if (!ret) asserted[*id] = false; return ret;
}
static int qcom_uke_videocc_set_retention(void *dev, bool on) {
    (void)dev; assert(clocks[1] == 1); record(on ? 'R' : 'r');
    ++retain_calls; int ret = fail(5); if (!ret) retained = on; return ret;
}
static int dev_pm_genpd_set_hwmode(void *pd, bool on) {
    assert(pd == domains.pd_devs[1] && !on && refs[1]); ++hwm_calls; return fail(6);
}
static bool iris_vpu3x_hw_power_collapsed(struct iris_core *c) { (void)c; return collapsed; }
static int iris_vpu33_2p_quiesce(struct iris_core *c) { (void)c; ++quiesce_calls; return fail(7); }
static void usleep_range(int low, int high) {
    assert((low==1000 && high==1100) || (low==400 && high==500) || (low==80 && high==100));
    record(low == 1000 ? '1' : low == 400 ? '4' : '8');
}
static u32 readl(void *address) { return *(u32 *)address; }
static void writel(u32 value, void *address) {
    assert(clocks[1] == 1 && refs[0] == 1); ++writes; *(u32 *)address = value;
}
static int poll(void) { ++polls; return fail(8); }
#define readl_poll_timeout(address, value, condition, delay, timeout) \
    ((void)(address), (void)(delay), (void)(timeout), (value)=0, (void)(condition), poll())
C
sed -n '/^#define SM7675_CTRL_PD/,$p' "$iris/iris_sm7675_memory.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(void) {
    memory = (struct iris_fw_memory){0}; memset(regs, 0, sizeof(regs));
    memset(refs, 0, sizeof(refs)); memset(pm_puts, 0, sizeof(pm_puts));
    memset(clocks, 0, sizeof(clocks)); memset(asserted, 0, sizeof(asserted));
    fault = calls = polls = writes = resets_done = hwm_calls = retain_calls = quiesce_calls = 0;
    nth = 1; collapsed = retained = false; trace[0] = 0;
}
static void clean(void) {
    assert(!memory.power && !memory.off_step && !memory.power_error && !retained);
    for (int i=0; i<3; ++i) assert(!clocks[i]);
    for (int i=0; i<2; ++i) assert(!refs[i] && pm_puts[i] <= 1);
    for (int i=0; i<4; ++i) assert(!asserted[i]);
}
static void start(void) {
    assert(iris_sm7675_power_on_controller(&core) == 0);
    assert(iris_sm7675_power_on_hw(&core) == 0);
}
int main(void) {
    reset(); start();
    assert(!strcmp(trace, "PBK1bkACHH")); trace[0] = 0;
    assert(iris_sm7675_power_off(&core) == 0);
    assert(!strcmp(trace, "hBVRK4vbkX8xhrcpa")); clean();
    assert(polls == 3 && quiesce_calls == 1 && hwm_calls == 1 && writes == 13);
    assert(iris_sm7675_power_off(&core) == 0); clean();
    for (int cycle=0; cycle<3; ++cycle) { start(); assert(iris_sm7675_power_off(&core)==0); }
    assert(pm_puts[0] == 4 && pm_puts[1] == 4 && !memory.power && !memory.off_step);
    for (int type=1; type<=4; ++type) {
        int count = type == 1 ? 2 : type == 3 ? 3 : type == 4 ? 4 : 0;
        for (int n=1; n<=count; ++n) {
            reset(); fault=type; nth=n;
            int ret=iris_sm7675_power_on_controller(&core);
            if (!ret) ret=iris_sm7675_power_on_hw(&core);
            assert(ret == -EREMOTEIO);
            fault=0; assert(iris_sm7675_power_off(&core)==0); clean();
        }
    }
    for (int type=4; type<=8; ++type) {
        int count = type==4 ? 8 : type==5 ? 2 : type==8 ? 3 : 1;
        for (int n=1; n<=count; ++n) {
            reset(); start(); fault=type; nth=n; calls=0;
            assert(iris_sm7675_power_off(&core)==-EREMOTEIO);
            assert(memory.power && clocks[1] && refs[0]);
            assert(iris_sm7675_power_on_controller(&core)==-EBUSY);
            int poll_count=polls;
            fault=0; assert(iris_sm7675_power_off(&core)==0); clean();
            if (type==4 && n>=1) assert(polls == poll_count + (n<=6 ? 1 : 0));
        }
    }
    for (int n=1; n<=2; ++n) {
        reset(); start(); fault=2; nth=n;
        assert(iris_sm7675_power_off(&core)==-EREMOTEIO);
        assert(memory.power_error == -EREMOTEIO && pm_puts[n==1]);
        int total=pm_puts[0]+pm_puts[1]; fault=0;
        assert(iris_sm7675_power_off(&core)==-EREMOTEIO);
        assert(pm_puts[0]+pm_puts[1] == total && iris_sm7675_power_on_controller(&core)==-EBUSY);
    }
    reset(); start(); collapsed=true;
    assert(iris_sm7675_power_off(&core)==0 && !quiesce_calls); clean();
    puts("SM7675 power sequence, partial startup, teardown retries and consumed PM references: PASS");
}
C
cc -std=gnu11 -Wall -Wextra -Werror -Wno-misleading-indentation "$work/check.c" -o "$work/check"
"$work/check"
