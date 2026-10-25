#!/usr/bin/env bash
# Execute the actual bridge mode validator before any target clock or power use.
set -Eeuo pipefail
manager=${1:?Pass prepared dsi_manager.c}
header=${2:?Pass src/display/o82-mode.h}
modes=${3:?Pass generated o82-data.h}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work/linux" "$work/drm"
cp "$header" "$work/o82-mode.h"
printf '#define EINVAL 22\n#define EIO 5\n#define ERANGE 34\n' > "$work/linux/errno.h"
cat > "$work/drm/drm_modes.h" <<'CPP'
struct drm_display_mode {
    int clock,hdisplay,hsync_start,hsync_end,htotal,vdisplay,vsync_start,vsync_end,vtotal;
    unsigned int width_mm,height_mm,flags=0,hskew=0;
    int vscan=0;
};
CPP
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstring>
#include <cstdint>
#include <cerrno>
#include "o82-mode.h"
enum drm_mode_status {MODE_OK,MODE_BAD,MODE_CLOCK_RANGE,MODE_ERROR,MODE_H_ILLEGAL};
struct drm_display_info {};
struct drm_bridge {int id=0;};
struct device_node {bool pb=true,tm=false,refresh=true,trial=false;};
struct device {device_node *of_node;};
struct platform_device {device dev;};
struct mipi_dsi_host {};
struct msm_dsi {mipi_dsi_host *host;platform_device *pdev;};
struct dev_pm_opp {};
struct o82_timing {unsigned int group;drm_display_mode mode;};
static bool uke=true,sm7675=true,bonded=true;
static device_node parent_node,panel_node,*remote=&panel_node;
static platform_device pdev{{&parent_node}};
static mipi_dsi_host hosts[2];
static msm_dsi devices[2]{{&hosts[0],&pdev},{&hosts[1],&pdev}};
static unsigned int node_gets=0,node_puts=0,clock_calls=0,opp_calls=0,opp_puts=0,dsc_calls=0;
static long opp_error=0;
static unsigned int opp_count=1;
static dev_pm_opp opp;
static drm_mode_status dsc_result=MODE_OK;
static int dsi_mgr_bridge_get_id(drm_bridge *bridge) {return bridge->id;}
static msm_dsi *dsi_mgr_get_dsi(int id) {assert(id==0||id==1);return &devices[id];}
static device_node *of_graph_get_remote_node(device_node *node,int port,int endpoint) {
    assert(node==&parent_node&&port==1&&endpoint==-1);++node_gets;return remote;
}
static void of_node_put(device_node *node) {assert(node==remote);++node_puts;}
static bool of_machine_is_compatible(const char *name) {
    if(!std::strcmp(name,"xiaomi,uke"))return uke;
    assert(!std::strcmp(name,"qcom,sm7675"));return sm7675;
}
static bool of_device_is_compatible(device_node *node,const char *name) {
    if(!std::strcmp(name,"xiaomi,o82-42-02-0b"))return node&&node->pb&&!node->tm;
    assert(!std::strcmp(name,"xiaomi,o82-36-02-0a"));return node&&node->pb&&node->tm;
}
static bool of_property_read_bool(device_node *node,const char *name) {
    if(!std::strcmp(name,"xiaomi,oem-refresh-modes"))return node&&node->refresh;
    assert(!std::strcmp(name,"xiaomi,o82-36-60-120-trial"));return node&&node->trial;
}
static unsigned int drm_mode_vrefresh(const drm_display_mode *mode) {
    const uint64_t total=static_cast<uint64_t>(mode->htotal)*mode->vtotal;
    return (static_cast<uint64_t>(mode->clock)*1000+total/2)/total;
}
#define IS_BONDED_DSI() (bonded)
#define IS_ERR(ptr) (reinterpret_cast<intptr_t>(ptr)<0)
#define PTR_ERR(ptr) (reinterpret_cast<intptr_t>(ptr))
static unsigned long dsi_byte_clk_get_rate(mipi_dsi_host *host,bool pair,const drm_display_mode *) {
    assert((host==&hosts[0]||host==&hosts[1])&&pair==bonded);++clock_calls;return 148648500;
}
static dev_pm_opp *dev_pm_opp_find_freq_ceil(device *dev,unsigned long *rate) {
    assert(dev==&pdev.dev&&*rate==148648500);++opp_calls;
    return opp_error ? reinterpret_cast<dev_pm_opp *>(opp_error):&opp;
}
static void dev_pm_opp_put(dev_pm_opp *value) {assert(value==&opp);++opp_puts;}
static unsigned int dev_pm_opp_get_opp_count(device *dev) {assert(dev==&pdev.dev);return opp_count;}
static drm_mode_status msm_dsi_host_check_dsc(mipi_dsi_host *host,const drm_display_mode *) {
    assert(host==&hosts[0]||host==&hosts[1]);++dsc_calls;return dsc_result;
}
CPP
{
sed -n '/^static const struct o82_timing o82_modes\[\] = {/,/^};/p' "$modes"
awk '
    /^static enum drm_mode_status dsi_mgr_bridge_mode_valid\(/ {emit=1;found=1}
    emit {print}
    emit && /^}/ {exit}
    END {if (!found) exit 1}
' "$manager"
cat <<'CPP'
int main() {
    static_assert(sizeof(o82_modes)/sizeof(o82_modes[0])==7);
    drm_bridge bridge;
    auto reset=[] {
        assert(node_gets==node_puts);
        node_gets=node_puts=clock_calls=opp_calls=opp_puts=dsc_calls=0;
        uke=sm7675=bonded=true;panel_node={};remote=&panel_node;
        opp_error=0;opp_count=1;dsc_result=MODE_OK;
    };
    for(int link=0;link<2;link++)for(const auto &entry:o82_modes) {
        reset();bridge.id=link;
        assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&entry.mode)==MODE_OK);
        assert(clock_calls==1&&opp_calls==1&&opp_puts==1&&dsc_calls==1);
        assert(node_gets==node_puts);
        auto bad=entry.mode;bad.hsync_start++;
        reset();
        assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&bad)==MODE_BAD);
        assert(!clock_calls&&!opp_calls&&!opp_puts&&!dsc_calls&&node_gets==node_puts);
        bad=entry.mode;bad.flags=1;
        reset();
        assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&bad)==MODE_BAD);
        assert(!clock_calls&&!opp_calls&&!opp_puts&&!dsc_calls&&node_gets==node_puts);
    }
    for(int link=0;link<2;link++)for(size_t i=0;i<7;i++) {
        reset();bridge.id=link;panel_node.tm=panel_node.trial=true;
        const auto status=dsi_mgr_bridge_mode_valid(&bridge,nullptr,&o82_modes[i].mode);
        assert(status==((i==3||i==5) ? MODE_OK:MODE_BAD));
        assert(clock_calls==((i==3||i==5) ? 1U:0U));
        assert(node_gets==node_puts);
    }
    /* Every unrelated board, panel or absent profile retains legacy validation. */
    for(unsigned int outside=0;outside<5;outside++) {
        reset();auto bad=o82_modes[5].mode;bad.hsync_start++;
        switch(outside) {
        case 0:uke=false;break;
        case 1:sm7675=false;break;
        case 2:panel_node.pb=false;break;
        case 3:panel_node.refresh=false;break;
        case 4:remote=nullptr;break;
        }
        assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&bad)==MODE_OK);
        assert(clock_calls==1&&opp_calls==1&&opp_puts==1&&dsc_calls==1&&node_gets==node_puts);
    }
    reset();opp_error=-ERANGE;opp_count=0;
    assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&o82_modes[5].mode)==MODE_OK);
    assert(clock_calls==1&&opp_calls==1&&!opp_puts&&dsc_calls==1);
    reset();opp_error=-ERANGE;
    assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&o82_modes[5].mode)==MODE_CLOCK_RANGE);
    assert(clock_calls==1&&opp_calls==1&&!opp_puts&&!dsc_calls);
    reset();opp_error=-EIO;
    assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&o82_modes[5].mode)==MODE_ERROR);
    assert(clock_calls==1&&opp_calls==1&&!opp_puts&&!dsc_calls);
    reset();dsc_result=MODE_H_ILLEGAL;
    assert(dsi_mgr_bridge_mode_valid(&bridge,nullptr,&o82_modes[5].mode)==MODE_H_ILLEGAL);
    assert(clock_calls==1&&opp_calls==1&&opp_puts==1&&dsc_calls==1&&node_gets==node_puts);
}
CPP
} >> "$work/check.cpp"
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error -I"$work" "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual O82 bridge mode_valid: seven modes/both links, pre-clock malformed-mode refusal, legacy and OPP/DSC behavior passed\n'
