#!/usr/bin/env bash
# Exercise the actual DP envelope/bandwidth and PHY ownership functions; host only.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
utils=$kernel/drivers/gpu/drm/msm/dp/dp_utils.c
ctrl=$kernel/drivers/gpu/drm/msm/dp/dp_ctrl.c
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
using u8=uint8_t;using u32=uint32_t;using u64=uint64_t;
#define BIT(n) (1U<<(n))
#define DIV_ROUND_UP_ULL(n,d) (((n)+(d)-1)/(d))
#define round_down(n,d) ((n)/(d)*(d))
#define min3(a,b,c) std::min({a,b,c})
#define max(a,b) std::max(a,b)
enum drm_colorspace {DRM_MODE_COLORIMETRY_DEFAULT,DRM_MODE_COLORIMETRY_BT2020_RGB};
enum {DP_SDP_VSC=7,DP_PIXELFORMAT_YUV420=3,DP_PIXELFORMAT_RGB=0,
      DP_DYNAMIC_RANGE_CTA=1,DP_DYNAMIC_RANGE_VESA=0,DP_CONTENT_TYPE_NOT_DEFINED=0,
      DP_COLORIMETRY_DEFAULT=0,DP_COLORIMETRY_BT2020_RGB=6,
      HDMI_INFOFRAME_HEADER_SIZE=4,HDMI_DRM_INFOFRAME_SIZE=26,
      HDMI_STATIC_METADATA_TYPE1=0,HDMI_EOTF_BT_2100_HLG=3,HDMI_INFOFRAME_TYPE_DRM=0x87};
