#!/usr/bin/env bash
# Actual HFI completion functions; queue submission and buffer ownership are modeled.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#include <linux/videodev2.h>
using u32 = uint32_t;
using u64 = uint64_t;
enum { DECODER=2, ENCODER=1, IRIS_INST_STREAMING=3, DISPLAY_DELAY_ENABLE=0,
       BUF_ATTR_PENDING_RELEASE=2, BUF_ATTR_QUEUED=4, BUF_ATTR_DEQUEUED=8,
       HFI_GEN2_PICTURE_IDR=1, HFI_GEN2_PICTURE_P=2, HFI_GEN2_PICTURE_B=4,
       HFI_GEN2_PICTURE_I=8, HFI_GEN2_PICTURE_CRA=16, HFI_GEN2_PICTURE_BLA=32,
       HFI_GEN2_PICTURE_NOSHOW=64, HFI_BUF_FW_FLAG_READONLY=16,
       HFI_BUF_FW_FLAG_LAST=0x10000000, HFI_BUF_FW_FLAG_PSC_LAST=0x20000000 };
struct iris_hfi_frame_info { u32 picture_type, data_corrupt, overflow; };
struct iris_inst_hfi_gen2 { iris_hfi_frame_info hfi_frame_info; };
struct iris_buffer { u32 index, data_offset, data_size, flags, attr; u64 device_addr, timestamp; };
struct vb2_v4l2_buffer { iris_buffer *buffer; };
struct v4l2_m2m_buffer { vb2_v4l2_buffer vb; };
struct v4l2_m2m_ctx { v4l2_m2m_buffer *first; };
struct platform_inst_fw_cap { u32 value; };
struct iris_inst {
    v4l2_m2m_ctx *m2m_ctx; iris_inst_hfi_gen2 *hfi;
    u32 domain, state; v4l2_format *fmt_src, *fmt_dst;
    platform_inst_fw_cap fw_caps[1];
};
struct iris_hfi_buffer { u32 index, data_offset, data_size, flags; u64 base_address, timestamp; };
static iris_inst_hfi_gen2 *to_iris_inst_hfi_gen2(iris_inst *inst) { return inst->hfi; }
static iris_buffer *to_iris_buffer(vb2_v4l2_buffer *vb) { return vb->buffer; }
#define v4l2_m2m_for_each_dst_buf_safe(ctx, buffer, next) \
    for (buffer=(ctx)->first, next=nullptr; buffer; buffer=next)
static int queued, queue_result, drain, psc;
[[maybe_unused]] static int iris_queue_buffer(iris_inst *, iris_buffer *buffer) {
    ++queued;
    if (buffer->attr != BUF_ATTR_QUEUED || buffer->data_size || buffer->data_offset)
        return -EUCLEAN;
    return queue_result;
}
static int iris_inst_sub_state_change_drain_last(iris_inst *) { ++drain; return 0; }
static int iris_inst_sub_state_change_drc_last(iris_inst *) { ++psc; return 0; }
CPP
for name in iris_hfi_gen2_get_driver_buffer_flags iris_hfi_gen2_handle_output_buffer; do
    awk -v name="$name" '$0 ~ "^static int " name "\\(" {emit=1} emit{print} emit && /^}/{exit}' \
        "$iris/iris_hfi_gen2_response.c" >> "$work/check.cpp"
