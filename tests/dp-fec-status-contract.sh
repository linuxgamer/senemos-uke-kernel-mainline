#!/usr/bin/env bash
# Exercise the real FEC setup/enable functions with a latched receiver status.
set -Eeuo pipefail
ulimit -c 0
ulimit -c 0
source=${1:?Pass prepared dp_ctrl.c}
registers=$(dirname -- "$source")/dp_reg.h
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <stdio.h>
typedef uint8_t u8; typedef uint32_t u32;
#define __packed __attribute__((packed))
#define BIT(n) (1U<<(n))
#define GENMASK(h,l) ((~0U<<(l))&(~0U>>(31-(h))))
#define WRITE_ONCE(v,n) ((v)=(n))
#define drm_dbg_dp(...) ((void)0)
#define container_of(p,type,member) ((type *)((char *)(p)-offsetof(type,member)))
C
sed '/^#include /d' "$(dirname -- "$source")/../../../../../include/drm/display/drm_dp.h"
sed '/^#include /d' "$registers"
cat <<'C'
struct msm_dp_panel {
 bool dsc_active; u8 fec_cap; unsigned stream_id;
 struct {struct {unsigned bits_per_pixel;} dsc;} dsc;
 struct {unsigned bpp; bool out_fmt_is_yuv_420;} msm_dp_mode;
 struct {unsigned version;} psr_cap;
};
struct msm_dp_link { unsigned sink_request; };
struct msm_dp_ctrl { int unused; };
struct device { void *of_node; };
struct msm_dp_ctrl_private {
 struct msm_dp_ctrl msm_dp_ctrl;
 bool fec_prepared,link_clks_on,stream_clks_on[2];
 void *aux,*drm_dev,*pixel_clk[2];struct msm_dp_link *link;
 struct device *dev;unsigned num_pixel_clks;
};
static bool sm7675,clock_live[2],expect_ack;
static unsigned dto_acks,clock_stops;
static bool of_device_is_compatible(void *node,const char *name) {
 (void)node;(void)name;return sm7675;
}
static void msm_dp_panel_config_dto(struct msm_dp_panel *panel,bool ack) {
 assert(ack&&panel->stream_id<2&&clock_live[panel->stream_id]);dto_acks++;
}
static void clk_disable_unprepare(void *clock) {
 bool *live=clock;assert(*live&&dto_acks==(expect_ack?1U:0U));
 *live=false;clock_stops++;
}
static u32 mainlink;
static u8 status, receiver_config, receiver_decoder;
static unsigned writes,reads,training,detect_after;
static int write_error,read_error,training_error;
static u32 addresses[8]; static u8 values[8];
static u32 rejected_readback;
static bool reject_selector;
static int readback_error;
static u32 stream_config[2];
static u32 msm_dp_read_stream_link(void *ctrl,unsigned id,u32 reg) {
 (void)ctrl;assert(id<2&&reg==REG_DP_CONFIGURATION_CTRL);return stream_config[id];
}
static void msm_dp_write_stream_link(void *ctrl,unsigned id,u32 reg,u32 value) {
 (void)ctrl;assert(id<2&&reg==REG_DP_CONFIGURATION_CTRL);stream_config[id]=value;
}
static u32 msm_dp_link_get_test_bits_depth(void *link,unsigned bpp) {
 (void)link;assert(bpp==18||bpp==24||bpp==30);return bpp/6-3;
}
static u32 msm_dp_read_link(void *p,u32 reg) { (void)p; assert(reg==REG_DP_MAINLINK_CTRL); return mainlink; }
static void msm_dp_write_link(void *p,u32 reg,u32 value) { (void)p; assert(reg==REG_DP_MAINLINK_CTRL); mainlink=value; }
static void msm_dp_ctrl_mainlink_enable(void *p) { (void)p; mainlink|=BIT(0); }
static int drm_dp_dpcd_write_byte(void *aux,u32 reg,u8 value) {
 (void)aux; assert(writes<8); addresses[writes]=reg; values[writes++]=value;
 if(write_error && writes==(unsigned)write_error)return -EIO;
 if(reg==DP_FEC_STATUS)status&=~value;
 else if(reg==DP_FEC_CONFIGURATION)receiver_config=value;
 else {assert(reg==DP_DSC_ENABLE);receiver_decoder=value;}
 return 0;
}
static int drm_dp_dpcd_read_byte(void *aux,u32 reg,u8 *value) {
 (void)aux;
 if(reg!=DP_FEC_STATUS) {
  assert(reg==DP_DSC_ENABLE || reg==DP_FEC_CONFIGURATION);
  if(readback_error)return readback_error;
  *value=reg==rejected_readback?0:(reg==DP_DSC_ENABLE?receiver_decoder:receiver_config);
  if(reg==DP_FEC_CONFIGURATION&&reject_selector)*value&=~DP_FEC_ERR_COUNT_SEL_MASK;
  return 0;
 }
 reads++;
 if(read_error)return read_error;
 if(detect_after && reads>=detect_after)status|=DP_FEC_DECODE_EN_DETECTED;
 *value=status; return 0;
}
static void usleep_range(unsigned lo,unsigned hi) { assert(lo==900 && hi==1000); }
static int msm_dp_ctrl_link_train(struct msm_dp_ctrl_private *ctrl,struct msm_dp_panel *panel,int *step) {
 (void)panel; (void)step; training++;
 if(ctrl->fec_prepared)assert(!status && writes==2 &&
  addresses[0]==DP_FEC_CONFIGURATION && values[0]==DP_FEC_READY &&
  addresses[1]==DP_FEC_STATUS && values[1]==(DP_FEC_DECODE_EN_DETECTED|DP_FEC_DECODE_DIS_DETECTED));
 return training_error;
}
C
for name in msm_dp_ctrl_config_ctrl_streams msm_dp_ctrl_fec_enable msm_dp_ctrl_setup_main_link msm_dp_ctrl_off_pixel_clk; do
    awk -v name="$name" '$0 ~ "^(static )?(int|void) " name "\\(" {emit=1} emit{print} emit&&/^}/{exit}' "$source"
