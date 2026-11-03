#!/usr/bin/env bash
# Execute the actual AVR arithmetic, INTF operations and bonded-host transaction.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel}
here=$(cd -- "$(dirname -- "$0")/../src/display" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/linux" "$work/drm"
cp "$here/o82-mode.h" "$work/drm/uke-o82-mode.h"
cp "$here/o82-avr.h" "$work/o82-avr.h"
printf '#define EINVAL 22\n' > "$work/linux/errno.h"
cat > "$work/linux/math64.h" <<'C'
#include <stdint.h>
typedef uint64_t u64;
static inline u64 div64_u64(u64 a, u64 b) { return a / b; }
C
cat > "$work/drm/drm_modes.h" <<'C'
#include <stdbool.h>
struct drm_display_mode {
 int clock,hdisplay,hsync_start,hsync_end,htotal,hskew;
 int vdisplay,vsync_start,vsync_end,vtotal,vscan;
 unsigned int flags;
};
C
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <limits.h>
#include <stddef.h>
#include <string.h>
#include "o82-avr.h"
typedef uint32_t u32;
#define U32_MAX UINT32_MAX
#define BIT(n) (1U << (n))
#define EPIPE 32
#define EIO 5
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define READ_ONCE(a) (a)
#define SINGLE_DEPTH_NESTING 1
static const struct drm_display_mode base = {
 967428,3200,3426,3458,3490,0,2136,2162,2164,2310,0,0
};
enum { INTF_HSYNC_CTL, INTF_AVR_VTOTAL, INTF_AVR_MODE, INTF_AVR_CONTROL, INTF_AVR_TRIGGER };
struct registers { u32 reg[5];unsigned writes; };
struct dpu_hw_intf { struct registers hw; };
static bool fail_intf_readback;
#define DPU_REG_READ(h,r) (fail_intf_readback && (r)==INTF_AVR_VTOTAL ? 0 : (h)->reg[r])
#define DPU_REG_WRITE(h,r,v) ((h)->reg[r]=(v),++(h)->writes)
C
extract() {
 awk -v signature="$2" 'index($0,signature)==1 {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$1" >> "$work/check.c"
}
intf=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_intf.c
for name in 'static int dpu_hw_intf_setup_avr(' 'static void dpu_hw_intf_enable_avr(' 'static void dpu_hw_intf_avr_trigger('; do
 extract "$intf" "$name"
done
cat >> "$work/check.c" <<'C'
#define DSI_0 0
#define DSI_1 1
#define REG_DSI_VID_CFG0 0
struct mipi_dsi_host { int unused; };
struct msm_dsi_host {
 struct mipi_dsi_host base;
 unsigned id; bool power_on,enabled,cmd_dma_blocked,scope;
 struct drm_display_mode *mode;
 void *uke_dfps_mode,*vm;
 int dev_mutex,cmd_mutex;
 u32 reg; unsigned writes;
};
static unsigned locks;
static bool fail_readback;
static void mutex_lock(int *m) { assert(*m==(int)locks);++locks; }
#define mutex_lock_nested(m,n) mutex_lock(m)
static void mutex_unlock(int *m) { assert(*m==(int)locks-1);--locks; }
static struct msm_dsi_host *to_msm_dsi_host(struct mipi_dsi_host *h) { return (void *)h; }
static bool dsi_uke_o82_refresh_modes(struct msm_dsi_host *h,const struct drm_display_mode *m) {
 return h->scope && qcom_uke_o82_mode(m);
}
static bool drm_mode_equal(const struct drm_display_mode *a,const struct drm_display_mode *b) {
 return !memcmp(a,b,sizeof(*a));
}
static u32 dsi_read(struct msm_dsi_host *h,unsigned reg) {
 assert(!reg && locks==4);
 return fail_readback && h->id==1 ? h->reg & ~BIT(29) : h->reg;
}
static void dsi_write(struct msm_dsi_host *h,unsigned reg,u32 val) {
 assert(!reg && locks==4);h->reg=val;++h->writes;
}
C
host=$kernel/drivers/gpu/drm/msm/dsi/dsi_host.c
extract "$host" 'bool msm_dsi_host_uke_avr_check('
extract "$host" 'int msm_dsi_host_uke_avr_pair('
cat >> "$work/check.c" <<'C'
static void reset(struct msm_dsi_host h[2],struct drm_display_mode *m) {
 for(unsigned i=0;i<2;++i)h[i]=(struct msm_dsi_host){
  .id=i,.power_on=true,.enabled=true,.scope=true,.mode=m,.vm=m,
  .dev_mutex=(int)i,.cmd_mutex=3-(int)i,.reg=0x1234
 };
 fail_readback=false;assert(!locks);
}
int main(void) {
 assert(qcom_uke_o82_avr_lines(NULL,119)==-EINVAL);
 assert(qcom_uke_o82_avr_lines(&base,0)==-EINVAL);
 assert(qcom_uke_o82_avr_lines(&base,119)==2329);
 for(unsigned hz=1;hz<1000;++hz) {
  int lines=qcom_uke_o82_avr_lines(&base,hz);
  assert((lines>0)==(hz>=30&&hz<=120));
  if(lines>0) {
   assert((u64)lines*base.htotal*hz<=(u64)base.clock*1000);
   assert((u64)(lines+1)*base.htotal*hz>(u64)base.clock*1000);
  }
 }
 assert(qcom_uke_o82_avr_lines(&base,UINT_MAX)==-EINVAL);
 struct drm_display_mode bad=base;
 bad.vtotal=4620;bad.vsync_start=4472;bad.vsync_end=4474;
 assert(qcom_uke_o82_avr_lines(&bad,119)==-EINVAL);
 const struct drm_display_mode modes[] = {
  {967428,3200,3426,3458,3490,0,2136,2162,2164,2310,0,0},
  {1097712,3200,3236,3268,3300,0,2136,2162,2164,2310,0,0},
  {804988,3200,3808,3840,3872,0,2136,2162,2164,2310,0,0},
  {967428,3200,3426,3458,3490,0,2136,4472,4474,4620,0,0},
  {804988,3200,3808,3840,3872,0,2136,4010,4012,4158,0,0},
  {804988,3200,3808,3840,3872,0,2136,4183,4185,4331,0,0},
  {804988,3200,3808,3840,3872,0,2136,6782,6784,6930,0,0},
 };
 const int max_lines[] = {9240,11088,6929,9240,6929,6929,6930};
 for(unsigned i=0;i<ARRAY_SIZE(modes);++i) {
  assert(qcom_uke_o82_avr_lines(&modes[i],30)==max_lines[i]);
  assert(qcom_uke_o82_avr_lines(&modes[i],29)==-EINVAL);
 }
 bad=base;bad.clock++;assert(qcom_uke_o82_avr_lines(&bad,119)==-EINVAL);
 struct dpu_hw_intf a={0},b={0};u32 period;
 a.hw.reg[INTF_HSYNC_CTL]=572U<<16;b.hw.reg[INTF_HSYNC_CTL]=572U<<16;
 assert(!dpu_hw_intf_setup_avr(&a,2329,&period)&&!dpu_hw_intf_setup_avr(&b,2329,&period));
 assert(a.hw.reg[INTF_AVR_VTOTAL]==1332188);
 assert(a.hw.reg[INTF_AVR_VTOTAL]==b.hw.reg[INTF_AVR_VTOTAL]);
 fail_intf_readback=true;assert(dpu_hw_intf_setup_avr(&a,2329,&period)==-EIO);
 fail_intf_readback=false;
 unsigned writes=a.hw.writes;
 assert(dpu_hw_intf_setup_avr(&a,UINT_MAX,&period)==-EINVAL&&a.hw.writes==writes);
 assert(dpu_hw_intf_setup_avr(&a,0,&period)==-EINVAL&&a.hw.writes==writes);
 a.hw.reg[INTF_HSYNC_CTL]=0;
 assert(dpu_hw_intf_setup_avr(&a,2329,&period)==-EINVAL&&a.hw.writes==writes);
 dpu_hw_intf_enable_avr(&b,true);assert(b.hw.reg[INTF_AVR_CONTROL]==1&&!b.hw.reg[INTF_AVR_MODE]);
 dpu_hw_intf_avr_trigger(&b);assert(b.hw.reg[INTF_AVR_TRIGGER]==1);
 dpu_hw_intf_enable_avr(&b,false);assert(!b.hw.reg[INTF_AVR_CONTROL]);
 struct drm_display_mode m=base;
 struct msm_dsi_host h[2];reset(h,&m);
 assert(!msm_dsi_host_uke_avr_pair(&h[0].base,&h[1].base,true));
 assert(h[0].reg==(0x1234|BIT(29))&&h[1].reg==h[0].reg&&!locks);
 assert(!msm_dsi_host_uke_avr_pair(&h[0].base,&h[1].base,false));
 assert(h[0].reg==0x1234&&h[1].reg==0x1234&&!locks);
 for(unsigned fault=0;fault<9;++fault) {
  reset(h,&m);
  switch(fault) {
  case 0:h[1].power_on=false;break;
  case 1:h[1].enabled=false;break;
  case 2:h[1].cmd_dma_blocked=true;break;
  case 3:h[1].uke_dfps_mode=&m;break;
  case 4:h[1].scope=false;break;
  case 5:h[1].mode=NULL;break;
  case 6:h[1].vm=NULL;break;
  case 7:h[0].vm=NULL;break;
  case 8:h[1].id=0;break;
  }
  assert(msm_dsi_host_uke_avr_pair(&h[0].base,&h[1].base,true)<0);
  assert(!h[0].writes&&!h[1].writes&&!locks);
 }
 reset(h,&m);fail_readback=true;
 assert(msm_dsi_host_uke_avr_pair(&h[0].base,&h[1].base,true)==-EIO);
 assert(h[0].reg==0x1234&&h[1].reg==0x1234&&h[0].writes==2&&h[1].writes==2&&!locks);
 reset(h,&m);h[0].reg|=BIT(29);h[1].power_on=false;
 assert(!msm_dsi_host_uke_avr_pair(&h[0].base,&h[1].base,false));
 assert(h[0].reg==0x1234&&!h[1].writes&&!locks);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined \
 -fsanitize-undefined-trap-on-error -I"$work" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual AVR: rational floor, experiment bounds, local INTF units/overflow, bonded readiness/locking/readback rollback and fixed fallback passed\n'
cat > "$work/timestamp.c" <<'C'
#include <assert.h>
#include <stdbool.h>
typedef long long ktime_t;
struct drm_crtc_state { bool vrr_enabled; };
struct drm_crtc { struct drm_crtc_state *state; };
#define READ_ONCE(x) (x)
static unsigned calls;
static bool drm_crtc_vblank_helper_get_vblank_timestamp(struct drm_crtc *c,
 int *error, ktime_t *time, bool irq) {
 assert(!c->state->vrr_enabled && *error==123 && irq);
 ++calls; *time=456; return true;
}
C
crtc=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c
awk '/^static bool dpu_crtc_get_vblank_timestamp\(/ {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$crtc" >> "$work/timestamp.c"
cat >> "$work/timestamp.c" <<'C'
int main(void) {
 struct drm_crtc_state s={false}; struct drm_crtc c={&s}; int error=123;ktime_t time=0;
 assert(dpu_crtc_get_vblank_timestamp(&c,&error,&time,true)&&calls==1&&time==456);
 s.vrr_enabled=true;time=0;
 assert(!dpu_crtc_get_vblank_timestamp(&c,&error,&time,true)&&calls==1&&!time);
 assert(!dpu_crtc_get_vblank_timestamp(&c,&error,&time,false)&&calls==1&&!time);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/timestamp.c" -o "$work/timestamp"
"$work/timestamp"
grep -Fq '.get_vblank_timestamp = dpu_crtc_get_vblank_timestamp,' "$crtc"
printf 'Actual timestamp callback: fixed helper retained; VRR selects DRM core estimate inside and outside IRQ\n'
# Run the logical encoder owner with two physical interfaces and injected errors.
cat > "$work/lifecycle.c" <<'C'
#include <assert.h>
#include <stddef.h>
#include "o82-avr.h"
typedef unsigned int u32;
#define DPU_ENC_DISABLED 0
#define DPU_ENC_ENABLED 1
#define DRM_ERROR(...) ((void)0)
#define DRM_INFO(...) ((void)0)
struct drm_crtc_state { bool active,vrr_enabled;struct drm_display_mode adjusted_mode; };
struct drm_crtc { struct drm_crtc_state *state; };
struct drm_encoder { int unused; };
struct dpu_hw_intf {
 struct {int (*setup_avr)(struct dpu_hw_intf *,u32,u32 *);void (*enable_avr)(struct dpu_hw_intf *,bool);void (*avr_trigger)(struct dpu_hw_intf *);} ops;
 unsigned idx,setups,period_bias;bool enabled;int error;
};
struct dpu_hw_ctl {struct {void (*update_pending_flush_intf)(struct dpu_hw_ctl *,unsigned);} ops;unsigned mask;};
struct dpu_encoder_phys { struct dpu_hw_intf *hw_intf;struct dpu_hw_ctl *hw_ctl;int enable_state; };
struct dpu_encoder_virt {
 struct drm_encoder base;bool avr_enabled,avr_failed;unsigned enc_spinlock,num_phys_encs;
 struct dpu_encoder_phys *phys_encs[2],*cur_master;struct drm_crtc *crtc;
};
static unsigned o82_vrr_test_min_hz=119,host_calls;
static bool allowed,split,hosts_on;
static int host_error;
static struct dpu_hw_intf interfaces[2];
static bool dpu_encoder_uke_vrr_check(struct drm_encoder *e,const struct drm_crtc_state *s) {
 (void)e;return allowed&&qcom_uke_o82_avr_lines(&s->adjusted_mode,o82_vrr_test_min_hz)>0;
}
static bool dpu_encoder_uke_split_flush(struct dpu_encoder_phys *p) { assert(p);return split; }
static int msm_dsi_manager_uke_avr_set(bool on) {
 ++host_calls;assert(!interfaces[0].enabled&&!interfaces[1].enabled);
 if(on&&host_error)return host_error;
 hosts_on=on;return 0;
}
#define spin_lock_irqsave(l,f) ((f)=0,assert(!*(l)),++*(l))
#define spin_unlock_irqrestore(l,f) ((void)(f),assert(*(l)==1),--*(l))
static int setup(struct dpu_hw_intf *i,u32 lines,u32 *period) { assert(lines==2329&&!i->enabled);*period=lines*572+i->period_bias; ++i->setups;return i->error; }
static void enable(struct dpu_hw_intf *i,bool on) { if(on)assert(hosts_on);i->enabled=on; }
static void flush(struct dpu_hw_ctl *c,unsigned idx) { c->mask|=1U<<idx; }
static void trigger(struct dpu_hw_intf *i) { assert(i->enabled); }
C
encoder=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
for signature in 'static void dpu_encoder_uke_avr_disable(' 'static void dpu_encoder_uke_avr_update('; do
 awk -v signature="$signature" 'index($0,signature)==1 {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$encoder" >> "$work/lifecycle.c"
done
cat >> "$work/lifecycle.c" <<'C'
int main(void) {
 struct drm_crtc_state state={.active=true,.vrr_enabled=true,.adjusted_mode={967428,3200,3426,3458,3490,0,2136,2162,2164,2310,0,0}};
 struct drm_crtc crtc={.state=&state};
 struct dpu_hw_ctl ctl={.ops={flush}};
 for(unsigned i=0;i<2;++i)interfaces[i]=(struct dpu_hw_intf){.ops={setup,enable,trigger},.idx=i};
 struct dpu_encoder_phys phys[2]={{&interfaces[0],&ctl,DPU_ENC_ENABLED},{&interfaces[1],&ctl,DPU_ENC_ENABLED}};
 struct dpu_encoder_virt enc={.num_phys_encs=2,.phys_encs={&phys[0],&phys[1]},.cur_master=&phys[0],.crtc=&crtc};
 allowed=split=true;
 dpu_encoder_uke_avr_update(&enc);
 assert(enc.avr_enabled&&hosts_on&&interfaces[0].enabled&&interfaces[1].enabled&&ctl.mask==3&&host_calls==1);
 dpu_encoder_uke_avr_update(&enc);assert(host_calls==1&&interfaces[0].setups==1);
 state.vrr_enabled=false;dpu_encoder_uke_avr_update(&enc);
 assert(!enc.avr_enabled&&!hosts_on&&!interfaces[0].enabled&&!interfaces[1].enabled&&host_calls==2);
 dpu_encoder_uke_avr_update(&enc);assert(host_calls==2);
 state.vrr_enabled=true;interfaces[1].error=-22;
 dpu_encoder_uke_avr_update(&enc);assert(!enc.avr_enabled&&!hosts_on&&host_calls==2);
 assert(enc.avr_failed);dpu_encoder_uke_avr_update(&enc);assert(host_calls==2);
 state.vrr_enabled=false;dpu_encoder_uke_avr_update(&enc);state.vrr_enabled=true;
 assert(!enc.avr_failed);
 interfaces[1].error=0;interfaces[1].period_bias=1;
 dpu_encoder_uke_avr_update(&enc);assert(!enc.avr_enabled&&!hosts_on&&host_calls==2);
 state.vrr_enabled=false;dpu_encoder_uke_avr_update(&enc);state.vrr_enabled=true;
 interfaces[1].period_bias=0;host_error=-5;
 dpu_encoder_uke_avr_update(&enc);assert(!enc.avr_enabled&&!interfaces[0].enabled&&!interfaces[1].enabled&&host_calls==3);
 assert(enc.avr_failed);dpu_encoder_uke_avr_update(&enc);assert(host_calls==3);
 state.vrr_enabled=false;dpu_encoder_uke_avr_update(&enc);state.vrr_enabled=true;
 host_error=0;
 for(unsigned gate=0;gate<5;++gate) {
  allowed=split=true;phys[1].enable_state=DPU_ENC_ENABLED;enc.cur_master=&phys[0];
  switch(gate) {
  case 0:allowed=false;break;
  case 1:split=false;break;
  case 2:phys[1].enable_state=DPU_ENC_DISABLED;break;
  case 3:enc.cur_master=0;break;
  case 4:state.active=false;break;
  }
  dpu_encoder_uke_avr_update(&enc);assert(!enc.avr_enabled&&host_calls==3&&!enc.enc_spinlock);
 }
 state.active=true;allowed=split=true;
 dpu_encoder_uke_avr_update(&enc);assert(enc.avr_enabled);
 dpu_encoder_uke_avr_disable(&enc);assert(!enc.avr_enabled&&!hosts_on&&!interfaces[0].enabled&&!interfaces[1].enabled);
 dpu_encoder_uke_avr_disable(&enc);assert(host_calls==5&&!enc.enc_spinlock);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined \
 -fsanitize-undefined-trap-on-error -I"$work" "$work/lifecycle.c" -o "$work/lifecycle"
"$work/lifecycle"
printf 'Actual shared encoder owner: enable, page-flip reuse, off, second-INTF failure, host error, invalid topology and idempotent disable passed\n'
# Initial timing enable must precede the pair trigger, as in the OEM video path.
cat > "$work/kickoff.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#define DPU_ATRACE_BEGIN(...) ((void)0)
#define DPU_ATRACE_END(...) ((void)0)
#define trace_dpu_enc_kickoff(...) ((void)0)
struct drm_encoder {int unused;};
struct dpu_hw_intf {struct {void (*avr_trigger)(struct dpu_hw_intf *);} ops;};
struct dpu_encoder_phys {struct {void (*handle_post_kickoff)(struct dpu_encoder_phys *);} ops;struct dpu_hw_intf *hw_intf;};
struct dpu_encoder_virt {struct drm_encoder base;bool avr_enabled;unsigned enc_spinlock,num_phys_encs;struct dpu_encoder_phys *phys_encs[2];};
static unsigned stage,triggers;
static struct dpu_encoder_virt *to_dpu_encoder_virt(struct drm_encoder *e) {return (void *)e;}
static void _dpu_encoder_kickoff_phys(struct dpu_encoder_virt *e) {(void)e;assert(!stage);stage=1;}
static void post(struct dpu_encoder_phys *p) {(void)p;assert(stage==1||stage==2);++stage;}
static void trigger(struct dpu_hw_intf *i) {(void)i;assert(stage==3);++triggers;}
#define spin_lock_irqsave(l,f) ((f)=0,assert(!*(l)),++*(l))
#define spin_unlock_irqrestore(l,f) ((void)(f),assert(*(l)==1),--*(l))
C
awk '/^void dpu_encoder_kickoff\(/ {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$encoder" >> "$work/kickoff.c"
cat >> "$work/kickoff.c" <<'C'
int main(void) {
 struct dpu_hw_intf intf[2]={{{trigger}},{{trigger}}};
 struct dpu_encoder_phys phys[2]={{{post},&intf[0]},{{post},&intf[1]}};
 struct dpu_encoder_virt enc={.avr_enabled=true,.num_phys_encs=2,.phys_encs={&phys[0],&phys[1]}};
 dpu_encoder_kickoff(&enc.base);assert(stage==3&&triggers==2&&!enc.enc_spinlock);
 stage=triggers=0;enc.avr_enabled=false;
 dpu_encoder_kickoff(&enc.base);assert(stage==3&&!triggers&&!enc.enc_spinlock);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined \
 -fsanitize-undefined-trap-on-error -I"$work" "$work/kickoff.c" -o "$work/kickoff"
"$work/kickoff"
printf 'Actual kickoff: shared CTL flush and both initial timing callbacks precede paired AVR triggers; fixed commits do not trigger AVR\n'

# The nominal five-frame watchdog must also cover five stretched AVR frames.
cat > "$work/watchdog.c" <<'C'
#include <assert.h>
#include "o82-avr.h"
#define DPU_ENCODER_FRAME_DONE_TIMEOUT_FRAMES 5
#define max_t(t,a,b) ((t)(a)>(t)(b)?(t)(a):(t)(b))
struct drm_crtc_state { bool active,vrr_enabled;struct drm_display_mode adjusted_mode; };
struct drm_crtc { struct drm_crtc_state *state; };
struct drm_encoder { struct drm_crtc *crtc; };
struct dpu_encoder_virt { struct drm_encoder base;bool avr_enabled,avr_failed;unsigned long frame_done_timer; };
static bool allowed=true;
static unsigned o82_vrr_test_min_hz=30;
static unsigned long jiffies=1000;
static struct dpu_encoder_virt *to_dpu_encoder_virt(struct drm_encoder *e) {return (void *)e;}
static bool dpu_encoder_uke_vrr_check(struct drm_encoder *e,const struct drm_crtc_state *s) {(void)e;(void)s;return allowed;}
static unsigned drm_mode_vrefresh(const struct drm_display_mode *m) {
 u64 cycles=(u64)m->htotal*m->vtotal;
 return ((u64)m->clock*1000+cycles/2)/cycles;
}
#define atomic_set(p,v) (*(p)=(v))
#define msecs_to_jiffies(ms) (ms)
#define mod_timer(p,v) (*(p)=(v))
C
awk '/^void dpu_encoder_start_frame_done_timer\(/ {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$encoder" >> "$work/watchdog.c"
cat >> "$work/watchdog.c" <<'C'
static void expect(struct dpu_encoder_virt *e,unsigned long ms) {
 dpu_encoder_start_frame_done_timer(&e->base);
 assert(e->frame_done_timer==jiffies+ms);
}
int main(void) {
 const unsigned modes[][4]={
  {967428,3490,2310,41},{967428,3490,4620,83},
  {1097712,3300,2310,34},{804988,3872,2310,55},
  {804988,3872,4158,100},{804988,3872,4331,104},{804988,3872,6930,166}
 };
 struct drm_crtc_state state={.active=true};
 (void)&dpu_encoder_uke_vrr_check; (void)o82_vrr_test_min_hz;
 struct drm_crtc crtc={.state=&state};
 struct dpu_encoder_virt e={.base={.crtc=&crtc}};
 for(unsigned i=0;i<7;i++) {
  state.adjusted_mode=(struct drm_display_mode){
   .clock=modes[i][0],.hdisplay=3200,.htotal=modes[i][1],
   .hsync_start=modes[i][1]-64,.hsync_end=modes[i][1]-32,
   .vdisplay=2136,.vtotal=modes[i][2],
   .vsync_start=modes[i][2]-148,.vsync_end=modes[i][2]-146
  };
  e.avr_enabled=false;e.avr_failed=false;state.vrr_enabled=false;
  expect(&e,modes[i][3]);
  state.vrr_enabled=true;expect(&e,167); // Entry before hardware activation.
  e.avr_enabled=true;expect(&e,167);
  state.vrr_enabled=false;expect(&e,167); // Exit before hardware deactivation.
  e.avr_enabled=false;e.avr_failed=true;state.vrr_enabled=true;
  expect(&e,modes[i][3]);
  e.avr_failed=false;allowed=false;expect(&e,modes[i][3]);allowed=true;
  state.active=false;expect(&e,modes[i][3]);state.active=true;
  o82_vrr_test_min_hz=0;expect(&e,modes[i][3]);o82_vrr_test_min_hz=30;
  state.adjusted_mode.htotal++; // Foreign geometry must retain the nominal path.
  expect(&e,5000/drm_mode_vrefresh(&state.adjusted_mode));
 }
 return 0;
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined -fsanitize-undefined-trap-on-error -I"$work" "$work/watchdog.c" -o "$work/watchdog"
"$work/watchdog"
printf 'Actual watchdog: all seven AVR bases retain five maximum frame periods through entry and exit; fixed, failed, inactive and foreign paths remain nominal\n'

# Execute the actual encoder disable caller, including its DSI ownership boundary.
if grep -Fq 'retire_stop_error' "$encoder";then
    printf '#define UKE_RETIRE_PROOF 1\n' > "$work/disable.c"
else
    : > "$work/disable.c"
fi
cat >> "$work/disable.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
struct drm_crtc_state {bool self_refresh_active;};
struct drm_crtc {struct drm_crtc_state *state;};
struct drm_encoder {struct {int id;} base;};
struct drm_atomic_commit {struct drm_crtc *crtc;};
enum {DPU_ENC_DISABLED,DPU_ENC_ENABLED};
enum {INTF_MODE_VIDEO,INTF_MODE_CMD};
struct dpu_encoder_phys {struct {void (*disable)(struct dpu_encoder_phys *);} ops;int id,enable_state,retire_disable_error;};
struct dpu_encoder_virt {struct drm_encoder base;int enc_lock,num_phys_encs;bool enabled;
 struct dpu_encoder_phys *phys_encs[2];int frame_done_timer;void *connector;int retire_stop_error;};
static char events[32];static unsigned n,errors;static int stop_error;
static int tx_error,phys_error[2],mode=INTF_MODE_VIDEO;
static void event(char value) {assert(n+1<sizeof(events));events[n++]=value;events[n]=0;}
static struct dpu_encoder_virt *to_dpu_encoder_virt(struct drm_encoder *e) {return (void *)e;}
static struct drm_crtc *drm_atomic_get_old_crtc_for_encoder(struct drm_atomic_commit *s,struct drm_encoder *e) {(void)e;return s->crtc;}
static struct drm_crtc_state *drm_atomic_get_old_crtc_state(struct drm_atomic_commit *s,struct drm_crtc *c) {assert(s->crtc==c);return c->state;}
static void mutex_lock(int *l) {assert(!*l);++*l;}
static void mutex_unlock(int *l) {assert(*l==1);--*l;}
#define DPU_DEBUG_ENC(...) ((void)0)
#define trace_dpu_enc_disable(...) ((void)0)
#define DPU_ERROR_ENC(...) (++errors)
#define DPU_ERROR(...) (++errors)
#define DRMID(e) ((e)->base.id)
enum {DPU_ENC_RC_EVENT_PRE_STOP,DPU_ENC_RC_EVENT_STOP};
static void dpu_encoder_uke_avr_disable(struct dpu_encoder_virt *e) {assert(!e->enabled);event('A');}
static int dpu_encoder_wait_for_tx_complete(struct drm_encoder *e) {(void)e;event('W');return tx_error;}
static int dpu_encoder_get_intf_mode(struct drm_encoder *e) {(void)e;return mode;}
static void dpu_encoder_resource_control(struct drm_encoder *e,int value) {(void)e;event(value==DPU_ENC_RC_EVENT_PRE_STOP?'P':'S');}
static void disable(struct dpu_encoder_phys *p) {
#ifdef UKE_RETIRE_PROOF
 if(p->enable_state!=DPU_ENC_DISABLED)assert(p->retire_disable_error==-EINPROGRESS);
#endif
 event('0'+p->id);p->enable_state=DPU_ENC_DISABLED;p->retire_disable_error=phys_error[p->id];
}
static int msm_dsi_manager_uke_video_stop(struct drm_encoder *e) {(void)e;event('D');return stop_error;}
static void timer_delete_sync(int *t) {*t=0;event('T');}
C
awk '/^static void dpu_encoder_virt_atomic_disable\(/ {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$encoder" >> "$work/disable.c"
cat >> "$work/disable.c" <<'C'
int main(void) {
 struct dpu_encoder_phys phys[2]={{.ops={disable},.id=0,.enable_state=DPU_ENC_ENABLED},
                                {.ops={disable},.id=1,.enable_state=DPU_ENC_ENABLED}};
 struct dpu_encoder_virt e={.num_phys_encs=2,.phys_encs={&phys[0],&phys[1]},.enabled=true,.connector=&e};
 struct drm_crtc_state old={0};struct drm_crtc crtc={&old};struct drm_atomic_commit s={&crtc};
 dpu_encoder_virt_atomic_disable(&e.base,&s);
 assert(!strcmp(events,"AWP01DTS")&&!e.connector&&!e.enabled&&!e.enc_lock&&!errors);
 n=0;events[0]=0;e.enabled=true;e.connector=&e;old.self_refresh_active=true;
 dpu_encoder_virt_atomic_disable(&e.base,&s);
 assert(!n&&e.enabled&&e.connector==&e&&!e.enc_lock);
 old.self_refresh_active=false;stop_error=-5;e.frame_done_timer=1;
 dpu_encoder_virt_atomic_disable(&e.base,&s);
 assert(!strcmp(events,"AWP01DTS")&&errors==1&&!e.frame_done_timer&&!e.enc_lock);
 n=errors=0;events[0]=0;stop_error=0;s.crtc=NULL;phys[0].ops.disable=NULL;
 phys[0].enable_state=DPU_ENC_ENABLED;phys[0].retire_disable_error=0;
 dpu_encoder_virt_atomic_disable(&e.base,&s);
 assert(!strcmp(events,"AWP1DTS")&&!errors&&!e.enc_lock);
 (void)dpu_encoder_get_intf_mode;
#ifdef UKE_RETIRE_PROOF
 assert(e.retire_stop_error==-EINPROGRESS);
 const int expected[]={-ETIMEDOUT,0,0,-EIO,-EBUSY,-EIO,-ETIMEDOUT,-EIO};
 for(unsigned trial=0;trial<sizeof(expected)/sizeof(expected[0]);++trial) {
  n=errors=0;events[0]=0;mode=INTF_MODE_VIDEO;tx_error=stop_error=0;phys_error[0]=phys_error[1]=0;
  for(unsigned i=0;i<2;++i){phys[i].ops.disable=disable;phys[i].enable_state=DPU_ENC_ENABLED;}
  e.enabled=true;e.connector=&e;e.frame_done_timer=1;s.crtc=&crtc;
  switch(trial) {
   case 0:mode=INTF_MODE_CMD;tx_error=-ETIMEDOUT;break;
   case 1:mode=INTF_MODE_CMD;tx_error=-EWOULDBLOCK;break;
   case 2:tx_error=-ETIMEDOUT;break;
   case 3:phys_error[0]=-EIO;break;
   case 4:phys_error[1]=-EBUSY;break;
   case 5:phys_error[0]=-EIO;phys_error[1]=-EBUSY;break;
   case 6:mode=INTF_MODE_CMD;tx_error=-ETIMEDOUT;phys_error[0]=-EIO;stop_error=-EBUSY;break;
   case 7:stop_error=-EIO;break;
  }
  dpu_encoder_virt_atomic_disable(&e.base,&s);
  assert(!strcmp(events,"AWP01DTS")&&e.retire_stop_error==expected[trial]&&!e.enc_lock&&!e.connector&&!e.frame_done_timer);
  assert(errors==(stop_error!=0));
 }
#endif
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/disable.c" -o "$work/disable"
"$work/disable"
printf 'Actual encoder disable: AVR and frame drain, both physical timing stops, DSI stop, then resource release; self-refresh and stop errors remain bounded\n'
