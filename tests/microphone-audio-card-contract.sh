#!/usr/bin/env bash
# Execute actual admission/lifecycle callbacks with memory-only ASoC/SDW fakes.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
typedef uint32_t u32;
#define BIT(n) (1U << (n))
#define DISPLAY_PORT_RX_0 104
#define SECONDARY_TDM_RX_0 40
#define TX_CODEC_DMA_TX_3 120
#define SNDRV_PCM_STREAM_CAPTURE 1
#define SNDRV_PCM_FORMAT_S16_LE 2
#define SNDRV_PCM_HW_PARAM_CHANNELS 0
#define SNDRV_PCM_HW_PARAM_RATE 1
#define SNDRV_PCM_HW_PARAM_FORMAT 2
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define IS_ERR_OR_NULL(p) (!(p) || (uintptr_t)(p) >= (uintptr_t)-4095)
struct snd_soc_jack { int unused; };
struct device { int unused; };
struct snd_soc_pcm_stream { unsigned channels_min,channels_max; };
struct snd_soc_dai_driver { struct snd_soc_pcm_stream playback,capture; };
struct snd_soc_dai { int id; struct snd_soc_dai_driver *driver; void *stream; };
struct snd_soc_dai_link { bool no_pcm,dynamic; };
struct snd_soc_pcm_runtime;
struct snd_soc_card { void *data; unsigned count; struct snd_soc_pcm_runtime *rtd[6]; };
struct snd_soc_pcm_runtime { struct snd_soc_card *card; struct snd_soc_dai_link *dai_link;
 struct snd_soc_dai *cpu,*codec[3]; struct device *dev; };
struct snd_pcm_substream { int stream; struct snd_soc_pcm_runtime *rtd; };
struct snd_interval { unsigned min,max; };
struct snd_mask { unsigned format; };
struct snd_pcm_hw_params { unsigned rate,channels,format;
 struct snd_interval intervals[2]; struct snd_mask format_mask; };
