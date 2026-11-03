#!/usr/bin/env bash
# Run the real TDM token parser and top-level widget callback; no DSP access.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
source_file=$kernel/sound/soc/qcom/qdsp6/topology.c
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
typedef uint16_t u16; typedef uint32_t u32;
#define U16_MAX UINT16_MAX
#define le32_to_cpu(x) (x)
#define dev_err(...) ((void)0)
struct snd_soc_tplg_vendor_value_elem { u32 token,value; };
struct snd_soc_tplg_vendor_array { u32 num_elems; struct snd_soc_tplg_vendor_value_elem value[12]; };
struct audioreach_module {
    u32 hw_interface_idx,hw_interface_type,data_format,slot_mask,active_lane_mask;
    u16 sync_src,ctrl_data_out_enable,nslots_per_frame,slot_width,sync_mode,
        ctrl_invert_sync_pulse,ctrl_sync_data_delay;
};
C
grep '^#define AR_TKN_' "$kernel/include/uapi/sound/snd_ar_tokens.h" >> "$work/check.c"
awk '/^static int audioreach_widget_tdm_module_load\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct snd_soc_component { int unused; };
struct snd_soc_tplg_dapm_widget { int unused; };
struct snd_soc_dapm_widget { int id; };
enum { snd_soc_dapm_aif_in,snd_soc_dapm_aif_out,snd_soc_dapm_decoder,
    snd_soc_dapm_encoder,snd_soc_dapm_src,snd_soc_dapm_buffer,snd_soc_dapm_mixer,
    snd_soc_dapm_pga,snd_soc_dapm_dai_link,snd_soc_dapm_scheduler,snd_soc_dapm_out_drv };
static int loader_result;
#define LOADER(name) static int name(struct snd_soc_component *c,int i,struct snd_soc_dapm_widget *w,const struct snd_soc_tplg_dapm_widget *t) { (void)c;(void)i;(void)w;(void)t;return loader_result; }
LOADER(audioreach_widget_load_buffer)
LOADER(audioreach_widget_load_enc_dec_cnv)
LOADER(audioreach_widget_load_mixer)
LOADER(audioreach_widget_load_pga)
C
awk '/^static int audioreach_widget_ready\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    const u32 narrow[] = { AR_TKN_U16_MODULE_SYNC_SRC,AR_TKN_U16_MODULE_CTRL_DATA_OUT_ENABLE,
        AR_TKN_U16_MODULE_NSLOTS_PER_FRAME,AR_TKN_U16_MODULE_SLOT_WIDTH,
        AR_TKN_U16_MODULE_SYNC_MODE,AR_TKN_U16_MODULE_CTRL_INVERT_SYNC_PULSE,
        AR_TKN_U16_MODULE_CTRL_SYNC_DATA_DELAY };
    struct audioreach_module module={0};
    struct snd_soc_tplg_vendor_array array={.num_elems=1};
    for (unsigned i=0;i<sizeof narrow/sizeof *narrow;i++) {
        array.value[0]=(struct snd_soc_tplg_vendor_value_elem){narrow[i],UINT16_MAX+1U};
        assert(audioreach_widget_tdm_module_load(&module,&array)==-EINVAL);
        array.value[0].value=1;
        assert(audioreach_widget_tdm_module_load(&module,&array)==0);
    }
    array.value[0]=(struct snd_soc_tplg_vendor_value_elem){AR_TKN_U16_MODULE_SLOT_WIDTH,32};
    assert(audioreach_widget_tdm_module_load(&module,&array)==0 && module.slot_width==32);
    for (int id=snd_soc_dapm_aif_in;id<=snd_soc_dapm_pga;id++) {
        struct snd_soc_dapm_widget widget={id};
        loader_result=-EINVAL;
        assert(audioreach_widget_ready(NULL,0,&widget,NULL)==-EINVAL);
        loader_result=-ENOMEM;
        assert(audioreach_widget_ready(NULL,0,&widget,NULL)==-ENOMEM);
        loader_result=0;
        assert(audioreach_widget_ready(NULL,0,&widget,NULL)==0);
    }
    puts("Actual TDM token overflow and widget-loader error propagation passed; host only");
}
C
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -fsanitize=undefined \
    -fsanitize-undefined-trap-on-error "$work/check.c" -o "$work/check"
"$work/check"
