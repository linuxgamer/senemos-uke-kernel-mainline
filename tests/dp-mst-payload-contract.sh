#!/usr/bin/env bash
# Run the production stream transaction with failed helpers and an existing stream.
set -Eeuo pipefail
ulimit -c 0
source=${1:?Pass prepared dp_mst_drm.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/test.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdio>
enum { DRM_DP_MST_PAYLOAD_ALLOCATION_NONE,DRM_DP_MST_PAYLOAD_ALLOCATION_LOCAL,
 DRM_DP_MST_PAYLOAD_ALLOCATION_DFP,DRM_DP_MST_PAYLOAD_ALLOCATION_REMOTE,DP_CAP_ANSI_8B10B };
struct drm_encoder {};
struct drm_connector { int refs; };
struct drm_dp_mst_port {};
struct drm_dp_mst_atomic_payload { int payload_allocation_status,vc_start_slot,time_slots,pbn; };
struct drm_dp_mst_topology_state { drm_dp_mst_atomic_payload payload; };
struct drm_dp_mst_topology_mgr { unsigned payload_count; };
struct msm_dp { void *drm_dev;unsigned active_stream_cnt;bool link_ready; };
struct msm_dp_panel { drm_connector *connector;unsigned stream_id;bool stream_active; };
struct msm_dp_mst { drm_dp_mst_topology_mgr mst_mgr;struct msm_dp *msm_dp;bool mst_lock; };
struct msm_dp_mst_connector { drm_connector connector;msm_dp_mst *dp_mst;drm_dp_mst_port *mst_port; };
struct drm_atomic_commit { msm_dp_mst_connector *connector;drm_dp_mst_topology_state *topology; };
struct Guard {bool *lock;explicit Guard(bool *p):lock(p){assert(!*lock);*lock=true;}~Guard(){assert(*lock);*lock=false;}};
#define guard(type) const Guard held
#define to_dp_mst_connector(p) reinterpret_cast<msm_dp_mst_connector*>(p)
#define drm_err(...) ((void)0)
#define drm_dbg_kms(...) ((void)0)
static msm_dp_panel panel;
static unsigned stage,pm_gets,pm_puts,removes,restores,slot_updates,retained_streams;
static drm_connector *drm_atomic_get_new_connector_for_encoder(drm_atomic_commit *state,drm_encoder*) {return &state->connector->connector;}
static msm_dp_panel *msm_dp_mst_panel_from_encoder(msm_dp_mst*,drm_encoder*) {return &panel;}
static drm_dp_mst_topology_state *drm_atomic_get_new_mst_topology_state(drm_atomic_commit *state,drm_dp_mst_topology_mgr*) {return state->topology;}
static drm_dp_mst_atomic_payload *drm_atomic_get_mst_payload_state(drm_dp_mst_topology_state *state,drm_dp_mst_port*) {return &state->payload;}
static void drm_connector_get(drm_connector *c) {++c->refs;}
static void drm_connector_put(drm_connector *c) {assert(c->refs>1);--c->refs;}
static int msm_dp_display_set_mode_helper(msm_dp*,drm_atomic_commit*,drm_encoder*,msm_dp_panel*) {return stage==1?-EIO:0;}
static int msm_dp_display_prepare_link(msm_dp *dp) {if(stage==2)return -EIO;if(!dp->link_ready){dp->link_ready=true;++pm_gets;}return 0;}
static void drm_dp_mst_update_slots(drm_dp_mst_topology_state*,int) {}
static int drm_dp_add_payload_part1(drm_dp_mst_topology_mgr *mgr,drm_dp_mst_topology_state*,drm_dp_mst_atomic_payload *p) {
 ++mgr->payload_count;p->payload_allocation_status=DRM_DP_MST_PAYLOAD_ALLOCATION_LOCAL;
 if(stage==3)return -EIO;
 p->payload_allocation_status=DRM_DP_MST_PAYLOAD_ALLOCATION_DFP;return 0;
}
static void msm_dp_display_set_stream_info(msm_dp*,msm_dp_panel*,int,int,int) {++slot_updates;}
static int msm_dp_display_enable_helper(msm_dp *dp,msm_dp_panel *p) {if(stage==4)return -EIO;p->stream_active=true;++dp->active_stream_cnt;return 0;}
static int drm_dp_check_act_status(drm_dp_mst_topology_mgr*) {return stage==5?-ETIMEDOUT:0;}
static int drm_dp_add_payload_part2(drm_dp_mst_topology_mgr*,drm_dp_mst_atomic_payload *p) {
 if(stage==6)return -EIO;
 p->payload_allocation_status=DRM_DP_MST_PAYLOAD_ALLOCATION_REMOTE;return 0;
}
static void drm_dp_remove_payload_part1(drm_dp_mst_topology_mgr*,drm_dp_mst_topology_state*,drm_dp_mst_atomic_payload *p) {assert(p->payload_allocation_status);++removes;}
static void drm_dp_remove_payload_part2(drm_dp_mst_topology_mgr *mgr,drm_dp_mst_topology_state*,drm_dp_mst_atomic_payload*,drm_dp_mst_atomic_payload *p) {
 assert(mgr->payload_count>retained_streams);--mgr->payload_count;p->payload_allocation_status=DRM_DP_MST_PAYLOAD_ALLOCATION_NONE;p->vc_start_slot=-1;
}
static void msm_dp_mst_remove_payload(msm_dp_mst*,drm_dp_mst_topology_state*,msm_dp_panel*) {++restores;}
static void msm_dp_display_atomic_post_disable_helper(msm_dp *dp,msm_dp_panel *p) {if(p->stream_active){p->stream_active=false;assert(dp->active_stream_cnt>retained_streams);--dp->active_stream_cnt;}}
static bool msm_dp_display_is_plugged(msm_dp*) {return true;}
static int msm_dp_display_mst_send_act(msm_dp *dp,msm_dp_panel*) {assert(stage>=3&&dp->active_stream_cnt==retained_streams);return 0;}
static void msm_dp_display_unprepare(msm_dp *dp) {if(!dp->active_stream_cnt&&dp->link_ready){dp->link_ready=false;++pm_puts;}}
static unsigned link_failures;
static void msm_dp_display_set_link_failure(msm_dp*,bool failed) {if(failed)++link_failures;}
CPP
awk '/^int msm_dp_mst_stream_enable\(/ {emit=1} emit{print} emit&&/^}/{exit}' "$source" >> "$work/test.cpp"
cat >> "$work/test.cpp" <<'CPP'
int main() {
 for(retained_streams=0;retained_streams<=1;retained_streams++)for(stage=0;stage<=6;stage++) {
  pm_gets=pm_puts=removes=restores=slot_updates=link_failures=0;
  msm_dp dp{};dp.active_stream_cnt=retained_streams;dp.link_ready=retained_streams!=0;
  msm_dp_mst mst{{retained_streams},&dp,false};drm_dp_mst_port port;
  msm_dp_mst_connector connector{{1},&mst,&port};
  drm_dp_mst_topology_state topology{{0,-1,8,100}};drm_atomic_commit state{&connector,&topology};
  panel={nullptr,1,false};drm_encoder encoder;
  const int result=msm_dp_mst_stream_enable(&encoder,&state);
  if(!stage) {
   assert(!result&&panel.connector==&connector.connector&&panel.stream_active&&connector.connector.refs==2);
   assert(mst.mst_mgr.payload_count==retained_streams+1&&dp.active_stream_cnt==retained_streams+1);
   assert(msm_dp_mst_stream_enable(&encoder,&state)==-EBUSY&&connector.connector.refs==2);
  } else {
   assert(result<0&&!panel.connector&&!panel.stream_active&&connector.connector.refs==1);
   assert(mst.mst_mgr.payload_count==retained_streams&&dp.active_stream_cnt==retained_streams);
   assert(!mst.mst_lock&&dp.link_ready==(retained_streams!=0));
   assert(removes==(stage>=3?1U:0U)&&restores==removes);
   assert(pm_gets==pm_puts);
   assert(link_failures==1);
  }
 }
 puts("Production MST transaction: mode/PM/part1/stream/ACT/part2 failures, reference release and surviving payload: PASS; host only.");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-unused-function \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/test.cpp" -o "$work/test"
"$work/test"
