#!/usr/bin/env bash
# Execute the actual scoped OEM refresh/clock helpers without target access.
set -Eeuo pipefail
host=${1:?Pass prepared dsi_host.c}
header=${2:?Pass src/display/o82-mode.h}
modes=${3:?Pass generated o82-data.h}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work/linux" "$work/drm"
cp "$header" "$work/o82-mode.h"
printf '#define EINVAL 22\n' > "$work/linux/errno.h"
cat > "$work/drm/drm_modes.h" <<'CPP'
struct drm_display_mode {
    int clock,hdisplay,hsync_start,hsync_end,htotal,vdisplay,vsync_start,vsync_end,vtotal;
    unsigned int width_mm,height_mm,flags=0,hskew=0;
    int vscan=0;
};
CPP
extract() {
    awk -v signature="$1" '
        index($0,signature)==1 {emit=1;found=1}
        emit {print}
        emit && /^}/ {exit}
        END {if (!found) exit 1}
    ' "$host"
}
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstring>
#include <cstddef>
#include "o82-mode.h"
using u8=uint8_t;using u32=uint32_t;
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define mult_frac(n,m,d) ((static_cast<uint64_t>(n)*(m))/(d))
#define READ_ONCE(v) (v)
#define CONFIG_DEBUG_FS 1
#define IS_ENABLED(v) (v)
#define DSI_0 0
#define DSI_1 1
#define MSM_DSI_VER_MAJOR_6G 0x03
#define MSM_DSI_6G_VER_MINOR_V2_8_0 0x20080000
#define DSI_6G_REG_SHIFT 4
#define UKE_DSI_MISR_SIGNATURE (0x368-DSI_6G_REG_SHIFT)
#define MIPI_DSI_FMT_RGB101010 30
#define MIPI_DSI_FMT_RGB888 24
#define MIPI_DSI_MODE_VIDEO 1
#define DSI_TOTAL_H_TOTAL(v) (v)
#define DSI_TOTAL_V_TOTAL(v) ((v)<<16)
#define pr_err(...) ((void)0)
#define DBG(...) ((void)0)
struct device_node {bool pb=true,tm=false,refresh=true,initial=false,trial=false;};
struct device {device_node *of_node;};
struct platform_device {device dev;};
struct msm_dsi_cfg {unsigned int io_offset=DSI_6G_REG_SHIFT;};
struct msm_dsi_cfg_handler {
    msm_dsi_cfg *cfg;
    unsigned int major=MSM_DSI_VER_MAJOR_6G,minor=MSM_DSI_6G_VER_MINOR_V2_8_0;
};
struct drm_dsc_config {
    unsigned int bits_per_component=10,bits_per_pixel=8<<4,slice_width=800,slice_height=24;
};
struct mipi_dsi_host {void *owner;};
struct msm_dsi_host {
    mipi_dsi_host base;platform_device *pdev;drm_display_mode *mode,*uke_dfps_mode=nullptr;
    bool uke_dfps_staged=false;
    msm_dsi_cfg_handler *cfg_hnd;drm_dsc_config *dsc;
    unsigned int ctrl_size=0x400;
    int id=0;
    bool power_on=true,cmd_dma_blocked=false,cphy_mode=false;
    unsigned int lanes=4,format=MIPI_DSI_FMT_RGB101010,mode_flags=MIPI_DSI_MODE_VIDEO;
    unsigned long pixel_clk_rate=0,byte_clk_rate=0;
};
struct o82_timing {unsigned int group;drm_display_mode mode;};
static bool uke=true,sm7675=true;
static device_node parent_node,panel_node,*remote=&panel_node;
static unsigned int node_gets=0,node_puts=0;
static msm_dsi_host *to_msm_dsi_host(mipi_dsi_host *host) {
    return static_cast<msm_dsi_host *>(host->owner);
}
static bool of_machine_is_compatible(const char *name) {
    if(!std::strcmp(name,"xiaomi,uke"))return uke;
    assert(!std::strcmp(name,"qcom,sm7675"));return sm7675;
}
static device_node *of_graph_get_remote_node(device_node *node,int port,int endpoint) {
    assert(node==&parent_node&&port==1&&endpoint==-1);++node_gets;return remote;
}
static void of_node_put(device_node *node) {assert(node==remote);++node_puts;}
static bool of_device_is_compatible(device_node *node,const char *name) {
    if(!std::strcmp(name,"xiaomi,o82-42-02-0b"))return node&&node->pb&&!node->tm;
    assert(!std::strcmp(name,"xiaomi,o82-36-02-0a"));return node&&node->pb&&node->tm;
}
static bool of_property_read_bool(device_node *node,const char *name) {
    if(!node)return false;
    if(!std::strcmp(name,"xiaomi,oem-refresh-modes"))return node->refresh;
    if(!std::strcmp(name,"xiaomi,initial-120hz-only"))return node->initial;
    assert(!std::strcmp(name,"xiaomi,o82-36-60-120-trial"));return node->trial;
}
static unsigned int drm_mode_vrefresh(const drm_display_mode *mode) {
    return (static_cast<uint64_t>(mode->clock)*1000+mode->htotal*mode->vtotal/2)/
        (mode->htotal*mode->vtotal);
}
static unsigned int drm_dsc_get_bpp_int(const drm_dsc_config *dsc) {return dsc->bits_per_pixel>>4;}
static unsigned int mipi_dsi_pixel_format_to_bpp(unsigned int format) {return format;}
CPP
{
    sed -n '/^static const struct o82_timing o82_modes\[\] = {/,/^};/p' "$modes"
    extract 'static bool dsi_uke_misr_scope('
    extract 'static bool dsi_uke_o82_refresh_selected('
    extract 'static bool dsi_uke_o82_refresh_modes('
    extract 'static bool dsi_uke_o82_initial120('
    extract 'static bool dsi_uke_o82_powered_profile('
    extract 'static u32 dsi_uke_o82_total('
    printf 'static unsigned long\n'
    extract 'dsi_adjust_pclk_for_compression('
    extract 'static unsigned long dsi_get_pclk_rate('
    extract 'unsigned long dsi_byte_clk_get_rate('
    extract 'static void dsi_calc_pclk('
} >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    static_assert(sizeof(o82_modes)/sizeof(o82_modes[0])==7);
    platform_device p{{&parent_node}};
    msm_dsi_cfg cfg;msm_dsi_cfg_handler handler{&cfg};drm_dsc_config dsc;
    drm_display_mode mode=o82_modes[5].mode;
    msm_dsi_host h{};
    auto reset=[&] {
        uke=sm7675=true;panel_node={};remote=&panel_node;
        cfg={};handler={&cfg};dsc={};mode=o82_modes[6].mode;
        h={};h.base.owner=&h;h.pdev=&p;h.mode=&mode;h.cfg_hnd=&handler;h.dsc=&dsc;
        assert(node_gets==node_puts);node_gets=node_puts=0;
    };
    reset();panel_node.refresh=false;
    mode=o82_modes[5].mode;
    const unsigned long baseline_pixel=dsi_get_pclk_rate(&mode,&dsc,true);
    const unsigned long baseline_byte=dsi_byte_clk_get_rate(&h.base,true,&mode);
    assert(baseline_pixel==158558400UL&&baseline_byte*8==1189188000UL);
    constexpr u32 totals[]={0x1b1102fa,0x10ea02fa,0x103d02fa,0x120b023b,0x090502fa,0x0905023b,0x090501dc};
    for(unsigned int link=0;link<2;link++)for(size_t i=0;i<7;i++) {
        reset();h.id=link;mode=o82_modes[i].mode;
        const auto pure_before=dsi_get_pclk_rate(&mode,&dsc,true);
        assert(dsi_uke_o82_refresh_modes(&h,&mode));
        assert(dsi_uke_o82_powered_profile(&h));
        assert(dsi_uke_o82_total(&h)==totals[i]);
        dsi_calc_pclk(&h,true);
        assert(h.pixel_clk_rate==baseline_pixel&&h.byte_clk_rate==baseline_byte);
        assert(dsi_get_pclk_rate(&mode,&dsc,true)==pure_before);
        if(o82_modes[i].group!=0)assert(pure_before!=baseline_pixel);
        assert(dsi_byte_clk_get_rate(&h.base,false,&mode)!=baseline_byte);
        h.power_on=false;
        assert(dsi_uke_o82_refresh_modes(&h,&mode));
        assert(!dsi_uke_o82_powered_profile(&h));
        h.power_on=true;h.cmd_dma_blocked=true;
        assert(dsi_uke_o82_refresh_modes(&h,&mode));
        assert(!dsi_uke_o82_powered_profile(&h));
        assert(node_gets==node_puts);
    }
    /* Invalid scope/profile/link/DSC never acquires the new fixed-clock path. */
    for(unsigned int bad=0;bad<25;bad++) {
        reset();
        switch(bad) {
        case 0:uke=false;break;
        case 1:sm7675=false;break;
        case 2:h.id=-1;break;
        case 3:h.id=2;break;
        case 4:h.cfg_hnd=nullptr;break;
        case 5:handler.cfg=nullptr;break;
        case 6:handler.major++;break;
        case 7:handler.minor++;break;
        case 8:cfg.io_offset=0;break;
        case 9:h.ctrl_size=UKE_DSI_MISR_SIGNATURE+sizeof(u32)-1;break;
        case 10:h.cphy_mode=true;break;
        case 11:h.lanes=3;break;
        case 12:h.format=MIPI_DSI_FMT_RGB888;break;
        case 13:h.mode_flags=0;break;
        case 14:h.dsc=nullptr;break;
        case 15:dsc.bits_per_component=8;break;
        case 16:dsc.bits_per_pixel=7<<4;break;
        case 17:dsc.slice_width=400;break;
        case 18:dsc.slice_height=12;break;
        case 19:remote=nullptr;break;
        case 20:panel_node.pb=false;break;
        case 21:panel_node.refresh=false;break;
        case 22:mode.clock++;break;
        case 23:mode.flags=2;break;
        case 24:mode.vscan=2;break;
        }
        assert(!dsi_uke_o82_refresh_modes(&h,&mode));
        assert(!dsi_uke_o82_powered_profile(&h));
        const auto generic_pixel=dsi_get_pclk_rate(&mode,h.dsc,true);
        const auto generic_byte=dsi_byte_clk_get_rate(&h.base,true,&mode);
        dsi_calc_pclk(&h,true);
        assert(h.pixel_clk_rate==generic_pixel&&h.byte_clk_rate==generic_byte);
        assert(node_gets==node_puts);
    }
    reset();assert(!dsi_uke_o82_refresh_modes(&h,nullptr));
    reset();panel_node.tm=panel_node.trial=true;mode=o82_modes[3].mode;
    assert(dsi_uke_o82_refresh_modes(&h,&mode));
    panel_node.trial=false;
    assert(!dsi_uke_o82_refresh_modes(&h,&mode));
    h.mode=nullptr;assert(!dsi_uke_o82_powered_profile(&h));
    /* The original initial120 profile remains independent of the new flag. */
    reset();mode=o82_modes[5].mode;panel_node.refresh=false;panel_node.initial=true;
    assert(!dsi_uke_o82_refresh_modes(&h,&mode));
    assert(dsi_uke_o82_powered_profile(&h));
    dsi_calc_pclk(&h,true);
    assert(h.pixel_clk_rate==baseline_pixel&&h.byte_clk_rate==baseline_byte);
    assert(node_gets==node_puts);
}
CPP
"${CXX:-g++}" -std=c++20 -O2 -Wall -Wextra -Werror -fsanitize=undefined \
    -fsanitize-undefined-trap-on-error -I"$work" "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Actual O82 refresh host helpers: seven modes/both links preserve accepted120 clocks; total, scope/DSC/profile refusals, power/quarantine admission, generic clocks and DT references passed\n'
