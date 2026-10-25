#!/usr/bin/env bash
# shellcheck disable=SC2129
# Execute the panel's scoped OEM timing callbacks without target I/O.
set -Eeuo pipefail
panel=${1:?Pass panel-xiaomi-o82.c}
modes=${2:?Pass o82-data.h}
mode_header=${3:?Pass o82-mode.h}
api_header=${4:?Pass qcom-uke-display.h}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work/drm"
: > "$work/drm/drm_modes.h"
cp "$mode_header" "$work/o82-mode.h"
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint64_t u64;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define BIT(n) (1U<<(n))
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define MIPI_DSI_DCS_LONG_WRITE 0x39
struct drm_display_mode {
    unsigned int clock,hdisplay,hsync_start,hsync_end,htotal;
    unsigned int vdisplay,vsync_start,vsync_end,vtotal,width_mm,height_mm,flags,hskew,vscan;
};
#include "o82-mode.h"
static unsigned int drm_mode_vrefresh(const struct drm_display_mode *m) {
    u64 total=(u64)m->htotal*m->vtotal;
    return ((u64)m->clock*1000+total/2)/total;
}
struct drm_panel {int unused;};
struct mipi_dsi_device {int unused;};
struct mipi_dsi_msg {unsigned int type,channel,flags;size_t tx_len;const void *tx_buf;};
struct mutex {bool locked;};
static void mutex_lock(struct mutex *m) {assert(!m->locked);m->locked=true;}
static void mutex_unlock(struct mutex *m) {assert(m->locked);m->locked=false;}
typedef struct {u64 value;} atomic64_t;
static u64 atomic64_read(const atomic64_t *a) {return a->value;}
C
{
    sed -n '/^struct qcom_uke_o82_dfps_ops {/,/^};/p' "$api_header"
    sed -n '/^struct o82_command {/,/^struct o82_panel {/p' "$panel" |
        sed '$d; /#include "o82-data.h"/d'
    cat "$modes"
} >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct o82_panel {
    struct drm_panel panel;
    struct mipi_dsi_device *dsi[2];
    struct mutex lock;
    const struct o82_profile *profiles,*active;
    bool oem_refresh_modes,trial_60_120_only,trial_all_rates,prepared,removing;
    atomic64_t touch_state;
};
static struct o82_panel *current;
static unsigned int target_group,pen_calls,tp_calls;
static int pen_error,tp_error;
static void check_messages(const struct mipi_dsi_msg *msgs,const u8 (*data)[2],size_t count) {
    assert(current->lock.locked);
    for(size_t i=0;i<count;i++) {
        assert(msgs[i].type==MIPI_DSI_DCS_LONG_WRITE && !msgs[i].channel && !msgs[i].flags);
        assert(msgs[i].tx_len==2 && msgs[i].tx_buf && !memcmp(msgs[i].tx_buf,data[i],2));
    }
}
static int qcom_uke_dsi_pen_clear_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs) {
    static const u8 expected[3][2]={{0xff,0x10},{0xfb,0x01},{0xb2,0x80}};
    assert(dsi==current->dsi[0]);check_messages(msgs,expected,3);++pen_calls;return pen_error;
}
static int qcom_uke_dsi_tp_fps_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs) {
    u8 expected[4][2]={{0xff,0x10},{0xfb,0x01},{0xb2,0x91},{0xb3,0x40}};
    if(target_group==1) {expected[2][1]=0;expected[3][1]=0;}
    if(target_group==2) {expected[2][1]=0;expected[3][1]=0x80;}
    assert(dsi==current->dsi[0]);check_messages(msgs,expected,4);++tp_calls;return tp_error;
}
C
sed -n '/^static bool o82_dfps_check_locked(/,/^static const struct drm_panel_funcs/p' "$panel" |
    sed '$d' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
