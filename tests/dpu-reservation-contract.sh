#!/usr/bin/env bash
# COPR-only: execute production reservation/check/mode-set functions with fake blocks.
set -Eeuo pipefail
ulimit -c 0
candidate=${1:?Pass fully prepared candidate source}
baseline=${2:?Pass the pre-patch source directory}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
    local file=$1 name=$2 optional=${3:-false}
    awk -v name="$name" -v optional="$optional" '
      $0 ~ "^(static )?(int|bool|void) " name "\\(" {emit=1;found=1}
      emit {print} emit && /^}/ {exit}
      END {if(!found && optional!="true")exit 1}' "$file"
}
cat > "$work/preamble.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define MAX_CHANNELS_PER_ENC 2
#define MAX_CHANNELS_PER_CRTC 2
#define MAX_CWB_PER_ENC 2
#define CONFIG_DRM_MSM_DSI 1
#define IS_ENABLED(x) (x)
#define ARRAY_SIZE(x) (sizeof(x)/sizeof((x)[0]))
#define BIT(x) (1U<<(x))
#define hweight32(x) __builtin_popcount(x)
#define CWB_0 0
#define DSC_0 0
enum {INTF_WB,INTF_DP,INTF_DSI};
enum {DPU_HW_BLK_CTL,DPU_HW_BLK_LM,DPU_HW_BLK_DSPP,DPU_HW_BLK_PINGPONG,
      DPU_HW_BLK_DCWB_PINGPONG,DPU_HW_BLK_CWB,DPU_HW_BLK_DSC,DPU_HW_BLK_CDM,BLOCK_TYPES};
struct dpu_hw_blk {int idx;};
struct drm_device {void *dev_private;};
struct drm_crtc {struct drm_device *dev; struct {int id;} base;};
struct drm_atomic_commit;
struct drm_crtc_state {
 struct drm_crtc *crtc;struct drm_atomic_commit *state;void *ctm,*gamma_lut;
 bool mode_changed,connectors_changed,color_mgmt_changed,clone,active,enable;
 bool vrr_enabled,planes_changed,zpos_changed;unsigned encoder_mask;int adjusted_mode;
};
struct mixer {struct dpu_hw_blk *hw_lm,*lm_ctl,*hw_dspp;};
struct dpu_crtc_state {struct drm_crtc_state base;unsigned num_mixers;struct mixer mixers[2];int new_perf;};
struct drm_atomic_commit {struct drm_device *dev;bool allow_modeset;struct dpu_crtc_state old,next;};
struct drm_encoder {struct drm_device *dev;struct drm_crtc *crtc;};
struct drm_connector_state {void *writeback_job;};
struct dpu_encoder_phys {
 struct dpu_hw_blk *hw_pp,*hw_ctl,*hw_cdm;int cached_mode;
 struct {void (*atomic_mode_set)(struct dpu_encoder_phys *,struct drm_crtc_state *,struct drm_connector_state *);
         void (*seamless_mode_set)(struct dpu_encoder_phys *);} ops;
};
struct dpu_encoder_virt {
 struct drm_encoder base;struct {int intf_type;bool is_cmd_mode;} disp_info;
 struct dpu_hw_blk *hw_pp[2],*hw_cwb[2],*hw_dsc[2];unsigned cwb_mask,dsc_mask;
 int num_phys_encs;struct dpu_encoder_phys *cur_master,*phys_encs[2];
};
struct msm_kms;
struct msm_kms_funcs {int (*check_mode_changed)(struct msm_kms *,struct drm_atomic_commit *);};
struct msm_kms {const struct msm_kms_funcs *funcs;};
struct dpu_kms {struct msm_kms base;int rm,bandwidth_ref;};
struct msm_drm_private {struct msm_kms *kms;};
struct dpu_global_state {int unused;};
struct msm_display_topology {int unused;};
struct dpu_crtc {const char *name;};
struct drm_plane {struct {int id;} base;};
struct drm_plane_state {bool visible;};
struct dpu_plane_state {struct drm_plane_state base;bool needs_dirtyfb;};
static struct dpu_global_state global;
static struct dpu_crtc dummy_crtc={"fixture"};
static struct dpu_encoder_virt fixture_encoder;
static struct dpu_encoder_phys physical[2];
static struct dpu_kms kms;
static struct msm_drm_private priv;
static struct drm_device dev;
static struct drm_crtc fixture_crtc;
static struct drm_atomic_commit commit;
static struct drm_connector_state connector;
static struct dpu_hw_blk blocks[BLOCK_TYPES][2];
static struct dpu_hw_blk reassigned_ctl[2];
static int counts[BLOCK_TYPES],reserves,releases,reserve_error,bounds_error,perf_error,mst_error;
static unsigned modesets,seamless;
static bool dfps_failed,dfps_pending,encoder_modeset;
static const bool dpu_use_virtual_planes=false;
static void log_message(const char *message,...) {(void)message;}
#define DPU_ERROR(...) log_message(__VA_ARGS__)
#define DPU_DEBUG_ENC(e,...) ((void)(e),log_message(__VA_ARGS__))
#define DPU_ERROR_ENC(e,...) ((void)(e),log_message(__VA_ARGS__))
#define DRM_DEBUG_ATOMIC(...) log_message(__VA_ARGS__)
#define DRMID(x) ((void)(x),0)
#define trace_dpu_enc_mode_set(x) ((void)(x))
#define to_dpu_encoder_virt(e) ((struct dpu_encoder_virt *)(e))
#define to_dpu_kms(k) ((struct dpu_kms *)(k))
#define to_dpu_crtc_state(s) ((struct dpu_crtc_state *)(s))
#define to_dpu_plane_state(s) ((struct dpu_plane_state *)(s))
#define to_dpu_crtc(c) ((void)(c),&dummy_crtc)
#define to_dpu_hw_mixer(p) (p)
#define to_dpu_hw_ctl(p) (p)
#define to_dpu_hw_dspp(p) (p)
#define to_dpu_hw_pingpong(p) (p)
#define to_dpu_hw_cwb(p) (p)
#define to_dpu_hw_dsc(p) (p)
#define to_dpu_hw_cdm(p) (p)
#define IS_ERR(p) ((uintptr_t)(p) > UINTPTR_MAX-4095)
#define IS_ERR_OR_NULL(p) (!(p)||IS_ERR(p))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define drm_for_each_encoder_mask(e,d,m) for((e)=((void)(d),(m)&1?&fixture_encoder.base:NULL);(e);(e)=NULL)
#define for_each_oldnew_crtc_in_state(s,c,o,n,i) \
 for((i)=0;(i)<1&&(((c)=&fixture_crtc),(void)(c),((o)=&(s)->old.base),((n)=&(s)->next.base),1);++(i))
