#!/usr/bin/env bash
# Source-extracted USBSS/codec reset; register/pin fakes, no device access.
set -euo pipefail
source_file=${1:?Pass src/usb/wcd939x-uke-typec.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define BIT(n) (1u<<(n))
#define FSM_OVERRIDE 0x63
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
struct reset_controller_dev {int unused;};
struct pinctrl_state {int active;};
struct pinctrl {int unused;};
struct regmap {unsigned values[256];};
struct uke_usbss {struct regmap *regmap;int lock;bool removing,applied;int last_error;};
struct uke_codec_reset {
 struct reset_controller_dev controller;
 struct uke_usbss *usbss;
 struct pinctrl *pinctrl;
 struct pinctrl_state *active,*sleep;
};
static struct regmap regs;
static struct uke_usbss usbss;
static unsigned op,fail_at,fail_second,restore_attempts,assertions,releases,delays;
static bool pin_active;
static int step(void) {
 assert(usbss.lock==1);op++;
 if(op==fail_at)return -EIO;
 if(op==fail_second)return -ENOMEM;
 return 0;
}
static void mutex_lock(int *lock){assert(*lock==0);*lock=1;}
static void mutex_unlock(int *lock){assert(*lock==1);*lock=0;}
static int regmap_read(struct regmap *map,unsigned address,unsigned *value)
{int ret=step();assert(map==&regs);if(ret)return ret;*value=map->values[address];return 0;}
static int regmap_update_bits(struct regmap *map,unsigned address,unsigned mask,unsigned value)
{
 assert(map==&regs);
 if((address==0x1e||address==0x21)&&value==0x0c)restore_attempts++;
 if(address==0x63&&value==8)restore_attempts++;
 int ret=step();if(ret)return ret;
 map->values[address]=(map->values[address]&~mask)|(value&mask);return 0;
}
static int regmap_clear_bits(struct regmap *m,unsigned a,unsigned mask)
{return regmap_update_bits(m,a,mask,0);}
static int regmap_set_bits(struct regmap *m,unsigned a,unsigned mask)
{return regmap_update_bits(m,a,mask,mask);}
static int pinctrl_select_state(struct pinctrl *p,struct pinctrl_state *state)
{
 (void)p;
 if(state->active) {
  assert((regs.values[0x63]&0x7f)==0x77);
  assert((regs.values[0x1e]&0x0e)==8 && (regs.values[0x21]&0x0e)==8);
  releases++;
 }else assertions++;
 int ret=step();if(ret)return ret;pin_active=state->active;return 0;
}
static void usleep_range(unsigned minimum,unsigned maximum)
{assert(usbss.lock==1 && minimum==80 && maximum==85);delays++;}
C
awk '/^static int uke_codec_reset_cycle\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void clear(void) {
 memset(&regs,0,sizeof(regs));
 regs.values[0x63]=0xff;regs.values[0x1e]=0xad;regs.values[0x21]=0x5c;
 usbss=(struct uke_usbss){.regmap=&regs,.applied=true};
 op=restore_attempts=assertions=releases=delays=fail_at=fail_second=0;pin_active=false;
}
static void protected(void) {
 assert(regs.values[0x63]==0xff && regs.values[0x1e]==0xad && regs.values[0x21]==0x5c);
 assert(usbss.lock==0);
}
int main(void) {
 struct pinctrl pins={0};struct pinctrl_state active={1},sleep={0};
 struct uke_codec_reset r={.usbss=&usbss,.pinctrl=&pins,.active=&active,.sleep=&sleep};
 clear();assert(uke_codec_reset_cycle(&r.controller,0)==0);protected();
 assert(op==11 && restore_attempts==3 && assertions==1 && releases==1 && delays==2 && pin_active);
 for(unsigned failure=1;failure<=11;failure++) {
  clear();fail_at=failure;assert(uke_codec_reset_cycle(&r.controller,0)==-EIO);
  assert(usbss.lock==0 && !pin_active);
  if(failure<=3){assert(op==failure && !assertions && !releases && !restore_attempts);protected();}
  else {
   assert(restore_attempts==3);
   if(failure<=8){protected();assert(usbss.applied);}
   else {assert(!usbss.applied && usbss.last_error==-EIO);}
  }
 }
 clear();fail_at=5;fail_second=7;
 assert(uke_codec_reset_cycle(&r.controller,0)==-EIO);
 assert(restore_attempts==3 && !usbss.applied && usbss.last_error==-EIO && !pin_active);
 clear();usbss.removing=true;assert(uke_codec_reset_cycle(&r.controller,0)==-ESHUTDOWN);
 assert(op==0 && usbss.lock==0);
 clear();assert(uke_codec_reset_cycle(&r.controller,1)==-EINVAL);assert(op==0);
 const unsigned addresses[]={0x63,0x1e,0x21};
 for(unsigned i=0;i<3;i++) {
  clear();regs.values[addresses[i]]=0;
  assert(uke_codec_reset_cycle(&r.controller,0)==-EPROTO);
  assert(op==i+1 && !restore_attempts && !assertions && !releases && usbss.lock==0);
 }
 puts("Actual coordinated reset: protected ordering, reserved bits, all 11 fault points, compound failure and refusal passed; host only.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
