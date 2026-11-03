#!/usr/bin/env bash
# Execute the actual topology selector across mixer-width and color boundaries.
set -Eeuo pipefail
file=${1:?Pass prepared dpu_crtc.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
struct drm_display_mode { unsigned hdisplay; };
struct drm_encoder { int unused; } encoder;
struct drm_crtc { void *dev; bool clone; } crtc;
struct drm_crtc_state { struct drm_display_mode adjusted_mode; void *state,*ctm,*gamma_lut; unsigned encoder_mask; bool clone; };
struct msm_display_topology { unsigned num_intf,num_dsc,num_lm,num_dspp; bool cwb_enabled; } requested;
struct caps { bool has_3d_merge; unsigned max_mixer_width; } caps={true,2560};
struct catalog { struct caps *caps; } dpu_sm7675_cfg={&caps},foreign={&caps};
struct dpu_kms { struct catalog *catalog; };
#define MAX_HDISPLAY_SPLIT 1080
#define drm_for_each_encoder_mask(e,d,m) for((e)=((void)(d),(void)(m),&encoder);(e);(e)=NULL)
static void dpu_encoder_update_topology(struct drm_encoder *e,struct msm_display_topology *t,void *s,struct drm_display_mode *m) { (void)e;(void)s;(void)m;*t=requested; }
static bool drm_crtc_in_clone_mode(struct drm_crtc_state *c) {return c->clone;}
C
awk '/^static struct msm_display_topology dpu_crtc_get_topology\(/ {emit=1} emit{print} emit&&/^}/{exit}' "$file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 const unsigned widths[]={640,1080,1081,1920,2560,2561,3200,3840};
 for(unsigned own=0;own<2;own++) for(unsigned merge=0;merge<2;merge++)
 for(unsigned clone=0;clone<2;clone++) for(unsigned intf=1;intf<3;intf++)
 for(unsigned dsc=0;dsc<3;dsc++) for(unsigned color=0;color<4;color++)
 for(unsigned w=0;w<sizeof(widths)/sizeof(widths[0]);w++) {
  caps.has_3d_merge=merge;crtc.clone=clone;
  struct dpu_kms kms={own?&dpu_sm7675_cfg:&foreign};
  struct drm_crtc_state state={.adjusted_mode={widths[w]},.clone=clone,.ctm=color&1?&crtc:NULL,.gamma_lut=color&2?&crtc:NULL};
  requested=(struct msm_display_topology){.num_intf=intf,.num_dsc=dsc};
  struct msm_display_topology got=dpu_crtc_get_topology(&crtc,&kms,&state);
  unsigned lm=(intf==2&&!clone)||dsc==2?2:merge&&dsc==0?(widths[w]>(own?2560:1080)?2:1):1;
  assert(got.num_lm==lm && got.num_dspp==(color?lm:0));
  assert(got.num_intf==intf && got.num_dsc==dsc && got.cwb_enabled==clone);
 }
 puts("Actual topology: Uke mixer-width/color boundaries, bonded/DSC/clone and foreign catalog cases passed; no hardware claim");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
