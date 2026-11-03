#!/usr/bin/env bash
# Execute real DPU/DSI timing functions on the host; never accesses hardware.
set -Eeuo pipefail
dpu=${1:?Pass prepared dpu_encoder_phys_vid.c}
dsi=${2:?Pass prepared dsi_host.c}
modes=${3:?Pass generated o82-data.h}
panel=${4:?Pass panel-xiaomi-o82.c}
intf_source=${5:?Pass prepared dpu_hw_intf.c}
msm_source=${intf_source%/disp/dpu1/dpu_hw_intf.c}
bpc8=$(sed -n '/<enum name="mdp_bpc">/,/<\/enum>/p' "$msm_source/registers/display/mdp_common.xml" |
    sed -n 's/.*<value name="BPC8" value="\([0-9]*\)".*/\1/p')
[[ $bpc8 =~ ^[0-9]+$ ]]
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
printf '#define BPC8 %s\n' "$bpc8" > "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstring>
#include <initializer_list>
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define mult_frac(n,m,d) ((static_cast<uint64_t>(n)*(m))/(d))
#define DPU_ERROR(...) ((void)0)
#define BIT(n) (1U<<(n))
#define MSM_FORMAT_IS_YUV(fmt) false
#define DRM_MODE_FLAG_NHSYNC 1
#define DRM_MODE_FLAG_NVSYNC 2
using u32=uint32_t;
enum { INTF_DSI, INTF_DP };
enum mipi_dsi_pixel_format {
    MIPI_DSI_FMT_RGB101010, MIPI_DSI_FMT_RGB888, MIPI_DSI_FMT_RGB666,
    MIPI_DSI_FMT_RGB666_PACKED, MIPI_DSI_FMT_RGB565
};
enum dsi_vid_dst_format {
    VID_DST_FORMAT_RGB101010, VID_DST_FORMAT_RGB888, VID_DST_FORMAT_RGB666_LOOSE,
    VID_DST_FORMAT_RGB666, VID_DST_FORMAT_RGB565
};
struct drm_display_mode {
    int clock,hdisplay,hsync_start,hsync_end,htotal,vdisplay,vsync_start,vsync_end,vtotal;
    unsigned int width_mm,height_mm,flags,hskew;
};
struct drm_dsc_config {
    unsigned int bits_per_pixel,bits_per_component,slice_count,slice_chunk_size;
};
struct drm_encoder { bool dsc,wide; drm_dsc_config config; };
struct dpu_intf_caps { int type; };
struct dpu_hw_blk_reg_map { u32 regs[0x300/4]; };
struct mdss_version { unsigned core_major_ver; };
struct dpu_hw_intf { dpu_intf_caps *cap; dpu_hw_blk_reg_map hw; mdss_version *mdss_ver; };
struct msm_format { unsigned bpc_g_y,bpc_b_cb,bpc_r_cr; };
#define DPU_REG_READ(c,off) ((c)->regs[(off)/4])
#define DPU_REG_WRITE(c,off,value) ((c)->regs[(off)/4]=(value))
struct dpu_encoder_phys { drm_encoder *parent; dpu_hw_intf *hw_intf; };
struct dpu_hw_intf_timing_params {
    unsigned int width,height,xres,yres,h_back_porch,h_front_porch,v_back_porch,
        v_front_porch,hsync_pulse_width,vsync_pulse_width,hsync_polarity,
        vsync_polarity,border_clr,underflow_clr,hsync_skew,dce_bytes_per_line;
    bool wide_bus_en,compression_en;
};
static bool dpu_encoder_is_widebus_enabled(const drm_encoder *e) { return e->wide; }
static bool dpu_encoder_is_dsc_enabled(const drm_encoder *e) { return e->dsc; }
static drm_dsc_config *dpu_encoder_get_dsc_config(drm_encoder *e) { return &e->config; }
static unsigned int drm_dsc_get_bpp_int(const drm_dsc_config *d) { return d->bits_per_pixel>>4; }
static unsigned int msm_dsc_get_bytes_per_line(const drm_dsc_config *d) {
    return d->slice_count*d->slice_chunk_size;
}
struct o82_timing { unsigned int group; drm_display_mode mode; };
CPP
{
sed -n '/^static const struct o82_timing o82_modes\[\] = {/,/^};/p' "$modes"
printf 'static inline enum dsi_vid_dst_format\n'
sed -n '/^dsi_get_vid_fmt(/,/^static inline enum dsi_cmd_dst_format/p' "$dsi" | sed '$d'
sed -n 's/^[[:space:]]*ctx->dsi\[i\]->format = /static const auto panel_format = /p' "$panel"
sed -n '/^static void drm_mode_to_intf_timing_params(/,/^static u32 get_horizontal_total(/p' "$dpu" |
    sed '$d'
sed -n '/^#define INTF_/p' "$intf_source"
sed -n '/^static void dpu_hw_intf_setup_timing_engine(/,/^static void dpu_hw_intf_enable_timing_engine(/p' "$intf_source" | sed '$d'
printf 'static unsigned long\n'
sed -n '/^dsi_adjust_pclk_for_compression(/,/^unsigned long dsi_byte_clk_get_rate(/p' "$dsi" |
    sed '$d'
cat <<'CPP'
static unsigned int dsi_active(const drm_dsc_config *dsc, unsigned int bits_per_pclk) {
    struct { const drm_dsc_config *dsc; } host{dsc};
    auto *msm_host=&host;
    unsigned int hdisplay;
CPP
sed -n '/^[[:space:]]*hdisplay = DIV_ROUND_UP(msm_dsc_get_bytes_per_line(msm_host->dsc)/p' "$dsi"
cat <<'CPP'
    return hdisplay;
}
int main() {
    assert(dsi_get_vid_fmt(panel_format)==VID_DST_FORMAT_RGB101010);
    static_assert(sizeof(o82_modes)/sizeof(o82_modes[0])==7);
    drm_encoder encoder{true,true,{8<<4,10,2,800}};
    dpu_intf_caps caps{INTF_DSI}; dpu_hw_intf intf{&caps};
    dpu_encoder_phys physical{&encoder,&intf};
    for(const auto &entry : o82_modes) {
        auto mode=entry.mode;
        mode.hdisplay/=2; mode.htotal/=2; mode.hsync_start/=2; mode.hsync_end/=2;
        dpu_hw_intf_timing_params timing{};
        drm_mode_to_intf_timing_params(&physical,&mode,&timing);
        const auto active=dsi_active(&encoder.config,30);
        const auto porch=entry.mode.htotal/2-1600;
        assert(active==427 && timing.width==active && timing.xres==active);
        assert(timing.dce_bytes_per_line==1600);
        assert(timing.width+timing.h_back_porch+timing.h_front_porch+timing.hsync_pulse_width==active+porch);
        const auto host_clock=dsi_get_pclk_rate(&entry.mode,&encoder.config,true);
        const auto expected=mult_frac(entry.mode.clock*1000u,2*(active+porch),entry.mode.htotal)/2;
        assert(host_clock==expected);
        if(entry.mode.clock==967428 && entry.mode.vtotal==4620) {
            assert(active+porch==572 && host_clock==158558400);
        }
        encoder.config.bits_per_component=8;
        drm_mode_to_intf_timing_params(&physical,&mode,&timing);
        assert(timing.width==534 && timing.width==dsi_active(&encoder.config,24));
        encoder.config.bits_per_component=10;
        encoder.dsc=false;
        drm_mode_to_intf_timing_params(&physical,&mode,&timing);
        assert(timing.width==1600 && !timing.compression_en);
        encoder.dsc=true;
    }
    mdss_version version{10}; intf.mdss_ver=&version;
    msm_format format{BPC8,BPC8,BPC8};
    const drm_display_mode dp_modes[] = {
        {241500,2560,2608,2640,2720,1440,1443,1448,1481},
        {148500,1920,2008,2052,2200,1080,1084,1089,1125},
        {594000,3840,4016,4104,4400,2160,2168,2178,2250}
    };
    caps.type=INTF_DP;
    for(const auto &mode:dp_modes) for(unsigned depth:{8u,10u}) {
        encoder.config={8<<4,depth,mode.hdisplay>2560?2u:1u,
                        static_cast<unsigned>(mode.hdisplay)/(mode.hdisplay>2560?2u:1u)};
        encoder.wide=true;
        for(bool compressed:{true,false}) {
            encoder.dsc=compressed;
            dpu_hw_intf_timing_params timing{};
            drm_mode_to_intf_timing_params(&physical,&mode,&timing);
            assert(timing.width==static_cast<unsigned>(mode.hdisplay)/2);
            intf.hw={};
            dpu_hw_intf_setup_timing_engine(&intf,&timing,&format);
            assert(intf.hw.regs[INTF_PANEL_FORMAT/4]==0x213f);
            const unsigned start=(mode.htotal-mode.hdisplay)/2;
            const unsigned data_width=compressed?DIV_ROUND_UP(mode.hdisplay,6):mode.hdisplay/2;
            const auto window=((start+data_width-1)<<16)|start;
            assert(intf.hw.regs[INTF_DISPLAY_DATA_HCTL/4]==window);
            assert(intf.hw.regs[INTF_ACTIVE_DATA_HCTL/4]==(compressed?window:0));
            assert(intf.hw.regs[INTF_CONFIG2/4]==(compressed?0x1011u:0x11u));
            assert((intf.hw.regs[INTF_HSYNC_CTL/4]>>16)==static_cast<unsigned>(mode.htotal)/2);
        }
    }
    caps.type=INTF_DSI; encoder.dsc=true;
    dpu_hw_intf_timing_params timing{};
    drm_mode_to_intf_timing_params(&physical,&o82_modes[3].mode,&timing);
    intf.hw={}; dpu_hw_intf_setup_timing_engine(&intf,&timing,&format);
    assert(!intf.hw.regs[INTF_ACTIVE_DATA_HCTL/4]);
    assert(intf.hw.regs[INTF_PANEL_FORMAT/4]==0x213f);
}
CPP
} >> "$work/check.cpp"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-missing-field-initializers \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Real DPU/DSI functions: seven O82 line periods and DP compressed/uncompressed data windows at FHD/QHD/UHD, 8/10 bpc checked\n'
