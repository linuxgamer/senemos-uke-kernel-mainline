#!/usr/bin/env bash
# Actual runtime-resume admission prefix; no MMIO, IRQ or clock access.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdio.h>
struct device { int unused; };
struct qcom_swrm_ctrl { int wake_irq; void *hclk; };
static struct qcom_swrm_ctrl ctrl;
static int clock_error,irq_disabled;
static unsigned clocks,irq_reads,irq_disables;
static struct qcom_swrm_ctrl *dev_get_drvdata(struct device *d)
{ (void)d;return &ctrl; }
static int clk_prepare_enable(void *clock)
{ assert(clock==ctrl.hclk);clocks++;return clock_error; }
static int irq_get_irq_data(int irq)
{ assert(irq==ctrl.wake_irq && clocks==1 && !clock_error);irq_reads++;return irq; }
static int irqd_irq_disabled(int irq)
{ assert(irq==ctrl.wake_irq);return irq_disabled; }
static void disable_irq_nosync(int irq)
{ assert(irq==ctrl.wake_irq && clocks==1 && !clock_error);irq_disables++; }
static int actual_resume_admission(struct device *dev)
{
C
awk '/^static int __maybe_unused swrm_runtime_resume\(/ {resume=1}
 resume && /struct qcom_swrm_ctrl \*ctrl =/ {emit=1}
 emit && /if \(ctrl->clock_stop_not_supported\)/ {exit}
 emit {print}' "$kernel/drivers/soundwire/qcom.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 return 0;
}
int main(void)
{
 struct device dev;
 const int errors[]={-EIO,-ETIMEDOUT,-517};
 for(unsigned i=0;i<3;i++) {
  clock_error=errors[i];ctrl.wake_irq=520;
  clocks=irq_reads=irq_disables=0;
  assert(actual_resume_admission(&dev)==clock_error);
  assert(clocks==1 && !irq_reads && !irq_disables);
 }
 clock_error=0;
 for(unsigned enabled=0;enabled<2;enabled++) {
  clocks=irq_reads=irq_disables=0;irq_disabled=!enabled;
  assert(!actual_resume_admission(&dev));
  assert(clocks==1 && irq_reads==1 && irq_disables==enabled);
 }
 ctrl.wake_irq=0;clocks=irq_reads=irq_disables=0;
 assert(!actual_resume_admission(&dev) && clocks==1 && !irq_reads && !irq_disables);
 puts("Actual SoundWire resume admission: 6 memory-only clock/wake IRQ cases passed; clock-stop and hardware resume untested.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
