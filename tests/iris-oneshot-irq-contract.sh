#!/usr/bin/env bash
# Execute native IRQ ownership: PM before lock, no MMIO after teardown, no re-enable.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
typedef int irqreturn_t;
#define IRQ_NONE 0
#define IRQ_HANDLED 1
#define IRIS_CORE_INIT 1
#define IRIS_CORE_ERROR 2
struct iris_core;
struct hfi { void (*sys_hfi_response_handler)(struct iris_core *); };
struct vpu_ops { int (*power_off)(struct iris_core *); };
struct platform { const struct vpu_ops *vpu_ops; };
struct iris_core {
    void *dev; int lock, state, irq; unsigned intr_status;
    bool irq_enabled, removing;
    const struct hfi *hfi_sys_ops;
    const struct platform *iris_platform_data;
};
static int pm_error, refs, gets, puts_count, clears, responses, enables, disables;
static bool locked;
static int native_off(struct iris_core *core) { (void)core; return 0; }
static const struct vpu_ops native = {native_off}, legacy = {NULL};
static const struct platform native_platform = {&native}, legacy_platform = {&legacy};
static int pm_runtime_resume_and_get(void *dev) {
    (void)dev; assert(!locked); ++gets;
    if (pm_error) return pm_error;
    ++refs; return 0;
}
static void mutex_lock(int *lock) { (void)lock; assert(!locked); locked=true; }
static void mutex_unlock(int *lock) { (void)lock; assert(locked); locked=false; }
static void pm_runtime_mark_last_busy(void *dev) { (void)dev; assert(!locked && refs==1); }
static void pm_runtime_put_autosuspend(void *dev) { (void)dev; assert(!locked && refs==1); --refs; ++puts_count; }
static void iris_vpu_clear_interrupt(struct iris_core *core) {
    assert(locked && refs==1 && core->irq_enabled && !core->removing && core->state==IRIS_CORE_INIT);
    ++clears;
}
static int iris_vpu_watchdog(struct iris_core *core, unsigned intr) { (void)core; return intr ? -EIO : 0; }
static void response(struct iris_core *core) { (void)core; assert(!locked && refs==1); ++responses; }
static void enable_irq(int irq) { assert(irq==174); ++enables; }
static void disable_irq_nosync(int irq) { assert(irq==174); ++disables; }
static const struct hfi hfi_ops = {response};
C
for name in iris_vpu_enable_irq iris_vpu_disable_irq; do
    awk -v name="$name" '$0 ~ "^void " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' \
        "$iris/iris_vpu_common.c" >> "$work/check.c"
done
awk '/^irqreturn_t iris_hfi_oneshot_handler\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$iris/iris_hfi_common.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct iris_core core;
static void reset(void) {
    assert(!locked && !refs);
    pm_error=gets=puts_count=clears=responses=enables=disables=0;
    core=(struct iris_core){NULL,0,IRIS_CORE_INIT,174,0,false,false,&hfi_ops,&native_platform};
}
int main(void) {
    reset(); assert(iris_hfi_oneshot_handler(174,NULL)==IRQ_NONE && !gets);
    iris_vpu_enable_irq(&core); iris_vpu_enable_irq(&core);
    assert(enables==1 && core.irq_enabled);
    assert(iris_hfi_oneshot_handler(174,&core)==IRQ_HANDLED);
    assert(clears==1 && responses==1 && puts_count==1 && !refs && enables==1);
    iris_vpu_disable_irq(&core); iris_vpu_disable_irq(&core);
    assert(disables==1 && !core.irq_enabled);
    assert(iris_hfi_oneshot_handler(174,&core)==IRQ_HANDLED);
    assert(clears==1 && responses==1 && puts_count==2 && !refs && enables==1);
    for (int refusal=0; refusal<3; ++refusal) {
        reset(); core.irq_enabled=true;
        if (refusal==0) core.removing=true;
        if (refusal==1) core.state=IRIS_CORE_ERROR;
        if (refusal==2) pm_error=-EREMOTEIO;
        assert(iris_hfi_oneshot_handler(174,&core)==IRQ_HANDLED);
        assert(!clears && !responses && !refs && puts_count==(refusal!=2));
        if (refusal==2) assert(!core.irq_enabled && disables==1 && core.state==IRIS_CORE_ERROR);
    }
    reset(); core.irq_enabled=true; core.intr_status=1;
    assert(iris_hfi_oneshot_handler(174,&core)==IRQ_HANDLED);
    assert(disables==1 && !core.irq_enabled && responses==1 && !refs && !enables);
    reset(); core.removing=true; iris_vpu_enable_irq(&core); assert(!enables);
    reset(); core.iris_platform_data=&legacy_platform; iris_vpu_enable_irq(&core); assert(!enables);
    puts("Native oneshot IRQ: balanced PM, deferred enable, watchdog and teardown guards: PASS");
}
C
cc -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter "$work/check.c" -o "$work/check"
"$work/check"
