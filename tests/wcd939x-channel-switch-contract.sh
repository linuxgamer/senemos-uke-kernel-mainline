#!/usr/bin/env bash
# Actual WCD939x switch callbacks; host memory only, no codec or mixer access.
set -euo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef uint8_t u8;
struct wcd_sdw_ch_info {u8 port_num,ch_mask;};
struct sdw_port_config {unsigned num,ch_mask;};
struct wcd939x_sdw_priv {
 const struct wcd_sdw_ch_info *ch_info;
 struct sdw_port_config port_config[6];
 bool port_enable[7];
};
struct wcd939x_priv {struct wcd939x_sdw_priv *sdw_priv[2];};
struct snd_soc_component {struct wcd939x_priv *data;};
struct soc_mixer_control {unsigned reg,shift;};
struct snd_kcontrol {uintptr_t private_value;struct snd_soc_component *comp;};
struct snd_ctl_elem_value {struct {struct {long value[1];} integer;} value;};
static struct snd_soc_component *snd_kcontrol_chip(struct snd_kcontrol *k){return k->comp;}
static struct wcd939x_priv *snd_soc_component_get_drvdata(struct snd_soc_component *c){return c->data;}
C
awk '/^static int (wcd939x_sdw_connect_port|wcd939x_connect_port|wcd939x_get_swr_port|wcd939x_set_swr_port)\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$kernel/sound/soc/codecs/wcd939x.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 const struct wcd_sdw_ch_info adc[]={{1,1},{1,2},{1,4},{1,8}};
 struct wcd939x_sdw_priv tx={.ch_info=adc};
 struct wcd939x_priv priv={.sdw_priv={NULL,&tx}};
 struct snd_soc_component comp={&priv};
 struct soc_mixer_control maps[4];struct snd_kcontrol ctl[4];
 struct snd_ctl_elem_value value={0};
 for(unsigned i=0;i<4;i++){maps[i]=(struct soc_mixer_control){i,1};ctl[i]=(struct snd_kcontrol){(uintptr_t)&maps[i],&comp};}
 value.value.integer.value[0]=1;wcd939x_set_swr_port(&ctl[0],&value);
 wcd939x_get_swr_port(&ctl[1],&value);assert(value.value.integer.value[0]==0);
 value.value.integer.value[0]=0;wcd939x_set_swr_port(&ctl[0],&value);
 for(unsigned mask=0;mask<16;mask++) {
  for(unsigned i=0;i<4;i++) {
   value.value.integer.value[0]=!!(mask&(1u<<i));
   int changed=!!(tx.port_config[0].ch_mask&(1u<<i))!=value.value.integer.value[0];
   assert(wcd939x_set_swr_port(&ctl[i],&value)==changed);
   assert(wcd939x_set_swr_port(&ctl[i],&value)==0);
  }
  assert(tx.port_config[0].ch_mask==mask);
  unsigned saved=0;
  for(unsigned i=0;i<4;i++) {
   assert(wcd939x_get_swr_port(&ctl[i],&value)==0);
   assert(value.value.integer.value[0]==!!(mask&(1u<<i)));
   saved|=(unsigned)value.value.integer.value[0]<<i;
  }
  assert(saved==mask);
  for(unsigned i=0;i<4;i++) {value.value.integer.value[0]=0;wcd939x_set_swr_port(&ctl[i],&value);}
  for(unsigned i=0;i<4;i++) {value.value.integer.value[0]=!!(saved&(1u<<i));wcd939x_set_swr_port(&ctl[i],&value);}
  assert(tx.port_config[0].ch_mask==mask);
 }
 puts("Actual WCD939x callbacks: all 16 four-ADC combinations, unchanged writes and save/restore passed; host only.");
}
C
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