#define drm_atomic_crtc_state_for_each_plane_state(p,s,c) \
 for((p)=NULL,(s)=NULL;(void)(c),(p)!=NULL;)
static struct dpu_kms *_dpu_crtc_get_kms(struct drm_crtc *c) {(void)c;return &kms;}
static struct dpu_global_state *dpu_kms_get_global_state(struct drm_atomic_commit *s) {(void)s;return &global;}
static struct dpu_global_state *dpu_kms_get_existing_global_state(struct dpu_kms *k) {(void)k;return &global;}
static void dpu_rm_release(struct dpu_global_state *g,struct drm_crtc *c) {(void)g;(void)c;++releases;}
static struct msm_display_topology dpu_crtc_get_topology(struct drm_crtc *c,struct dpu_kms *k,struct drm_crtc_state *s) {(void)c;(void)k;(void)s;return (struct msm_display_topology){0};}
static int dpu_rm_reserve(int *rm,struct dpu_global_state *g,struct drm_crtc *c,struct msm_display_topology *t) {(void)rm;(void)g;(void)c;(void)t;++reserves;return reserve_error;}
static int dpu_rm_get_assigned_resources(int *rm,struct dpu_global_state *g,struct drm_crtc *c,int type,struct dpu_hw_blk **out,size_t capacity) {
 (void)rm;(void)g;(void)c;assert(counts[type]>=0&&(size_t)counts[type]<=capacity);
 for(int i=0;i<counts[type];i++)out[i]=type==DPU_HW_BLK_CTL&&reserves?&reassigned_ctl[i]:&blocks[type][i];return counts[type];
}
static bool drm_crtc_in_clone_mode(const struct drm_crtc_state *s) {return s->clone;}
static bool dpu_encoder_needs_modeset(struct drm_encoder *e,struct drm_atomic_commit *s) {(void)e;(void)s;return encoder_modeset;}
static struct drm_crtc_state *drm_atomic_get_new_crtc_state(struct drm_atomic_commit *s,struct drm_crtc *c) {(void)c;return &s->next.base;}
static bool dpu_crtc_needs_dirtyfb(struct drm_crtc_state *s) {(void)s;return false;}
static bool dpu_encoder_uke_vrr_check(struct drm_encoder *e,struct drm_crtc_state *s) {(void)e;(void)s;return true;}
static int dpu_crtc_reassign_planes(struct drm_crtc *c,struct drm_crtc_state *s) {(void)c;(void)s;return 0;}
static int dpu_crtc_assign_planes(struct drm_crtc *c,struct drm_crtc_state *s) {(void)c;(void)s;return 0;}
static bool drm_atomic_crtc_effectively_active(struct drm_crtc_state *s) {return s->active;}
static int _dpu_crtc_check_and_setup_lm_bounds(struct drm_crtc *c,struct drm_crtc_state *s) {(void)c;(void)s;return bounds_error;}
static void atomic_inc(int *n) {++*n;}
static int dpu_core_perf_crtc_check(struct drm_crtc *c,struct drm_crtc_state *s) {(void)c;(void)s;return perf_error;}
static bool msm_uke_dfps_failed(void) {return dfps_failed;}
static bool msm_dsi_manager_uke_dfps_pending(struct drm_encoder *e) {(void)e;return dfps_pending;}
static int drm_atomic_helper_check(struct drm_device *d,struct drm_atomic_commit *s);
static int drm_dp_mst_atomic_check(struct drm_atomic_commit *s) {(void)s;return mst_error;}
C
cat > "$work/cases.c" <<'C'
static void fake_modeset(struct dpu_encoder_phys *p,struct drm_crtc_state *s,struct drm_connector_state *c) {(void)p;(void)s;(void)c;++modesets;}
static void fake_seamless(struct dpu_encoder_phys *p) {(void)p;++seamless;}
static int mode_check(struct msm_kms *k,struct drm_atomic_commit *s) {(void)k;return dpu_crtc_check_mode_changed(&s->old.base,&s->next.base);}
static const struct msm_kms_funcs funcs={mode_check};
static int drm_atomic_helper_check(struct drm_device *d,struct drm_atomic_commit *s) {(void)d;return dpu_crtc_atomic_check(&fixture_crtc,s);}
static void reset(void) {
 memset(&fixture_encoder,0,sizeof(fixture_encoder));memset(physical,0,sizeof(physical));memset(&commit,0,sizeof(commit));
 memset(counts,0,sizeof(counts));reserves=releases=reserve_error=bounds_error=perf_error=mst_error=0;
 dfps_failed=dfps_pending=encoder_modeset=false;modesets=seamless=0;
 kms=(struct dpu_kms){.base={&funcs}};priv=(struct msm_drm_private){&kms.base};dev.dev_private=&priv;
 fixture_crtc=(struct drm_crtc){.dev=&dev,.base={1}};commit.dev=&dev;
 commit.old.base=(struct drm_crtc_state){.crtc=&fixture_crtc,.state=&commit,.active=true,.enable=true,.encoder_mask=1};
 commit.next.base=commit.old.base;
 fixture_encoder.base=(struct drm_encoder){&dev,&fixture_crtc};fixture_encoder.num_phys_encs=2;fixture_encoder.cur_master=&physical[0];
 connector=(struct drm_connector_state){0};
 for(int t=0;t<BLOCK_TYPES;t++)for(int i=0;i<2;i++)blocks[t][i].idx=i;
 for(int i=0;i<2;i++) {
  fixture_encoder.phys_encs[i]=&physical[i];physical[i].ops.atomic_mode_set=fake_modeset;physical[i].ops.seamless_mode_set=fake_seamless;
  physical[i].hw_ctl=&blocks[DPU_HW_BLK_CTL][0];
  fixture_encoder.hw_cwb[i]=&blocks[DPU_HW_BLK_CWB][i];fixture_encoder.hw_dsc[i]=&blocks[DPU_HW_BLK_DSC][i];
  commit.old.mixers[i]=(struct mixer){&blocks[DPU_HW_BLK_LM][i],&blocks[DPU_HW_BLK_CTL][0],&blocks[DPU_HW_BLK_DSPP][i]};
 }
 commit.old.num_mixers=2;commit.next=commit.old;
 counts[DPU_HW_BLK_LM]=counts[DPU_HW_BLK_CTL]=counts[DPU_HW_BLK_PINGPONG]=counts[DPU_HW_BLK_DCWB_PINGPONG]=2;
 physical[0].hw_cdm=&blocks[DPU_HW_BLK_CDM][0];
}
static void run(const char *which) {
 if(!which||!strcmp(which,"permission")) {
  reset();for(int i=0;i<2;i++)commit.old.mixers[i].hw_dspp=NULL;
  commit.next=commit.old;commit.next.base.ctm=&fixture_crtc;commit.next.base.color_mgmt_changed=true;
  assert(msm_atomic_check(&dev,&commit)==0);assert(!commit.allow_modeset);
  assert(commit.next.base.mode_changed);
 }
 if(!which||!strcmp(which,"color")) {
  reset();commit.old.base.ctm=commit.next.base.ctm=&fixture_crtc;commit.next.base.color_mgmt_changed=true;
  assert(msm_atomic_check(&dev,&commit)==0);
  assert(commit.next.mixers[0].lm_ctl==physical[0].hw_ctl);assert(!reserves&&!releases);
 }
 if(!which||!strcmp(which,"dspp")) {
  reset();assert(dpu_crtc_assign_resources(&fixture_crtc,&commit.next.base)==0);
  assert(!commit.next.mixers[0].hw_dspp&&!commit.next.mixers[1].hw_dspp);
 }
 for(int type=0;type<3;type++) {
  const char *name=type==0?"cwb":type==1?"cdm":"dsc";
  if(which&&strcmp(which,name))continue;
  for(int count=0;count<3;count++) {
   reset();counts[DPU_HW_BLK_CWB]=counts[DPU_HW_BLK_DSC]=count;
   fixture_encoder.disp_info.intf_type=type==1?INTF_DSI:INTF_WB;commit.next.base.clone=true;
   dpu_encoder_virt_atomic_mode_set(&fixture_encoder.base,&commit.next.base,&connector);
   assert(modesets==2);
   if(type==0)for(int i=0;i<2;i++)assert(fixture_encoder.hw_cwb[i]==(i<count?&blocks[DPU_HW_BLK_CWB][i]:NULL));
   if(type==1)assert(!physical[0].hw_cdm);
   if(type==2)for(int i=0;i<2;i++)assert(fixture_encoder.hw_dsc[i]==(i<count?&blocks[DPU_HW_BLK_DSC][i]:NULL));
  }
 }
 if(which)return;
 for(int color=0;color<4;color++)for(int mixers=0;mixers<3;mixers++)for(int hole=0;hole<2;hole++) {
  reset();commit.old.num_mixers=mixers;if(hole&&mixers)commit.old.mixers[mixers-1].hw_dspp=NULL;
  commit.next=commit.old;commit.next.base.ctm=color&1?&fixture_crtc:NULL;commit.next.base.gamma_lut=color&2?&fixture_crtc:NULL;
  assert(!dpu_crtc_check_mode_changed(&commit.old.base,&commit.next.base));
  assert(commit.next.base.mode_changed==!!(color&&(mixers==0||hole)));
 }
 reset();commit.next.base.mode_changed=true;reserve_error=-ENOSPC;
 assert(msm_atomic_check(&dev,&commit)==-ENOSPC&&!commit.allow_modeset);
 reset();dfps_failed=true;assert(msm_atomic_check(&dev,&commit)==-EIO&&!reserves);
 reset();mst_error=-ERANGE;assert(msm_atomic_check(&dev,&commit)==-ERANGE);
 reset();encoder_modeset=true;assert(!msm_atomic_check(&dev,&commit)&&commit.next.base.mode_changed);
 reset();commit.next.base.clone=true;assert(!msm_atomic_check(&dev,&commit)&&commit.next.base.mode_changed);
 reset();dfps_pending=true;fixture_encoder.disp_info.intf_type=INTF_DP;counts[DPU_HW_BLK_CDM]=1;
 dpu_encoder_virt_atomic_mode_set(&fixture_encoder.base,&commit.next.base,&connector);
 assert(modesets==2&&seamless==2&&physical[0].hw_cdm==&blocks[DPU_HW_BLK_CDM][0]);
 puts("Actual DPU color/resource admission, caller modeset flag, stale CWB/CDM/DSC/DSPP and Uke/MST/error paths passed; no hardware opened");
}
int main(int argc,char **argv) {run(argc==2?argv[1]:NULL);return 0;}
C
compile() {
    local tree=$1 output=$2
    local crtc=$tree/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c
    cat "$work/preamble.c" > "$work/$output.c"
    for function in dpu_crtc_needs_dspp dpu_crtc_has_dspp; do extract "$crtc" "$function" true >> "$work/$output.c"; done
    for function in dpu_crtc_check_mode_changed dpu_crtc_assign_resources dpu_crtc_atomic_check; do extract "$crtc" "$function" >> "$work/$output.c"; done
    extract "$tree/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c" dpu_encoder_virt_atomic_mode_set >> "$work/$output.c"
    extract "$tree/drivers/gpu/drm/msm/msm_atomic.c" msm_atomic_check >> "$work/$output.c"
    cat "$work/cases.c" >> "$work/$output.c"
    "${CC:-clang}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-function -Wno-misleading-indentation \
        -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/$output.c" -o "$work/$output"
}
compile "$candidate" candidate
"$work/candidate"
compile "$baseline" baseline
for defect in permission color dspp cwb cdm dsc; do
    if "$work/baseline" "$defect" > "$work/$defect.log" 2>&1; then
        code=0
    else
        code=$?
    fi
    [[ $code == 134 ]] || { printf 'Unmodified %s control did not reach its assertion (status%s)\n' "$defect" "$code" >&2; cat "$work/$defect.log" >&2; exit 1; }
    printf 'Unmodified %s negative control refused\n' "$defect"
done
