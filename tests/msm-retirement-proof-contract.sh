#!/usr/bin/env bash
# COPR-only: actual DPU kickoff and encoder completion-proof admission.
set -Eeuo pipefail
ulimit -c 0
candidate=${1:?Prepared candidate}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
dpu=$candidate/drivers/gpu/drm/msm/disp/dpu1
extract() {
 awk -v name="$2" '$0 ~ "^(static )?(int|void|bool) " name "\\(" && $0 !~ /;[[:space:]]*$/ {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$1"
}
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#define container_of(p,t,m) ((t *)((char *)(p)-__builtin_offsetof(t,m)))
#define unlikely(x) (x)
#define DPU_ATRACE_BEGIN(...) ((void)0)
#define DPU_ATRACE_END(...) ((void)0)
#define DRM_DEBUG_ATOMIC(...) ((void)0)
#define DPU_ERROR(...) ((void)0)
#define trace_dpu_kms_commit(...) ((void)0)
#define trace_dpu_kms_wait_for_commit_done(...) ((void)0)
#define DPU_ENC_DISABLED 0
#define DPU_ENC_ENABLED 1
typedef int atomic_t;
static int atomic_inc_return(atomic_t *a) {return ++*a;}
static void reinit_completion(int *c) {++*c;}
enum dpu_intf_mode {INTF_MODE_VIDEO,INTF_MODE_CMD,INTF_MODE_WB_LINE,INTF_MODE_UNKNOWN};
struct drm_crtc_state {bool active,clone,modeset;unsigned encoder_mask;};
struct dpu_crtc_state {struct drm_crtc_state base;unsigned num_mixers;};
struct drm_device {unsigned nencoders;struct {int encoder_list;} mode_config;};
struct drm_crtc {struct drm_device *dev;struct drm_crtc_state *state;};
struct dpu_crtc {struct drm_crtc base;bool enabled,failed,quarantined;atomic_t frame_pending;unsigned play_count;int frame_done_comp;};
struct drm_encoder {struct drm_crtc *crtc;};
struct dpu_encoder_phys;
struct dpu_encoder_phys {int enable_state,retire_disable_error;struct {int (*wait_for_tx_complete)(struct dpu_encoder_phys *),(*wait_for_commit_done)(struct dpu_encoder_phys *);} ops;};
struct dpu_encoder_virt {struct drm_encoder base;bool enabled;int retire_stop_error;unsigned num_phys_encs;struct dpu_encoder_phys *phys_encs[2];enum dpu_intf_mode mode;};
static struct dpu_encoder_virt encoders[2];
static struct dpu_crtc *current_crtc;
struct msm_kms {struct drm_device *dev;};
struct dpu_kms {struct drm_device *dev;};
static struct dpu_kms backend;
#define to_dpu_crtc(c) container_of(c,struct dpu_crtc,base)
#define to_dpu_crtc_state(s) container_of(s,struct dpu_crtc_state,base)
#define to_dpu_encoder_virt(e) container_of(e,struct dpu_encoder_virt,base)
#define to_dpu_kms(k) ((void)(k),&backend)
#define drm_for_each_encoder_mask(e,d,m) for(unsigned _i=0;_i<(d)->nencoders;++_i) if(((m)&(1U<<_i))&&((e)=&encoders[_i].base))
#define list_for_each_entry(e,h,member) for(unsigned _i=((void)(h),0);_i<backend.dev->nencoders&&((e)=&encoders[_i].base);++_i)
#define for_each_crtc_mask(d,c,m) for(unsigned _once=((void)(d),(void)(m),0);_once<1&&((c)=&current_crtc->base);++_once)
struct drm_atomic_commit {struct drm_crtc_state *new_state;};
#define for_each_new_crtc_in_state(s,c,n,i) for((i)=0;(i)<1&&(((c)=&current_crtc->base),((n)=(s)->new_state),1);++(i))
static bool drm_atomic_crtc_needs_modeset(struct drm_crtc_state *s) {return s->modeset;}
static struct dpu_kms *_dpu_crtc_get_kms(struct drm_crtc *c) {(void)c;return &backend;}
static bool drm_crtc_in_clone_mode(struct drm_crtc_state *s) {return s->clone;}
static bool valid_encoder=true;
static int clone_error,wait_result,tx_result;
static unsigned kickoffs,waits,tx_waits,flush_calls;
static bool flush_valid,flush_one_shot;
static int dpu_crtc_kickoff_clone_mode(struct drm_crtc *c) {(void)c;if(!clone_error)kickoffs+=2;return clone_error;}
static bool dpu_encoder_is_valid_for_commit(struct drm_encoder *e) {(void)e;return valid_encoder;}
static void dpu_encoder_prepare_for_kickoff(struct drm_encoder *e,bool clone) {(void)e;assert(!clone);}
static void dpu_vbif_clear_errors(struct dpu_kms *k) {(void)k;}
static void dpu_encoder_kickoff(struct drm_encoder *e) {(void)e;++kickoffs;}
static void dpu_encoder_start_frame_done_timer(struct drm_encoder *e) {(void)e;}
static enum dpu_intf_mode dpu_encoder_get_intf_mode(struct drm_encoder *e) {return to_dpu_encoder_virt(e)->mode;}
static int dpu_encoder_wait_for_commit_done(struct drm_encoder *e) {(void)e;++waits;return wait_result;}
static int dpu_encoder_wait_for_tx_complete(struct drm_encoder *e) {(void)e;++tx_waits;return tx_result;}
static void dpu_crtc_retire_wait_status(struct drm_crtc *c,int error) {if(error){to_dpu_crtc(c)->failed=true;to_dpu_crtc(c)->quarantined=true;}}
static bool dpu_crtc_retire_failed(struct drm_crtc *c) {return to_dpu_crtc(c)->failed;}
static bool dpu_crtc_retire_quarantined(struct drm_crtc *c) {return to_dpu_crtc(c)->quarantined;}
static bool dpu_crtc_retire_stopped(struct drm_crtc *c) {return !to_dpu_crtc(c)->enabled&&!to_dpu_crtc(c)->quarantined;}
static void dpu_crtc_retire_flush(struct drm_crtc *c,bool valid,bool one_shot) {(void)c;++flush_calls;flush_valid=valid;flush_one_shot=one_shot;}
static int phys_wait(struct dpu_encoder_phys *p) {(void)p;return 0;}
C
extract "$dpu/dpu_crtc.c" dpu_crtc_commit_kickoff >> "$work/check.c"
extract "$dpu/dpu_encoder.c" dpu_encoder_retire_stopped >> "$work/check.c"
extract "$dpu/dpu_encoder.c" dpu_encoder_retire_wait >> "$work/check.c"
for fn in dpu_kms_flush_commit dpu_kms_wait_for_commit_done dpu_kms_wait_flush dpu_kms_commit_failed dpu_kms_retire_flush;do
 extract "$dpu/dpu_kms.c" "$fn" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
