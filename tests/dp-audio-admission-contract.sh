#!/usr/bin/env bash
# Actual admission/card callbacks with host mocks; no DSP, DMA or playback.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#define EPROBE_DEFER 517
#define DISPLAY_PORT_RX_0 104
struct device_node { bool compatible,hdmi,registration; };
struct iommu_fwspec { unsigned num_ids,ids[3]; };
struct iommu_domain { bool dma; };
struct device { struct device_node *of_node; struct iommu_fwspec *spec; struct iommu_domain *domain; };
static bool uke=true;
static struct device_node owned={true,true,false};
static struct device_node *found=&owned;
static unsigned refs;
static bool of_machine_is_compatible(const char *name) { assert(!strcmp(name,"xiaomi,uke")); return uke; }
static bool of_device_is_compatible(struct device_node *n,const char *name) { assert(!strcmp(name,"qcom,q6apm-dais")); return n && n->compatible; }
static bool of_property_read_bool(struct device_node *n,const char *name) { assert(!strcmp(name,"xiaomi,hdmi-only")); return n && n->hdmi; }
static struct iommu_fwspec *dev_iommu_fwspec_get(struct device *d) { return d->spec; }
static struct device_node *of_find_node_by_path(const char *p) {
 assert(!strcmp(p,"/soc/remoteproc-adsp@03000000/glink-edge/qcom,gpr/service@1/dais"));
 if(found) refs++;
 return found;
}
static void of_node_put(struct device_node *n) { if(n) { assert(refs); refs--; } }
static struct iommu_domain *iommu_get_domain_for_dev(struct device *d) { return d->domain; }
static bool iommu_is_dma_domain(struct iommu_domain *d) { return d->dma; }
C
awk '/^static bool qcom_uke_hdmi_dma\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
 "$kernel/drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c" >> "$work/check.c"
awk '/^static int q6apm_hdmi_dma_ready\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
 "$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct snd_soc_dai_link { bool no_pcm,dynamic; };
struct snd_soc_dai_driver { struct { unsigned channels_min; } capture; };
struct snd_soc_dai { unsigned id; struct snd_soc_dai_driver *driver; };
struct snd_soc_pcm_runtime { struct snd_soc_dai_link *dai_link; struct snd_soc_dai *cpu; };
struct snd_soc_card { unsigned count; struct snd_soc_pcm_runtime *rtd; };
#define for_each_card_rtds(c,r) for(r=(c)->rtd;r<(c)->rtd+(c)->count;r++)
static struct snd_soc_dai *snd_soc_rtd_to_cpu(struct snd_soc_pcm_runtime *r,unsigned n) { assert(n==0); return r->cpu; }
C
awk '/^static int uke_hdmi_late_probe\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
 "$root/src/audio/uke-audio-card.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
 struct iommu_fwspec spec={2,{0x801001,0x1061,0}};
 struct iommu_domain domain={true};
 struct device d={&owned,&spec,&domain};
 assert(qcom_uke_hdmi_dma(&d) && refs==0);
 for(unsigned i=0;i<2;i++) { spec.ids[i]^=1; assert(!qcom_uke_hdmi_dma(&d) && refs==0); spec.ids[i]^=1; }
 for(unsigned n=0;n<=3;n++) { spec.num_ids=n; assert(qcom_uke_hdmi_dma(&d)==(n==2)); }
 spec.num_ids=2;
 struct device_node foreign=owned; d.of_node=&foreign;
 assert(!qcom_uke_hdmi_dma(&d) && refs==0);
 d.of_node=&owned; found=NULL; assert(!qcom_uke_hdmi_dma(&d)); found=&owned;
 owned.hdmi=false; assert(!qcom_uke_hdmi_dma(&d)); assert(q6apm_hdmi_dma_ready(&d)==0);
 owned.hdmi=true; uke=false;
 assert(!qcom_uke_hdmi_dma(&d) && q6apm_hdmi_dma_ready(&d)==-ENODEV);
 uke=true; d.spec=NULL; assert(!qcom_uke_hdmi_dma(&d)); d.spec=&spec;
 assert(q6apm_hdmi_dma_ready(&d)==0);
 d.domain=NULL; assert(q6apm_hdmi_dma_ready(&d)==-EPROBE_DEFER);
 d.domain=&domain; domain.dma=false; assert(q6apm_hdmi_dma_ready(&d)==-EINVAL);
 domain.dma=true;
 struct snd_soc_dai_driver drivers[3]={0};
 struct snd_soc_dai dais[3]={{0,&drivers[0]},{104,&drivers[1]},{1,&drivers[2]}};
 struct snd_soc_dai_link links[3]={{false,true},{true,false},{false,true}};
 struct snd_soc_pcm_runtime rtd[3]={{&links[0],&dais[0]},{&links[1],&dais[1]},{&links[2],&dais[2]}};
 struct snd_soc_card card={2,rtd};
 assert(uke_hdmi_late_probe(&card)==0);
 for(unsigned n=0;n<=3;n++) { card.count=n; assert(uke_hdmi_late_probe(&card)==(n==2?0:-EINVAL)); }
 card.count=2; drivers[0].capture.channels_min=1;
 assert(uke_hdmi_late_probe(&card)==-EINVAL); drivers[0].capture.channels_min=0;
 dais[1].id=102; assert(uke_hdmi_late_probe(&card)==-EINVAL); dais[1].id=104;
 dais[0].id=1; assert(uke_hdmi_late_probe(&card)==-EINVAL); dais[0].id=0;
 links[0].dynamic=false; assert(uke_hdmi_late_probe(&card)==-EINVAL);
 assert(!refs);
 puts("Actual DP audio admission: exact owned SIDs, DMA-only domain, one playback FE / DP BE and capture refusal passed; host only");
}
C
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
