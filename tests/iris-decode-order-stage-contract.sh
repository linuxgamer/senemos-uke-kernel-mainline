#!/usr/bin/env bash
set -Eeuo pipefail
iris=${1:?Pass prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <linux/videodev2.h>
using u32=uint32_t;
enum platform_inst_fw_cap_type {STAGE,DISPLAY_DELAY_ENABLE,DISPLAY_DELAY};
constexpr int DECODER=0,ENCODER=1,STAGE_1=1,STAGE_2=2;
constexpr u32 CAP_FLAG_CLIENT_SET=4,HFI_HOST_FLAGS_NONE=0,HFI_PAYLOAD_U32=7;
struct platform_data{};static platform_data sm7675_data,other;
struct iris_core {platform_data *iris_platform_data=&sm7675_data;};
struct fw_cap {u32 hfi_id=17,flags=0,value=0;};
struct iris_inst;
struct iris_hfi_session_ops {int (*session_set_property)(iris_inst*,u32,u32,u32,u32,void*,u32);};
struct iris_inst {const iris_hfi_session_ops *hfi_session_ops;v4l2_format *fmt_src;
 iris_core *core;int domain=DECODER;u32 codec=V4L2_PIX_FMT_VP9;fw_cap fw_caps[3];};
static u32 sent;static int result;
static int set_property(iris_inst *i,u32 id,u32 flags,u32 port,u32 payload,void *data,u32 size) {
 assert(id==17&&!flags&&port==2&&payload==HFI_PAYLOAD_U32&&size==sizeof(u32));
 sent=*static_cast<u32*>(data);assert(i->fw_caps[STAGE].value==sent);return result;
}
static u32 iris_get_port_info(iris_inst*,platform_inst_fw_cap_type) {return 2;}
static bool iris_res_is_less_than(u32 w,u32 h,u32 mw,u32 mh){return uint64_t(w)*h<uint64_t(mw)*mh;}
CPP
awk '/^int iris_set_stage\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$iris/iris_ctrls.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
 iris_core core;v4l2_format fmt{};fmt.fmt.pix_mp.width=3840;fmt.fmt.pix_mp.height=2160;
 iris_hfi_session_ops ops{set_property};iris_inst i{};i.hfi_session_ops=&ops;i.fmt_src=&fmt;i.core=&core;
 auto test=[&](u32 expected){sent=0;assert(iris_set_stage(&i,STAGE)==result);assert(sent==expected);};
 test(STAGE_2);i.fw_caps[DISPLAY_DELAY_ENABLE].value=1;test(STAGE_2);
 i.fw_caps[DISPLAY_DELAY_ENABLE].flags=CAP_FLAG_CLIENT_SET;test(STAGE_1);
 result=-5;test(STAGE_1);result=0;
 i.fw_caps[DISPLAY_DELAY].value=1;test(STAGE_2);i.fw_caps[DISPLAY_DELAY].value=0;
 i.domain=ENCODER;test(STAGE_2);i.domain=DECODER;
 i.codec=V4L2_PIX_FMT_H264;test(STAGE_2);i.codec=V4L2_PIX_FMT_VP9;
 core.iris_platform_data=&other;test(STAGE_2);core.iris_platform_data=&sm7675_data;
 i.fw_caps[DISPLAY_DELAY_ENABLE].value=0;test(STAGE_2);
 fmt.fmt.pix_mp.width=640;fmt.fmt.pix_mp.height=480;test(STAGE_1);
 i.domain=ENCODER;test(STAGE_2);
}
CPP
c++ -std=c++17 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
echo 'PASS actual stage function: client/platform/codec/domain/delay gates, cache and firmware errors (host only)'
