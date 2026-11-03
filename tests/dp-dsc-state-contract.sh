#!/usr/bin/env bash
# Execute production policy, atomic selection, receiver health and recovery functions.
set -Eeuo pipefail
ulimit -c 0
source=${1:?Pass prepared dp_display.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/test.cpp" <<'CPP'
#include <cassert>
#include <cstddef>
#include <cerrno>
#include <cstring>
#include <sys/types.h>
using u8=unsigned char;
using u32=unsigned;
enum { DP_LINK_STATUS_SIZE=6,DP_DSC_ENABLE=0x160,DP_DECOMPRESSION_EN=1,
 DP_FEC_CONFIGURATION=0x120,DP_FEC_READY=1,DP_HW_VERSION_1_0=1,
 HDMI_EOTF_TRADITIONAL_GAMMA_SDR=0,DRM_MODE_COLORIMETRY_DEFAULT=0,
 DRM_MODE_LINK_STATUS_BAD=1,HZ=100,DP_FEC_UNCORR_BLK_ERROR_COUNT_CAP=2,
 DP_FEC_ERR_COUNT_SEL_MASK=14,DP_FEC_UNCORR_BLK_ERROR_COUNT=2,
 DP_FEC_ERROR_COUNT_LSB=0x281,DP_FEC_ERR_COUNT_VALID=128,DP_FEC_ERROR_COUNT_MASK=127 };
struct drm_dsc_config {unsigned bits_per_pixel;};
struct msm_dp_dsc_config {drm_dsc_config dsc;unsigned dto_count,compression_ctrl;};
struct drm_bridge_state {};
struct msm_dp;
struct drm_bridge {msm_dp *msm_dp_display=nullptr;};
#define to_dp_bridge(p) (p)
struct packet {u8 db[32];};
struct msm_dp_bridge_state {drm_bridge_state base;msm_dp_dsc_config dsc;packet hdr_sdp,vsc_sdp;bool hdr_enabled,vsc_enabled;int bpp;unsigned colorspace;};
struct drm_connector_state;
struct drm_atomic_commit {drm_bridge_state *bridge;drm_bridge_state *old_bridge=nullptr;drm_connector_state *old_conn=nullptr;};
struct drm_display_mode {unsigned clock;};
struct drm_crtc_state {drm_atomic_commit *state;drm_display_mode adjusted_mode;bool mode_changed;};
struct drm_display_info {unsigned bpc,max_tmds_clock;bool is_hdmi;};
struct drm_connector {drm_display_info display_info;};
struct drm_connector_state {drm_connector *connector;unsigned max_requested_bpc,colorspace;void *hdr_output_metadata;drm_atomic_commit *state=nullptr;void *crtc=nullptr;};
struct device {void *data,*of_node;};
struct drm_device {bool registered;unsigned refs;};
struct device_attribute {};
struct platform_device {device dev;};
struct msm_dp {bool is_edp;unsigned active_stream_cnt;bool mst_active;platform_device *pdev;drm_bridge *bridge;drm_connector *connector;};
struct msm_dp_panel {bool dsc_requested,dsc_force,dsc_failed,dsc_active,dsc_counter_valid;unsigned dsc_fallbacks,hw_revision,dsc_uncorrected;int dsc_last_error;msm_dp_dsc_config dsc;u8 dsc_dpcd[16],fec_cap;};
struct work_struct {};
struct delayed_work {work_struct work;};
struct link_info {unsigned rate,num_lanes;};
struct msm_dp_link {link_info link_caps,link_params;bool vsc_sdp_supported;};
struct msm_dp_display_private {
 msm_dp msm_dp_display;msm_dp_panel *panel;msm_dp_link *link;void *aux;drm_device *drm_dev;
 bool plugged_lock,plugged,stream_pm_active,stream_link_attempted;
 bool link_failed,link_status_notified,dsc_policy_changed,wide_bus_supported,dsc_control_bound;
 work_struct link_status_work;delayed_work dsc_health_work;
};
#define container_of(p,type,field) reinterpret_cast<type*>(reinterpret_cast<char*>(p)-offsetof(type,field))
#define to_delayed_work(p) container_of(p,delayed_work,work)
#define to_dp_bridge_state(p) container_of(p,msm_dp_bridge_state,base)
#define READ_ONCE(v) (v)
#define drm_warn(...) ((void)0)
#define round_down(x,y) ((x)/(y)*(y))
#define min3(x,y,z) ((x)<(y)?((x)<(z)?(x):(z)):((y)<(z)?(y):(z)))
struct Guard {bool *lock;explicit Guard(bool *p):lock(p){assert(!*p);*p=true;}~Guard(){assert(*lock);*lock=false;}};
#define guard(type) Guard held
#define scoped_guard(type,p) if (Guard held{p};true)
static bool modeset_locked,compatible=true;
static unsigned queued,polled,notified,bad_status,aux_reads;
static int uncompressed=30,prepare_error,aux_error,aux_fail_at;
static bool eq_ok=true,decoder_on=true,fec_ready=true;
static unsigned fec_selector,counter;static bool counter_valid;
static bool unbind_during_lock;static msm_dp_display_private *selected_dp;
static void drm_dev_get(drm_device *drm) {assert(drm&&drm->registered);drm->refs++;}
static void drm_dev_put(drm_device *drm) {assert(drm&&drm->refs==1);drm->refs--;}
static void drm_modeset_lock_all(drm_device *drm) {assert(drm&&drm->refs==1&&!modeset_locked);modeset_locked=true;if(unbind_during_lock)selected_dp->dsc_control_bound=false;}
static void drm_modeset_unlock_all(drm_device*) {assert(modeset_locked);modeset_locked=false;}
static void schedule_work(work_struct*) {assert(!modeset_locked);queued++;}
static void schedule_delayed_work(delayed_work*,unsigned delay) {assert(delay==HZ);polled++;}
static msm_dp_display_private *dev_get_dp_display_private(device *dev) {return static_cast<msm_dp_display_private*>(dev->data);}
static bool sysfs_streq(const char *a,const char *b) {return !strncmp(a,b,strlen(b))&&(a[strlen(b)]=='\0'||a[strlen(b)]=='\n');}
static int kstrtobool(const char *text,bool *value) {if(!strcmp(text,"1\n")){*value=true;return 0;}if(!strcmp(text,"0\n")){*value=false;return 0;}return -EINVAL;}
static bool of_device_is_compatible(void*,const char*) {return compatible;}
static drm_bridge_state *drm_atomic_get_new_bridge_state(drm_atomic_commit *state,drm_bridge*) {return state->bridge;}
[[maybe_unused]] static drm_bridge_state *drm_atomic_get_old_bridge_state(drm_atomic_commit *state,drm_bridge*) {return state->old_bridge;}
static drm_connector_state *drm_atomic_get_old_connector_state(drm_atomic_commit *state,drm_connector*) {return state->old_conn;}
static bool drm_connector_atomic_hdr_metadata_equal(drm_connector_state *a,drm_connector_state *b) {return a->hdr_output_metadata==b->hdr_output_metadata;}
static void drm_connector_set_link_status_property(drm_connector*,unsigned status) {assert(status==DRM_MODE_LINK_STATUS_BAD);bad_status++;}
static void drm_kms_helper_connector_hotplug_event(drm_connector*) {notified++;}
static void msm_dp_mst_report_link_failure(msm_dp*,bool notify) {assert(notify);}
static bool drm_mode_is_420_only(const drm_display_info*,const drm_display_mode*) {return false;}
static int msm_dp_utils_pack_hdr_sdp(drm_connector_state*,packet*) {return 0;}
static int msm_dp_utils_select_bpp(unsigned,unsigned,unsigned,unsigned,unsigned,bool,bool,unsigned) {return uncompressed;}
static bool msm_dp_utils_tmds_fits(unsigned clock,unsigned bpp,unsigned limit,bool) {return clock*bpp<=limit*24;}
static int msm_dp_dsc_prepare(const u8*,u8,const drm_display_mode*,unsigned,unsigned,unsigned,msm_dp_dsc_config *out) {if(!prepare_error)out->dsc.bits_per_pixel=128;return prepare_error;}
static int msm_dp_utils_pack_vsc_sdp(packet*,unsigned,unsigned,bool) {return 0;}
static int aux_result() {aux_reads++;return aux_fail_at==int(aux_reads)?aux_error:0;}
static int drm_dp_dpcd_read_link_status(void*,u8*) {return aux_result();}
static bool drm_dp_channel_eq_ok(const u8*,unsigned lanes) {assert(lanes==2);return eq_ok;}
static int drm_dp_dpcd_read_byte(void*,unsigned reg,u8 *out) {const int ret=aux_result();if(ret)return ret;assert(reg==DP_DSC_ENABLE||reg==DP_FEC_CONFIGURATION);*out=reg==DP_DSC_ENABLE?decoder_on:(fec_ready|fec_selector);return 0;}
static int drm_dp_dpcd_read_data(void*,unsigned reg,u8 *out,size_t len) {assert(reg==DP_FEC_ERROR_COUNT_LSB&&len==2);const int ret=aux_result();if(ret)return ret;out[0]=counter&255;out[1]=(counter>>8)|(counter_valid?128:0);return 0;}
CPP
for name in uke_dp_dsc_store msm_dp_get_dsc_config msm_dp_display_set_link_failure msm_dp_display_link_status_work msm_dp_display_dsc_health msm_dp_display_dsc_health_work msm_dp_display_atomic_check; do
 awk -v name="$name" '$0 ~ "^(static )?(ssize_t|int|void|struct drm_dsc_config \\*) ?" name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$source" >> "$work/test.cpp"
done
for name in msm_dp_color_managed msm_dp_bridge_atomic_check; do
 awk -v name="$name" '$0 ~ "^static (bool|int) " name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$(dirname -- "$source")/dp_drm.c" >> "$work/test.cpp"
done
cat >> "$work/test.cpp" <<'CPP'
int main() {
 platform_device pdev{};drm_bridge bridge;msm_dp_panel panel{};msm_dp_link link{{540000,2},{540000,2},true};
 drm_connector connector{{10,320000,true}};
 msm_dp_display_private dp{};dp.panel=&panel;dp.link=&link;dp.wide_bus_supported=true;
 drm_device drm{true,0};dp.drm_dev=&drm;dp.dsc_control_bound=true;selected_dp=&dp;
 dp.msm_dp_display.pdev=&pdev;dp.msm_dp_display.bridge=&bridge;dp.msm_dp_display.connector=&connector;
 device dev{&dp,nullptr};
 dp.drm_dev=nullptr;assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==-ENODEV&&!modeset_locked&&!drm.refs);dp.drm_dev=&drm;
 drm.registered=false;assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==-ENODEV&&!drm.refs);drm.registered=true;
 dp.dsc_control_bound=false;assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==-ENODEV);dp.dsc_control_bound=true;
 unbind_during_lock=true;assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==-ENODEV&&!drm.refs&&!panel.dsc_requested);
 unbind_during_lock=false;dp.dsc_control_bound=true;
 assert(uke_dp_dsc_store(&dev,nullptr,"bad",3)==-EINVAL&&!panel.dsc_requested&&!modeset_locked);
 for(unsigned attached=0;attached<2;attached++) {
  dp.plugged=attached;dp.msm_dp_display.active_stream_cnt=attached;dp.stream_pm_active=attached;dp.stream_link_attempted=attached;
  const auto before=queued;
  assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==2&&panel.dsc_requested&&panel.dsc_force&&!dp.plugged_lock&&!modeset_locked);
  assert(queued==before+attached);
  assert(!drm.refs);
 }
 dp.msm_dp_display.mst_active=true;
 assert(uke_dp_dsc_store(&dev,nullptr,"0\n",2)==-EBUSY&&panel.dsc_requested&&!modeset_locked);
 dp.msm_dp_display.mst_active=false;
 assert(uke_dp_dsc_store(&dev,nullptr,"auto\n",5)==5&&panel.dsc_requested&&!panel.dsc_force);
 assert(!msm_dp_get_dsc_config(&dp.msm_dp_display,nullptr));
 panel.dsc.dsc.bits_per_pixel=128;
 assert(msm_dp_get_dsc_config(&dp.msm_dp_display,nullptr)==&panel.dsc.dsc);
 msm_dp_bridge_state next{};drm_atomic_commit commit{&next.base};
 assert(!msm_dp_get_dsc_config(&dp.msm_dp_display,&commit));
 next.dsc.dsc.bits_per_pixel=128;
 assert(msm_dp_get_dsc_config(&dp.msm_dp_display,&commit)==&next.dsc.dsc);
 compatible=false;assert(!msm_dp_get_dsc_config(&dp.msm_dp_display,nullptr));compatible=true;
 drm_connector_state conn{&connector,10,0,nullptr};drm_display_mode mode{241500};msm_dp_bridge_state state{};
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&state.bpp==30&&!state.dsc.dsc.bits_per_pixel);
 mode.clock=299890;uncompressed=24;
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&state.bpp==24&&!state.dsc.dsc.bits_per_pixel);
 connector.display_info.max_tmds_clock=600000;mode.clock=594000;uncompressed=-ENOSPC;
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&state.bpp==24&&state.dsc.dsc.bits_per_pixel==128);
 prepare_error=-EOPNOTSUPP;mode.clock=200000;uncompressed=24;
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&state.bpp==24&&!state.dsc.dsc.bits_per_pixel);
 assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==2);
 assert(msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)==-EOPNOTSUPP);
 prepare_error=0;
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&state.dsc.dsc.bits_per_pixel==128);
 panel.dsc.dsc.bits_per_pixel=128;dp.dsc_policy_changed=false;dp.link_status_notified=false;
 panel.dsc_last_error=-EAGAIN;msm_dp_display_set_link_failure(&dp.msm_dp_display,true);
 assert(!panel.dsc_failed&&!panel.dsc_fallbacks);panel.dsc_last_error=0;
 msm_dp_display_set_link_failure(&dp.msm_dp_display,true);
 assert(panel.dsc_failed&&panel.dsc_fallbacks==1);
 msm_dp_display_link_status_work(&dp.link_status_work);const auto notices=notified;
 msm_dp_display_set_link_failure(&dp.msm_dp_display,true);msm_dp_display_link_status_work(&dp.link_status_work);
 assert(panel.dsc_fallbacks==1&&notified==notices&&bad_status>=2);
 assert(!msm_dp_display_atomic_check(&dp.msm_dp_display,&mode,&conn,&state)&&!state.dsc.dsc.bits_per_pixel);
 msm_dp_display_set_link_failure(&dp.msm_dp_display,false);assert(panel.dsc_failed);
 assert(uke_dp_dsc_store(&dev,nullptr,"1\n",2)==2&&!panel.dsc_failed);
 msm_dp_display_link_status_work(&dp.link_status_work);assert(notified==notices+1);
 aux_reads=0;msm_dp_display_dsc_health_work(&dp.dsc_health_work.work);assert(!aux_reads);
 panel.dsc_active=true;aux_reads=0;
 dp.dsc_control_bound=false;msm_dp_display_dsc_health_work(&dp.dsc_health_work.work);assert(!aux_reads);dp.dsc_control_bound=true;
 msm_dp_display_dsc_health_work(&dp.dsc_health_work.work);assert(aux_reads==3&&polled==1);
 for(unsigned fail=1;fail<=3;fail++) {aux_reads=0;aux_fail_at=fail;aux_error=-ETIMEDOUT;assert(msm_dp_display_dsc_health(&dp)==-ETIMEDOUT);}
 aux_fail_at=0;eq_ok=false;assert(msm_dp_display_dsc_health(&dp)==-ENOLINK);eq_ok=true;
 decoder_on=false;assert(msm_dp_display_dsc_health(&dp)==-EIO);decoder_on=true;
 panel.fec_cap=DP_FEC_UNCORR_BLK_ERROR_COUNT_CAP;fec_selector=DP_FEC_UNCORR_BLK_ERROR_COUNT;
 assert(!msm_dp_display_dsc_health(&dp)&&!panel.dsc_counter_valid);
 counter_valid=true;assert(!msm_dp_display_dsc_health(&dp)&&panel.dsc_counter_valid&&!panel.dsc_uncorrected);
 counter=257;assert(msm_dp_display_dsc_health(&dp)==-EILSEQ&&panel.dsc_uncorrected==257);
 aux_reads=0;aux_fail_at=4;assert(msm_dp_display_dsc_health(&dp)==-ETIMEDOUT);aux_fail_at=0;
 counter=0;fec_selector=0;assert(!msm_dp_display_dsc_health(&dp)&&!panel.dsc_counter_valid);
 fec_ready=false;msm_dp_display_dsc_health_work(&dp.dsc_health_work.work);
 assert(panel.dsc_failed&&panel.dsc_last_error==-EIO&&panel.dsc_fallbacks==2&&polled==1);
 aux_reads=0;msm_dp_display_dsc_health_work(&dp.dsc_health_work.work);assert(!aux_reads);
 assert(uke_dp_dsc_store(&dev,nullptr,"0\n",2)==2&&!panel.dsc_requested);
 bridge.msm_dp_display=&dp.msm_dp_display;
 msm_dp_bridge_state old_stream{},new_stream{};
 auto old_conn=conn;
 drm_atomic_commit transition{&new_stream.base,&old_stream.base,&old_conn};
 drm_crtc_state crtc{&transition,{200000},false};
 conn.state=&transition;conn.crtc=&crtc;uncompressed=30;
 old_stream.bpp=30;panel.dsc_requested=true;panel.dsc_force=true;panel.dsc_failed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&crtc.mode_changed);
 old_stream=new_stream;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&!crtc.mode_changed);
 old_stream.dsc.dto_count=1;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&crtc.mode_changed);
 old_stream=new_stream;panel.dsc_requested=false;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&crtc.mode_changed);
 old_stream=new_stream;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&!crtc.mode_changed);
 uncompressed=24;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&crtc.mode_changed);
 old_stream=new_stream;crtc.mode_changed=false;
 assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn)&&!crtc.mode_changed);
 conn.crtc=nullptr;assert(!msm_dp_bridge_atomic_check(&bridge,&new_stream.base,&crtc,&conn));
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
 -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/test.cpp" -o "$work/test"
"$work/test"
grep -Fx 'static DEVICE_ATTR_RW(uke_dp_dsc);' "$source" >/dev/null
grep -F 'cancel_delayed_work_sync(&msm_dp_display->dsc_health_work);' "$source" >/dev/null
printf '%s\n' 'Production attached DSC policy, automatic selection, per-commit PPS, receiver health faults and bounded recovery: PASS; host only'
