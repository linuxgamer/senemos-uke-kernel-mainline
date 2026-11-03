#!/usr/bin/env bash
set -Eeuo pipefail
file=${1:?Pass prepared dpu_rm.c}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define MAX_BLOCKS 4
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define LM_0 0
#define PINGPONG_0 0
#define DPU_ERROR(...) ((void)0)
#define DPU_DEBUG(...) ((void)0)
#define trace_dpu_rm_reserve_lms(...) ((void)0)
struct msm_display_topology { unsigned num_lm,num_intf,num_dspp,num_dsc; bool cwb_enabled; };
struct dpu_rm { void *mixer_blks[4]; };
struct dpu_global_state { uint32_t mixer_to_crtc_id[4],pingpong_to_crtc_id[4],dspp_to_crtc_id[4]; };
struct catalog { unsigned dspp_count; } dpu_sm7675_cfg={3},foreign={3};
struct dpu_kms { struct catalog *catalog; };
static bool _dpu_rm_check_lm_and_get_connected_blks(struct dpu_rm *r,struct dpu_global_state *s,uint32_t owner,int i,int *pp,int *dspp,struct msm_display_topology *t) {
 (void)r;
 if(s->mixer_to_crtc_id[i]&&s->mixer_to_crtc_id[i]!=owner)return false;
 if(s->pingpong_to_crtc_id[i]&&s->pingpong_to_crtc_id[i]!=owner)return false;
 *pp=i;
 if(t->num_dspp) {
  if(i==3||(s->dspp_to_crtc_id[i]&&s->dspp_to_crtc_id[i]!=owner))return false;
  *dspp=i;
 }
 return true;
}
static int _dpu_rm_get_lm_peer(struct dpu_rm *r,int i) {(void)r;return i^1;}
static unsigned select_start(struct dpu_kms *kms,struct dpu_rm *rm,struct msm_display_topology *topology) {
 unsigned lm_start=0;(void)kms;(void)rm;(void)topology;
C
awk '/\/\* Leave the bonded panel/{emit=1} emit{print} emit&&/lm_start = kms->catalog->dspp_count - 1;/{exit}' "$file" >> "$work/check.c"
printf ' return lm_start;\n}\n' >> "$work/check.c"
awk '/^static int _dpu_rm_reserve_lms\(/{emit=1} emit{print} emit&&/^}/{exit}' "$file" >> "$work/check.c"
if grep -q 'unsigned int lm_start)' "$file"; then
 printf '#define reserve(r,s,o,t,start) _dpu_rm_reserve_lms(r,s,o,t,start)\n' >> "$work/check.c"
else
 printf '#define reserve(r,s,o,t,start) ((void)(start),_dpu_rm_reserve_lms(r,s,o,t))\n' >> "$work/check.c"
fi
cat >> "$work/check.c" <<'C'
int main(void) {
 struct dpu_rm rm={.mixer_blks={&rm,&rm,&rm,&rm}};
 struct dpu_kms kms={&dpu_sm7675_cfg};
 struct dpu_global_state state={0};
 struct msm_display_topology dp={.num_lm=1,.num_intf=1,.num_dspp=1};
 struct msm_display_topology panel={.num_lm=2,.num_intf=2,.num_dspp=2,.num_dsc=2};
 assert(select_start(&kms,&rm,&dp)==2);
 assert(select_start(&kms,&rm,&panel)==0);
 kms.catalog=&foreign;assert(select_start(&kms,&rm,&dp)==0);kms.catalog=&dpu_sm7675_cfg;
 dp.cwb_enabled=true;assert(select_start(&kms,&rm,&dp)==0);dp.cwb_enabled=false;
 assert(reserve(&rm,&state,2,&dp,select_start(&kms,&rm,&dp))==0);
 assert(state.mixer_to_crtc_id[2]==2&&state.dspp_to_crtc_id[2]==2);
 for(unsigned cycle=0;cycle<5;cycle++) {
  assert(reserve(&rm,&state,1,&panel,0)==0);
  assert(state.mixer_to_crtc_id[0]==1&&state.mixer_to_crtc_id[1]==1);
  assert(state.mixer_to_crtc_id[2]==2&&state.dspp_to_crtc_id[2]==2);
  for(unsigned i=0;i<4;i++) {
   if(state.mixer_to_crtc_id[i]==1)state.mixer_to_crtc_id[i]=0;
   if(state.pingpong_to_crtc_id[i]==1)state.pingpong_to_crtc_id[i]=0;
   if(state.dspp_to_crtc_id[i]==1)state.dspp_to_crtc_id[i]=0;
  }
 }
 memset(&state,0,sizeof(state));
 assert(reserve(&rm,&state,1,&panel,0)==0);
 dp.num_dspp=0;assert(reserve(&rm,&state,2,&dp,0)==0);
 assert(state.dspp_to_crtc_id[0]==1&&state.dspp_to_crtc_id[1]==1);
 memset(&state,0,sizeof(state));dp.num_dspp=1;
 state.mixer_to_crtc_id[2]=state.pingpong_to_crtc_id[2]=state.dspp_to_crtc_id[2]=9;
 assert(reserve(&rm,&state,2,&dp,2)==0&&state.mixer_to_crtc_id[0]==2);
 for(unsigned i=0;i<4;i++)state.mixer_to_crtc_id[i]=9;
 struct dpu_global_state before=state;
 assert(reserve(&rm,&state,3,&dp,2)==-ENAVAIL&&!memcmp(&before,&state,sizeof(state)));
 puts("Actual RM: external-first HDR/panel cycles, unrelated DSPP ownership, occupied preference fallback and failed-allocation preservation passed; tablet test pending");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare "$work/check.c" -o "$work/check"
"$work/check"
