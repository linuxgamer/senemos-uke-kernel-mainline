#!/usr/bin/env bash
# Host-only production TU calculations; no device or firmware access.
set -Eeuo pipefail
ulimit -c 0
kernel=${1:?Pass the prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32;
typedef uint64_t u64,__u64; typedef int64_t s64; typedef unsigned uint;
#define BIT(n) (1U<<(n))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define kzalloc_obj(v) calloc(1,sizeof(v))
#define kfree(v) free(v)
#define drm_dbg_dp(...) ((void)0)
#define pr_info(...) ((void)0)
#define pr_debug(...) ((void)0)
#define pr_warn(...) ((void)0)
static s64 div64_s64(s64 a,s64 b){assert(b);return a/b;}
static u64 div64_u64_rem(u64 a,u64 b,u64 *r){assert(b);*r=a%b;return a/b;}
struct msm_dp_ctrl_private { void *drm_dev; };
C
# Retain the upstream fixed-point implementation and its attribution.
head -31 "$kernel/include/drm/drm_fixed.h" | sed '/^#/d'
awk '/^#define DRM_FIXED_POINT/ {emit=1} /^static inline s64 drm_fixp_exp\(/ {exit} emit {print}' "$kernel/include/drm/drm_fixed.h"
awk '/^struct msm_dp_tu_calc_input/ {emit=1} /^struct msm_dp_ctrl_private/ {exit} emit {print}' "$kernel/drivers/gpu/drm/msm/dp/dp_ctrl.c"
awk '/^struct tu_algo_data/ {emit=1} /^static void msm_dp_ctrl_calc_tu_parameters/ {exit} emit {print}' "$kernel/drivers/gpu/drm/msm/dp/dp_ctrl.c"
cat <<'C'
int main(void) {
 const struct {unsigned pclk,width,porch,slices,height;} modes[]={
  {241500,2560,160,1,1440},{299890,2560,140,1,1440},{594000,3840,560,2,2160}
 };
 for(unsigned m=0;m<ARRAY_SIZE(modes);m++) for(unsigned fec=0;fec<2;fec++) {
  struct msm_dp_vc_tu_mapping_table outputs[2]={{0}};
  for(unsigned i=0;i<2;i++) {
   struct msm_dp_tu_calc_input in={.lclk=540,.pclk_khz=modes[m].pclk,
    .hactive=modes[m].width,.hporch=modes[m].porch,.nlanes=2,.bpp=i?30:24,
    .pixel_enc=444,.dsc_en=1,.fec_en=fec,.compress_ratio=i?375:300,
    .num_of_dsc_slices=modes[m].slices};
   struct tu_algo_data timing={0}; msm_dp_panel_update_tu_timings(&in,&timing);
   const unsigned bytes=modes[m].width+2*modes[m].slices;
   assert(timing.bpp==24);
   assert(llabs(timing.lwidth_fp-drm_fixp_from_fraction(bytes,3))<4);
   /* Upstream fixed-point multiplication discards low bits; clock bounds are in MHz. */
   const s64 clock=drm_fixp_from_fraction(fec?527040:540000,1000);
   assert(llabs(timing.lclk_fp-clock)<drm_fixp_from_fraction(5,1000000));
   const s64 expected_pixel=drm_fixp_from_fraction((s64)modes[m].pclk*bytes,3000*modes[m].width);
   assert(llabs(timing.pclk_fp-expected_pixel)<drm_fixp_from_fraction(1,1000000));
   const s64 symbols=drm_fixp_mul(timing.pclk_fp,drm_fixp_from_fraction(3,2));
   const s64 ratio=drm_fixp_div(symbols,timing.lclk_fp);
   assert(ratio>0 && ratio<(s64)DRM_FIXED_ONE);
   struct msm_dp_ctrl_private ctrl={0}; _dp_ctrl_calc_tu(&ctrl,&in,&outputs[i]);
   const unsigned size=outputs[i].tu_size_minus1+1;
   assert(size>=32 && size<=64);
   assert(outputs[i].valid_boundary_link>0 && outputs[i].valid_boundary_link<=size);
   assert(outputs[i].delay_start_link>0 && outputs[i].delay_start_link<65535);
   if(outputs[i].boundary_moderation_en) {
    assert(outputs[i].upper_boundary_count>0 && outputs[i].upper_boundary_count<=15);
    assert(outputs[i].lower_boundary_count>0 && outputs[i].lower_boundary_count<=15);
   }
  }
  assert(!memcmp(&outputs[0],&outputs[1],sizeof(outputs[0])));
  printf("%ux%u pclk=%u slices=%u FEC=%u: identical 8/10-bpc compressed TU; size=%u valid=%u delay=%u\n",
   modes[m].width,modes[m].height,modes[m].pclk,modes[m].slices,fec,outputs[0].tu_size_minus1+1,
   outputs[0].valid_boundary_link,outputs[0].delay_start_link);
 }
 puts("Production fixed-point/TU source, independent byte-rate/FEC budget and 8/10-bpc equivalence: PASS; host only.");
}
C
} > "$work/test.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare -Wno-pointer-sign -Wno-unused-parameter -Wno-unused-function "$work/test.c" -o "$work/test"
"$work/test"
