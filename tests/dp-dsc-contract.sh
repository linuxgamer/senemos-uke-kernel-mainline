#!/usr/bin/env bash
# Host-only execution of production DSC and upstream RC/PPS helpers; no AUX I/O.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel tree}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cmp "$root/src/display/dp_dsc.c" "$kernel/drivers/gpu/drm/msm/dp/dp_dsc.c"
cmp "$root/src/display/dp_dsc.h" "$kernel/drivers/gpu/drm/msm/dp/dp_dsc.h"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
extract() {
    awk -v name="$2" '
      $0 ~ "^(static )?(inline )?((unsigned )?(int|void|u8|u16|u32|bool) )?" name "\\(" {
        if ($0 ~ "^" name) print previous;
        emit=1
      }
      emit {print} emit && /^}/ {exit} {previous=$0}' "$1"
}
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <endian.h>
#define U16_MAX UINT16_MAX
typedef uint8_t u8; typedef uint16_t u16, __be16; typedef uint32_t u32;
typedef uint64_t u64; typedef int64_t s64;
#define __packed __attribute__((packed))
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((UINT32_MAX>>(31-(h))) & (UINT32_MAX<<(l)))
#define FIELD_GET(mask,value) (((value)&(mask)) >> __builtin_ctz(mask))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define DIV_ROUND_UP_ULL(n,d) DIV_ROUND_UP(n,d)
#define ALIGN(n,a) (((n)+((a)-1))&~((a)-1))
#define min(a,b) ((a)<(b)?(a):(b))
#define max(a,b) ((a)>(b)?(a):(b))
#define cpu_to_be16(v) htobe16(v)
#define BUILD_BUG_ON(v) _Static_assert(!(v),#v)
static bool warn_on(bool value) { return value; }
#define WARN_ON_ONCE(v) warn_on(v)
#define WARN_ON(v) ((void)(v))
#define DRM_DEBUG_KMS(...) ((void)0)
#define EXPORT_SYMBOL(v)
#define WRITE_ONCE(value,new_value) ((value)=(new_value))
#define drm_dbg_dp(...) ((void)0)
#define container_of(ptr,type,member) ((type *)((char *)(ptr)-offsetof(type,member)))
static u64 mul_u32_u32(u32 a,u32 b) { return (u64)a*b; }
struct drm_display_mode { int clock, hdisplay, vdisplay; unsigned int flags; };
#define DRM_MODE_FLAG_INTERLACE (1U<<4)
C
sed '/^#include /d' "$kernel/include/drm/display/drm_dp.h"
sed '/^#include /d' "$kernel/include/drm/display/drm_dsc.h"
sed '/^#include /d' "$kernel/include/drm/display/drm_dsc_helper.h"
grep -E '^#define (DP_DSC_RECEIVER_CAP_SIZE|DRM_DP_BW_OVERHEAD_)' "$kernel/include/drm/display/drm_dp_helper.h"
for name in drm_dp_sink_supports_dsc drm_dp_dsc_sink_max_slice_width drm_dp_dsc_sink_supports_format; do
    extract "$kernel/include/drm/display/drm_dp_helper.h" "$name"
done
for name in drm_dp_dsc_sink_bpp_incr drm_dp_dsc_slice_count_to_mask drm_dp_dsc_sink_slice_count_mask drm_dp_dsc_sink_line_buf_depth dsc_sink_min_slice_throughput drm_dp_dsc_sink_max_slice_throughput drm_dp_link_data_symbol_cycles drm_dp_link_symbol_cycles drm_dp_bw_overhead; do
    extract "$kernel/drivers/gpu/drm/display/drm_dp_helper.c" "$name"
done
awk '/^static void drm_dsc_dump_config_main_params/ {exit} !/^#include / {print}' "$kernel/drivers/gpu/drm/display/drm_dsc_helper.c"
for name in msm_dp_utils_get_g0_value msm_dp_utils_get_g1_value msm_dp_utils_calculate_parity; do
    extract "$kernel/drivers/gpu/drm/msm/dp/dp_utils.c" "$name"
