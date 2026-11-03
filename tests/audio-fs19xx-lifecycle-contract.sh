#!/usr/bin/env bash
# Execute the real amplifier callbacks with fake registers, GPIO and workqueue.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:-}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
if [[ -z $kernel ]]; then
    kernel=$work/kernel
    mkdir -p "$kernel/sound/soc/codecs"
    awk '
      /^diff --git a\/sound\/soc\/codecs\/fs19xx.c / {emit=1; next}
      emit && /^diff --git/ {exit}
      emit && /^\+[^+]/ {print substr($0,2)}
      emit && $0=="+" {print ""}
    ' "$root/patches/7.3.0/0115-asoc-fs19xx-smart-amplifier.patch" > "$kernel/sound/soc/codecs/fs19xx.c"
    git -C "$kernel" apply --include=sound/soc/codecs/fs19xx.c \
        "$root/patches/7.3.0/0117-asoc-uke-audio-runtime-safety.patch"
    git -C "$kernel" apply --include=sound/soc/codecs/fs19xx.c \
        "$root/patches/7.3.0/0118-asoc-fs19xx-speaker-rotation.patch"
    git -C "$kernel" apply --include=sound/soc/codecs/fs19xx.c \
        "$root/patches/7.3.0/0119-asoc-uke-probe-readiness.patch"
    git -C "$kernel" apply --include=sound/soc/codecs/fs19xx.c \
        "$root/patches/boot/0058-fs19xx-current-workqueue.patch"
fi
source_file=$kernel/sound/soc/codecs/fs19xx.c
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16, __le16; typedef uint32_t __le32;
#define __packed __attribute__((packed))
#define BIT(n) (1U << (n))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define is_power_of_2(x) ((x) && !((x) & ((x)-1)))
#define GENMASK(h,l) ((~0U << (l)) & (~0U >> (31-(h))))
#define FIELD_GET(m,v) (((v)&(m)) >> __builtin_ctz(m))
#define FIELD_PREP(m,v) (((v) << __builtin_ctz(m)) & (m))
#define le16_to_cpu(v) (v)
struct device { int unused; };
struct i2c_client { void *data; };
struct gpio_desc { bool asserted; };
struct mutex { bool held; };
struct work_struct { int unused; };
struct delayed_work { struct work_struct work; bool pending; unsigned delay; };
struct regmap {
    unsigned reg[256], writes, reads;
    int fail_read, fail_write;
    bool unstable, ignore_ts_write, ignore_i2s_write;
};
static unsigned unlocks, sleeps;
static void mutex_lock(struct mutex *m) { assert(!m->held); m->held=true; }
static void mutex_unlock(struct mutex *m) { assert(m->held); m->held=false; unlocks++; }
static struct mutex *take_lock(struct mutex *m) { mutex_lock(m); return m; }
static void drop_lock(struct mutex **m) { mutex_unlock(*m); }
#define guard(t) struct mutex *held_guard __attribute__((cleanup(drop_lock))) = take_lock
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define to_delayed_work(w) container_of(w,struct delayed_work,work)
#define dev_err(...) ((void)0)
#define dev_err_once(...) ((void)0)
#define dev_dbg(...) ((void)0)
#define dev_info(...) ((void)0)
#define msecs_to_jiffies(x) (x)
static void *system_percpu_wq;
static void msleep(unsigned x) { sleeps+=x; }
static void usleep_range(unsigned a,unsigned b) { (void)a;(void)b; }
static void gpiod_set_value_cansleep(struct gpio_desc *g,int v) { g->asserted=v; }
static bool mod_delayed_work(void *q,struct delayed_work *w,unsigned d) {
    (void)q; w->pending=true; w->delay=d; return true;
}
static bool cancel_delayed_work(struct delayed_work *w) { w->pending=false; return true; }
static void cancel_delayed_work_sync(struct delayed_work *w) { w->pending=false; }
static int regmap_read(struct regmap *r,unsigned a,unsigned *v) {
    r->reads++;
    if ((int)a==r->fail_read) return -EIO;
    *v=r->unstable?r->reads:r->reg[a]; return 0;
}
static int regmap_write(struct regmap *r,unsigned a,unsigned v) {
    r->writes++;
    if ((int)a==r->fail_write) return -EIO;
    if (!(a==0x4c && r->ignore_ts_write) && !(a==0x17 && r->ignore_i2s_write)) r->reg[a]=v;
    return 0;
}
static void *i2c_get_clientdata(struct i2c_client *c) { return c->data; }
C
awk '/^#define FS19XX_DEFAULT_FW_NAME/ {emit=1} /^static int fs19xx_read_stable/ {exit} emit' \
    "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct snd_soc_component { struct fs19xx_priv *data; };
