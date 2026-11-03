#!/usr/bin/env bash
set -Eeuo pipefail
file=${1:?Pass prepared dpu_kms.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#define BIT(n) (1U << (n))
enum { DRM_MODE_ENCODER_DSI=6, DRM_MODE_ENCODER_TMDS=2, DRM_MODE_ENCODER_VIRTUAL=5 };
struct drm_encoder { unsigned encoder_type,possible_crtcs,possible_clones; };
struct drm_device { struct { unsigned num_crtc; } mode_config; struct drm_encoder encoders[5]; unsigned count; };
struct dpu_mdss_cfg { unsigned cwb_count; } dpu_sm7675_cfg,foreign;
#define drm_for_each_encoder(e,d) for(unsigned idx=0;idx<(d)->count && ((e)=&(d)->encoders[idx],true);idx++)
static unsigned dpu_encoder_get_clones(struct drm_encoder *e) {(void)e;return 0x5a;}
static void apply(struct drm_device *dev,const struct dpu_mdss_cfg *catalog) {
 struct drm_encoder *encoder;
 unsigned num_encoders=0,num_dsi=0,num_tmds=0;
 (void)num_dsi;(void)num_tmds;
C
awk '/^\tnum_encoders = 0;/{emit=1} emit&&/^\tmax_crtc_count =/{exit} emit{print}' "$file" >> "$work/check.c"
awk '/\/\* (All CRTCs are compatible|Keep the Uke SST pipelines)/{emit=1} emit&&/^\treturn 0;/{exit} emit{print}' "$file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 (void)num_encoders;
}
int main(void) {
 for(unsigned own=0;own<2;own++) for(unsigned crtcs=1;crtcs<4;crtcs++)
 for(unsigned dsi=0;dsi<3;dsi++) for(unsigned dp=0;dp<3;dp++) for(unsigned wb=0;wb<2;wb++) {
  if(dsi+dp+wb>5)continue;
  struct drm_device dev={.mode_config={.num_crtc=crtcs}};
  for(unsigned i=0;i<dsi+dp+wb;i++)dev.encoders[dev.count++].encoder_type=i<dsi?DRM_MODE_ENCODER_DSI:i<dsi+dp?DRM_MODE_ENCODER_TMDS:DRM_MODE_ENCODER_VIRTUAL;
  apply(&dev,own?&dpu_sm7675_cfg:&foreign);
  unsigned all=(1U<<crtcs)-1;
  for(unsigned i=0;i<dev.count;i++) {
   unsigned expected=all;
   if(own&&dsi==1&&dp==1&&crtcs>=2) {
    if(dev.encoders[i].encoder_type==DRM_MODE_ENCODER_DSI)expected=BIT(0);
    if(dev.encoders[i].encoder_type==DRM_MODE_ENCODER_TMDS)expected=all&~BIT(0);
   }
   assert(dev.encoders[i].possible_crtcs==expected && expected);
  }
 }
 puts("Actual encoder masks: independent Uke SST outputs, foreign/headless/multiple-output/writeback fallbacks passed; tablet test pending");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
cat > "$work/streams.c" <<'C'
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
typedef unsigned u32;
enum { INTF_0, INTF_1, INTF_2, INTF_3, INTF_DP, INTF_DSI, INTF_WB };
enum { MSM_DP_CONTROLLER_0, MSM_DSI_CONTROLLER_0=0, MSM_DSI_CONTROLLER_1=1 };
#define DPU_IRQ_IDX(a,b) (b)
struct dpu_intf_cfg {const char *name;unsigned id,base,len,type,controller_id,prog_fetch_lines_worst_case,intr_underrun,intr_vsync,intr_tear_rd_ptr;};
C
awk '/^static const struct dpu_intf_cfg sm7675_intf\[\] =/{emit=1} emit{print} emit&&/^};/{exit}' \
    "$(dirname -- "$file")/catalog/dpu_10_1_sm7675.h" >> "$work/streams.c"
cat >> "$work/streams.c" <<'C'
struct dpu_hw_intf {unsigned id;} hw[4];
struct dpu_rm {int unused;};
struct dpu_mdss_cfg {const struct dpu_intf_cfg *intf;int intf_count;};
struct msm_display_info {unsigned h_tile_instance[2],intf_type;int stream_id;};
static struct dpu_hw_intf *dpu_rm_get_intf(struct dpu_rm *rm,unsigned id) {(void)rm;assert(id<4);return &hw[id];}
C
awk '/^static struct dpu_hw_intf \*dpu_encoder_get_intf\(/{emit=1} emit{print} emit&&/^}/{exit}' \
    "$(dirname -- "$file")/dpu_encoder.c" >> "$work/streams.c"
cat >> "$work/streams.c" <<'C'
int main(void) {
 struct dpu_rm rm={0};struct dpu_mdss_cfg catalog={sm7675_intf,4};
 struct msm_display_info info={.intf_type=INTF_DP};
 assert(dpu_encoder_get_intf(&catalog,&rm,&info,0)==&hw[INTF_0]);
 info.stream_id=1;assert(dpu_encoder_get_intf(&catalog,&rm,&info,0)==&hw[INTF_3]);
 assert(sm7675_intf[3].base==0x37000 && sm7675_intf[3].len==0x300);
 assert(sm7675_intf[3].intr_underrun==30 && sm7675_intf[3].intr_vsync==31);
 info.stream_id=2;assert(!dpu_encoder_get_intf(&catalog,&rm,&info,0));
 info.stream_id=0;info.h_tile_instance[0]=1;assert(!dpu_encoder_get_intf(&catalog,&rm,&info,0));
 info.intf_type=INTF_DSI;assert(dpu_encoder_get_intf(&catalog,&rm,&info,0)==&hw[INTF_2]);
 info.h_tile_instance[0]=0;assert(dpu_encoder_get_intf(&catalog,&rm,&info,0)==&hw[INTF_1]);
 info.intf_type=INTF_WB;assert(!dpu_encoder_get_intf(&catalog,&rm,&info,0));
 puts("Actual Uke stream mapping: DP0 INTF0/3, DSI0/1 and unsupported-stream rejection passed; host only");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/streams.c" -o "$work/streams"
"$work/streams"