done
sed '/^#include /d' "$root/src/display/dp_dsc.h"
sed '/^#include /d' "$root/src/display/dp_dsc.c"
sed '/^#include /d' "$kernel/drivers/gpu/drm/msm/dp/dp_reg.h"
cat <<'C'
struct msm_dp_panel { struct msm_dp_dsc_config dsc; bool dsc_active; u8 fec_cap; };
struct msm_dp_panel_private { struct msm_dp_panel msm_dp_panel; };
struct msm_dp_ctrl_private { bool fec_prepared,link_clks_on; void *aux,*drm_dev; };
static u32 link_regs[0x500/4],p0_regs[0x100/4];
static unsigned link_writes,p0_writes,reads,aux_writes,delays;
static u32 first_dto;
static bool dto_seen;
static int read_error,write_error; static unsigned detect_after;
static u32 aux_registers[8]; static u8 aux_values[8];
static void msm_dp_write_link(void *p,u32 offset,u32 value) {
 (void)p; assert(!(offset&3) && offset<sizeof(link_regs));
 link_regs[offset/4]=value; link_writes++;
}
static u32 msm_dp_read_link(void *p,u32 offset) {
 (void)p; assert(!(offset&3) && offset<sizeof(link_regs)); return link_regs[offset/4];
}
static void msm_dp_write_pn(void *p,u32 offset,u32 value) {
 if(offset==MMSS_DP_DSC_DTO && !dto_seen) {first_dto=value;dto_seen=true;}
 (void)p; assert(!(offset&3) && offset<sizeof(p0_regs)); p0_regs[offset/4]=value; p0_writes++;
}
static __attribute__((unused)) u32 msm_dp_read_pn(void *p,u32 offset) {
 (void)p; assert(!(offset&3) && offset<sizeof(p0_regs)); return p0_regs[offset/4];
}
static u32 get_unaligned_le32(const void *p) { u32 value; memcpy(&value,p,4); return le32toh(value); }
static int drm_dp_dpcd_read_byte(void *aux,u32 reg,u8 *value) {
 (void)aux;
 if(reg!=DP_FEC_STATUS) {
  assert(reg==DP_DSC_ENABLE || reg==DP_FEC_CONFIGURATION);*value=1;return 0;
 }
 reads++;
 if(read_error)return read_error;
 *value=reads>=detect_after?DP_FEC_DECODE_EN_DETECTED:0; return 0;
}
static int drm_dp_dpcd_write_byte(void *aux,u32 reg,u8 value) {
 (void)aux; assert(reg==DP_DSC_ENABLE || reg==DP_FEC_CONFIGURATION);
 assert(aux_writes<ARRAY_SIZE(aux_registers));
 aux_registers[aux_writes]=reg; aux_values[aux_writes]=value; aux_writes++;
 if(write_error && aux_writes==(unsigned)write_error)return -EIO;
 return 0;
}
static bool msm_dp_aux_is_link_connected(void *aux) { (void)aux; return true; }
static void usleep_range(unsigned lo,unsigned hi) { assert(lo==900 && hi==1000); delays++; }
C
for name in msm_dp_panel_config_dto msm_dp_panel_clear_dsc_dto msm_dp_panel_config_dsc; do
    extract "$kernel/drivers/gpu/drm/msm/dp/dp_panel.c" "$name"
done
for name in msm_dp_ctrl_fec_enable msm_dp_ctrl_fec_disable; do
    extract "$kernel/drivers/gpu/drm/msm/dp/dp_ctrl.c" "$name"
