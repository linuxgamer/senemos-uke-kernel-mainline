#!/usr/bin/env bash
# Actual I/O setup and its caller unwind, using fake registers only.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include <limits.h>
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((UINT_MAX << (l)) & (UINT_MAX >> (31-(h))))
struct snd_soc_component { int unused; };
struct device { int unused; };
struct regmap { int unused; };
struct wcd939x_priv { struct regmap *regmap; int clsh_info; };
static struct { int num_regs; } wcd939x_regmap_irq_chip={3};
static unsigned calls,delays,pm_puts,clsh_frees;
static int failure_at,failure,changed;
static unsigned registers[0x4000];
C
awk '/^#define WCD939X_/ {emit=1} emit {print} emit && !/\\$/ {emit=0}' "$kernel/sound/soc/codecs/wcd939x.h" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int snd_soc_component_write_field(struct snd_soc_component *c,unsigned reg,
                                          unsigned mask,unsigned value)
{
 (void)c;assert(reg<0x4000 && mask);calls++;
 if((int)calls==failure_at)return failure;
 registers[reg]=(registers[reg]&~mask)|((value<<__builtin_ctz(mask))&mask);
 return changed;
}
static int snd_soc_component_write(struct snd_soc_component *c,unsigned reg,unsigned value)
{
 (void)c;assert(reg<0x4000);calls++;
 if((int)calls==failure_at)return failure;
 registers[reg]=value;return 0;
}
static int regmap_write(struct regmap *m,unsigned reg,unsigned value)
{ (void)m;return snd_soc_component_write(NULL,reg,value); }
static void usleep_range(unsigned low,unsigned high)
{ assert(low==10000 && high==10010 && calls==2);delays++; }
static void pm_runtime_put(struct device *d) { (void)d;pm_puts++; }
static void wcd_clsh_ctrl_free(int state) { assert(state==7);clsh_frees++; }
C
awk '/^static int wcd939x_io_init\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/codecs/wcd939x.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int actual_io_guard(struct snd_soc_component *component)
{
 struct regmap map;
 struct wcd939x_priv codec={&map,7},*wcd939x=&codec;
 struct device device,*dev=&device;
 int ret,i;
C
awk '/^static int wcd939x_soc_codec_probe\(/ {probe=1}
 probe && /ret = wcd939x_io_init\(/ {emit=1}
 emit && /Request for watchdog/ {exit}
 emit {print}' "$kernel/sound/soc/codecs/wcd939x.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
 return 0;
err_free_clsh_ctrl:
 wcd_clsh_ctrl_free(wcd939x->clsh_info);
 return ret;
}
static void clear(void)
{
 memset(registers,0xff,sizeof(registers));
 calls=delays=pm_puts=clsh_frees=0;
 failure_at=0;failure=-EIO;changed=0;
}
int main(void)
{
 struct snd_soc_component component;
 unsigned scenarios=0;
 for(unsigned positive=0;positive<2;positive++) {
  clear();changed=positive;
  assert(!actual_io_guard(&component));
  assert(calls==22 && delays==1 && pm_puts==1 && !clsh_frees);
  assert(!(registers[WCD939X_ANA_BIAS]&WCD939X_BIAS_PRECHRG_EN));
  scenarios++;
 }
 const int errors[]={-EIO,-ETIMEDOUT,-EREMOTEIO};
 for(unsigned op=1;op<=22;op++)
  for(unsigned err=0;err<3;err++) {
   clear();failure_at=op;failure=errors[err];
   assert(actual_io_guard(&component)==failure);
   assert(calls==op && pm_puts==1 && clsh_frees==1);
   assert(delays==(op>2));
   scenarios++;
  }
 printf("Actual WCD I/O setup: %u memory-only sequence, write-error and PM/class-H unwind cases passed.\n",scenarios);
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
