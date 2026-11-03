#!/usr/bin/env bash
# COPR-only: execute the prepared driver's mixer and mute functions with fake I/O.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=${1:?Pass prepared kernel tree}
baseline=${2:?Pass unmodified native TX macro source}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
ulimit -c 0
cat > "$work/header.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef uint8_t u8;
#define BIT(n) (1UL << (n))
#define TX_MACRO_MAX_DAIS 3
#define TX_MACRO_DEC_MAX 8
#define CDC_TXn_TX_PATH_CTL(n) (0x0400 + 0x80 * (n))
#define CDC_TXn_PGA_MUTE_MASK BIT(4)
#define test_bit(n,p) (!!(*(p) & BIT(n)))
#define set_bit(n,p) (*(p) |= BIT(n))
#define clear_bit(n,p) (*(p) &= ~BIT(n))
#define for_each_set_bit(n,p,max) for ((n)=0;(n)<(max);(n)++) if (test_bit(n,p))
struct tx_macro { unsigned long active_ch_mask[3],active_ch_cnt[3]; int active_decimator[3]; };
struct snd_soc_component { struct tx_macro *tx; };
struct snd_soc_dapm_context { struct snd_soc_component *component; };
struct snd_soc_dapm_widget { struct snd_soc_dapm_context *dapm; unsigned shift; };
struct soc_mixer_control { unsigned shift; };
struct snd_kcontrol { uintptr_t private_value; struct snd_soc_dapm_widget *widget; };
struct snd_ctl_elem_value { struct { struct { long value[2]; } integer; } value; };
struct snd_soc_dapm_update { int unused; };
struct snd_soc_dai { struct snd_soc_component *component; unsigned id; };
static unsigned dapm_calls,writes[8],updates[8];
static struct snd_soc_dapm_widget *snd_soc_dapm_kcontrol_to_widget(struct snd_kcontrol *k) { return k->widget; }
static struct snd_soc_component *snd_soc_dapm_to_component(struct snd_soc_dapm_context *d) { return d->component; }
static struct tx_macro *snd_soc_component_get_drvdata(struct snd_soc_component *c) { return c->tx; }
static void snd_soc_dapm_mixer_update_power(struct snd_soc_dapm_context *d,struct snd_kcontrol *k,unsigned enable,struct snd_soc_dapm_update *u)
{ assert(d && k && enable<=1 && !u); dapm_calls++; }
static unsigned index_for(unsigned reg,unsigned mask)
{ assert(reg>=0x400 && (reg-0x400)%0x80==0 && mask==BIT(4)); unsigned i=(reg-0x400)/0x80; assert(i<8); return i; }
static void snd_soc_component_write_field(struct snd_soc_component *c,unsigned reg,unsigned mask,unsigned value)
{ assert(c && value==1); writes[index_for(reg,mask)]++; }
static void snd_soc_component_update_bits(struct snd_soc_component *c,unsigned reg,unsigned mask,unsigned value)
{ assert(c && value==0); updates[index_for(reg,mask)]++; }
C
cat > "$work/footer.c" <<'C'
static void state(struct tx_macro *tx,unsigned dai,unsigned expected)
{
 assert(tx->active_ch_mask[dai]==expected);
 assert(tx->active_ch_cnt[dai]==(unsigned)__builtin_popcount(expected));
 for(unsigned other=0;other<3;other++) if(other!=dai) {
  assert(tx->active_ch_mask[other]==0 && tx->active_ch_cnt[other]==0);
 }
}
int main(int argc,char **argv)
{
 bool mute_only=argc>1 && !strcmp(argv[1],"mute-only");
 unsigned cases=0;
 for(unsigned dai=0;dai<3;dai++) for(unsigned mask=0;mask<256;mask++)
 for(unsigned reverse=0;reverse<2;reverse++) {
  struct tx_macro tx={.active_decimator={-1,-1,-1}};
  struct snd_soc_component component={&tx};
  struct snd_soc_dapm_context dapm={&component};
  struct snd_soc_dapm_widget widget={&dapm,dai};
  struct soc_mixer_control mc={0};
  struct snd_kcontrol k={(uintptr_t)&mc,&widget};
  struct snd_ctl_elem_value value={0};
  struct snd_soc_dai stream={&component,dai};
  unsigned expected=0;
  if(mute_only) {
   tx.active_ch_mask[dai]=mask;tx.active_ch_cnt[dai]=__builtin_popcount(mask);
   tx.active_decimator[dai]=mask?31-__builtin_clz(mask):-1;
  } else {
   for(unsigned step=0;step<8;step++) {
    unsigned bit=reverse?7-step:step;
    if(!(mask & BIT(bit))) continue;
    mc.shift=bit;value.value.integer.value[0]=1;
    unsigned calls=dapm_calls;
    assert(tx_macro_tx_mixer_put(&k,&value)==1);expected|=BIT(bit);
    assert(dapm_calls==calls+1);state(&tx,dai,expected);
   }
   /* Retry every selected control after other decimators have been selected. */
   for(unsigned bit=0;bit<8;bit++) {
    mc.shift=bit;value.value.integer.value[0]=!!(mask & BIT(bit));
    unsigned calls=dapm_calls;
    assert(tx_macro_tx_mixer_put(&k,&value)==0);
    assert(dapm_calls==calls);state(&tx,dai,expected);
    assert(tx_macro_tx_mixer_get(&k,&value)==0);
    assert(value.value.integer.value[0]==!!(mask & BIT(bit)));
   }
  }
  memset(writes,0,sizeof(writes));memset(updates,0,sizeof(updates));
  assert(tx_macro_digital_mute(&stream,1,1)==0);
  assert(tx_macro_digital_mute(&stream,0,1)==0);
  for(unsigned bit=0;bit<8;bit++) {
   assert(writes[bit]==!!(mask & BIT(bit)));
   assert(updates[bit]==!!(mask & BIT(bit)));
  }
  if(!mute_only) for(unsigned step=0;step<8;step++) {
   unsigned bit=reverse?7-step:step;
   mc.shift=bit;value.value.integer.value[0]=0;
   unsigned calls=dapm_calls;bool selected=!!(expected & BIT(bit));
   assert(tx_macro_tx_mixer_put(&k,&value)==selected);expected &= ~BIT(bit);
   assert(dapm_calls==calls+selected);state(&tx,dai,expected);
   assert(tx_macro_tx_mixer_put(&k,&value)==0);state(&tx,dai,expected);
  }
  cases++;
 }
 printf("Actual TX mixer and mute: %u cases passed; fake I/O only.\n",cases);
}
C
for variant in fixed original; do
 case $variant in fixed) source=$kernel/sound/soc/codecs/lpass-tx-macro.c;; original) source=$baseline;; esac
 cat "$work/header.c" > "$work/$variant.c"
 for function in tx_macro_tx_mixer_get tx_macro_tx_mixer_put tx_macro_digital_mute; do
  awk -v name="$function" '$0 ~ "^static int "name"\\(" {inside=1} inside {print} inside && /^}/ {exit}' "$source" > "$work/function.c"
  test -s "$work/function.c"
  cat "$work/function.c" >> "$work/$variant.c"
 done
 cat "$work/footer.c" >> "$work/$variant.c"
 extra=()
 # The unchanged native scalar comparison has a pre-existing sign warning.
 [[ $variant != original ]] || extra=(-Wno-sign-compare)
 ${CC:-cc} -std=c11 -Wall -Wextra -Werror -Wno-unused-parameter "${extra[@]}" -fsanitize=address,undefined "$work/$variant.c" -o "$work/$variant"
done
"$work/fixed"
for mode in mixer mute-only; do
 if "$work/original" "$mode" > "$work/negative-$mode.log" 2>&1; then
  printf 'Unpatched native source unexpectedly passed %s regression\n' "$mode" >&2;exit 1
 fi
 grep -Eq 'Assertion .* failed' "$work/negative-$mode.log"
 printf 'Unpatched native %s negative control rejected.\n' "$mode"
done