struct snd_soc_dai { struct snd_soc_component *component; };
struct snd_pcm_substream { int unused; };
struct snd_kcontrol { struct snd_soc_component *component; };
struct snd_ctl_elem_value { struct { struct { long value[1]; } integer;
    struct { unsigned item[1]; } enumerated; } value; };
static struct snd_soc_component *snd_kcontrol_chip(struct snd_kcontrol *c) { return c->component; }
static struct fs19xx_priv *snd_soc_component_get_drvdata(struct snd_soc_component *c) { return c->data; }
C
sed -n '/^static const char \* const fs19xx_rotation_text\[\]/p' "$source_file" >> "$work/check.c"
for fn in fs19xx_read_stable fs19xx_apply_unit fs19xx_write_tables fs19xx_reset_chip \
          fs19xx_chip_init fs19xx_set_volume_reg fs19xx_set_rotation_reg fs19xx_chip_start fs19xx_chip_stop \
          fs19xx_unmute_work fs19xx_power_on fs19xx_power_off fs19xx_dai_startup \
          fs19xx_dai_mute fs19xx_dai_shutdown fs19xx_volume_get fs19xx_volume_put \
          fs19xx_enable_get fs19xx_enable_put fs19xx_rotation_get fs19xx_rotation_put \
          fs19xx_suspend fs19xx_resume fs19xx_detect fs19xx_i2c_remove; do
    awk -v name="$fn" '$0 ~ "^static [^(]*[ *]" name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' \
        "$source_file" > "$work/function.c"
    grep -Fq "$fn(" "$work/function.c"
    cat "$work/function.c" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
