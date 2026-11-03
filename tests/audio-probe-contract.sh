#!/usr/bin/env bash
# Exercise actual topology and amplifier probe callbacks with host-only inputs.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#define EPROBE_DEFER 517
#define GFP_KERNEL 0
#define GPIOD_OUT_HIGH 1
#define FS19XX_VOL_DEFAULT 0xdf
struct device { int unused; };
struct snd_soc_component { int unused; };
struct snd_soc_tplg_vendor_array { int unused; };
struct snd_soc_tplg_dapm_widget { int priv; };
struct snd_soc_dobj { void *private; };
struct snd_soc_dapm_widget { struct snd_soc_dobj dobj; };
struct audioreach_module { unsigned module_id; };
static struct audioreach_module module;
static int common_error, hardware_error;
static int audioreach_widget_load_module_common(struct snd_soc_component *c,
    int i, struct snd_soc_dapm_widget *w, const struct snd_soc_tplg_dapm_widget *t) {
    (void)c; (void)i; (void)t; w->dobj.private=&module; return common_error;
}
static const struct snd_soc_tplg_vendor_array *audioreach_get_module_array(const int *p) {
    (void)p; return NULL;
}
#define HARDWARE(name) static int name(struct audioreach_module *m, const struct snd_soc_tplg_vendor_array *a) { (void)m; (void)a; return hardware_error; }
HARDWARE(audioreach_widget_dma_module_load)
HARDWARE(audioreach_widget_log_module_load)
HARDWARE(audioreach_widget_i2s_module_load)
HARDWARE(audioreach_widget_audio_if_module_load)
HARDWARE(audioreach_widget_tdm_module_load)
HARDWARE(audioreach_widget_dp_module_load)
C
grep '^#define MODULE_ID_' "$kernel/sound/soc/qcom/qdsp6/audioreach.h" >> "$work/check.c"
extract() {
    awk -v name="$1" '$0 ~ "^static [^(]*[ *]" name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$2" > "$work/function.c"
    grep -Fq "$1(" "$work/function.c"
    cat "$work/function.c" >> "$work/check.c"
}
extract audioreach_widget_load_buffer "$kernel/sound/soc/qcom/qdsp6/topology.c"
cat >> "$work/check.c" <<'C'
struct mutex { int unused; };
struct delayed_work { int unused; };
struct i2c_client { struct device dev; void *data; };
struct fs19xx_priv {
    struct i2c_client *i2c; struct device *dev; unsigned volume, position;
    struct mutex lock; struct delayed_work unmute_work;
    void *regmap, *gpio_reset, *preset;
};
static struct fs19xx_priv storage;
static unsigned registrations, presets;
static int detect_error;
static const int fs19xx_regmap_config, fs19xx_component, fs19xx_dai;
static void *devm_kzalloc(struct device *d, size_t n, int flags) {
    (void)d; (void)flags; assert(n==sizeof storage); memset(&storage,0,n); return &storage;
}
#define mutex_init(m) ((void)(m))
#define INIT_DELAYED_WORK(w,f) ((void)(w))
#define IS_ERR(p) ((long)(p)<0 && (long)(p)>-4096)
#define PTR_ERR(p) ((int)(long)(p))
#define dev_err_probe(d,e,...) ((void)(d),(e))
#define dev_err(...) ((void)0)
#define dev_info(...) ((void)0)
static void i2c_set_clientdata(struct i2c_client *c, void *p) { c->data=p; }
static void *devm_regmap_init_i2c(struct i2c_client *c, const int *cfg) { (void)c; (void)cfg; return &storage; }
static void *devm_gpiod_get(struct device *d, const char *name, int state) { (void)d; assert(!strcmp(name,"reset") && state==1); return &storage; }
static bool gpiod_is_active_low(void *g) { (void)g; return true; }
static int fs19xx_detect(struct fs19xx_priv *p, unsigned *id) { (void)p; *id=0x29; return detect_error; }
static int fs19xx_load_preset(struct fs19xx_priv *p, unsigned id) { assert(id==0x29); presets++; p->preset=&storage; return 0; }
static int devm_snd_soc_register_component(struct device *d, const int *c, const int *dai, int n) { (void)d; (void)c; (void)dai; assert(n==1); registrations++; return 0; }
C
extract fs19xx_i2c_probe "$kernel/sound/soc/codecs/fs19xx.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    struct snd_soc_dapm_widget w={0}; struct snd_soc_tplg_dapm_widget t={0};
    const unsigned shared[]={MODULE_ID_WR_SHARED_MEM_EP,MODULE_ID_RD_SHARED_MEM_EP};
    for (unsigned i=0;i<sizeof shared/sizeof *shared;i++) {
        module.module_id=shared[i];
        assert(audioreach_widget_load_buffer(NULL,0,&w,&t)==0);
    }
    module.module_id=0xffffffff;
    assert(audioreach_widget_load_buffer(NULL,0,&w,&t)==-EINVAL);
    common_error=-ENOMEM;
    assert(audioreach_widget_load_buffer(NULL,0,&w,&t)==-ENOMEM);
    common_error=0; hardware_error=-ERANGE; module.module_id=MODULE_ID_TDM_SINK;
    assert(audioreach_widget_load_buffer(NULL,0,&w,&t)==-ERANGE);
    struct i2c_client client={0};
    const int transient[]={-EPROBE_DEFER,-ENXIO,-EAGAIN,-ETIMEDOUT};
    for (unsigned i=0;i<sizeof transient/sizeof *transient;i++) {
        detect_error=transient[i];
        assert(fs19xx_i2c_probe(&client)==-EPROBE_DEFER);
        assert(!registrations && !presets && !storage.preset);
    }
    detect_error=-ENODEV;
    assert(fs19xx_i2c_probe(&client)==0 && registrations==1 && !presets && !storage.preset);
    detect_error=0;
    assert(fs19xx_i2c_probe(&client)==0 && registrations==2 && presets==1 && storage.preset);
    puts("Actual shared-memory topology admission and transient amplifier probe deferral passed; host only");
}
C
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -fsanitize=undefined \
    -fsanitize-undefined-trap-on-error "$work/check.c" -o "$work/check"
"$work/check"