done
cat <<'C'
static void reset(void) {
 status=DP_FEC_DECODE_EN_DETECTED|DP_FEC_DECODE_DIS_DETECTED;
 writes=reads=training=detect_after=0;write_error=read_error=training_error=0;
 receiver_config=receiver_decoder=0;reject_selector=false;
 mainlink=BIT(6)|BIT(12);
}
int main(void) {
 struct msm_dp_link link={0};struct msm_dp_ctrl_private ctrl={.link=&link};
 struct msm_dp_panel panel={0};int step=0;
 for(unsigned id=0;id<2;id++)for(unsigned bpp=18;bpp<=30;bpp+=6)
  for(unsigned compressed=0;compressed<2;compressed++) {
   if(compressed&&bpp==18)continue;
   panel.stream_id=id;panel.msm_dp_mode.bpp=bpp;
   panel.dsc.dsc.bits_per_pixel=compressed?128:0;
   stream_config[id]=BIT(31)|DP_CONFIGURATION_CTRL_BPC_MASK|
    DP_CONFIGURATION_CTRL_RGB_YUV_MASK|DP_CONFIGURATION_CTRL_SEND_VSC;
   stream_config[1-id]=BIT(7);
   msm_dp_ctrl_config_ctrl_streams(&ctrl,&panel);
   assert(stream_config[id]==(BIT(31)|((compressed?1:bpp/6-3)<<DP_CONFIGURATION_CTRL_BPC_SHIFT)));
   assert(stream_config[1-id]==BIT(7));
  }
 panel=(struct msm_dp_panel){0};
 reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 assert(!writes && training==1 && status==3);
 ctrl.fec_prepared=true;link.sink_request=DP_TEST_LINK_PHY_TEST_PATTERN;
 reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));assert(!writes && !training);
 link.sink_request=0;reset();panel.dsc_active=true;
 assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 assert(!panel.dsc_active && !status && training==1 && (mainlink&BIT(6)) && !(mainlink&BIT(12)));
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-ETIMEDOUT);
 assert(reads==3 && writes==2 && !panel.dsc_active);
 reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 detect_after=2;assert(!msm_dp_ctrl_fec_enable(&ctrl,&panel));
 assert(reads==2 && writes==4 && addresses[2]==DP_DSC_ENABLE &&
  values[2]==DP_DECOMPRESSION_EN && panel.dsc_active);
 assert(addresses[3]==DP_FEC_CONFIGURATION&&values[3]==DP_FEC_READY);
 panel.fec_cap=DP_FEC_UNCORR_BLK_ERROR_COUNT_CAP;reset();
 assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 assert(values[0]==DP_FEC_READY);detect_after=1;
 assert(!msm_dp_ctrl_fec_enable(&ctrl,&panel)&&panel.dsc_active);
 assert(writes==4&&addresses[3]==DP_FEC_CONFIGURATION&&
  values[3]==(DP_FEC_READY|DP_FEC_UNCORR_BLK_ERROR_COUNT));
 reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 detect_after=1;reject_selector=true;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-EIO&&!panel.dsc_active);
 reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 detect_after=1;write_error=4;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-EIO&&!panel.dsc_active);
 panel.fec_cap=0;
 for(unsigned reg=DP_FEC_CONFIGURATION;reg<=DP_DSC_ENABLE;reg+=DP_DSC_ENABLE-DP_FEC_CONFIGURATION) {
  reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
  detect_after=1;rejected_readback=reg;
  assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-EIO&&!panel.dsc_active);
 }
 rejected_readback=0;reset();assert(!msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step));
 detect_after=1;readback_error=-ETIMEDOUT;
 assert(msm_dp_ctrl_fec_enable(&ctrl,&panel)==-ETIMEDOUT&&!panel.dsc_active);readback_error=0;
 for(int failure=1;failure<=2;failure++) {
  reset();write_error=failure;panel.dsc_active=true;
  assert(msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step)==-EIO);
  assert(!training && !panel.dsc_active && ctrl.fec_prepared);
 }
 reset();training_error=-ETIMEDOUT;
 assert(msm_dp_ctrl_setup_main_link(&ctrl,&panel,&step)==-ETIMEDOUT);
 assert(training==1 && !status && !panel.dsc_active);
 struct device dev={0};ctrl.dev=&dev;ctrl.num_pixel_clks=2;
 for(unsigned managed=0;managed<2;managed++)for(unsigned link_on=0;link_on<2;link_on++)
  for(unsigned id=0;id<2;id++) {
   sm7675=managed;ctrl.link_clks_on=link_on;expect_ack=managed&&link_on;
   panel.stream_id=id;ctrl.stream_clks_on[id]=clock_live[id]=true;
   ctrl.pixel_clk[id]=&clock_live[id];dto_acks=clock_stops=0;
   msm_dp_ctrl_off_pixel_clk(&ctrl.msm_dp_ctrl,&panel);
   assert(!ctrl.stream_clks_on[id]&&!clock_live[id]&&clock_stops==1);
   assert(dto_acks==(expect_ack?1U:0U));
   dto_acks=clock_stops=0;msm_dp_ctrl_off_pixel_clk(&ctrl.msm_dp_ctrl,&panel);
   assert(!dto_acks&&!clock_stops);
  }
 msm_dp_ctrl_off_pixel_clk(&ctrl.msm_dp_ctrl,NULL);
 panel.stream_id=2;msm_dp_ctrl_off_pixel_clk(&ctrl.msm_dp_ctrl,&panel);
 panel.stream_id=~0U;msm_dp_ctrl_off_pixel_clk(&ctrl.msm_dp_ctrl,&panel);
 assert(!dto_acks&&!clock_stops);
 puts("Production DSC packetizer, FEC ACK/errors and clock-guarded DTO quiescence: PASS; host only.");
}
C
} > "$work/test.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -fsanitize=undefined -fsanitize-undefined-trap-on-error "$work/test.c" -o "$work/test"
"$work/test"
