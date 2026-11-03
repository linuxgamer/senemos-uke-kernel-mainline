#!/bin/bash
# COPR-only: exercise the actual gain helper, including failed bus transfers.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
typedef uint32_t u32;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
struct regmap { unsigned registers[0x3100]; };
struct snd_soc_component { struct regmap *regmap; };
struct snd_soc_dai { struct snd_soc_component *component; };
struct snd_soc_pcm_runtime { struct snd_soc_dai *codec[3];void *dev; };
#define snd_soc_rtd_to_codec(r,i) ((r)->codec[i])
#define dev_err(d,...) ((void)(d))
static unsigned reads,writes,fail_read,fail_write;
static bool fail_after_write;
static int regmap_read(struct regmap *map,unsigned reg,unsigned *value)
{
 assert(reg<0x3100);
 if(++reads==fail_read)return -EIO;
 *value=map->registers[reg];return 0;
}
static int snd_soc_component_update_bits(struct snd_soc_component *c,
                                         unsigned reg,unsigned mask,unsigned value)
{
 assert(reg<0x3100);writes++;
 if(writes==fail_write && !fail_after_write)return -EIO;
 c->regmap->registers[reg]=(c->regmap->registers[reg]&~mask)|(value&mask);
 if(writes==fail_write)return -EIO;
 return 1;
}
C
printf '#include "%s/src/audio/uke-microphone-gain.h"\n' "$root" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
 static struct regmap wcd,tx,original_wcd,original_tx;
 struct snd_soc_component components[]={{&wcd},{&tx}};
 struct snd_soc_dai dais[]={{&components[0]},{0},{&components[1]}};
 struct snd_soc_pcm_runtime rtd={{&dais[0],&dais[1],&dais[2]},0};
 u32 analog[]={8,8,8,8},digital[]={24,24,24,24};
 unsigned checks=0;
 for(unsigned i=0;i<0x3100;i++){wcd.registers[i]=0xabcdef06;tx.registers[i]=0x12340000;}
 original_wcd=wcd;original_tx=tx;
 assert(!uke_microphone_apply_gain(&rtd,analog,digital));
 for(unsigned i=0;i<4;i++){
  assert(wcd.registers[0x300e + i]==0xabcdef08);
  assert(tx.registers[0x040c+0x80*i]==0x12340018);
  wcd.registers[0x300e + i]=original_wcd.registers[0x300e + i];
  tx.registers[0x040c+0x80*i]=original_tx.registers[0x040c+0x80*i];
 }
 assert(!memcmp(&wcd,&original_wcd,sizeof(wcd)));
 assert(!memcmp(&tx,&original_tx,sizeof(tx)));checks++;
 for(unsigned kind=0;kind<3;kind++)for(unsigned fault=1;fault<=8;fault++){
  wcd=original_wcd;tx=original_tx;reads=writes=0;
  fail_read=kind==0?fault:0;fail_write=kind?fault:0;fail_after_write=kind==2;
  assert(uke_microphone_apply_gain(&rtd,analog,digital)==-EIO);
  assert(!memcmp(&wcd,&original_wcd,sizeof(wcd)));
  assert(!memcmp(&tx,&original_tx,sizeof(tx)));checks++;
 }
 fail_read=fail_write=0;reads=writes=0;
 for(unsigned i=0;i<4;i++){
  analog[i]=0;assert(uke_microphone_apply_gain(&rtd,analog,digital)==-EINVAL);
  analog[i]=9;assert(uke_microphone_apply_gain(&rtd,analog,digital)==-EINVAL);
  analog[i]=8;digital[i]=25;
  assert(uke_microphone_apply_gain(&rtd,analog,digital)==-EINVAL);
  digital[i]=24;checks+=3;
 }
 assert(!reads && !writes);
 components[0].regmap=0;
 assert(uke_microphone_apply_gain(&rtd,analog,digital)==-ENODEV);checks++;
 printf("Microphone gain preservation, bounded defaults and bus-failure rollback: %u cases passed\n",checks);
 return 0;
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
