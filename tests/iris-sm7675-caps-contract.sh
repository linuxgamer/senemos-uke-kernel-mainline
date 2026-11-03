#!/usr/bin/env bash
# Actual source selectors, admission, control limits and frequency arithmetic.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <algorithm>
#include <cassert>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <vector>
#include <linux/videodev2.h>
using u32 = uint32_t;
using u64 = uint64_t;
using s64 = int64_t;
#define BIT(n) (1ULL << (n))
#define GENMASK_ULL(hi, lo) ((~0ULL << (lo)) & (~0ULL >> (63 - (hi))))
#define min_t(type,a,b) std::min<type>(a,b)
#define max(a,b) std::max((a),(b))
#define min(a,b) std::min((a),(b))
#define max3(a,b,c) max(max(a,b),c)
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define NUM_MBS_PER_FRAME(h,w) (DIV_ROUND_UP(h,16)*DIV_ROUND_UP(w,16))
#define MAXIMUM_FPS 480
#define DEFAULT_FPS 30
#define STAGE_1 1
#define STAGE_2 2
#define STEP_WIDTH 2
#define STEP_HEIGHT 2
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
enum {DECODER, ENCODER};
struct iris_core;
struct iris_inst;
CPP
for tag in 'struct platform_inst_caps' 'enum platform_inst_fw_cap_type' 'enum platform_inst_fw_cap_flags' 'struct platform_inst_fw_cap' 'struct bw_info' 'struct iris_inst_power' 'struct icc_vote_data'; do
    awk -v tag="$tag" '$0 == tag " {" {emit=1} emit {print} emit && /^};/ {exit}' \
        "$iris/iris_platform_common.h" >> "$work/check.cpp"
done
cat >> "$work/check.cpp" <<'CPP'
struct iris_platform_data {
    platform_inst_caps *inst_caps;
    const platform_inst_caps *(*get_inst_caps)(iris_inst *, u32);
    u32 max_core_mbps, num_vpp_pipe;
    const bw_info *bw_tbl_dec{};
    u32 bw_tbl_dec_size{};
};
struct vb2_queue {bool streaming;};
struct context {vb2_queue src{}, dst{};};
struct iris_core {
    const struct iris_platform_data *iris_platform_data;
    platform_inst_fw_cap inst_fw_caps_dec[INST_FW_CAP_MAX]{}, inst_fw_caps_enc[INST_FW_CAP_MAX]{};
    std::vector<iris_inst *> instances{};
    int lock{};
};
struct iris_inst {
    iris_core *core; int domain; u32 codec, frame_rate, operating_rate;
    u32 frame_rate_q16{}, operating_rate_q16{};
    v4l2_format *fmt_src; v4l2_rect crop{};
    platform_inst_fw_cap fw_caps[INST_FW_CAP_MAX]{};
    context *m2m_ctx;
    icc_vote_data icc_data{};
    iris_inst_power power{};
};
CPP
# Include the actual immutable platform table and selector, not a copied model.
printf '#include "iris_platform_sm7675.h"\n' >> "$work/check.cpp"
awk '/^static const struct bw_info iris_bw_table_dec_vpu3x\[\] =/ {emit=1} emit {print} emit && /^};/ {exit}' \
    "$iris/iris_platform_vpu3x.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static const iris_platform_data sm7675_data{&platform_inst_cap_sm7675, sm7675_get_inst_caps, 2088960, 2,
    iris_bw_table_dec_vpu3x, ARRAY_SIZE(iris_bw_table_dec_vpu3x)};