static struct regmap regs;
static struct gpio_desc gpio;
static struct fs19xx_priv amp;
static struct snd_soc_component component={.data=&amp};
static struct snd_soc_dai dai={.component=&component};
static struct snd_kcontrol control={.component=&component};
static struct snd_ctl_elem_value value;
static void fresh(void) {
    memset(&regs,0,sizeof regs); memset(&amp,0,sizeof amp);
    regs.fail_read=regs.fail_write=-1;
    regs.reg[FS19XX_REG_CHIPINI]=FS19XX_CHIPINI_DONE_A;
    gpio.asserted=true; sleeps=unlocks=0;
    amp.regmap=&regs; amp.gpio_reset=&gpio; amp.preset=(u8 *)"qualified fixture";
    amp.volume=FS19XX_VOL_DEFAULT; amp.tcoef=258; amp.position=8;
}
static int rotation(unsigned v) { value.value.enumerated.item[0]=v; return fs19xx_rotation_put(&control,&value); }
static int enabled(long v) { value.value.integer.value[0]=v; return fs19xx_enable_put(&control,&value); }
static int volume(long v) { value.value.integer.value[0]=v; return fs19xx_volume_put(&control,&value); }
static void start(void) {
    fresh(); assert(fs19xx_dai_startup(NULL,&dai)==0);
    assert(enabled(1)==1 && !amp.powered && gpio.asserted);
    assert(fs19xx_dai_mute(&dai,0,0)==0 && amp.powered && !gpio.asserted);
    assert(amp.unmute_work.pending && amp.unmute_work.delay==FS19XX_UNMUTE_DELAY_MS);
    assert(regs.reg[FS19XX_REG_DACCTRL]==FS19XX_DACCTRL_MUTE);
}
static void poll(void) {
    assert(amp.unmute_work.pending);
    amp.unmute_work.pending=false;
    fs19xx_unmute_work(&amp.unmute_work.work);
}
static void stopped(void) {
    assert(!amp.powered && gpio.asserted && !amp.unmute_work.pending);
}
int main(void) {
    unsigned v=123;
    fresh(); unsigned chip;
    regs.reg[FS19XX_REG_CHIPID]=0x2900;
    assert(fs19xx_detect(&amp,&chip)==0 && chip==0x29 && gpio.asserted);
    regs.reg[FS19XX_REG_CHIPID]=0x1700;
    assert(fs19xx_detect(&amp,&chip)==-ENODEV && gpio.asserted);
    fresh(); regs.unstable=true;
    assert(fs19xx_read_stable(&amp,0,&v)==-EIO && v==123 && regs.reads==5);
    regs.unstable=false; regs.reads=0; regs.reg[0]=7;
    assert(fs19xx_read_stable(&amp,0,&v)==0 && v==7 && regs.reads==2);
    regs.fail_read=0; assert(fs19xx_read_stable(&amp,0,&v)==-EIO);
    fresh(); struct fs19xx_reg_unit wait={.ctrl=0x2f22,.value=1};
    assert(fs19xx_apply_unit(&amp,&wait)==-ETIMEDOUT);
    struct fs19xx_reg_unit unknown={.ctrl=0x3f22};
    assert(fs19xx_apply_unit(&amp,&unknown)==-EINVAL);
    struct fs19xx_reg_unit overflow={.ctrl=0x2722};
    assert(fs19xx_apply_unit(&amp,&overflow)==0);
    overflow.ctrl=0x2e22; assert(fs19xx_apply_unit(&amp,&overflow)==-EINVAL);
    struct fs19xx_reg_unit unsafe={.ctrl=0xf030,.value=FS19XX_DACCTRL_RUN};
    assert(fs19xx_apply_unit(&amp,&unsafe)==0);
    assert(regs.reg[FS19XX_REG_DACCTRL]&FS19XX_DACCTRL_MUTE_BIT);
    unsafe.ctrl=0x0830; unsafe.value=0;
    assert(fs19xx_apply_unit(&amp,&unsafe)==0);
    assert(regs.reg[FS19XX_REG_DACCTRL]&FS19XX_DACCTRL_MUTE_BIT);
    unsafe.ctrl=0xf016; unsafe.value=0xffc0;
    assert(fs19xx_apply_unit(&amp,&unsafe)==0);
    assert(regs.reg[FS19XX_REG_VOLCTRL]==0xdfc0);
    unsafe.ctrl=0x7816; unsafe.value=0xff;
    assert(fs19xx_apply_unit(&amp,&unsafe)==0);
    assert(regs.reg[FS19XX_REG_VOLCTRL]==0xdfc0);

    start(); poll(); assert(amp.powered && amp.unmute_work.pending);
    assert(regs.reg[FS19XX_REG_DACCTRL]==FS19XX_DACCTRL_MUTE);
    unsigned before=unlocks, sleep_before=sleeps; assert(enabled(0)==1); stopped();
    assert(unlocks==before+1); /* stop never releases its lock to cancel work */
    assert(sleeps-sleep_before==10);
    assert(enabled(1)==1 && amp.powered); /* same active stream resumes */
    regs.reg[FS19XX_REG_STATUS]=FS19XX_STATUS_PLLS; poll();
    assert(amp.powered && !amp.unmute_work.pending);
    assert(regs.reg[FS19XX_REG_DACCTRL]==FS19XX_DACCTRL_RUN);
    assert(regs.reg[FS19XX_REG_TSCTRL]&FS19XX_TSCTRL_TSEN);
    fs19xx_dai_shutdown(NULL,&dai); stopped();
    unsigned writes=regs.writes; fs19xx_unmute_work(&amp.unmute_work.work);
    assert(regs.writes==writes); /* a stale worker cannot restart a stopped stream */

    start(); for (unsigned i=0;i<FS19XX_LOCK_POLL_COUNT;i++) poll(); stopped();
    start(); regs.fail_read=FS19XX_REG_STATUS; poll(); stopped();
    for (unsigned fault=0;fault<4;fault++) {
        start(); regs.reg[FS19XX_REG_STATUS]=FS19XX_STATUS_PLLS;
        if (fault==0) regs.fail_read=FS19XX_REG_TSCTRL;
        if (fault==1) regs.fail_write=FS19XX_REG_TSCTRL;
        if (fault==2) regs.ignore_ts_write=true;
        if (fault==3) regs.fail_write=FS19XX_REG_DACCTRL;
        poll(); stopped();
    }
    for (unsigned a=FS19XX_REG_PLLCTRL1;a<=FS19XX_REG_PLLCTRL3;a++) {
        fresh(); assert(enabled(1)==1); regs.fail_write=a;
        assert(fs19xx_dai_mute(&dai,0,0)==-EIO); stopped();
        assert(regs.reg[FS19XX_REG_OTPACC]==0);
    }
    fresh(); assert(enabled(1)==1); regs.fail_write=FS19XX_REG_OTPACC;
    assert(fs19xx_dai_mute(&dai,0,0)==-EIO); stopped();
    fresh(); assert(enabled(1)==1); regs.fail_write=FS19XX_REG_PWRCTRL;
    assert(fs19xx_dai_mute(&dai,0,0)==-EIO); stopped();
    fresh(); amp.preset=NULL;
    assert(fs19xx_dai_startup(NULL,&dai)==-ENODEV);
    assert(enabled(1)==1 && fs19xx_dai_mute(&dai,0,0)==-ENODEV); stopped();

    fresh(); assert(volume(0x80)==1 && regs.writes==0);
    assert(volume(-1)==-EINVAL && volume(FS19XX_VOL_MAX+1)==-EINVAL);
    start(); regs.fail_write=FS19XX_REG_VOLCTRL;
    assert(volume(0x80)==-EIO && amp.volume==FS19XX_VOL_DEFAULT);
    regs.fail_write=-1; assert(volume(0x80)==1);
    assert(regs.reg[FS19XX_REG_VOLCTRL]==0x80c0 && amp.volume==0x80);
    fs19xx_volume_get(&control,&value); assert(value.value.integer.value[0]==0x80);
    assert(enabled(-1)==-EINVAL && enabled(2)==-EINVAL);

    start(); assert(fs19xx_suspend(&component)==0); stopped();
    assert(enabled(0)==1 && enabled(1)==1 && !amp.powered);
    assert(fs19xx_dai_mute(&dai,0,0)==-EBUSY);
    assert(fs19xx_resume(&component)==0 && !amp.powered);
    assert(fs19xx_dai_mute(&dai,0,0)==0 && amp.powered);
    struct i2c_client client={.data=&amp}; fs19xx_i2c_remove(&client); stopped();
    assert(enabled(0)==-ENODEV && fs19xx_dai_mute(&dai,0,0)==-ENODEV);
    fresh(); assert(rotation(4)==-EINVAL && regs.writes==0);
    amp.preset=NULL; assert(rotation(1)==-ENODEV && regs.writes==0);
    fresh(); assert(rotation(1)==1 && regs.writes==0 && !amp.powered);
    assert(fs19xx_suspend(&component)==0 && rotation(2)==1 && regs.writes==0);
    assert(fs19xx_resume(&component)==0 && !amp.powered);
    assert(enabled(1)==1 && fs19xx_dai_mute(&dai,0,0)==0);
    assert(FIELD_GET(FS19XX_I2SCTRL_CHS12,regs.reg[FS19XX_REG_I2SCTRL])==2);
    fs19xx_rotation_get(&control,&value); assert(value.value.enumerated.item[0]==2);
    /* Expected rows are LT, RT, LB, RB from the exact OEM position contract. */
    const unsigned positions[]={8,2,4,1};
    const unsigned channels[4][4]={{1,2,1,2},{2,2,1,1},{2,1,2,1},{1,1,2,2}};
    for (unsigned turn=0;turn<4;turn++) for(unsigned pos=0;pos<4;pos++) {
        fresh(); amp.position=positions[pos];
        regs.reg[FS19XX_REG_I2SCTRL]=0xa6e7;
        assert(fs19xx_set_rotation_reg(&amp,turn)==0);
        assert(regs.reg[FS19XX_REG_I2SCTRL]==
            ((0xa6e7 & ~FS19XX_I2SCTRL_CHS12)|FIELD_PREP(FS19XX_I2SCTRL_CHS12,channels[turn][pos])));
    }
    fresh(); amp.position=0; assert(fs19xx_set_rotation_reg(&amp,0)==-EINVAL && regs.writes==0);
    start(); assert(rotation(1)==1 && amp.rotation==1 && amp.powered);
    writes=regs.writes; assert(rotation(1)==0 && regs.writes==writes);
    regs.fail_read=FS19XX_REG_I2SCTRL;
    assert(rotation(2)==-EIO && amp.rotation==1); stopped();
    start(); regs.fail_write=FS19XX_REG_I2SCTRL;
    assert(rotation(2)==-EIO && amp.rotation==0); stopped();
    start(); regs.ignore_i2s_write=true;
    assert(rotation(1)==-EIO && amp.rotation==0); stopped();
    fresh(); regs.fail_write=FS19XX_REG_I2SCTRL;
    assert(enabled(1)==1 && fs19xx_dai_mute(&dai,0,0)==-EIO); stopped();
    assert(FS19XX_VOL_MAX==0xdf);
    puts("FS19xx real lifecycle: clock/thermal faults, retry, switch, shutdown, suspend and remove passed; host only");
}
C
flags=(-O1 -g -Wall -Wextra -Werror -Wno-unused-function -Wno-unused-parameter)
cc=${CC:-clang}
if ! "$cc" "${flags[@]}" -fsanitize=address,undefined -fno-sanitize-recover=undefined \
    "$work/check.c" -o "$work/check" 2>"$work/compile.log"; then
    printf 'ASan unavailable; using trapping UBSan\n' >&2
    "$cc" "${flags[@]}" -fsanitize=undefined -fsanitize-undefined-trap-on-error \
        "$work/check.c" -o "$work/check" || { cat "$work/compile.log" >&2; exit 1; }
fi
"$work/check"
if grep -Eq 'module_param\((force_unmute|max_volume)' "$source_file"; then
    echo 'Unqualified amplifier bypass remains' >&2; exit 1
fi