int main(void) {
    static struct mipi_dsi_device links[2];
    static struct o82_panel ctx={.dsi={&links[0],&links[1]},.profiles=o82_42_02_0b_profiles,
        .oem_refresh_modes=true,.prepared=true,.touch_state={5}};
    current=&ctx;
    assert(!o82_dfps_ops.check(NULL,NULL,NULL));
    assert(o82_dfps_ops.apply(NULL,NULL,NULL,false)==-EINVAL);
    for(size_t i=0;i<ARRAY_SIZE(o82_modes);i++)for(size_t j=0;j<ARRAY_SIZE(o82_modes);j++) {
        const struct drm_display_mode *old=&o82_modes[i].mode,*target=&o82_modes[j].mode;
        const struct o82_profile *original=&ctx.profiles[o82_modes[i].group];
        ctx.active=original;target_group=o82_modes[j].group;
        pen_calls=tp_calls=0;pen_error=tp_error=0;
        assert(o82_dfps_ops.check(&ctx.panel,old,target)==(i!=j));
        assert(!pen_calls && !tp_calls && !ctx.lock.locked);
        if(i==j) {
            assert(o82_dfps_ops.apply(&ctx.panel,old,target,false)==-EAGAIN);continue;
        }
        const bool pen=drm_mode_vrefresh(old)==60 && drm_mode_vrefresh(target)!=120;
        assert(o82_dfps_ops.apply(&ctx.panel,old,target,true)==0);
        assert(pen_calls==pen && !tp_calls && ctx.active==original);
        assert(o82_dfps_ops.apply(&ctx.panel,old,target,false)==0);
        assert(tp_calls==1 && ctx.active==&ctx.profiles[target_group]);
        assert(ctx.touch_state.value==5 && ctx.prepared && !ctx.removing && !ctx.lock.locked);
        ctx.active=original;tp_error=-EIO;
        assert(o82_dfps_ops.apply(&ctx.panel,old,target,false)==-EIO && ctx.active==original);
        if(pen) {
            pen_error=-ETIMEDOUT;
            assert(o82_dfps_ops.apply(&ctx.panel,old,target,true)==-ETIMEDOUT && ctx.active==original);
        }
    }
    const struct drm_display_mode *old=&o82_modes[5].mode,*target=&o82_modes[6].mode;
    for(unsigned int bad=0;bad<8;bad++) {
        struct drm_display_mode altered=*target;
        ctx.active=&ctx.profiles[0];ctx.profiles=o82_42_02_0b_profiles;
        ctx.prepared=ctx.oem_refresh_modes=true;ctx.removing=false;ctx.touch_state.value=5;
        pen_calls=tp_calls=0;
        switch(bad) {
        case 0:ctx.oem_refresh_modes=false;break;
        case 1:ctx.prepared=false;break;
        case 2:ctx.removing=true;break;
        case 3:ctx.touch_state.value=4;break;
        case 4:ctx.active=&ctx.profiles[1];break;
        case 5:ctx.profiles=o82_36_02_0a_profiles;break;
        case 6:altered.clock++;break;
        case 7:old=NULL;break;
        }
        assert(!o82_dfps_ops.check(&ctx.panel,old,&altered));
        assert(o82_dfps_ops.apply(&ctx.panel,old,&altered,true)==-EAGAIN);
        assert(o82_dfps_ops.apply(&ctx.panel,old,&altered,false)==-EAGAIN);
        assert(!pen_calls && !tp_calls && !ctx.lock.locked);
    }
    ctx.profiles=o82_36_02_0a_profiles;
    ctx.trial_60_120_only=true;
    ctx.oem_refresh_modes=ctx.prepared=true;
    ctx.removing=false;ctx.touch_state.value=5;
    for(size_t i=3;i<=5;i+=2)for(size_t j=3;j<=5;j+=2) {
        const struct drm_display_mode *old=&o82_modes[i].mode,*target=&o82_modes[j].mode;
        ctx.active=&ctx.profiles[0];target_group=0;pen_calls=tp_calls=0;
        assert(o82_dfps_ops.check(&ctx.panel,old,target)==(i!=j));
        if(i==j) continue;
        assert(o82_dfps_ops.apply(&ctx.panel,old,target,true)==0);
        assert(o82_dfps_ops.apply(&ctx.panel,old,target,false)==0);
        assert(tp_calls==1 && !ctx.lock.locked);
    }
    ctx.active=&ctx.profiles[0];
    assert(!o82_dfps_ops.check(&ctx.panel,&o82_modes[3].mode,&o82_modes[6].mode));
    ctx.trial_all_rates=true;
    for(size_t i=0;i<ARRAY_SIZE(o82_modes);i++)for(size_t j=0;j<ARRAY_SIZE(o82_modes);j++) {
        ctx.active=&ctx.profiles[o82_modes[i].group];
        assert(o82_dfps_ops.check(&ctx.panel,&o82_modes[i].mode,&o82_modes[j].mode)==(i!=j));
    }
    ctx.trial_all_rates=false;
    ctx.trial_60_120_only=false;
    assert(!o82_dfps_ops.check(&ctx.panel,&o82_modes[3].mode,&o82_modes[5].mode));
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare \
    -fsanitize=undefined -fsanitize-undefined-trap-on-error -I"$work" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual O82 DFPS callbacks: 42 transitions, exact OEM pen/TP batches, scope/readiness rejection and failure-state preservation passed\n'
