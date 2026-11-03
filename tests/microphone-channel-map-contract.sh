#!/usr/bin/env bash
# COPR-only: exercise actual frontend format assignment and native map defaults.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=${1:?prepared kernel}; baseline=${2:?unmodified frontend source}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
ulimit -c 0
cat > "$work/header.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;
#define SNDRV_PCM_STREAM_CAPTURE 1
#define SND_AUDIOCODEC_PCM 1
C
awk '/^#define PCM_CHANNEL_(FL|FR|FC|LS|RS)[[:space:]]/ {print}' "$kernel/sound/soc/qcom/qdsp6/q6apm.h" >> "$work/header.c"
awk '/^void audioreach_set_default_channel_mapping\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/sound/soc/qcom/qdsp6/audioreach.c" >> "$work/header.c"
cat >> "$work/header.c" <<'C'
struct device_node { bool microphones; };
struct device { struct device_node *of_node; };
struct snd_soc_card { struct device *dev; };
struct snd_soc_dai_link { unsigned id; };
struct snd_soc_pcm_runtime { struct snd_soc_card *card;struct snd_soc_dai_link *dai_link; };
struct q6apm_dai_rtd { unsigned bits_per_sample; };
struct snd_pcm_runtime { unsigned channels,rate; struct q6apm_dai_rtd *private_data; };
struct snd_pcm_substream { int stream;struct snd_pcm_runtime *runtime;struct snd_soc_pcm_runtime *soc; };
struct audioreach_module_config { unsigned direction,sample_rate,num_channels,bit_width,fmt;u8 channel_map[32]; };
static bool uke;
bool of_machine_is_compatible(const char *name) { assert(!strcmp(name,"xiaomi,uke"));return uke; }
bool of_device_is_compatible(struct device_node *node,const char *name)
{ assert(!strcmp(name,"xiaomi,uke-microphone-audio-card"));return node && node->microphones; }
static struct audioreach_module_config configure(struct snd_pcm_substream *substream)
{
 struct snd_soc_pcm_runtime *soc_prtd=substream->soc;
 struct snd_pcm_runtime *runtime=substream->runtime;
 struct q6apm_dai_rtd *prtd=runtime->private_data;
 struct audioreach_module_config cfg={0};
 (void)soc_prtd;
C
cat > "$work/footer.c" <<'C'
 return cfg;
}
int main(void)
{
 unsigned cases=0,counts[]={1,2,4};
 struct device_node node={0};struct device dev={&node};struct snd_soc_card card={&dev};
 struct snd_soc_dai_link link={0};struct snd_soc_pcm_runtime soc={&card,&link};
 struct q6apm_dai_rtd prtd={16};struct snd_pcm_runtime runtime={0,48000,&prtd};
 struct snd_pcm_substream sub={0,&runtime,&soc};
 for(unsigned board=0;board<2;board++) for(unsigned profile=0;profile<2;profile++)
 for(unsigned graph=0;graph<4;graph++) for(int direction=0;direction<2;direction++)
 for(unsigned channel=0;channel<3;channel++) {
  uke=board;node.microphones=profile;link.id=graph;sub.stream=direction;runtime.channels=counts[channel];
  struct audioreach_module_config cfg=configure(&sub);
  u8 expected[32]={0};
  audioreach_set_default_channel_mapping(expected,runtime.channels);
  if(board && profile && graph==2 && direction==1 && runtime.channels==4) {
   for(unsigned i=0;i<4;i++)expected[i]=i+1;
  }
  assert(!memcmp(cfg.channel_map,expected,sizeof(expected)));
  assert(cfg.sample_rate==48000 && cfg.num_channels==runtime.channels && cfg.bit_width==16);
  assert(cfg.direction==(unsigned)direction && cfg.fmt==SND_AUDIOCODEC_PCM);
  cases++;
 }
 uke=true;node.microphones=true;link.id=2;sub.stream=1;runtime.channels=4;dev.of_node=NULL;
 struct audioreach_module_config cfg=configure(&sub);assert(cfg.channel_map[2]==4 && cfg.channel_map[3]==5);
 printf("Actual microphone frontend channel mapping: %u cases and missing node passed; no DSP execution.\n",cases);
}
C
for variant in fixed original; do
 case $variant in fixed) source=$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c;; original) source=$baseline;; esac
 cat "$work/header.c" > "$work/$variant.c"
 awk '/^static int q6apm_dai_prepare\(/ {inside=1}
 inside && /^\tcfg.direction =/ {emit=1}
 emit && /^\tif \(prtd->state\)/ {exit}
 emit {print}' "$source" > "$work/assignment.c"
 test -s "$work/assignment.c"
 cat "$work/assignment.c" "$work/footer.c" >> "$work/$variant.c"
 ${CC:-cc} -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined "$work/$variant.c" -o "$work/$variant"
done
"$work/fixed"
if "$work/original" > "$work/negative.log" 2>&1; then
 echo 'Unmodified quad speaker map unexpectedly passed raw microphone mapping' >&2;exit 1
fi
grep -Eq 'Assertion .* failed' "$work/negative.log"
printf 'Unmodified frontend mapping negative control rejected.\n'
