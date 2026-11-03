#!/usr/bin/env bash
# Execute real ACT timing and separate VCPF status decoders with modeled registers.
set -Eeuo pipefail
ulimit -c 0
source=${1:?Pass prepared dp_ctrl.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <errno.h>
#include <stdio.h>
typedef uint32_t u32;typedef uint64_t u64;
typedef int irqreturn_t;
enum {IRQ_NONE,IRQ_HANDLED,IRQ_WAKE_THREAD};
enum {connector_status_connected=1,connector_status_disconnected=2,DRM_CONNECTOR_DP_IRQ_HPD=1};
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((~0U<<(l))&(~0U>>(31-(h))))
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define container_of(p,type,field) ((type*)((char*)(p)-offsetof(type,field)))
#define drm_dbg_dp(...) ((void)0)
struct msm_dp_ctrl {int unused;};
struct msm_dp_ctrl_private {struct msm_dp_ctrl msm_dp_ctrl;bool mst_active;void *drm_dev;};
struct drm_display_mode {unsigned htotal,vtotal,clock;};
struct msm_dp_panel {struct {struct drm_display_mode drm_mode;} msm_dp_mode;};
static unsigned reads,writes,sleeps,last_sleep;static bool timeout;
static u32 status5,status7;
C
sed '/^#include /d' "$(dirname -- "$source")/dp_reg.h"
sed -n '/^#define DP_INTERRUPT_STATUS_ACK_SHIFT/,/^#define DP_CTRL_INTR_READY_FOR_VIDEO/p' "$source" | sed '$d'
cat <<'C'
static u32 msm_dp_read_ahb(struct msm_dp_ctrl_private *ctrl,u32 reg) {
 (void)ctrl;assert(reg==REG_DP_INTR_STATUS5||reg==REG_DP_INTR_STATUS7);return reg==REG_DP_INTR_STATUS5?status5:status7;
}
static void msm_dp_write_ahb(struct msm_dp_ctrl_private *ctrl,u32 reg,u32 value) {(void)ctrl;(void)reg;(void)value;}
static void msm_dp_write_link(struct msm_dp_ctrl_private *ctrl,u32 reg,u32 value) {(void)ctrl;assert(reg==REG_DP_MST_ACT&&value==1);++writes;}
static u32 msm_dp_read_link(struct msm_dp_ctrl_private *ctrl,u32 reg) {(void)ctrl;assert(reg==REG_DP_MST_ACT);++reads;return timeout?1:0;}
static void wmb(void) {}
static void msleep(unsigned delay) {assert(reads>0);++sleeps;last_sleep=delay;}
struct msm_dp_display_private {
 void *aux,*drm_dev;struct msm_dp_ctrl *ctrl;struct msm_dp_panel *panel;
 int irq_thread_lock;u32 hpd_isr_status;struct {void *bridge;unsigned connector_type;} msm_dp_display;
};
static u32 raw_irq;static irqreturn_t ctrl_irq;
static char events[8];static unsigned event_count;
static u32 msm_dp_aux_get_hpd_intr_status(void *p) {(void)p;return raw_irq;}
static irqreturn_t msm_dp_ctrl_isr(struct msm_dp_ctrl *c,struct msm_dp_panel *p) {(void)c;(void)p;return ctrl_irq;}
#define spin_lock_irqsave(p,f) do {(void)(p);(f)=0;} while(0)
#define spin_unlock_irqrestore(p,f) do {(void)(p);(void)(f);} while(0)
static void drm_bridge_hpd_notify(void *b,int status) {(void)b;events[event_count++]=status==connector_status_connected?'C':'D';}
static void drm_bridge_hpd_notify_extra(void *b,int status,int event) {(void)b;assert(status==connector_status_connected&&event==DRM_CONNECTOR_DP_IRQ_HPD);events[event_count++]='I';}
C
for name in msm_dp_ctrl_mst_send_act msm_dp_ctrl_get_mst_vcpf_interrupt_0_1 msm_dp_ctrl_get_mst_vcpf_interrupt_2_3; do
    awk -v name="$name" '$0 ~ "^(static )?(int|u32) " name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$source"
done
for name in msm_dp_display_irq_handler msm_dp_display_irq_thread; do
    awk -v name="$name" '$0 ~ "^static irqreturn_t " name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$(dirname -- "$source")/dp_display.c"
done
cat <<'C'
int main(void) {
 struct msm_dp_ctrl_private ctrl={0};struct msm_dp_panel panel={0};
 assert(!msm_dp_ctrl_mst_send_act(&ctrl.msm_dp_ctrl,&panel)&&!writes&&!sleeps);
 ctrl.mst_active=true;
 assert(msm_dp_ctrl_mst_send_act(&ctrl.msm_dp_ctrl,&panel)==-EINVAL&&!writes&&!sleeps);
 panel.msm_dp_mode.drm_mode=(struct drm_display_mode){2720,1481,241500};
 assert(!msm_dp_ctrl_mst_send_act(&ctrl.msm_dp_ctrl,&panel));
 assert(writes==1&&reads>=2&&sleeps==1&&last_sleep==18);
 timeout=true;assert(msm_dp_ctrl_mst_send_act(&ctrl.msm_dp_ctrl,&panel)<0);
 const u32 all=DP_INTR_MST_DP0_VCPF_SENT|DP_INTR_MST_DP1_VCPF_SENT|DP_INTR_MST_DP2_VCPF_SENT|DP_INTR_MST_DP3_VCPF_SENT;
 status5=DP_INTR_MST_DP2_VCPF_SENT;status7=DP_INTR_MST_DP0_VCPF_SENT;
 assert(!((msm_dp_ctrl_get_mst_vcpf_interrupt_0_1(&ctrl)|msm_dp_ctrl_get_mst_vcpf_interrupt_2_3(&ctrl))&all));
 status5=DP_INTR_MST_DP0_VCPF_SENT|DP_INTR_MST_DP1_VCPF_SENT;
 status7=DP_INTR_MST_DP2_VCPF_SENT|DP_INTR_MST_DP3_VCPF_SENT;
 assert((msm_dp_ctrl_get_mst_vcpf_interrupt_0_1(&ctrl)|msm_dp_ctrl_get_mst_vcpf_interrupt_2_3(&ctrl))==all);
 struct msm_dp_display_private dp={0};
 for(ctrl_irq=0;ctrl_irq<=1;ctrl_irq++)for(raw_irq=0;raw_irq<16;raw_irq++) {
  dp.hpd_isr_status=0;
  assert(msm_dp_display_irq_handler(1,&dp)==((raw_irq&DP_DP_HPD_INT_MASK)?IRQ_WAKE_THREAD:IRQ_HANDLED));
  assert(dp.hpd_isr_status==((raw_irq&DP_DP_HPD_INT_MASK)?raw_irq:0));
 }
 event_count=0;dp.hpd_isr_status=DP_DP_HPD_UNPLUG_INT_MASK|DP_DP_IRQ_HPD_INT_MASK;
 assert(msm_dp_display_irq_thread(1,&dp)==IRQ_HANDLED&&event_count==1&&events[0]=='D'&&!dp.hpd_isr_status);
 event_count=0;dp.hpd_isr_status=DP_DP_HPD_UNPLUG_INT_MASK|DP_DP_HPD_PLUG_INT_MASK|DP_DP_IRQ_HPD_INT_MASK;
 assert(msm_dp_display_irq_thread(1,&dp)==IRQ_HANDLED&&event_count==3&&events[0]=='D'&&events[1]=='C'&&events[2]=='I');
 puts("Production MST ACT: malformed mode refusal, write completion/timing, timeout and VCPF register isolation: PASS; host only.");
}
C
} > "$work/test.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/test.c" -o "$work/test"
"$work/test"
