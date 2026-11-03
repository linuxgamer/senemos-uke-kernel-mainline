#!/usr/bin/env bash
# Exercise production link ownership and per-stream failure cleanup without hardware.
set -Eeuo pipefail
ulimit -c 0
ulimit -c 0
kernel=${1:?Pass prepared kernel}
source=$kernel/drivers/gpu/drm/msm/dp/dp_display.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/test.cpp" <<'CPP'
#include <cassert>
#include <cstddef>
#include <cerrno>
#include <cstdio>
#include <initializer_list>
enum { DP_STREAM_0, DP_STREAM_1, DP_STREAM_2 };
struct device { void *of_node; };
struct platform_device { device dev; };
struct msm_dp_bridge_state {};
struct drm_bridge {};
struct drm_atomic_commit {};
struct msm_dp_ctrl {};
struct msm_dp_panel { unsigned stream_id; bool stream_active,hdr_active,dsc_active,dsc_failed; unsigned dsc_fallbacks;int dsc_last_error;struct {struct {unsigned bits_per_pixel;} dsc;} dsc; };
struct LinkInfo {unsigned rate,num_lanes;};
struct msm_dp_link { unsigned sink_count; LinkInfo link_caps,link_params; };
struct msm_dp { bool is_edp,link_ready; unsigned active_stream_cnt; bool mst_active; platform_device *pdev; drm_bridge *bridge;void *drm_dev;unsigned connector_type; };
struct msm_dp_display_private {
 msm_dp msm_dp_display; msm_dp_panel *panel; msm_dp_link *link; msm_dp_ctrl *ctrl;
 bool stream_pm_active,stream_link_attempted,phy_initialized; void *drm_dev;
 bool plugged_lock,link_failed,link_status_notified;int link_status_work;
 int dsc_health_work;
};
#define container_of(p,type,field) reinterpret_cast<type*>(reinterpret_cast<char*>(p)-offsetof(type,field))
#define drm_dbg_dp(...) ((void)0)
#define drm_err(...) ((void)0)
#define DRM_ERROR(...) ((void)0)
#define WARN_ON_ONCE(x) ((x) ? (++warnings,true) : false)
#define WRITE_ONCE(x,v) ((x)=(v))
#define READ_ONCE(x) (x)
#define HZ 100
#define drm_warn(...) ((void)0)
struct Guard { bool *lock;explicit Guard(bool *p):lock(p){assert(!*lock);*lock=true;}~Guard(){assert(*lock);*lock=false;} };
#define scoped_guard(type,p) if (Guard held{p};true)
static int warnings,resume_error,link_error,train_error,stream_error,post_error;
static unsigned gets,puts_count,link_on,link_off,phy_on,phy_off,vscoff,hdroff,notifies;
static bool pixel[3];
static bool managed=true;
static bool downshift;
static int pm_runtime_resume_and_get(device*) { if(resume_error)return resume_error; ++gets;return 0; }
static void pm_runtime_put_sync(device*) { assert(gets>puts_count);++puts_count; }
static void msm_dp_hpd_plug_handle(msm_dp_display_private*) {}
static void msm_dp_hpd_unplug_handle(msm_dp_display_private*) {}
static bool msm_dp_display_host_phy_init(msm_dp_display_private *dp) { if(!dp->phy_initialized)++phy_on;dp->phy_initialized=true;return true; }
static void msm_dp_display_host_phy_exit(msm_dp_display_private *dp) { if(dp->phy_initialized)++phy_off;dp->phy_initialized=false; }
static msm_dp_link *selected_link;
static int msm_dp_ctrl_on_link(msm_dp_ctrl*,msm_dp_panel*) {
 ++link_on;selected_link->link_params=selected_link->link_caps;
 if(downshift)selected_link->link_params.num_lanes/=2;
 return link_error;
}
static int msm_dp_ctrl_prepare_stream_on(msm_dp_ctrl*,msm_dp_panel*,bool) { return train_error; }
static void msm_dp_ctrl_off_link(msm_dp_ctrl*,msm_dp_panel*) { ++link_off; }
static void msm_dp_ctrl_reinit_phy(msm_dp_ctrl*) {}
static void msm_dp_link_psm_config(msm_dp_link*,LinkInfo*,bool) {}
static int msm_dp_ctrl_on_stream(msm_dp_ctrl*,msm_dp_panel *p,const msm_dp_bridge_state *color,bool mst) { assert((color!=nullptr)==(!mst&&managed));pixel[p->stream_id]=true;return stream_error; }
static void msm_dp_ctrl_off_pixel_clk(msm_dp_ctrl*,msm_dp_panel *panel) { pixel[panel->stream_id]=false; }
static void msm_dp_panel_disable_vsc_sdp(msm_dp_panel *p) { assert(pixel[p->stream_id]);++vscoff; }
static void msm_dp_panel_disable_hdr_sdp(msm_dp_panel *p) { assert(pixel[p->stream_id]);++hdroff; }
static bool of_device_is_compatible(void*,const char*) { return managed; }
static int msm_dp_display_post_enable(msm_dp*) { return post_error; }
static void msm_dp_display_audio_notify_disable(msm_dp_display_private*) {}
static msm_dp_bridge_state color;
static msm_dp_bridge_state *drm_atomic_get_new_bridge_state(drm_atomic_commit*,drm_bridge*) {return &color;}
static msm_dp_bridge_state *to_dp_bridge_state(msm_dp_bridge_state *s) {return s;}
static void schedule_work(int*) {++notifies;}
static void schedule_delayed_work(int*,unsigned) {}
static void cancel_delayed_work_sync(int*) {}
void msm_dp_display_unprepare(msm_dp*);
CPP
for name in msm_dp_display_unprepare msm_dp_display_prepare_link msm_dp_display_enable msm_dp_display_disable msm_dp_display_enable_helper msm_dp_display_set_link_failure msm_dp_display_atomic_enable msm_dp_display_atomic_post_disable_helper msm_dp_display_atomic_post_disable; do
    awk -v name="$name" '$0 ~ "^(static )?(int|void) " name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$source" >> "$work/test.cpp"