struct dp_sdp_header {u8 HB0,HB1,HB2,HB3;};
struct dp_sdp {dp_sdp_header sdp_header;u8 db[32];};
struct drm_dp_vsc_sdp {unsigned sdp_type,revision,length,pixelformat,bpc,dynamic_range,content_type,colorimetry;};
struct hdr_metadata_infoframe {
    u8 eotf,metadata_type;
    struct {uint16_t x,y;} display_primaries[3],white_point;
    uint16_t max_display_mastering_luminance,min_display_mastering_luminance,max_cll,max_fall;
};
struct hdr_output_metadata {u32 metadata_type;hdr_metadata_infoframe hdmi_metadata_type1;};
static_assert(sizeof(hdr_metadata_infoframe)==26&&sizeof(hdr_output_metadata)==32);
struct hdr_static_metadata {u8 eotf,metadata_type;};
struct drm_property_blob {size_t length;hdr_output_metadata* data;};
struct drm_connector {struct {struct {hdr_static_metadata hdmi_type1;} hdr_sink_metadata;} display_info;};
struct drm_connector_state {drm_property_blob* hdr_output_metadata;drm_connector* connector;};
struct hdmi_drm_infoframe {u8 version,length;};
static drm_dp_vsc_sdp last_vsc{};static int packet_error;
// Upstream packet packers are dependencies: a fixed HDMI packet checks the DP envelope.
static int drm_dp_vsc_sdp_pack(drm_dp_vsc_sdp* vsc,dp_sdp*) {last_vsc=*vsc;return packet_error;}
static int drm_hdmi_infoframe_set_hdr_metadata(hdmi_drm_infoframe* frame,const drm_connector_state*) {
    frame->version=1;frame->length=26;return packet_error;
}
static int hdmi_drm_infoframe_pack_only(hdmi_drm_infoframe*,u8* bytes,size_t length) {
    assert(length==30);bytes[0]=0x87;bytes[1]=1;bytes[2]=26;bytes[3]=0xa5;
    for(unsigned i=0;i<26;i++)bytes[4+i]=u8(i+2);
    return packet_error?packet_error:30;
}
CPP
awk '/^(bool|int) msm_dp_utils_(link_fits|tmds_fits|select_bpp|pack_vsc_sdp|pack_hdr_sdp)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$utils" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
struct phy {};
struct msm_dp_ctrl {};
struct msm_dp_panel {u8 dpcd[16];};
struct TestLink {struct {unsigned num_lanes,rate;} link_params;};
struct msm_dp_ctrl_private {
    struct msm_dp_ctrl msm_dp_ctrl;
    struct phy* phy;
    TestLink* link;
    struct {struct {unsigned lanes,link_rate;bool ssc;} dp;} phy_opts;
    void *dev{},*drm_dev{};
    bool phy_powered=false,link_clks_on=false;
};
static int config_error,power_error,off_error,opp_error,clock_error;
static unsigned power_calls,off_calls;static unsigned long opp_rate;
static int phy_configure(struct phy*,const void*) {return config_error;}
static int phy_power_on(struct phy*) {++power_calls;return power_error;}
static int phy_power_off(struct phy*) {++off_calls;return off_error;}
static bool drm_dp_max_downspread(const u8*) {return false;}
static int dev_pm_opp_set_rate(void*,unsigned long rate) {opp_rate=rate;return rate?opp_error:0;}
static int msm_dp_ctrl_link_clk_enable(struct msm_dp_ctrl* public_ctrl) {
    if(!clock_error)reinterpret_cast<msm_dp_ctrl_private*>(public_ctrl)->link_clks_on=true;
    return clock_error;
}
#define DRM_ERROR(...) do {} while(0)
#define drm_dbg_dp(...) do {} while(0)
CPP
awk '/^static int msm_dp_ctrl_(phy_power_off|enable_mainlink_clocks)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$ctrl" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    assert(msm_dp_utils_link_fits(241500,30,540000,2,false));
    assert(!msm_dp_utils_link_fits(299890,30,540000,2,false));
    assert(msm_dp_utils_link_fits(299890,30,540000,4,false));
    assert(msm_dp_utils_link_fits(594000,24,540000,4,false));
    assert(!msm_dp_utils_link_fits(594000,30,540000,4,false));
    assert(!msm_dp_utils_link_fits(1188000,24,540000,4,false));
    assert(msm_dp_utils_link_fits(594000,24,540000,2,true));
    assert(!msm_dp_utils_link_fits(594000,30,540000,2,true));
    assert(!msm_dp_utils_link_fits(0,30,540000,4,false));
    assert(msm_dp_utils_tmds_fits(241500,30,320000,false));
    assert(msm_dp_utils_tmds_fits(241500,30,301875,false));
    assert(!msm_dp_utils_tmds_fits(241500,30,301874,false));
    assert(!msm_dp_utils_tmds_fits(299890,30,320000,false));
    assert(msm_dp_utils_tmds_fits(299890,30,374863,false));
    assert(!msm_dp_utils_tmds_fits(299890,30,374862,false));
    assert(msm_dp_utils_tmds_fits(299890,24,320000,false));
    assert(msm_dp_utils_tmds_fits(594000,30,371250,true));
    assert(!msm_dp_utils_tmds_fits(594000,30,371249,true));
    assert(msm_dp_utils_tmds_fits(594000,24,594000,false));
    assert(!msm_dp_utils_tmds_fits(594000,24,593999,false));
    assert(!msm_dp_utils_tmds_fits(299890,18,240000,false));
    assert(msm_dp_utils_tmds_fits(299890,30,0,false));
    assert(!msm_dp_utils_tmds_fits(0,30,320000,false));
    assert(!msm_dp_utils_tmds_fits(241500,0,320000,false));
    assert(msm_dp_utils_select_bpp(10,10,241500,540000,4,false,true,320000)==30);
    assert(msm_dp_utils_select_bpp(10,10,299890,540000,4,false,true,320000)==-ENOSPC);
    assert(msm_dp_utils_select_bpp(10,10,299890,540000,4,false,false,320000)==24);
    assert(msm_dp_utils_select_bpp(10,10,241500,540000,2,false,true,0)==30);
    assert(msm_dp_utils_select_bpp(10,10,299890,540000,2,false,true,0)==-ENOSPC);
    assert(msm_dp_utils_select_bpp(10,10,299890,540000,2,false,false,0)==24);
    assert(msm_dp_utils_select_bpp(0,10,241500,540000,2,false,false,0)==24);
    assert(msm_dp_utils_select_bpp(0,10,241500,540000,2,false,true,0)==-EINVAL);
    assert(msm_dp_utils_select_bpp(10,8,241500,540000,2,false,true,0)==-EINVAL);
    assert(msm_dp_utils_select_bpp(12,12,241500,540000,2,false,true,0)==30);
    assert(msm_dp_utils_select_bpp(5,10,241500,540000,2,false,false,0)==-EINVAL);
    dp_sdp sdp{};
    assert(msm_dp_utils_pack_vsc_sdp(&sdp,DRM_MODE_COLORIMETRY_BT2020_RGB,10,false)==0);
    assert(last_vsc.colorimetry==DP_COLORIMETRY_BT2020_RGB&&last_vsc.bpc==10);
    assert(last_vsc.pixelformat==DP_PIXELFORMAT_RGB&&last_vsc.dynamic_range==DP_DYNAMIC_RANGE_VESA);
    assert(last_vsc.revision==5&&last_vsc.length==0x13);
    assert(msm_dp_utils_pack_vsc_sdp(&sdp,DRM_MODE_COLORIMETRY_BT2020_RGB,10,true)==-EINVAL);
    assert(msm_dp_utils_pack_vsc_sdp(&sdp,DRM_MODE_COLORIMETRY_DEFAULT,8,true)==0);
    assert(last_vsc.dynamic_range==DP_DYNAMIC_RANGE_CTA&&last_vsc.pixelformat==DP_PIXELFORMAT_YUV420);
    packet_error=-EIO;
    assert(msm_dp_utils_pack_vsc_sdp(&sdp,DRM_MODE_COLORIMETRY_DEFAULT,8,false)==-EIO);
    packet_error=0;
    hdr_output_metadata metadata{};metadata.hdmi_metadata_type1.eotf=2;
    drm_property_blob blob{sizeof(metadata),&metadata};drm_connector connector{};
    connector.display_info.hdr_sink_metadata.hdmi_type1={BIT(2),BIT(0)};
    drm_connector_state state{&blob,&connector};
    assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==0);
    assert(sdp.sdp_header.HB0==0&&sdp.sdp_header.HB1==0x87&&sdp.sdp_header.HB2==0x1d&&sdp.sdp_header.HB3==0x4c);
    assert(sdp.db[0]==1&&sdp.db[1]==26);
    for(unsigned i=0;i<26;i++)assert(sdp.db[2+i]==i+2);
    for(unsigned i=28;i<32;i++)assert(sdp.db[i]==0);
    blob.length--;assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EINVAL);blob.length++;
    metadata.metadata_type=1;assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EINVAL);metadata.metadata_type=0;
    metadata.hdmi_metadata_type1.metadata_type=1;assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EINVAL);metadata.hdmi_metadata_type1.metadata_type=0;
    metadata.hdmi_metadata_type1.eotf=4;assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EINVAL);metadata.hdmi_metadata_type1.eotf=2;
    connector.display_info.hdr_sink_metadata.hdmi_type1.eotf=1;
    assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EINVAL);
    connector.display_info.hdr_sink_metadata.hdmi_type1.eotf=BIT(2);
    packet_error=-EIO;assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==-EIO);packet_error=0;
    state.hdr_output_metadata=nullptr;memset(&sdp,0xff,sizeof(sdp));
    assert(msm_dp_utils_pack_hdr_sdp(&state,&sdp)==0);
    const dp_sdp zero{};assert(!memcmp(&sdp,&zero,sizeof(sdp)));
    struct phy phy;msm_dp_ctrl_private ctrl{};
    struct msm_dp_panel panel{};
    TestLink link{};
    ctrl.phy=&phy;ctrl.link=&link;
    link.link_params={2,540000};
    config_error=-EIO;assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==-EIO&&power_calls==0);
    config_error=0;power_error=-ERANGE;
    assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==-ERANGE&&!ctrl.phy_powered);
    power_error=0;opp_error=-EAGAIN;
    assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==-EAGAIN&&!ctrl.phy_powered&&off_calls==1);
    opp_error=0;clock_error=-ETIMEDOUT;
    assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==-ETIMEDOUT&&!ctrl.phy_powered&&opp_rate==0&&off_calls==2);
    clock_error=0;assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==0&&ctrl.phy_powered&&ctrl.link_clks_on);
    const auto powers=power_calls;
    assert(msm_dp_ctrl_enable_mainlink_clocks(&ctrl,&panel)==0&&power_calls==powers);
    off_error=-EIO;assert(msm_dp_ctrl_phy_power_off(&ctrl)==-EIO&&ctrl.phy_powered);
    off_error=0;assert(msm_dp_ctrl_phy_power_off(&ctrl)==0&&!ctrl.phy_powered);
    const auto offs=off_calls;assert(msm_dp_ctrl_phy_power_off(&ctrl)==0&&off_calls==offs);
    puts("Actual DP helpers: HDR10 bandwidth, VSC range/color, HDR packet validation/envelope and PHY error ownership passed; host only");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unused-function -Wno-missing-field-initializers "$work/check.cpp" -o "$work/check"
"$work/check"