done
grep -q '^static int iris_hfi_gen2_handle_output_buffer' "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
struct Fixture {
    iris_inst inst{}; iris_inst_hfi_gen2 hfi{}; iris_buffer buffer{};
    v4l2_m2m_buffer entry{}; v4l2_m2m_ctx context{};
    v4l2_format src{}, dst{}; iris_hfi_buffer reply{};
    void reset() {
        inst={}; hfi={}; buffer={}; entry={}; context={}; src={}; dst={}; reply={};
        queued=queue_result=drain=psc=0;
        inst.m2m_ctx=&context; context.first=&entry; entry.vb.buffer=&buffer;
        inst.hfi=&hfi; inst.domain=DECODER; inst.state=IRIS_INST_STREAMING;
        inst.fmt_src=&src; inst.fmt_dst=&dst;
        src.fmt.pix_mp.pixelformat=V4L2_PIX_FMT_VP9;
        dst.fmt.pix_mp.pixelformat=V4L2_PIX_FMT_NV12;
        buffer.index=reply.index=2; buffer.device_addr=reply.base_address=0x1000;
        buffer.attr=BUF_ATTR_QUEUED; buffer.data_size=99;
        hfi.hfi_frame_info.picture_type=HFI_GEN2_PICTURE_P|HFI_GEN2_PICTURE_NOSHOW;
    }
};
static int failures, checks;
static void expect(bool value, const char *name) {
    ++checks;
    if (!value) { std::fprintf(stderr,"FAIL: %s\n",name); ++failures; }
}
int main() {
    Fixture f;
    for (u32 order : {0u,1u}) for (u64 timestamp : {0ull,12000ull})
    for (u32 format : {u32(V4L2_PIX_FMT_NV12),u32(V4L2_PIX_FMT_P010)}) {
        f.reset(); f.dst.fmt.pix_mp.pixelformat=format;
        f.inst.fw_caps[0].value=order; f.reply.timestamp=timestamp;
        expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==0 && queued==1,
               "valid hidden reference recycles one linear capture buffer");
        expect(f.buffer.attr==BUF_ATTR_QUEUED && !f.buffer.data_size && !drain && !psc,
               "capture remains owned, without a displayed frame or stream-end transition");
    }
    f.reset(); queue_result=-EREMOTEIO;
    expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==-EREMOTEIO && queued==1,
           "queue submission failure propagates");
    for (int scenario=0;scenario<13;++scenario) {
        f.reset();
        switch(scenario) {
        case 0: f.hfi.hfi_frame_info.data_corrupt=1; break;
        case 1: f.hfi.hfi_frame_info.overflow=1; break;
        case 2: f.reply.flags=HFI_BUF_FW_FLAG_READONLY; break;
        case 3: f.reply.flags=HFI_BUF_FW_FLAG_LAST; break;
        case 4: f.reply.flags=HFI_BUF_FW_FLAG_PSC_LAST; break;
        case 5: f.buffer.attr|=BUF_ATTR_PENDING_RELEASE; break;
        case 6: f.hfi.hfi_frame_info.picture_type=HFI_GEN2_PICTURE_P; break;
        case 7: f.src.fmt.pix_mp.pixelformat=V4L2_PIX_FMT_H264; break;
        case 8: f.dst.fmt.pix_mp.pixelformat=V4L2_PIX_FMT_YUV420; break;
        case 9: f.inst.domain=ENCODER; break;
        case 10: f.reply.data_size=100; break;
        case 11: f.reply.data_offset=f.buffer.data_offset=16; break;
        case 12: f.inst.state=0; break;
        }
        expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==0 && queued==0 &&
               (f.buffer.flags&V4L2_BUF_FLAG_ERROR) && (f.buffer.attr&BUF_ATTR_DEQUEUED),
               "real errors, ownership and unqualified paths retain original completion");
        if(scenario==3) expect(drain==1 && (f.buffer.flags&V4L2_BUF_FLAG_LAST),"drain LAST retained");
        if(scenario==4) expect(psc==1 && (f.buffer.flags&V4L2_BUF_FLAG_LAST),"PSC LAST retained");
    }
    f.reset(); f.hfi.hfi_frame_info.picture_type=HFI_GEN2_PICTURE_P; f.reply.data_size=4096;
    expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==0 && !queued &&
           f.buffer.data_size==4096 && !(f.buffer.flags&V4L2_BUF_FLAG_ERROR),
           "normal display frame follows its original path");
    f.reset(); f.reply.index=7;
    expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==-EINVAL && !queued,"wrong buffer refused");
    f.reset(); f.buffer.attr=0;
    expect(iris_hfi_gen2_handle_output_buffer(&f.inst,&f.reply)==-EINVAL && !queued,"unowned buffer refused");
    if(failures) return 1;
    std::printf("Actual HFI NOSHOW completion: %d modeled ownership/error checks passed; no hardware.\n",checks);
}
CPP
"${CXX:-g++}" -std=c++17 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
