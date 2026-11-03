#!/usr/bin/env bash
# Execute actual admission and metadata functions without hardware access.
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
static inline u64 div64_u64(u64 a,u64 b) {return a/b;}
C
cat > "$work/drm/drm_modes.h" <<'C'
#include <stdbool.h>
struct drm_display_mode {
 int clock,hdisplay,hsync_start,hsync_end,htotal,hskew;
 int vdisplay,vsync_start,vsync_end,vtotal,vscan;
 unsigned flags;
 struct drm_display_mode *next;
};
C
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stddef.h>
#include "o82-avr.h"
#define INTF_DSI 1
struct drm_encoder;
struct kms_funcs {unsigned (*get_vrr_min_hz)(struct drm_encoder *,const struct drm_display_mode *);};
struct dpu_kms {int *catalog;struct kms_funcs *funcs;};
struct msm_drm_private {struct dpu_kms *kms;};
struct drm_device {struct msm_drm_private *dev_private;};
struct drm_encoder {struct drm_device *dev;};
struct dpu_encoder_virt {struct drm_encoder base;struct {unsigned intf_type,num_of_h_tiles,h_tile_instance[2];bool is_cmd_mode;} disp_info;};
struct drm_crtc_state {struct drm_display_mode adjusted_mode;};
static int dpu_sm7675_cfg,foreign_catalog;
static unsigned o82_vrr_test_min_hz;
static bool hosts_admit=true;
#define to_dpu_encoder_virt(e) ((struct dpu_encoder_virt *)(e))
#define to_dpu_kms(k) (k)
static bool msm_dsi_manager_uke_avr_check(struct drm_encoder *e,const struct drm_display_mode *m) {(void)e;(void)m;return hosts_admit;}
C
extract() {
 awk -v signature="$2" 'index($0,signature)==1 {emit=1;found=1} emit {print} emit&&/^}/ {exit} END {if(!found)exit 1}' "$1" >> "$work/check.c"
}
encoder=$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
extract "$encoder" 'unsigned int dpu_encoder_uke_vrr_min_hz('
extract "$encoder" 'bool dpu_encoder_uke_vrr_check('
cat >> "$work/check.c" <<'C'
struct drm_connector {
 struct drm_device *dev;bool vrr_capable_property,capable;
 struct {struct {unsigned min_vfreq,max_vfreq;} monitor_range;} display_info;
 struct drm_display_mode *probed_modes;
 struct drm_encoder *encoder;
};
struct mipi_dsi_device {void *host;};
struct msm_dsi {void *host;};
#define DSI_CLOCK_MASTER 0
static struct msm_dsi master;
static bool master_present=true;
static struct msm_dsi *dsi_mgr_get_dsi(int id) {assert(!id);return master_present?&master:NULL;}
static void drm_connector_set_vrr_capable_property(struct drm_connector *c,bool v) {assert(c->vrr_capable_property);c->capable=v;}
#define drm_connector_for_each_possible_encoder(c,e) for(e=(c)->encoder;e;e=NULL)
#define list_for_each_entry(m,list,member) for(m=*(list);m;m=m->next)
#define max_t(t,a,b) ((t)(a)>(t)(b)?(t)(a):(t)(b))
static int drm_mode_vrefresh(const struct drm_display_mode *m) {u64 d=(u64)m->htotal*m->vtotal;return ((u64)m->clock*1000+d/2)/d;}
C
extract "$kernel/drivers/gpu/drm/msm/dsi/dsi_manager.c" 'void qcom_uke_dsi_update_vrr('
cat >> "$work/check.c" <<'C'
int main(void) {
 struct kms_funcs funcs={dpu_encoder_uke_vrr_min_hz};
 struct dpu_kms kms={&dpu_sm7675_cfg,&funcs};
 struct msm_drm_private priv={&kms};struct drm_device dev={&priv};
 struct dpu_encoder_virt enc={.base={&dev},.disp_info={INTF_DSI,2,{0,1},false}};
 struct drm_display_mode modes[7]={
  {967428,3200,3426,3458,3490,0,2136,2162,2164,2310,0,0,NULL},
  {1097712,3200,3236,3268,3300,0,2136,2162,2164,2310,0,0,NULL},
  {804988,3200,3808,3840,3872,0,2136,2162,2164,2310,0,0,NULL},
  {967428,3200,3426,3458,3490,0,2136,4472,4474,4620,0,0,NULL},
  {804988,3200,3808,3840,3872,0,2136,4010,4012,4158,0,0,NULL},
  {804988,3200,3808,3840,3872,0,2136,4183,4185,4331,0,0,NULL},
  {804988,3200,3808,3840,3872,0,2136,6782,6784,6930,0,0,NULL}};
 for(unsigned i=0;i<6;++i)modes[i].next=&modes[i+1];
 struct drm_connector c={.dev=&dev,.vrr_capable_property=true,.probed_modes=modes,.encoder=&enc.base};
 struct mipi_dsi_device dsi={&master};master.host=dsi.host;
 struct drm_crtc_state state={.adjusted_mode=modes[0]};
#define UPDATE() qcom_uke_dsi_update_vrr(&dsi,&c)
#define OFF() do {UPDATE();assert(!c.capable&&!c.display_info.monitor_range.min_vfreq&&!c.display_info.monitor_range.max_vfreq);}while(0)
 OFF();o82_vrr_test_min_hz=30;UPDATE();
 assert(c.capable&&c.display_info.monitor_range.min_vfreq==30&&c.display_info.monitor_range.max_vfreq==144);
 assert(dpu_encoder_uke_vrr_check(&enc.base,&state));
 o82_vrr_test_min_hz=29;OFF();
 o82_vrr_test_min_hz=90;UPDATE();
 assert(c.capable&&c.display_info.monitor_range.min_vfreq==90&&c.display_info.monitor_range.max_vfreq==144);
 assert(dpu_encoder_uke_vrr_check(&enc.base,&state));
 state.adjusted_mode=modes[3];assert(!dpu_encoder_uke_vrr_check(&enc.base,&state));
 state.adjusted_mode=modes[1];assert(dpu_encoder_uke_vrr_check(&enc.base,&state));
 state.adjusted_mode=modes[0];
 o82_vrr_test_min_hz=119;UPDATE();assert(c.capable&&c.display_info.monitor_range.min_vfreq==119);
 o82_vrr_test_min_hz=144;OFF();o82_vrr_test_min_hz=145;OFF();o82_vrr_test_min_hz=30;
 hosts_admit=false;OFF();hosts_admit=true;
 kms.catalog=&foreign_catalog;OFF();kms.catalog=&dpu_sm7675_cfg;
 enc.disp_info.is_cmd_mode=true;OFF();enc.disp_info.is_cmd_mode=false;
 enc.disp_info.num_of_h_tiles=1;OFF();enc.disp_info.num_of_h_tiles=2;
 enc.disp_info.h_tile_instance[1]=0;OFF();enc.disp_info.h_tile_instance[1]=1;
 modes[5].clock++;UPDATE();assert(c.capable);
 state.adjusted_mode=modes[5];assert(!dpu_encoder_uke_vrr_check(&enc.base,&state));
 state.adjusted_mode=modes[0];modes[5].clock--;
 struct drm_display_mode foreign=modes[0];foreign.clock++;foreign.next=NULL;
 c.probed_modes=&foreign;OFF();c.probed_modes=modes;
 c.probed_modes=NULL;OFF();c.probed_modes=modes;
 c.encoder=NULL;OFF();c.encoder=&enc.base;
 funcs.get_vrr_min_hz=NULL;OFF();funcs.get_vrr_min_hz=dpu_encoder_uke_vrr_min_hz;
 master_present=false;OFF();master_present=true;dsi.host=NULL;OFF();dsi.host=master.host;
 c.probed_modes=&modes[6];OFF();c.probed_modes=modes;
 c.vrr_capable_property=false;UPDATE();assert(!c.capable);
 return 0;
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I "$work" "$work/check.c" -o "$work/check"
"$work/check"
printf '%s\n' 'Actual O82 VRR admission and connector metadata: positive and refusal cases passed'