static platform_inst_caps old_caps{96,8192,96,8192,139264,0,25,200,489583,66234,480,480};
static const iris_platform_data legacy_data{&old_caps,nullptr,7777777,4};
static u64 div_u64(u64 n, u32 d) {assert(d); return n/d;}
static u64 mult_frac(u64 n, u32 numer, u32 denom) {assert(denom); return n*numer/denom;}
static vb2_queue *v4l2_m2m_get_src_vq(context *ctx) {return &ctx->src;}
static vb2_queue *v4l2_m2m_get_dst_vq(context *ctx) {return &ctx->dst;}
static bool vb2_is_streaming(vb2_queue *q) {return q->streaming;}
static int aggregate_error;
static int iris_check_core_mbpf(iris_inst *) {return aggregate_error;}
static void mutex_lock(int *) {}
static void mutex_unlock(int *) {}
static int interconnect_error;
static int iris_set_interconnects(iris_inst *) { return interconnect_error; }
#define list_for_each_entry(pos,head,member) \
    for (auto it=(head)->begin(); it!=(head)->end() && ((pos=*it),true); ++it)
struct file {iris_inst *inst;};
static iris_inst *iris_get_inst(file *f) {return f->inst;}
static int iris_venc_validate_format(iris_inst *, u32 format) {
    return format==V4L2_PIX_FMT_H264 || format==V4L2_PIX_FMT_HEVC || format==V4L2_PIX_FMT_NV12 ? 0 : -EINVAL;
}
static int iris_vdec_validate_format(iris_inst *inst, u32 format) {return iris_venc_validate_format(inst,format);}
CPP
extract() {
    FUNCTION_PATTERN="$1" awk '$0 ~ ENVIRON["FUNCTION_PATTERN"] {emit=1} emit {print} emit && /^}/ {exit}' "$2" >> "$work/check.cpp"
}
extract '^const struct platform_inst_caps \*iris_get_inst_caps\(' "$iris/iris_utils.c"
extract '^int iris_get_mbpf\(' "$iris/iris_utils.c"
extract '^int iris_check_inst_mbps\(' "$iris/iris_utils.c"
extract '^int iris_check_core_mbps\(' "$iris/iris_utils.c"
extract '^static void iris_sm7675_limit_level\(' "$iris/iris_ctrls.c"
extract '^static void iris_sm7675_limit_caps\(' "$iris/iris_ctrls.c"
extract '^u64 iris_vpu3x_vpu4x_calculate_frequency\(' "$iris/iris_vpu_common.c"
extract '^static u32 iris_calc_bw\(' "$iris/iris_power.c"
extract '^static int iris_vote_interconnects\(' "$iris/iris_power.c"
extract '^static int iris_enum_framesizes\(' "$iris/iris_vidc.c"
extract '^static int iris_enum_frameintervals\(' "$iris/iris_vidc.c"
extract '^int iris_venc_s_param\(' "$iris/iris_venc.c"
extract '^int iris_venc_g_param\(' "$iris/iris_venc.c"
for tag in 'enum hfi_packet_port_type' 'enum hfi_packet_payload_info' 'enum hfi_packet_host_flags'; do
    awk -v tag="$tag" '$0 == tag " {" {emit=1} emit {print} emit && /^};/ {exit}' \
        "$iris/iris_hfi_common.h" >> "$work/check.cpp"
done
awk '$2=="HFI_PROP_FRAME_RATE" {print}' "$iris/iris_hfi_gen2_defines.h" >> "$work/check.cpp"
awk '$2=="HFI_PROPERTY_CONFIG_FRAME_RATE" || $2=="HFI_BUFFER_OUTPUT" {print}' \
    "$iris/iris_hfi_gen1_defines.h" >> "$work/check.cpp"
awk '/^struct hfi_framerate {/ {emit=1} emit {print} emit && /^};/ {exit}' \
    "$iris/iris_hfi_gen1_defines.h" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