struct sdw_stream_runtime { int unused; };
#define for_each_card_rtds(c,r) for(unsigned n=0;n<(c)->count && (((r)=(c)->rtd[n]),1);n++)
#define for_each_rtd_codec_dais(r,i,d) for((i)=0;(i)<3 && (((d)=(r)->codec[i]),1);(i)++)
#define snd_soc_card_get_drvdata(c) ((c)->data)
#define snd_soc_substream_to_rtd(s) ((s)->rtd)
#define snd_soc_rtd_to_cpu(r,i) ((r)->cpu)
#define snd_soc_rtd_to_codec(r,i) ((r)->codec[i])
#define params_rate(p) ((p)->rate)
#define params_channels(p) ((p)->channels)
#define params_format(p) ((p)->format)
#define hw_param_interval(p,i) (&(p)->intervals[i])
#define hw_param_mask(p,i) (&(p)->format_mask)
static void snd_mask_none(struct snd_mask *mask) {mask->format=0;}
static void snd_mask_set_format(struct snd_mask *mask,unsigned format) {mask->format=format;}
static struct sdw_stream_runtime stream;
static void *get_stream;
static int startup_error,map_error,prepare_error;
static int gain_error;
static int uke_microphone_apply_gain(struct snd_soc_pcm_runtime *rtd,
                                    const u32 *analog, const u32 *digital)
{ assert(rtd && analog && digital);return gain_error; }
static unsigned tx_count,tx_mask,rx_count;
static unsigned starts,prepares,frees,releases,clears;
static bool *prepared_state;
static int snd_soc_dai_set_stream(struct snd_soc_dai *d,void *s,int direction)
{ assert(direction==1 && !s);d->stream=s;clears++;return 0; }
static int qcom_snd_sdw_startup(struct snd_pcm_substream *s)
{ starts++;for(unsigned i=0;i<3;i++)s->rtd->codec[i]->stream=&stream;return startup_error; }
static int snd_soc_dai_get_channel_map(struct snd_soc_dai *d,unsigned *n,unsigned *mask,
                                       unsigned *rn,unsigned *rm)
{ assert(d && rm);*n=tx_count;*mask=tx_mask;*rn=rx_count;*rm=0;return map_error; }
static int dev_err_probe(struct device *d,int error,const char *message)
{ (void)d;assert(message);return error; }
static struct sdw_stream_runtime *qcom_snd_sdw_get_stream(struct snd_pcm_substream *s)
{ (void)s;return get_stream; }
static int qcom_snd_sdw_prepare(struct snd_pcm_substream *s,bool *prepared)
{ (void)s;prepares++;if(prepare_error)return prepare_error;*prepared=true;return 0; }
static int qcom_snd_sdw_hw_free(struct snd_pcm_substream *s,bool *prepared)
{ (void)s;frees++;*prepared=false;return 0; }
static void qcom_snd_sdw_shutdown(struct snd_pcm_substream *s)
{ (void)s;assert(!*prepared_state);releases++; }
C
awk '/^struct uke_speaker_data [{]/ {emit=1} emit {print} emit && /^};/ {exit}' "$root/src/audio/uke-audio-card.c" >> "$work/check.c"
awk '/^static (int|void) (uke_speaker_late_probe|uke_capture_clear_stream|uke_capture_startup|uke_capture_fixup|uke_capture_hw_params|uke_capture_prepare|uke_capture_hw_free|uke_capture_shutdown)\(/ {emit=1}
 emit {print} emit && /^}/ {emit=0}' "$root/src/audio/uke-audio-card.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void)
{
 struct uke_speaker_data data={0};
 struct snd_soc_card card={.data=&data};
 struct snd_soc_pcm_stream mono={1,1};
 struct snd_soc_dai_driver drivers[6]={0},sdw_driver={.capture={1,1}};
 struct snd_soc_dai cpus[6]={0},codecs[3]={{0}};
 struct snd_soc_dai_link links[6]={0};
 struct snd_soc_pcm_runtime rtds[6]={0};
 const int ids[]={0,1,104,40,2,120};
 unsigned checks=0;
 for(unsigned i=0;i<6;i++) {
  cpus[i].id=ids[i];cpus[i].driver=&drivers[i];drivers[i].playback=mono;
  links[i].no_pcm=i==2||i==3||i==5;links[i].dynamic=!links[i].no_pcm;
  rtds[i].card=&card;rtds[i].cpu=&cpus[i];rtds[i].dai_link=&links[i];card.rtd[i]=&rtds[i];
  for(unsigned j=0;j<3;j++)rtds[i].codec[j]=&codecs[j];
 }
 codecs[1].driver=&sdw_driver;
 drivers[4].capture=(struct snd_soc_pcm_stream){1,4};drivers[4].playback.channels_min=0;
 card.count=4;assert(!uke_speaker_late_probe(&card));checks++;
 card.count=6;assert(uke_speaker_late_probe(&card)==-EINVAL);checks++;
 data.microphones=true;assert(!uke_speaker_late_probe(&card));checks++;
 sdw_driver.capture.channels_min=0;assert(uke_speaker_late_probe(&card)==-EINVAL);checks++;
 sdw_driver.capture.channels_min=1;
 for(int bad_id=-1;bad_id<7;bad_id++) {
  if(bad_id==2)continue;
  cpus[4].id=bad_id;
  assert(uke_speaker_late_probe(&card)==-EINVAL);checks++;
 }
 cpus[4].id=2;
 drivers[4].capture.channels_max=2;assert(uke_speaker_late_probe(&card)==-EINVAL);checks++;
 drivers[4].capture.channels_max=4;
 drivers[4].playback.channels_min=1;assert(uke_speaker_late_probe(&card)==-EINVAL);checks++;
 drivers[4].playback.channels_min=0;
 struct snd_pcm_substream sub={.stream=1,.rtd=&rtds[5]};
 struct snd_pcm_hw_params params={.rate=48000,.channels=1,.format=2};
 const unsigned allowed[]={1,2,4};
 const unsigned expected_masks[]={1,3,15};
 for(unsigned i=0;i<3;i++) {
  struct snd_pcm_hw_params fixed={.intervals={{allowed[i],allowed[i]},{44100,96000}}};
  assert(!uke_capture_fixup(&rtds[5],&fixed));
  assert(fixed.intervals[0].min==allowed[i] && fixed.intervals[0].max==allowed[i]);
  assert(fixed.intervals[1].min==48000 && fixed.intervals[1].max==48000);
  assert(fixed.format_mask.format==SNDRV_PCM_FORMAT_S16_LE);checks++;
 }
 const unsigned invalid[]={0,3,5,8,32};
 for(unsigned i=0;i<5;i++) {
  struct snd_pcm_hw_params bad={.intervals={{invalid[i],invalid[i]},{44100,96000}}};
  assert(uke_capture_fixup(&rtds[5],&bad)==-EINVAL);
  assert(bad.intervals[1].min==44100 && bad.intervals[1].max==96000);checks++;
 }
 struct snd_pcm_hw_params range={.intervals={{1,4},{44100,96000}}};
 assert(uke_capture_fixup(&rtds[5],&range)==-EINVAL);checks++;
 for(unsigned i=0;i<3;i++) {
  params.channels=allowed[i];tx_count=allowed[i];tx_mask=expected_masks[i];
  assert(!uke_capture_hw_params(&sub,&params));checks++;
  tx_mask<<=1;assert(uke_capture_hw_params(&sub,&params)==-EINVAL);checks++;
  tx_mask=expected_masks[i];tx_count++;
  assert(uke_capture_hw_params(&sub,&params)==-EINVAL);checks++;
 }
 params.channels=1;
 tx_count=1;tx_mask=1;
 assert(!uke_capture_hw_params(&sub,&params));checks++;
 const unsigned masks[]={0,2,3,8,255};
 for(unsigned i=0;i<5;i++) {
  tx_mask=masks[i];assert(uke_capture_hw_params(&sub,&params)==-EINVAL);checks++;
 }
 tx_mask=1;tx_count=2;assert(uke_capture_hw_params(&sub,&params)==-EINVAL);checks++;
 tx_count=1;rx_count=1;assert(uke_capture_hw_params(&sub,&params)==-EINVAL);checks++;
 rx_count=0;map_error=-EIO;assert(uke_capture_hw_params(&sub,&params)==-EIO);checks++;
 map_error=0;
 for(unsigned i=0;i<3;i++) {
  struct snd_pcm_hw_params bad=params;
  if(i==0)bad.rate=96000;
  if(i==1)bad.channels=3;
  if(i==2)bad.format=99;
  assert(uke_capture_hw_params(&sub,&bad)==-EINVAL);checks++;
 }
 sub.stream=0;assert(uke_capture_startup(&sub)==-EINVAL && !starts);checks++;
 sub.stream=1;startup_error=-EIO;
 assert(uke_capture_startup(&sub)==-EIO && clears==3 && !releases);checks++;
 for(unsigned i=0;i<3;i++)assert(!codecs[i].stream);
 startup_error=0;get_stream=&stream;prepared_state=&data.capture_prepared;
 for(unsigned i=0;i<30;i++) {
  assert(!uke_capture_startup(&sub));
  assert(!uke_capture_prepare(&sub) && data.capture_prepared);
  assert(!uke_capture_hw_free(&sub) && !data.capture_prepared);
  uke_capture_shutdown(&sub);
  for(unsigned j=0;j<3;j++)assert(!codecs[j].stream);
  checks++;
 }
 assert(releases==30 && clears==93 && frees==60);
 get_stream=NULL;unsigned before=prepares;
 gain_error=-EIO;unsigned before_starts=starts;
 assert(uke_capture_startup(&sub)==-EIO && starts==before_starts);checks++;
 gain_error=0;
 assert(uke_capture_prepare(&sub)==-ENODEV && prepares==before);checks++;
 get_stream=ERR_PTR(-EIO);
 assert(uke_capture_prepare(&sub)==-EIO && prepares==before);checks++;
 get_stream=&stream;prepare_error=-ETIMEDOUT;
 assert(uke_capture_prepare(&sub)==-ETIMEDOUT && !data.capture_prepared);checks++;
 prepare_error=0;assert(!uke_capture_startup(&sub));assert(!uke_capture_prepare(&sub));
 uke_capture_shutdown(&sub);assert(!data.capture_prepared && frees==61);checks++;
 printf("Actual Uke admission/lifecycle: %u memory-only cases passed; not physical start/stop.\n",checks);
}
C
# ASoC's fixup signature retains an unused runtime argument in the real body.
${CC:-cc} -std=gnu11 -Wall -Wextra -Werror -Wno-unused-parameter -fsanitize=address,undefined -fno-omit-frame-pointer "$work/check.c" -o "$work/check"
"$work/check"
