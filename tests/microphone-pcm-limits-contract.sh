#!/usr/bin/env bash
# COPR-only compiled check of the prepared component's actual hardware assignment.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
test ! -e /etc/senemos/kernel-update.conf
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <string.h>
#include <stdio.h>
#define SNDRV_PCM_STREAM_PLAYBACK 0
#define SNDRV_PCM_STREAM_CAPTURE 1
struct snd_pcm_hardware { unsigned channels_min,channels_max,rates,format,period,buffer; };
struct device_node { bool microphone; };
struct device { struct device_node *of_node; };
struct snd_soc_card { struct device *dev; };
struct snd_soc_pcm_runtime { struct snd_soc_card *card; };
struct snd_pcm_runtime { struct snd_pcm_hardware hw; };
struct snd_pcm_substream { int stream; };
static bool uke;
static bool of_machine_is_compatible(const char *name)
{ assert(!strcmp(name,"xiaomi,uke")); return uke; }
static bool of_device_is_compatible(struct device_node *node,const char *name)
{ assert(!strcmp(name,"xiaomi,uke-microphone-audio-card")); return node && node->microphone; }
static const struct snd_pcm_hardware q6apm_dai_hardware_capture={2,4,48000,16,6144,524288};
static const struct snd_pcm_hardware q6apm_dai_hardware_playback={2,8,192000,24,128,524288};
static void assign(struct snd_pcm_runtime *runtime,struct snd_pcm_substream *substream,
                   struct snd_soc_pcm_runtime *soc_prtd,int graph_id)
{
C
awk '/^static int q6apm_dai_open\(/ {inside=1}
 inside && /^\tif \(substream->stream == SNDRV_PCM_STREAM_PLAYBACK\)/ {emit=1}
 emit && /Ensure that buffer size/ {exit}
 emit {print}' "$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
}
int main(void)
{
 unsigned cases=0;
 struct device_node node={0};
 struct device dev={&node};
 struct snd_soc_card card={&dev};
 struct snd_soc_pcm_runtime soc={&card};
 for(unsigned board=0;board<2;board++) for(unsigned profile=0;profile<2;profile++)
 for(int id=0;id<4;id++) for(int direction=0;direction<2;direction++) {
  uke=board;node.microphone=profile;
  struct snd_pcm_runtime runtime={0};
  struct snd_pcm_substream sub={direction};
  struct snd_pcm_hardware expected=direction?q6apm_dai_hardware_capture:q6apm_dai_hardware_playback;
  if(board && profile && id==2 && direction)expected.channels_min=1;
  assign(&runtime,&sub,&soc,id);
  assert(!memcmp(&expected,&runtime.hw,sizeof(expected)));
  if(board && profile && id==2 && direction) assert(runtime.hw.channels_min<=1);
  cases++;
 }
 uke=true;dev.of_node=NULL;
 struct snd_pcm_runtime runtime={0};struct snd_pcm_substream sub={1};
 assign(&runtime,&sub,&soc,2);assert(runtime.hw.channels_min==2);
 assert(q6apm_dai_hardware_capture.channels_min==2);
 printf("Actual capture hardware assignment: %u cases and missing card node passed; no physical capture.\n",cases+1);
}
C
${CC:-cc} -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined "$work/check.c" -o "$work/check"
"$work/check"