static u32 sent_rate, packet_calls;
static int packet_error;
static u32 iris_hfi_gen2_get_port(iris_inst *, u32 plane) {
    assert(plane==V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE); return HFI_PORT_BITSTREAM;
}
static int iris_hfi_gen2_session_set_property(iris_inst *, u32 prop, u32 flags, u32 port,
                                             u32 type, void *data, u32 size) {
    assert(prop==HFI_PROP_FRAME_RATE && flags==HFI_HOST_FLAGS_NONE && port==HFI_PORT_BITSTREAM);
    assert(type==HFI_PAYLOAD_Q16 && size==sizeof(u32));
    sent_rate=*static_cast<u32 *>(data); ++packet_calls; return packet_error;
}
static int hfi_gen1_set_property(iris_inst *, u32 prop, void *data, u32 size) {
    auto packet=static_cast<hfi_framerate *>(data);
    assert(prop==HFI_PROPERTY_CONFIG_FRAME_RATE && size==sizeof(*packet));
    assert(packet->buffer_type==HFI_BUFFER_OUTPUT);
    sent_rate=packet->framerate; ++packet_calls; return packet_error;
}
CPP
extract '^static int iris_hfi_gen2_set_frame_rate\(' "$iris/iris_hfi_gen2_command.c"
extract '^static int iris_hfi_gen1_set_frame_rate\(' "$iris/iris_hfi_gen1_command.c"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    iris_core core{&sm7675_data}; v4l2_format format{}; context ctx{};
    iris_inst inst{&core,ENCODER,V4L2_PIX_FMT_H264,30,30,0,0,&format,{}, {},&ctx};
    core.instances.push_back(&inst);
    file f{&inst};
    auto caps=iris_get_inst_caps(&inst,V4L2_PIX_FMT_H264);
    assert(caps->min_frame_width==128 && caps->max_frame_width==4096 && caps->max_mbpf==34560);
    assert(caps->mb_cycles_vpp==675 && caps->mb_cycles_fw_vpp==48405 && caps->max_mbps==2073600);
    caps=iris_get_inst_caps(&inst,V4L2_PIX_FMT_HEVC);
    assert(caps->min_frame_width==96 && caps->max_mbps==2088960 && caps->max_frame_rate==480);
    inst.domain=DECODER;
    caps=iris_get_inst_caps(&inst,V4L2_PIX_FMT_H264);
    assert(caps->min_frame_width==96 && caps->mb_cycles_vpp==200 && caps->mb_cycles_vsp==25);
    caps=iris_get_inst_caps(&inst,V4L2_PIX_FMT_VP9);
    assert(caps->max_frame_rate==200 && caps->mb_cycles_vsp==60);
    inst.codec=V4L2_PIX_FMT_HEVC;
    assert(iris_get_inst_caps(&inst,V4L2_PIX_FMT_NV12)->max_mbps==2088960);
    inst.domain=ENCODER; inst.codec=V4L2_PIX_FMT_H264;
    v4l2_frmsizeenum size{}; size.pixel_format=V4L2_PIX_FMT_HEVC;
    assert(iris_enum_framesizes(&f,nullptr,&size)==0 && size.stepwise.min_width==96);
    size.pixel_format=V4L2_PIX_FMT_H264;
    assert(iris_enum_framesizes(&f,nullptr,&size)==0 && size.stepwise.min_width==128);
    v4l2_frmivalenum rate{}; rate.pixel_format=V4L2_PIX_FMT_H264; rate.width=2016; rate.height=2048;
    assert(iris_enum_frameintervals(&f,nullptr,&rate)==0 && rate.stepwise.min.denominator==128);
    rate.width=4096; rate.height=2160;
    assert(iris_enum_frameintervals(&f,nullptr,&rate)==0 && rate.stepwise.min.denominator==60);
    rate.height=2176; assert(iris_enum_frameintervals(&f,nullptr,&rate)==-EINVAL);
    rate.height=4096; assert(iris_enum_frameintervals(&f,nullptr,&rate)==-EINVAL);
    rate.width=96; rate.height=96; rate.pixel_format=V4L2_PIX_FMT_HEVC;
    assert(iris_enum_frameintervals(&f,nullptr,&rate)==0 && rate.stepwise.min.denominator==480);
    rate.pixel_format=V4L2_PIX_FMT_H264; assert(iris_enum_frameintervals(&f,nullptr,&rate)==-EINVAL);
    rate.index=1; assert(iris_enum_frameintervals(&f,nullptr,&rate)==-EINVAL);
    inst.domain=DECODER; rate.index=0; assert(iris_enum_frameintervals(&f,nullptr,&rate)==-ENOTTY);
    core.iris_platform_data=&legacy_data; assert(iris_get_inst_caps(&inst,V4L2_PIX_FMT_HEVC)==&old_caps);
    inst.domain=ENCODER; format.fmt.pix_mp.width=3840; format.fmt.pix_mp.height=2176;
    inst.frame_rate=480; assert(iris_check_inst_mbps(&inst)==0);
    core.iris_platform_data=&sm7675_data; inst.frame_rate=30;
    v4l2_streamparm param{}; param.type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    param.parm.capture.timeperframe={1,60};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==60);
    param.parm.capture.timeperframe={1,64};
    assert(iris_venc_s_param(&inst,&param)==-ENOMEM && inst.frame_rate==60);
    inst.codec=V4L2_PIX_FMT_HEVC;
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==64);
    param.parm.capture.timeperframe={1,65};
    assert(iris_venc_s_param(&inst,&param)==-ENOMEM && inst.frame_rate==64);
    ctx.dst.streaming=true; aggregate_error=-ENOMEM; param.parm.capture.timeperframe={1,30};
    assert(iris_venc_s_param(&inst,&param)==-ENOMEM && inst.frame_rate==64);
    ctx.dst.streaming=false; aggregate_error=0;
    inst.codec=V4L2_PIX_FMT_H264;
    param.parm.capture.timeperframe={2,127};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==64 && inst.frame_rate_q16==4161536);
    auto accepted=inst.frame_rate_q16;
    param.parm.capture.timeperframe={10,636};
    assert(iris_venc_s_param(&inst,&param)==-ENOMEM && inst.frame_rate_q16==accepted);
    assert(iris_check_core_mbps(&inst)==0);
    v4l2_streamparm readback{}; readback.type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    assert(iris_venc_g_param(&inst,&readback)==0 && readback.parm.capture.timeperframe.numerator==65536);
    assert(readback.parm.capture.timeperframe.denominator==accepted);
    param.parm.capture.timeperframe={1001,30000};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==30 && inst.frame_rate_q16==1964115);
    assert(param.parm.capture.timeperframe.numerator==65536 && param.parm.capture.timeperframe.denominator==1964115);
    assert(iris_hfi_gen2_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==0 && sent_rate==1964115);
    assert(iris_hfi_gen1_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==0 && sent_rate==1964115);
    auto calls=packet_calls;
    assert(iris_hfi_gen1_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE)==0 && packet_calls==calls);
    packet_error=-EPIPE;
    assert(iris_hfi_gen2_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==-EPIPE);
    assert(iris_hfi_gen1_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==-EPIPE);
    packet_error=0;
    param.parm.capture.timeperframe={2,0};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==30 && inst.frame_rate_q16==(30U<<16));
    param.type=V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    param.parm.output.timeperframe={1001,60000};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.operating_rate==60 && inst.operating_rate_q16==3928231);
    param.type=V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    format.fmt.pix_mp.width=1280; format.fmt.pix_mp.height=736;
    param.parm.capture.timeperframe={1,480};
    assert(iris_venc_s_param(&inst,&param)==0 && inst.frame_rate==480);
    inst.frame_rate=30; inst.operating_rate=30; inst.frame_rate_q16=inst.operating_rate_q16=0;
    assert(iris_hfi_gen2_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==0 && sent_rate==(30U<<16));
    assert(iris_hfi_gen1_set_frame_rate(&inst,V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE)==0 && sent_rate==(30U<<16));
    inst.fw_caps[STAGE].value=STAGE_2;
    format.fmt.pix_mp.width=1920; format.fmt.pix_mp.height=1088;
    // Encoder has no PIPE firmware capability; platform pipes must prevent divide-by-zero.
    assert(inst.fw_caps[PIPE].value==0);
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==96462774);
    inst.domain=DECODER; assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==ULONG_MAX);
    inst.fw_caps[PIPE].value=2;
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)>0);
    format.fmt.pix_mp.width=3840; format.fmt.pix_mp.height=2160;
    inst.codec=V4L2_PIX_FMT_VP9; inst.frame_rate=30;
    inst.operating_rate=platform_inst_cap_sm7675.max_mbps/platform_inst_cap_sm7675.max_mbpf;
    assert(inst.operating_rate==60);
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==241156936);
    assert(iris_vote_interconnects(&inst)==0 && inst.icc_data.fps==60 && inst.power.icc_bw==1608000);
    inst.frame_rate=90;
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==361735404);
    assert(iris_vote_interconnects(&inst)==0 && inst.icc_data.fps==90);
    interconnect_error=-EIO;
    assert(iris_vote_interconnects(&inst)==-EIO);
    interconnect_error=0; inst.frame_rate=30; inst.operating_rate=0;
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==113485617);
    assert(iris_vote_interconnects(&inst)==0 && inst.icc_data.fps==30 && inst.power.icc_bw==826000);
    core.iris_platform_data=&legacy_data; inst.operating_rate=60;
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==226971234);
    core.iris_platform_data=&sm7675_data; inst.operating_rate=0;
    inst.domain=ENCODER;
    const auto encoder_frequency=iris_vpu3x_vpu4x_calculate_frequency(&inst,10000);
    inst.operating_rate=60;
    assert(iris_vpu3x_vpu4x_calculate_frequency(&inst,10000)==encoder_frequency);
    assert(iris_vote_interconnects(&inst)==0 && inst.icc_data.fps==30);
    inst.domain=DECODER;
    for (unsigned domain=0; domain<2; ++domain) {
        auto table=domain ? core.inst_fw_caps_enc : core.inst_fw_caps_dec;
        for (unsigned id=1; id<INST_FW_CAP_MAX; ++id)
            table[id]={static_cast<platform_inst_fw_cap_type>(id),0,63,INT64_MAX,63,0,{},nullptr};
    }
    core.inst_fw_caps_enc[BITRATE].max=245000000;
    core.inst_fw_caps_enc[BITRATE].value=200000000;
    core.iris_platform_data=&legacy_data;
    iris_sm7675_limit_caps(&core); assert(core.inst_fw_caps_enc[BITRATE].max==245000000);
    core.iris_platform_data=&sm7675_data; iris_sm7675_limit_caps(&core);
    assert(core.inst_fw_caps_enc[BITRATE].max==100000000 && core.inst_fw_caps_enc[BITRATE].value==100000000);
    assert(core.inst_fw_caps_enc[LEVEL_H264].max==V4L2_MPEG_VIDEO_H264_LEVEL_5_2);
    assert(core.inst_fw_caps_dec[LEVEL_HEVC].max==V4L2_MPEG_VIDEO_HEVC_LEVEL_5_1);
    assert(core.inst_fw_caps_dec[LEVEL_VP9].max==V4L2_MPEG_VIDEO_VP9_LEVEL_5_1);
    assert(!(core.inst_fw_caps_enc[LEVEL_HEVC].step_or_mask & BIT(V4L2_MPEG_VIDEO_HEVC_LEVEL_6)));
    assert(!(core.inst_fw_caps_enc[PROFILE_HEVC].step_or_mask & BIT(V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN_10)));
    assert(core.inst_fw_caps_dec[PROFILE_HEVC].step_or_mask & BIT(V4L2_MPEG_VIDEO_HEVC_PROFILE_MAIN_10));
    for (unsigned id=LAYER0_BITRATE_H264; id<=LAYER5_BITRATE_HEVC; ++id)
        assert(core.inst_fw_caps_enc[id].max<=100000000);
    puts("Actual SM7675 codec caps: profile/level/bitrate, dimensions, rate budgets, rollback and encoder pipes: PASS");
}
CPP
"${CXX:-g++}" -std=c++20 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -I "$iris" "$work/check.cpp" -o "$work/check"
"$work/check"