done
cat >> "$work/test.cpp" <<'CPP'
static void reset() {
 warnings=resume_error=link_error=train_error=stream_error=post_error=0;
 gets=puts_count=link_on=link_off=phy_on=phy_off=vscoff=hdroff=notifies=0;
 for(bool& p:pixel)p=false;
 downshift=false;
}
int main() {
 platform_device pdev{};msm_dp_ctrl ctrl{};msm_dp_panel panels[3]{};
 panels[1].stream_id=1;panels[2].stream_id=2;
 msm_dp_link link{1,{540000,2},{0,0}};msm_dp_display_private dp{};
 auto init=[&] { reset();dp={};dp.msm_dp_display.pdev=&pdev;dp.panel=&panels[0];dp.link=&link;dp.ctrl=&ctrl;
  dp.msm_dp_display.mst_active=true;link.sink_count=1;link.link_caps={540000,2};selected_link=&link;for(auto& p:panels)p.stream_active=false; };
 for(int failure=0;failure<4;failure++) {
  init();
  if(failure==0)resume_error=-EIO;
  if(failure==1)link.sink_count=0;
  if(failure==2)link_error=-EIO;
  if(failure==3)train_error=-EIO;
  assert(msm_dp_display_prepare_link(&dp.msm_dp_display)<0);
  assert(!dp.msm_dp_display.link_ready&&!dp.stream_pm_active&&!dp.stream_link_attempted&&!dp.phy_initialized);
  assert(gets==puts_count&&phy_on==phy_off);msm_dp_display_unprepare(&dp.msm_dp_display);assert(gets==puts_count);
 }
 init();downshift=true;assert(msm_dp_display_prepare_link(&dp.msm_dp_display)==-EAGAIN);
 assert(!dp.msm_dp_display.link_ready&&link.link_caps.num_lanes==1&&gets==puts_count);
 downshift=false;assert(!msm_dp_display_prepare_link(&dp.msm_dp_display));msm_dp_display_unprepare(&dp.msm_dp_display);
 init();dp.msm_dp_display.mst_active=false;dp.link_status_notified=true;downshift=true;
 assert(msm_dp_display_prepare_link(&dp.msm_dp_display)==-EAGAIN);
 assert(link.link_caps.num_lanes==1&&gets==puts_count&&!dp.link_status_notified&&!dp.plugged_lock);
 init();assert(!msm_dp_display_prepare_link(&dp.msm_dp_display));
 assert(!msm_dp_display_prepare_link(&dp.msm_dp_display)&&gets==1&&link_on==1);
 assert(!msm_dp_display_enable_helper(&dp.msm_dp_display,&panels[0]));
 assert(!msm_dp_display_enable_helper(&dp.msm_dp_display,&panels[1]));
 assert(dp.msm_dp_display.active_stream_cnt==2&&pixel[0]&&pixel[1]);
 stream_error=-EIO;assert(msm_dp_display_enable_helper(&dp.msm_dp_display,&panels[2])==-EIO);
 assert(dp.msm_dp_display.active_stream_cnt==2&&!pixel[2]&&!panels[2].stream_active);
 assert(!msm_dp_display_disable(&dp,&panels[2])&&vscoff==0);
 assert(!msm_dp_display_disable(&dp,&panels[0]));msm_dp_display_unprepare(&dp.msm_dp_display);
 assert(dp.msm_dp_display.active_stream_cnt==1&&pixel[1]&&!pixel[0]&&puts_count==0&&link_off==0);
 assert(!msm_dp_display_disable(&dp,&panels[0])&&dp.msm_dp_display.active_stream_cnt==1);
 assert(!msm_dp_display_disable(&dp,&panels[1]));msm_dp_display_unprepare(&dp.msm_dp_display);
 assert(!dp.msm_dp_display.active_stream_cnt&&puts_count==1&&link_off==1&&vscoff==2&&hdroff==2);
 msm_dp_display_unprepare(&dp.msm_dp_display);assert(puts_count==1&&!warnings);
 init();assert(msm_dp_display_enable_helper(&dp.msm_dp_display,&panels[0])==-EIO);
 assert(!gets&&!dp.msm_dp_display.active_stream_cnt);
 assert(!msm_dp_display_prepare_link(&dp.msm_dp_display));post_error=-EIO;
 assert(msm_dp_display_enable_helper(&dp.msm_dp_display,&panels[0])==-EIO);
 assert(!dp.msm_dp_display.active_stream_cnt&&!pixel[0]&&!panels[0].stream_active);
 msm_dp_display_unprepare(&dp.msm_dp_display);assert(gets==puts_count&&!warnings);
 drm_atomic_commit commit;
 for(bool uke:{false,true})for(int failure=0;failure<7;failure++) {
  init();dp.msm_dp_display.mst_active=false;panels[0].hdr_active=true;
  managed=uke;
  if(failure==1)resume_error=-EIO;
  if(failure==2)link.sink_count=0;
  if(failure==3)link_error=-EIO;
  if(failure==4)train_error=-EIO;
  if(failure==5)stream_error=-EIO;
  if(failure==6)post_error=-EIO;
  msm_dp_display_atomic_enable(&dp.msm_dp_display,&commit);
  if(!failure)assert(panels[0].stream_active&&dp.msm_dp_display.active_stream_cnt==1&&gets==1&&!puts_count);
  else {
   assert(!dp.stream_pm_active&&!dp.stream_link_attempted&&!dp.msm_dp_display.link_ready);
   assert(!panels[0].stream_active&&!dp.msm_dp_display.active_stream_cnt&&!panels[0].hdr_active);
   assert(gets==puts_count&&phy_on==phy_off&&link_off==(failure>=3?1U:0U));
   assert(dp.link_failed&&notifies==1&&!dp.plugged_lock);
  }
  msm_dp_display_atomic_post_disable(&dp.msm_dp_display);
  assert(gets==puts_count&&!dp.msm_dp_display.active_stream_cnt&&!dp.stream_pm_active&&!pixel[0]);
  const auto released=puts_count,stopped=link_off;
  msm_dp_display_atomic_post_disable(&dp.msm_dp_display);assert(puts_count==released&&link_off==stopped);
 }
 puts("Production MST link/PM ownership, failed enable, duplicate disable and surviving stream: PASS; host only.");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/test.cpp" -o "$work/test"
"$work/test"