int main(void) {
 struct drm_device dev={.nencoders=1};struct dpu_crtc_state state={.base={.active=true,.encoder_mask=1},.num_mixers=1};
 struct dpu_crtc crtc={.base={.dev=&dev,.state=&state.base},.enabled=true};current_crtc=&crtc;backend.dev=&dev;struct msm_kms kms={.dev=&dev};
 struct dpu_encoder_phys phys={.enable_state=DPU_ENC_ENABLED,.ops={phys_wait,phys_wait}};
 encoders[0]=(struct dpu_encoder_virt){.base={.crtc=&crtc.base},.enabled=true,.num_phys_encs=1,.phys_encs={&phys},.mode=INTF_MODE_VIDEO};
 assert(dpu_crtc_commit_kickoff(&crtc.base)&&kickoffs==1);state.num_mixers=0;assert(!dpu_crtc_commit_kickoff(&crtc.base)&&kickoffs==1);
 dpu_kms_flush_commit(&kms,1);assert(crtc.quarantined&&kickoffs==1);crtc.failed=crtc.quarantined=false;state.num_mixers=1;
 valid_encoder=false;assert(!dpu_crtc_commit_kickoff(&crtc.base)&&kickoffs==1);valid_encoder=true;state.base.clone=true;clone_error=-EINVAL;
 assert(!dpu_crtc_commit_kickoff(&crtc.base)&&kickoffs==1);clone_error=0;assert(dpu_crtc_commit_kickoff(&crtc.base)&&kickoffs==3);state.base.clone=false;
 state.base.active=false;crtc.enabled=true;dpu_kms_flush_commit(&kms,1);assert(crtc.quarantined);crtc.failed=crtc.quarantined=false;
 /* A future inactive logical state cannot hide currently active hardware. */
 waits=0;assert(!dpu_kms_wait_for_commit_done(&kms,&crtc.base)&&waits==1);crtc.enabled=false;assert(!dpu_kms_wait_for_commit_done(&kms,&crtc.base)&&waits==1);
 crtc.enabled=true;state.base.active=true;
 for(unsigned mode=0;mode<3;++mode) {
  encoders[0].mode=mode;tx_result=0;dpu_kms_wait_flush(&kms,1);dpu_kms_retire_flush(&kms,1);
  assert(flush_valid&&flush_one_shot==(mode!=INTF_MODE_VIDEO));
 }
 encoders[0].mode=INTF_MODE_CMD;tx_result=-ETIMEDOUT;dpu_kms_retire_flush(&kms,1);assert(!flush_valid);tx_result=0;
 encoders[0].mode=INTF_MODE_VIDEO;phys.ops.wait_for_commit_done=NULL;dpu_kms_retire_flush(&kms,1);assert(!flush_valid);phys.ops.wait_for_commit_done=phys_wait;
 wait_result=-ETIMEDOUT;dpu_kms_wait_flush(&kms,1);wait_result=0;dpu_kms_wait_flush(&kms,1);dpu_kms_retire_flush(&kms,1);assert(!flush_valid&&crtc.quarantined);
 struct drm_atomic_commit atomic={.new_state=&state.base};state.base.modeset=true;assert(dpu_kms_commit_failed(&kms,&atomic,true)&&dpu_kms_commit_failed(&kms,&atomic,false));
 crtc.quarantined=false;assert(!dpu_kms_commit_failed(&kms,&atomic,true)&&dpu_kms_commit_failed(&kms,&atomic,false)&&crtc.quarantined);
 crtc.failed=crtc.quarantined=false;assert(!dpu_kms_commit_failed(&kms,&atomic,false));
 encoders[0].base.crtc=NULL;assert(dpu_kms_wait_for_commit_done(&kms,&crtc.base)==-ENODEV);dpu_kms_retire_flush(&kms,1);assert(!flush_valid);encoders[0].base.crtc=&crtc.base;
 encoders[0].enabled=false;phys.enable_state=DPU_ENC_DISABLED;assert(dpu_encoder_retire_stopped(&encoders[0].base));
 phys.retire_disable_error=-EIO;assert(!dpu_encoder_retire_stopped(&encoders[0].base));phys.retire_disable_error=0;encoders[0].retire_stop_error=-EIO;assert(!dpu_encoder_retire_stopped(&encoders[0].base));encoders[0].retire_stop_error=0;
 encoders[0].num_phys_encs=0;assert(!dpu_encoder_retire_stopped(&encoders[0].base));bool video;assert(dpu_encoder_retire_wait(&encoders[0].base,&video)==-ENODEV);
 assert(flush_calls&&tx_waits);puts("Actual DPU kickoff, runtime-active wait, mode proof, missing encoder and failed-stop gates pass");
}
C
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
 -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/check.c" -o "$work/check"
"$work/check"