done
cat <<'C'
static const u8 receiver[16]={0x01,0x21,0x00,0x14,0x0b,0x02,0x01,0,0,0x1f,0x06,0x11,0x08,0,0,0};
static void rejected(u8 *caps,u8 fec,struct drm_display_mode mode,unsigned bpc,unsigned rate,unsigned lanes) {
 struct msm_dp_dsc_config out; memset(&out,0xa5,sizeof(out));
 assert(msm_dp_dsc_prepare(caps,fec,&mode,bpc,rate,lanes,&out)<0);
 const u8 *p=(const u8 *)&out; for(size_t i=0;i<sizeof(out);i++)assert(!p[i]);
}
int main(void) {
 struct drm_display_mode mode={.clock=241500,.hdisplay=2560,.vdisplay=1440};
 struct msm_dp_dsc_config out;
 for(unsigned bpc=8;bpc<=10;bpc+=2) for(unsigned hz=60;hz<=75;hz+=15) {
  mode.clock=hz==60?241500:299890;
  assert(!msm_dp_dsc_prepare(receiver,1,&mode,bpc,540000,2,&out));
  assert(out.dsc.bits_per_component==bpc && out.dsc.bits_per_pixel==128);
  assert(out.dsc.pic_width==2560 && out.dsc.pic_height==1440);
  assert(out.dsc.slice_width*out.dsc.slice_count==2560 && out.dsc.slice_count==1);
  assert(out.dsc.slice_chunk_size==2560 && out.dto_count==426);
  /* Exact OEM DP padding/packet fields; generic DSI eol_byte_num differs. */
  assert(out.compression_ctrl==0x0a002811);
  assert(out.dsc.rc_model_size==8192 && out.dsc.initial_xmit_delay>0);
  struct drm_dsc_picture_parameter_set pps; drm_dsc_pps_payload_pack(&pps,&out.dsc);
  const u8 *bytes=(const u8 *)&pps;
  assert(sizeof(pps)==128 && bytes[0]==0x12);
  assert(bytes[6]==0x05 && bytes[7]==0xa0 && bytes[8]==0x0a && bytes[9]==0x00);
  for(unsigned i=88;i<128;i++)assert(!bytes[i]);
  struct msm_dp_panel_private panel={.msm_dp_panel.dsc=out};
  for(unsigned i=0;i<ARRAY_SIZE(link_regs);i++)link_regs[i]=0xdeadbeef;
  link_regs[REG_DP_SDP_FLUSH/4]=hz==60?0x40000008:0x4000000c;
  memset(p0_regs,0,sizeof(p0_regs)); link_writes=p0_writes=0; dto_seen=false;
  p0_regs[MMSS_DP_TIMING_ENGINE_EN/4]=0x80000001;
  msm_dp_panel_config_dsc(&panel.msm_dp_panel);
  assert(dto_seen && first_dto==BIT(1));
  assert(p0_regs[MMSS_DP_DSC_DTO/4]==0x3010b);
  msm_dp_panel_config_dto(&panel.msm_dp_panel,false);
  assert(link_regs[REG_DP_PPS_HEADER/4]==0x7f1000);
  assert(link_regs[REG_DP_PPS_HEADER_PARITY/4]==0xa22300);
  assert(link_regs[REG_DP_COMPRESSION_MODE_CTRL/4]==out.compression_ctrl);
  assert(p0_regs[MMSS_DP_DSC_DTO_COUNT/4]==426 && p0_regs[MMSS_DP_DSC_DTO/4]==0x30109);
  assert(p0_regs[MMSS_DP_TIMING_ENGINE_EN/4]==0x80000101);
  assert(link_writes==34 && p0_writes==5);
  assert(link_regs[REG_DP_SDP_FLUSH/4]==0x40000009);
  for(unsigned i=0;i<22;i++)assert(link_regs[(REG_DP_PPS_DATA/4)+i]==get_unaligned_le32(bytes+i*4));
  for(unsigned i=0;i<ARRAY_SIZE(link_regs);i++) {
   u32 offset=i*4;
   if(offset==REG_DP_COMPRESSION_MODE_CTRL || offset==REG_DP_SDP_FLUSH ||
      (offset>=REG_DP_PPS_HEADER && offset<REG_DP_PPS_DATA+88))continue;
   assert(link_regs[i]==0xdeadbeef);
  }
  memset(&panel.msm_dp_panel.dsc,0,sizeof(panel.msm_dp_panel.dsc));
  link_writes=p0_writes=0; dto_seen=false; p0_regs[MMSS_DP_TIMING_ENGINE_EN/4]&=~BIT(8);
  msm_dp_panel_config_dsc(&panel.msm_dp_panel);
  assert(dto_seen && first_dto==BIT(1) && p0_regs[MMSS_DP_DSC_DTO/4]==BIT(1));
  msm_dp_panel_config_dto(&panel.msm_dp_panel,false);
  assert(!link_regs[REG_DP_COMPRESSION_MODE_CTRL/4] && !p0_regs[MMSS_DP_DSC_DTO/4]);
  assert(p0_regs[MMSS_DP_TIMING_ENGINE_EN/4]==0x80000101);
  assert(link_writes==1 && p0_writes==3);
  p0_regs[MMSS_DP_DSC_DTO/4]=0x8003010b;
  msm_dp_panel_config_dto(&panel.msm_dp_panel,false);
  assert(p0_regs[MMSS_DP_DSC_DTO/4]==0x80030109);
  msm_dp_panel_config_dto(&panel.msm_dp_panel,true);
  assert(p0_regs[MMSS_DP_DSC_DTO/4]==BIT(1));
 }
 mode=(struct drm_display_mode){.clock=594000,.hdisplay=3840,.vdisplay=2160};
 assert(!msm_dp_dsc_prepare(receiver,1,&mode,10,540000,2,&out));
 assert(out.dsc.slice_count==2 && out.dsc.slice_width==1920 && out.dsc.slice_chunk_size==1920);
 assert(out.dto_count==639);
 assert(out.compression_ctrl==0x07802821);
 assert(!msm_dp_dsc_link_fits(&out,&mode,162000,2));
 mode.hdisplay=1922;mode.clock=241500;mode.vdisplay=1440;
 assert(!msm_dp_dsc_prepare(receiver,1,&mode,10,540000,2,&out));
 assert(out.dsc.slice_count==1 && out.compression_ctrl==0x07822809);
 mode=(struct drm_display_mode){.clock=594000,.hdisplay=3840,.vdisplay=2160};
 u8 caps[16]; memcpy(caps,receiver,16);
 rejected(caps,0,mode,10,540000,2); rejected(caps,1,mode,12,540000,2);
 rejected(caps,1,mode,10,540000,3); rejected(caps,1,mode,10,162000,1);
 mode.clock=0; rejected(caps,1,mode,10,540000,2); mode.clock=594000;
 mode.hdisplay=3839; rejected(caps,1,mode,10,540000,2); mode.hdisplay=3840;
 mode.flags=DRM_MODE_FLAG_INTERLACE; rejected(caps,1,mode,10,540000,2); mode.flags=0;
 mode.vdisplay=2161; rejected(caps,1,mode,10,540000,2); mode.vdisplay=2160;
 mode.vdisplay=-16; rejected(caps,1,mode,10,540000,2);
 mode.vdisplay=65536; rejected(caps,1,mode,10,540000,2); mode.vdisplay=2160;
 mode.hdisplay=-2560; rejected(caps,1,mode,10,540000,2);
 mode.hdisplay=65536; rejected(caps,1,mode,10,540000,2); mode.hdisplay=3840;
 for(unsigned offset=0;offset<16;offset++) {
  memcpy(caps,receiver,16); caps[offset]=0;
  if(offset==0 || offset==1 || offset==4 || offset==5 || offset==9 || offset==10 || offset==12)
   rejected(caps,1,mode,10,540000,2);
 }
 assert(msm_dp_utils_calculate_parity(0x10)==0x23);
 assert(msm_dp_utils_calculate_parity(0x7f)==0xa2);
 for(u32 value=0;value<10000;value++) {
  u32 word=value*2654435761U;
  u8 reference=(word&0xff00)?msm_dp_utils_calculate_parity(word):
   msm_dp_utils_calculate_parity(word^0x100)^msm_dp_utils_calculate_parity(0x100);
  assert(msm_dp_dsc_word_parity(word)==reference);
 }
 assert(msm_dp_dsc_word_parity(0x12000000)!=msm_dp_utils_calculate_parity(0x12000000));
 struct msm_dp_ctrl_private ctrl={.link_clks_on=true}; struct msm_dp_panel panel={};
 reads=aux_writes=delays=0;
 assert(!msm_dp_ctrl_fec_enable(&ctrl,&panel) && !reads && !aux_writes && !delays);
 ctrl.fec_prepared=true; detect_after=3; link_regs[REG_DP_MAINLINK_CTRL/4]=BIT(6);
 assert(!msm_dp_ctrl_fec_enable(&ctrl,&panel) && reads==3 && delays==3);
 assert(panel.dsc_active && aux_writes==2 && aux_registers[0]==DP_DSC_ENABLE && aux_values[0]==DP_DECOMPRESSION_EN);
 assert(aux_registers[1]==DP_FEC_CONFIGURATION&&aux_values[1]==DP_FEC_READY);
 assert(link_regs[REG_DP_MAINLINK_CTRL/4]&BIT(6));
 aux_writes=0; assert(!msm_dp_ctrl_fec_disable(&ctrl,&panel));
 assert(!panel.dsc_active && !ctrl.fec_prepared && aux_writes==2);
 assert(aux_registers[0]==DP_DSC_ENABLE && !aux_values[0] &&
        aux_registers[1]==DP_FEC_CONFIGURATION && !aux_values[1]);
 assert(!(link_regs[REG_DP_MAINLINK_CTRL/4]&BIT(12)));
 ctrl.fec_prepared=true; reads=aux_writes=delays=0; detect_after=4;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-ETIMEDOUT && reads==3 && !aux_writes && !panel.dsc_active);
 read_error=-EIO; reads=0;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-EIO && reads==1 && !panel.dsc_active); read_error=0;
 detect_after=1; reads=aux_writes=0; write_error=1;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-EIO && !panel.dsc_active);
 for(int fault=1;fault<=2;fault++) {
  aux_writes=0; write_error=fault; panel.dsc_active=true;
  assert(msm_dp_ctrl_fec_disable(&ctrl,&panel)==-EIO);
  assert(!panel.dsc_active && ctrl.fec_prepared && aux_writes==2);
 }
 aux_writes=0; write_error=0; ctrl.link_clks_on=false; link_writes=0;
 assert(!msm_dp_ctrl_fec_disable(&ctrl,&panel) && !ctrl.fec_prepared && !link_writes);
 puts("Production DSC/RC/PPS, bounded registers/DTO, 4K geometry, FEC ACK/timeout/cleanup and full-word parity: PASS; host only");
}
C
} > "$work/test.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare "$work/test.c" -o "$work/test"
"$work/test"
