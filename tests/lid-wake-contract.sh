#!/usr/bin/env bash
# Exercise the production paired-switch handler without accessing a device.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass prepared kernel}")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#define IRQCHIP_STATE_LINE_LEVEL 1
#define IRQ_HANDLED 1
typedef int irqreturn_t;
struct device {bool wake;};
struct input_dev {unsigned int reports, syncs; int state;};
struct smp2p_switch {
    struct device *dev; struct input_dev *input;
    unsigned int code; int open_irq, closed_irq;
};
static bool open_level, closed_level;
static int error, wakes;
static int irq_get_irqchip_state(int irq, int which, bool *state) {
    assert(which==IRQCHIP_STATE_LINE_LEVEL);
    if(error) return error;
    *state=irq==10 ? open_level : closed_level; return 0;
}
static bool device_may_wakeup(struct device *dev) {return dev->wake;}
static void pm_wakeup_event(struct device *dev, unsigned int ms) {
    assert(dev->wake && ms==500); ++wakes;
}
static void input_report_switch(struct input_dev *input, unsigned int code, int state) {
    assert(code==0); ++input->reports; input->state=state;
}
static void input_sync(struct input_dev *input) {++input->syncs;}
C
awk '/^static (int smp2p_switch_read\(|irqreturn_t smp2p_switch_irq\()/ {copy=1}
     copy {print} copy && /^}/ {copy=0}' \
    "$kernel/drivers/input/misc/qcom-smp2p-switch.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    struct device dev={true}; struct input_dev input={0};
    struct smp2p_switch sw={&dev,&input,0,10,11};
    open_level=true;
    assert(smp2p_switch_irq(0,&sw)==IRQ_HANDLED && !wakes);
    assert(smp2p_switch_irq(10,&sw)==IRQ_HANDLED && wakes==1 && input.state==0);
    open_level=false; closed_level=true;
    smp2p_switch_irq(11,&sw); assert(wakes==1 && input.state==1);
    smp2p_switch_irq(10,&sw); assert(wakes==1 && input.state==1);
    open_level=true; closed_level=false; dev.wake=false;
    smp2p_switch_irq(10,&sw); assert(wakes==1 && input.state==0);
    dev.wake=true; open_level=closed_level=false;
    unsigned int reports=input.reports;
    smp2p_switch_irq(10,&sw); assert(wakes==1 && input.reports==reports);
    open_level=closed_level=true;
    smp2p_switch_irq(10,&sw); assert(wakes==1 && input.reports==reports);
    error=-ENODEV;
    smp2p_switch_irq(10,&sw); assert(wakes==1 && input.reports==reports);
    assert(input.reports==input.syncs);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Lid wake: valid open only, close, initial report, disabled policy and invalid/provider states: PASS\n'
