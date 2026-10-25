#!/usr/bin/env bash
# shellcheck disable=SC2129
# Execute the candidate panel's real lifecycle functions with bounded host I/O.
set -Eeuo pipefail
source_file=${1:?Pass panel-xiaomi-o82.c} header=${2:?Pass generated o82-data.h}
kernel=${3:?Pass the prepared kernel source}
[[ $(awk '/ctx->panel.prepare_prev_first = true;/ {ready=1} /drm_panel_add\(&ctx->panel\)/ {print ready+0; exit}' "$source_file") == 1 ]]
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <video/mipi_display.h>
static char last_error[512];
static int on_complete;
static void info(const char *format,...) {
    if(!strcmp(format,"Uke O82 LP ON batching complete: commands=108 chunks=%u bytes=%u\n")) {
        va_list args;va_start(args,format);assert(va_arg(args,unsigned int)==8);
        assert(va_arg(args,unsigned int)==884);va_end(args);++on_complete;
    }
}
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64; typedef uint16_t __be16; typedef long ssize_t;
#define __packed __attribute__((packed))
#define DIV_ROUND_UP(n,d) (((n)+(d)-1)/(d))
#define BUILD_BUG_ON(c) _Static_assert(!(c), #c)
#define WARN_ON_ONCE(c) (c)
#define DRM_DEBUG_KMS(...) ((void)0)
#define DRM_DEV_ERROR(...) ((void)0)
#define DRM_DEV_INFO(...) ((void)0)
#define DP_SDP_PPS_HEADER_PAYLOAD_BYTES_MINUS_1 127
#define cpu_to_be16(v) ((uint16_t)__builtin_bswap16((uint16_t)(v)))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define ALIGN(n,a) (((n)+(a)-1)&~((a)-1))
#define BIT(n) (1U<<(n))
#define dev_err(dev,fmt,...) ((void)snprintf(last_error,sizeof(last_error),fmt,##__VA_ARGS__))
#define dev_info(dev,fmt,...) info(fmt,##__VA_ARGS__)
#define dev_warn(...) ((void)0)
#define dev_err_probe(dev,err,...) (err)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
#define IS_ERR(p) ((uintptr_t)(p)>=(uintptr_t)-4095)
#define PTR_ERR(p) ((long)(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
enum { MIPI_DSI_MSG_USE_LPM=2, MIPI_DSI_FMT_RGB101010=10,
       DRM_MODE_TYPE_DRIVER=1, DRM_MODE_TYPE_PREFERRED=2 };
C
# Use the selected kernel's public flag definitions.
awk '/^#define MIPI_DSI_MODE_VIDEO[ \t]|^#define MIPI_DSI_CLOCK_NON_CONTINUOUS[ \t]|^#define MIPI_DSI_MODE_LPM[ \t]/' \
    "$kernel/include/drm/drm_mipi_dsi.h" >> "$work/check.c"
# Compile the selected upstream structs, RC calculation and wire packer, not a second serializer.
{
sed -n '/^#define DSC_NUM_BUF_RANGES/,/^} __packed;/p' "$kernel/include/drm/display/drm_dsc.h"
sed -n '/^enum drm_dsc_params_type {/,/^};/p' "$kernel/include/drm/display/drm_dsc_helper.h"
sed -n '/^void drm_dsc_pps_payload_pack(/,/^EXPORT_SYMBOL(drm_dsc_compute_rc_parameters)/p' \
    "$kernel/drivers/gpu/drm/display/drm_dsc_helper.c" | sed '/^EXPORT_SYMBOL/d'
awk '/^u8 drm_dsc_initial_scale_value\(/ {p=1} p && /^EXPORT_SYMBOL/ {exit} p' \
    "$kernel/drivers/gpu/drm/display/drm_dsc_helper.c"
} >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct device_node { const char *compatible; };
static bool requested_initial60,requested_initial120,requested_oem_modes,requested_trial_rates;
static bool of_property_read_bool(struct device_node *node,const char *property) {
    assert(node);
    if(!strcmp(property,"xiaomi,initial-60hz-only")) return requested_initial60;
    if(!strcmp(property,"xiaomi,initial-120hz-only")) return requested_initial120;
    if(!strcmp(property,"xiaomi,oem-refresh-modes")) return requested_oem_modes;
    assert(!strcmp(property,"xiaomi,o82-36-60-120-trial")); return requested_trial_rates;
}
struct device { struct device_node *of_node; int kobj; };
typedef struct {u64 value;} atomic64_t;
static u64 atomic64_read(const atomic64_t *state) {return state->value;}
static void atomic64_set(atomic64_t *state,u64 value) {state->value=value;}
static void sysfs_notify(int *kobj,const char *directory,const char *name) {
    assert(kobj&&!directory&&!strcmp(name,"touch_reset_state"));
}
struct platform_device { struct device dev; };
struct msm_dsi_host { struct platform_device *pdev; };
static int node_refs;
static struct device_node *of_graph_get_remote_node(struct device_node *n,int port,int ep) {
    assert(port==1 && ep==-1); if(n) node_refs++; return n;
}
static int of_device_is_compatible(struct device_node *n,const char *name) {
    return n && !strcmp(n->compatible,name);
}
static void of_node_put(struct device_node *n) { if(n) node_refs--; }
C
awk '/^static int dsi_populate_dsc_params\(.*$/ && !/;$/ {p=1}
     p && /^static int dsi_host_parse_dt/ {exit} p' \
    "$kernel/drivers/gpu/drm/msm/dsi/dsi_host.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct drm_display_mode { unsigned int clock,hdisplay,hsync_start,hsync_end,htotal,
    vdisplay,vsync_start,vsync_end,vtotal,width_mm,height_mm,type; };
struct drm_panel;
struct drm_panel_funcs {int (*enable)(struct drm_panel *); int (*disable)(struct drm_panel *);};
struct mutex {int locked;};
struct drm_panel {bool enabled; const struct drm_panel_funcs *funcs;
    struct mutex follower_lock; int followers; void *backlight;};
struct drm_panel_follower;
struct follower_ops {int (*panel_enabled)(struct drm_panel_follower *);
    int (*panel_disabling)(struct drm_panel_follower *);};
struct drm_panel_follower {const struct follower_ops *funcs;};
static int backlight_calls,backlight_disable_calls,normal_transfers,hs_transfers,dimming_transfers;
static int batch_api_calls,batch_api_error;
static int lp_api_calls,lp_api_error,lp_api_fail_call=-1;
static int on_batch_calls,on_batch_error=-1,on_batch_counts[8],on_batch_sizes[8],on_batch_total;
static int backlight_enable_error,backlight_disable_error,positive_brightness=1;
static bool boundary_seen;
static bool video_started;
static int post_frame_reads;
static int pre_video_reads;
struct backlight_device {bool on;};
static void mutex_init(struct mutex *lock) {lock->locked=0;}
static void mutex_lock(struct mutex *lock) {assert(!lock->locked); lock->locked=1;}
static void mutex_unlock(struct mutex *lock) {assert(lock->locked); lock->locked=0;}
static int backlight_enable(void *backlight) {
    if(!backlight) return 0;
    assert(boundary_seen && normal_transfers==4 && hs_transfers==8);
    assert(dimming_transfers==0 || dimming_transfers==8);
    ++backlight_calls; ((struct backlight_device *)backlight)->on=true;
    return backlight_enable_error;
}
static int backlight_disable(void *backlight) {
    if(!backlight) return 0;
    ++backlight_disable_calls; if(backlight_disable_error) return backlight_disable_error;
    ((struct backlight_device *)backlight)->on=false; return 0;
}
static int backlight_get_brightness(struct backlight_device *backlight) {
    return backlight->on ? positive_brightness:0;
}
#define list_for_each_entry(entry,head,member) for(entry=NULL;entry;entry=NULL)
struct drm_crtc_state { struct drm_display_mode adjusted_mode; };
struct drm_crtc { struct drm_crtc_state *state; u64 count; };
struct kthread_work {void (*func)(struct kthread_work *);};
struct drm_vblank_work {struct kthread_work base; struct drm_crtc *crtc; u64 count; bool pending;};
#define to_drm_vblank_work(work) container_of(work,struct drm_vblank_work,base)
static int schedule_result=1,scheduled,cancelled;
static bool dispatch_during_cancel;
static void drm_vblank_work_init(struct drm_vblank_work *work,struct drm_crtc *crtc,
    void (*func)(struct kthread_work *)) {
    assert(crtc); work->base.func=func; work->crtc=crtc; work->pending=false;
}
static u64 drm_crtc_vblank_count(struct drm_crtc *crtc) {return crtc->count;}
static int drm_vblank_work_schedule(struct drm_vblank_work *work,u64 count,bool nextonmiss) {
    assert(nextonmiss && count==work->crtc->count+1 && !work->pending);
    assert(!backlight_calls && !normal_transfers && !hs_transfers); ++scheduled;
    if(schedule_result>0) {work->pending=true; work->count=count;}
    return schedule_result;
}
static bool drm_vblank_work_cancel_sync(struct drm_vblank_work *work) {
    bool pending=work->pending; ++cancelled;
    if(pending && dispatch_during_cancel) {
        boundary_seen=true; work->crtc->count=work->count;
        work->pending=false; work->base.func(&work->base);
    }
    work->pending=false; return pending;
}
static void first_boundary(struct drm_vblank_work *work) {
    assert(work->pending); boundary_seen=true;
    work->crtc->count=work->count; work->pending=false; work->base.func(&work->base);
}
struct drm_connector_state { struct drm_crtc *crtc; };
struct drm_connector { struct drm_connector_state *state; void *dev;
    struct { int bpc,width_mm,height_mm; } display_info; };
static unsigned int published, preferred, preferred_rate, duplication_failure;
static struct drm_display_mode copies[7];
static int drm_mode_vrefresh(const struct drm_display_mode *m) {
    uint64_t total=(uint64_t)m->htotal*m->vtotal;
    return ((uint64_t)m->clock*1000+total/2)/total;
}
static struct drm_display_mode *drm_mode_duplicate(void *dev,const struct drm_display_mode *mode) {
    (void)dev; assert(published<7);
    if(duplication_failure) return NULL;
    copies[published]=*mode; return &copies[published];
}
static void drm_mode_set_name(struct drm_display_mode *mode) { (void)mode; }
static void drm_mode_probed_add(struct drm_connector *c,struct drm_display_mode *mode) {
    (void)c; assert(mode->type&DRM_MODE_TYPE_DRIVER);
    if(mode->type&DRM_MODE_TYPE_PREFERRED) { preferred_rate=drm_mode_vrefresh(mode); preferred++; }
    published++;
}
struct regulator { int id; }; struct gpio_desc {};
struct mipi_dsi_msg { unsigned int channel,type,flags; size_t tx_len; const void *tx_buf; };
struct mipi_dsi_host;
struct host_ops { ssize_t (*transfer)(struct mipi_dsi_host *,const struct mipi_dsi_msg *); };
struct mipi_dsi_host { struct host_ops *ops; int id; };
struct mipi_dsi_device { struct mipi_dsi_host *host; unsigned long mode_flags;
    unsigned int lanes,format; struct drm_dsc_config *dsc; int id; struct device dev; };
static void qcom_uke_dsi_update_vrr(struct mipi_dsi_device *d,struct drm_connector *c) {
    (void)d; assert(published && c->display_info.bpc==10);
}
static ssize_t mipi_dsi_dcs_read(struct mipi_dsi_device *d,u8 reg,void *value,size_t len) {
    assert(d->id==0 && !(d->mode_flags&MIPI_DSI_MODE_LPM) && len==1);
    assert(reg==0xda || reg==0x0a || (reg>=0x0c && reg<=0x0f) || reg==0x54);
    if(video_started) {
        assert(boundary_seen && backlight_calls>=1 && normal_transfers>=4 && hs_transfers>=8);
        ++post_frame_reads;
    } else {assert(reg==0xda || reg==0x0a); ++pre_video_reads;}
    *(u8 *)value=0; return 1;
}
/* Working OEM PPS buffer after full off/on: full picture, not encoder width. */
static const u8 golden_pps[128]={
    0x11,0,0,0xab,0x30,0x80,0x08,0x58,0x0c,0x80,0,0x18,0x03,0x20,0x03,0x20,
    0x02,0,0x02,0xb2,0,0x20,0x02,0x9f,0,0x0b,0,0x0d,0x04,0x86,0x02,0xdc,
    0x18,0,0x10,0xf0,0x07,0x10,0x20,0,0x06,0x0f,0x0f,0x33,0x0e,0x1c,0x2a,0x38,
    0x46,0x54,0x62,0x69,0x70,0x77,0x79,0x7b,0x7d,0x7e,0x02,0x02,0x22,0,0x2a,0x40,
    0x2a,0xbe,0x3a,0xfc,0x3a,0xfa,0x3a,0xf8,0x3b,0x38,0x3b,0x78,0x3b,0xb6,0x4b,0xf6,
    0x4c,0x34,0x4c,0x74,0x5c,0x74,0x8c,0xf4
};
int balance[3], loads[3], enables, disables, transfers, failure=-1, operation, gpio_failure,
    short_write, wire_write, transfer_failure=-1, disable_failure=-1, settle_ms, off_order[3],
    lpm_transfers, pps_transfers, pps_start, transfer_short=-1;
static u8 hs_payloads[8][2];
static bool drm_mode_equal(const struct drm_display_mode *a,const struct drm_display_mode *b) {
    return !memcmp(a,b,offsetof(struct drm_display_mode,width_mm));
}
static int regulator_set_load(struct regulator *r,int load) {
    if (operation++==failure) return -EIO; loads[r->id]=load; return 0;
}
static int regulator_enable(struct regulator *r) {
    if (operation++==failure) return -EIO; balance[r->id]++; enables++; return 0;
}
static int regulator_disable(struct regulator *r) {
    if (r->id==disable_failure) return -EIO;
    assert(balance[r->id]==1); balance[r->id]--; off_order[disables++%3]=r->id; return 0;
}
static int gpiod_direction_output(struct gpio_desc *g,int value) {
    (void)g; assert(value==0); return gpio_failure ? -EIO : 0;
}
static void gpiod_set_value_cansleep(struct gpio_desc *g,int value) { (void)g; (void)value; }
static void msleep(unsigned int ms) {
    assert(ms<=200); /* Readiness follows completed commands, not the removed diagnostic timer. */
    settle_ms+=ms;
}
static ssize_t transfer(struct mipi_dsi_host *host,const struct mipi_dsi_msg *m) {
    assert((m->flags==MIPI_DSI_MSG_USE_LPM || m->flags==0) && m->channel==0 && m->tx_len>0);
    if (m->flags==MIPI_DSI_MSG_USE_LPM) {
        lpm_transfers++;
        if(video_started) {
            if(normal_transfers==4) {
                static const u8 dimming[4][2]={{0xff,0x27},{0xd1,0x28},{0xff,0x10},{0x53,0x2c}};
                assert(dimming_transfers<8 && host->id==dimming_transfers%2);
                assert(boundary_seen && backlight_calls==0 && hs_transfers==8);
                assert(m->type==(dimming_transfers<4 ? 0x39U:0x15U) && m->tx_len==2);
                assert(!memcmp(m->tx_buf,dimming[dimming_transfers/2],2));
                ++dimming_transfers;
            } else {
            static const u8 normal[2][2]={{0xff,0x10},{0x13,0x00}};
            if(!normal_transfers)dimming_transfers=0;
            assert(hs_transfers==8 && normal_transfers<4);
            assert(host->id==normal_transfers%2 && backlight_calls==0 && boundary_seen);
            assert(m->type==(normal_transfers<2 ? 0x15U:0x39U) && m->tx_len==2);
            assert(!memcmp(m->tx_buf,normal[normal_transfers/2],2));
            normal_transfers++;
            }
        }
    }
    else {
        assert(video_started && boundary_seen && pps_transfers==2 && hs_transfers<8);
        assert(m->type==0x39 && m->tx_len==2);
        memcpy(hs_payloads[hs_transfers++],m->tx_buf,2);
    }
    const int n=transfers++; if(n==transfer_failure) return -EIO;
    if(m->type==MIPI_DSI_PICTURE_PARAMETER_SET) {
        assert(n==pps_start+pps_transfers);
        assert(m->flags==MIPI_DSI_MSG_USE_LPM && m->tx_len==128);
        assert(!memcmp(m->tx_buf,golden_pps,128)); pps_transfers++;
    }
    return short_write || n==transfer_short ? 0 : (ssize_t)(wire_write ? (m->tx_len+7)&~3UL : m->tx_len);
}
/* Panel fixture observes the API's ordered payloads; the host fixture executes
 * the actual single-DMA transport, packet builder, locks and timeout cleanup.
 */
static int qcom_uke_dsi_tp_fps_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs) {
    assert(dsi->id==0&&boundary_seen&&video_started);++batch_api_calls;
    if(batch_api_error)return batch_api_error;
    static struct mipi_dsi_host peer={.id=1};
    for(int i=0;i<4;i++)for(int link=0;link<2;link++) {
        ssize_t ret=transfer(link ? &peer:dsi->host,&msgs[i]);
        if(ret<2)return ret<0 ? (int)ret:-EIO;
    }
    return 0;
}
static int qcom_uke_dsi_lp_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs,unsigned int count) {
    assert(dsi->id==0&&boundary_seen&&video_started&&backlight_calls==0);
    assert(count==(normal_transfers==0 ? 2U:4U));
    int call=lp_api_calls++;
    if(call==lp_api_fail_call)return lp_api_error;
    static struct mipi_dsi_host peer={.id=1};
    for(unsigned int i=0;i<count;i++)for(int link=0;link<2;link++) {
        assert(msgs[i].flags==MIPI_DSI_MSG_USE_LPM);
        ssize_t ret=transfer(link ? &peer:dsi->host,&msgs[i]);
        if(ret<2)return ret<0 ? (int)ret:-EIO;
    }
    return 0;
}
static int qcom_uke_dsi_on_batch(struct mipi_dsi_device *dsi,const struct mipi_dsi_msg *msgs,unsigned int count) {
    static const int counts[8]={7,6,31,31,28,3,1,1},sizes[8]={56,48,248,248,244,24,8,8};
    assert(!video_started&&!boundary_seen&&dsi->id==0&&count<=31&&on_batch_calls<8);
    unsigned int bytes=0;
    for(unsigned int i=0;i<count;i++) {
        assert(msgs[i].type==0x39&&msgs[i].channel==0&&msgs[i].flags==MIPI_DSI_MSG_USE_LPM);
        bytes+=ALIGN(msgs[i].tx_len+4,4);
    }
    assert(count==counts[on_batch_calls]&&bytes==sizes[on_batch_calls]);
    int call=on_batch_calls++;on_batch_counts[call]=count;on_batch_sizes[call]=bytes;on_batch_total+=bytes;
    if(call==on_batch_error)return -EIO;
    static struct mipi_dsi_host peer={.id=1};
    for(unsigned int i=0;i<count;i++)for(int link=0;link<2;link++) {
        ssize_t ret=transfer(link ? &peer:dsi->host,&msgs[i]);
        if(ret<(ssize_t)msgs[i].tx_len)return ret<0 ? (int)ret:-EIO;
    }
    return 0;
}
C
{
sed -n '/^struct o82_command {/,/^struct o82_panel {/p' "$source_file" | sed '$d; /#include "o82-data.h"/d'
cat "$header"
sed -n '/^struct o82_panel {/,/^};/p' "$source_file"
sed -n '/^static void o82_touch_state(/,/^static int o82_get_modes(/p' "$source_file" | sed '$d'
sed -n '/^static int o82_get_modes(/,/^static bool o82_dfps_check_locked(/p' "$source_file" | sed '$d'
} >> "$work/check.c"
# Execute the selected DRM core's duplicate-enable guard and backlight admission.
sed -n '/^void drm_panel_enable(/,/^EXPORT_SYMBOL(drm_panel_enable)/p' \
    "$kernel/drivers/gpu/drm/drm_panel.c" | sed '$d' >> "$work/check.c"
sed -n '/^void drm_panel_disable(/,/^EXPORT_SYMBOL(drm_panel_disable)/p' \
    "$kernel/drivers/gpu/drm/drm_panel.c" | sed '$d' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct o82_panel *attach_ctx;
static int attach_failure,attached,detached,panel_removed,secondary_removed;
struct qcom_uke_o82_dfps_ops {int unused;};
static const struct qcom_uke_o82_dfps_ops o82_dfps_ops={0};
static int dfps_register_calls,dfps_unregister_calls,dfps_register_error;
static int qcom_uke_dsi_dfps_register(struct mipi_dsi_device *dsi,
    struct drm_panel *panel,const struct qcom_uke_o82_dfps_ops *ops) {
    assert(dsi==attach_ctx->dsi[0] && panel==&attach_ctx->panel && !attach_ctx->lock.locked);
    if(ops) {
        assert(ops==&o82_dfps_ops && attached==2 && !detached);
        ++dfps_register_calls; return dfps_register_error;
    }
    ++dfps_unregister_calls; return 0;
}
static struct backlight_device *probe_backlight;
static struct backlight_device *devm_of_find_backlight(struct device *dev) {
    (void)dev; return probe_backlight;
}
static int mipi_dsi_attach(struct mipi_dsi_device *dsi) {
    int id=attached++;
    assert(id<2 && dsi==attach_ctx->dsi[id]);
    assert(dsi->mode_flags==(MIPI_DSI_MODE_VIDEO|MIPI_DSI_CLOCK_NON_CONTINUOUS|MIPI_DSI_MODE_LPM));
    assert(dsi->lanes==4 && dsi->format==MIPI_DSI_FMT_RGB101010 && dsi->dsc==&attach_ctx->dsc);
    return id==attach_failure ? -EIO:0;
}
static void mipi_dsi_detach(struct mipi_dsi_device *dsi) {
    assert(dsi==attach_ctx->dsi[0] || dsi==attach_ctx->dsi[1]);
    assert(!attach_ctx->first_frame_initialized && !attach_ctx->prepared); ++detached;
}
static void drm_panel_remove(struct drm_panel *panel) {
    assert(panel==&attach_ctx->panel && !attach_ctx->first_frame_initialized); ++panel_removed;
}
static void mipi_dsi_device_unregister(struct mipi_dsi_device *dsi) {
    assert(dsi==attach_ctx->dsi[1]); ++secondary_removed;
}
/* Execute the actual probe's attachment loop and its failure unwind. Resource
 * discovery before this block is outside the clock-policy change's scope.
 */
static int o82_probe_links(struct o82_panel *ctx) {
    int i,ret;
    struct mipi_dsi_device *dsi=ctx->dsi[0];
C
awk '
    /^static int o82_probe\(/ { probe=1 }
    probe && /^\tfor \(i = 0; i < ARRAY_SIZE\(ctx->dsi\); i\+\+\)/ { emit=1 }
    emit && /^static void o82_remove/ { exit }
    emit && !/^unregister_secondary:/ { print }
' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int o82_probe_backlight(struct o82_panel *ctx) {
    struct device device={0},*dev=&device;
    int ret;
C
awk '
    /^static int o82_probe\(/ {probe=1}
    probe && /^\tctx->backlight = devm_of_find_backlight/ {emit=1}
    emit && /^\tmipi_dsi_set_drvdata/ {exit}
    emit {print}
' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
    return 0;
unregister_secondary:
    return ret;
}
static struct o82_panel *mipi_dsi_get_drvdata(struct mipi_dsi_device *dsi) {
    assert(dsi==attach_ctx->dsi[0]); return attach_ctx;
}
C
sed -n '/^static void o82_remove(/,/^static const struct of_device_id/p' "$source_file" | sed '$d' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
/* Execute the probe's profile admission before any regulator acquisition. */
static int o82_probe_initial_mode(struct o82_panel *ctx,struct device_node *node) {
    struct device device={.of_node=node},*dev=&device;
    int ret;
C
awk '
    /^static int o82_probe\(/ { probe=1 }
    probe && /^\tret = o82_read_initial_mode\(/ { emit=1 }
    emit && /^\tfor \(i = 0; i < ARRAY_SIZE\(supply_names\)/ { exit }
    emit { print }
' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
    return 0;
}
static struct o82_panel context(int variant,int mode) {
    static const struct drm_panel_funcs funcs={.enable=o82_enable,.disable=o82_disable};
    static struct host_ops ops={transfer};
    static struct mipi_dsi_host hosts[2]={{&ops,0},{&ops,1}};
    static struct mipi_dsi_device dsis[2]={{.host=&hosts[0],.mode_flags=MIPI_DSI_MODE_LPM},
                                         {.host=&hosts[1],.mode_flags=MIPI_DSI_MODE_LPM,.id=1}};
    static struct regulator supplies[3]={{0},{1},{2}};
    static struct drm_crtc_state cs;
    static struct drm_crtc crtc={.state=&cs};
    static struct drm_connector_state state={&crtc};
    static struct drm_connector connector={.state=&state};
    static struct backlight_device backlight;
    memset(balance,0,sizeof(balance)); memset(loads,0,sizeof(loads));
    enables=disables=transfers=operation=gpio_failure=short_write=wire_write=settle_ms=0;
    lpm_transfers=hs_transfers=pps_transfers=normal_transfers=dimming_transfers=0;
    batch_api_calls=batch_api_error=0;
    lp_api_calls=lp_api_error=0;lp_api_fail_call=-1;
    post_frame_reads=0;
    pre_video_reads=0;
    on_batch_calls=on_batch_total=on_complete=0;on_batch_error=-1;
    backlight_calls=backlight_disable_calls=backlight_enable_error=backlight_disable_error=0;
    scheduled=cancelled=0; schedule_result=positive_brightness=1;
    video_started=boundary_seen=backlight.on=dispatch_during_cancel=false; crtc.count=100;
    last_error[0]=0;
    failure=transfer_failure=disable_failure=transfer_short=-1;
    cs.adjusted_mode=o82_modes[mode].mode;
    const struct o82_profile *p=(variant==0 || variant==3) ? o82_36_02_0a_profiles : o82_42_02_0b_profiles;
    struct o82_panel ctx={.panel={.funcs=&funcs},.dsi={&dsis[0],&dsis[1]},.supplies={&supplies[0],&supplies[1],&supplies[2]},
        .connector=&connector,.backlight=&backlight,.profiles=p,.active=p,
        .initial_120hz_only=variant==1 && mode==5,.oem_refresh_modes=variant>=2,
        .trial_60_120_only=variant==3};
    mutex_init(&ctx.lock);
    pps_start=2*p[o82_modes[mode].group].on_count;
    struct device_node node={(variant==0 || variant==3) ? "xiaomi,o82-36-02-0a" : "xiaomi,o82-42-02-0b"};
    struct platform_device platform={.dev={.of_node=&node}};
    struct msm_dsi_host h={&platform};
    ctx.dsc=(struct drm_dsc_config){.dsc_version_major=1,.dsc_version_minor=1,
        .slice_width=800,.slice_height=24,.slice_count=2,.bits_per_component=10,
        .bits_per_pixel=8<<4,.block_pred_enable=true,.pic_width=3200,.pic_height=2136};
    assert(dsi_populate_dsc_params(&h,&ctx.dsc)==0 && node_refs==0);
    assert(ctx.dsc.first_line_bpg_offset==13 && ctx.dsc.rc_range_params[0].range_max_qp==8);
    assert(ctx.dsc.initial_dec_delay==690 && ctx.dsc.nfl_bpg_offset==1158 &&
           ctx.dsc.scale_increment_interval==671 && ctx.dsc.slice_bpg_offset==732);
    return ctx;
}
int main(void) {
    for(int result=0;result<4;result++) {
        struct o82_panel ctx=context(0,3);
        probe_backlight=result==0 ? ctx.backlight:result==1 ? NULL:ERR_PTR(result==2 ? -EIO:-ENODEV);
        ctx.backlight=NULL;
        assert(o82_probe_backlight(&ctx)==(result==0 ? 0:result==2 ? -EIO:-ENODEV));
        assert(!ctx.panel.backlight && ctx.backlight==probe_backlight);
        assert(!enables && !transfers && !operation && !scheduled);
        if(result==0) assert(backlight_disable_calls==1 && !ctx.backlight->on);
    }
    {
        struct o82_panel ctx=context(0,3);
        probe_backlight=ctx.backlight; backlight_disable_error=-EIO;
        assert(o82_probe_backlight(&ctx)==-EIO && !transfers && !scheduled);
    }
    for(int variant=0;variant<2;variant++) for(int flags=0;flags<8;flags++) {
        struct o82_panel ctx=context(variant,3);
        struct device_node node={variant ? "xiaomi,o82-42-02-0b" : "xiaomi,o82-36-02-0a"};
        requested_initial60=flags&1; requested_initial120=flags&2; requested_oem_modes=flags&4;
        requested_trial_rates=false;
        const bool invalid=(requested_initial60 && requested_initial120) ||
            (requested_oem_modes && (requested_initial60 || requested_initial120)) ||
            ((requested_initial120 || requested_oem_modes) && !variant);
        assert(o82_probe_initial_mode(&ctx,&node)==(invalid ? -EINVAL:0));
        assert(!enables && !transfers && !operation && !ctx.prepared);
        assert(ctx.initial_60hz_only==requested_initial60 && ctx.initial_120hz_only==requested_initial120 &&
               ctx.oem_refresh_modes==requested_oem_modes);
    }
    {
        struct o82_panel ctx=context(3,3);
        struct device_node node={"xiaomi,o82-36-02-0a"};
        requested_initial60=requested_initial120=false;
        requested_oem_modes=requested_trial_rates=true;
        assert(o82_probe_initial_mode(&ctx,&node)==0 && ctx.trial_60_120_only);
        requested_oem_modes=false;
        assert(o82_probe_initial_mode(&ctx,&node)==-EINVAL);
        requested_oem_modes=true;
        node.compatible="xiaomi,o82-42-02-0b";
        assert(o82_probe_initial_mode(&ctx,&node)==-EINVAL);
        requested_trial_rates=false;requested_oem_modes=false;
    }
    {
        struct o82_panel ctx=context(0,3);
        struct device_node node={"unrelated,panel"};
        requested_initial60=requested_initial120=false; requested_oem_modes=true;
        assert(o82_probe_initial_mode(&ctx,&node)==-EINVAL);
        assert(!enables && !transfers && !operation && !ctx.prepared);
        requested_oem_modes=false;
    }
    for(int variant=0;variant<4;variant++) for(int fail=-1;fail<2;fail++) {
        struct o82_panel ctx=context(variant,3); attach_ctx=&ctx;
        dfps_register_calls=dfps_unregister_calls=dfps_register_error=0;
        attach_failure=fail; attached=detached=panel_removed=secondary_removed=0;
        assert(o82_probe_links(&ctx)==(fail<0 ? 0:-EIO));
        assert(attached==(fail==0 ? 1:2));
        assert(detached==(fail==1 ? 1:0));
        assert(panel_removed==(fail>=0) && secondary_removed==(fail>=0));
        assert(dfps_register_calls==(variant>=2 && fail<0) && !dfps_unregister_calls);
    }
    {
        struct o82_panel ctx=context(2,3); attach_ctx=&ctx;
        attach_failure=-1; attached=detached=panel_removed=secondary_removed=0;
        dfps_register_calls=dfps_unregister_calls=0; dfps_register_error=-EIO;
        assert(o82_probe_links(&ctx)==-EIO);
        assert(attached==2 && detached==2 && panel_removed==1 && secondary_removed==1);
        assert(dfps_register_calls==1 && !dfps_unregister_calls);
        dfps_register_error=0;
    }
    const unsigned int rates[]={30,48,50,60,90,120,144};
    const unsigned int groups[]={2,2,2,0,2,0,1};
    assert(ARRAY_SIZE(o82_modes)==7);
    struct o82_panel selection=context(0,3);
    published=preferred=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==7 && published==7 && preferred==1 && preferred_rate==60);
    selection.initial_60hz_only=true; published=preferred=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==1 && published==1 && preferred==1);
    assert(drm_mode_vrefresh(&copies[0])==60 && preferred_rate==60);
    duplication_failure=1; published=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==-ENOMEM && !published);
    duplication_failure=0;
    selection=context(1,5); published=preferred=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==1 && published==1 && preferred==1);
    assert(drm_mode_vrefresh(&copies[0])==120 && preferred_rate==120);
    duplication_failure=1; published=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==-ENOMEM && !published);
    duplication_failure=0;
    selection=context(2,5); published=preferred=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==7 && published==7 && preferred==1 && preferred_rate==120);
    for(unsigned int m=0;m<ARRAY_SIZE(rates);m++) assert(drm_mode_vrefresh(&copies[m])==rates[m]);
    duplication_failure=1; published=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==-ENOMEM && !published);
    duplication_failure=0;
    selection=context(3,3); published=preferred=0;
    assert(o82_get_modes(&selection.panel,selection.connector)==2 && published==2 && preferred==1 && preferred_rate==60);
    assert(drm_mode_vrefresh(&copies[0])==60 && drm_mode_vrefresh(&copies[1])==120);
    for(int trial_mode=3;trial_mode<=5;trial_mode+=2) {
        struct o82_panel trial=context(3,trial_mode);
        assert(o82_prepare(&trial.panel)==0 && trial.prepared && !on_batch_calls);
        video_started=true;
        drm_panel_enable(&trial.panel);
        first_boundary(&trial.first_frame_work);
        assert(trial.backlight->on && atomic64_read(&trial.touch_state)==3);
        assert(!on_batch_calls && !batch_api_calls && !lp_api_calls && !dimming_transfers);
        drm_panel_disable(&trial.panel);
        video_started=false;
        assert(o82_unprepare(&trial.panel)==0 && !trial.prepared);
    }
    for(int mode=0;mode<7;mode++) {
        if(mode==5) continue;
        struct o82_panel ctx=context(1,mode); ctx.initial_120hz_only=true;
        assert(o82_prepare(&ctx.panel)==-EINVAL && !enables && !transfers && !operation && !ctx.prepared);
    }
    selection=context(1,5); selection.connector->state->crtc->state->adjusted_mode.clock++;
    assert(o82_prepare(&selection.panel)==-EINVAL && !enables && !transfers && !operation);
    for(unsigned int v=0;v<3;v++) for(unsigned int m=0;m<7;m++) {
        const struct drm_display_mode *mode=&o82_modes[m].mode;
        const uint64_t divisor=(uint64_t)mode->htotal*mode->vtotal;
        assert(((uint64_t)mode->clock*1000+divisor/2)/divisor==rates[m]);
        assert(mode->width_mm==237 && mode->height_mm==158 && mode->vtotal<=8191);
        struct o82_panel c=context(v,m);
        const bool batched=c.initial_120hz_only || c.oem_refresh_modes;
        const struct drm_dsc_config encoder=c.dsc;
        drm_panel_enable(&c.panel);
        assert(!c.panel.enabled && !transfers && !backlight_calls);
        assert(o82_prepare(&c.panel)==0 && c.prepared && c.enabled_supplies==7);
        assert(atomic64_read(&c.touch_state)==2); /* reset generation1, not command-ready */
        assert(c.active==&c.profiles[groups[m]]);
        assert(!memcmp(&c.dsc,&encoder,sizeof(encoder)) && pps_transfers==2);
        assert(pre_video_reads==(batched ? 0:2));
        const int full=transfers;
        assert(full==2*(int)(c.active->on_count+1));
        if(batched)assert(on_batch_calls==8&&on_batch_total==884&&on_complete==1);
        else assert(!on_batch_calls&&!on_complete);
        assert(lpm_transfers==2*(int)(c.active->on_count+1));
        assert(!hs_transfers && !c.panel.enabled && !backlight_calls);
        assert(c.active->switch_count==4);
        assert(o82_prepare(&c.panel)==0 && transfers==full && enables==3);
        const int before_enable_wait=settle_ms;
        video_started=true; drm_panel_enable(&c.panel);
        assert(c.panel.enabled && !backlight_calls && enables==3 && scheduled==1);
        assert(!hs_transfers && settle_ms==before_enable_wait);
        assert(!normal_transfers && transfers==full && c.first_frame_work.pending);
        assert(!c.backlight->on && c.first_frame_initialized);
        /* Event-less startup remains nonblocking, blank and cancellable. */
        const int pending_full=transfers;
        drm_panel_enable(&c.panel);
        assert(transfers==pending_full && scheduled==1 && !backlight_calls);
        assert(o82_enable(&c.panel)==-EBUSY && transfers==pending_full && scheduled==1);
        first_boundary(&c.first_frame_work);
        assert(c.backlight->on);
        assert(atomic64_read(&c.touch_state)==3); /* all post-frame groups complete */
        assert(post_frame_reads==0);
        assert(settle_ms==before_enable_wait);
        assert(batch_api_calls==batched);
        assert(lp_api_calls==(batched ? 2:0));
        assert(normal_transfers==4 && transfers==full+(batched ? 20:12) && c.first_frame_initialized);
        assert(dimming_transfers==(batched ? 8:0));
        for(unsigned int command=0;command<c.active->switch_count;command++)
            for(int link=0;link<2;link++)
                assert(!memcmp(hs_payloads[2*command+link],c.active->switch_commands[command].data,2));
        const int enabled_full=transfers;
        drm_panel_enable(&c.panel);
        assert(transfers==enabled_full && backlight_calls==1);
        drm_panel_disable(&c.panel);
        assert(!c.panel.enabled && backlight_disable_calls==2 && cancelled==1);
        assert(atomic64_read(&c.touch_state)==2);
        assert(!c.first_frame_initialized && !c.first_frame_crtc && !c.backlight->on);
        drm_panel_disable(&c.panel);
        assert(backlight_disable_calls==2);
        /* A fresh core enable after disable repeats the panel protocol. */
        hs_transfers=normal_transfers=0; backlight_calls=0; boundary_seen=false;
        drm_panel_enable(&c.panel);
        assert(c.panel.enabled && !backlight_calls && !normal_transfers && !hs_transfers);
        first_boundary(&c.first_frame_work);
        assert(backlight_calls==1 && normal_transfers==4);
        drm_panel_disable(&c.panel);
        video_started=false;
        assert(o82_unprepare(&c.panel)==0 && !c.prepared && !c.enabled_supplies);
        assert(atomic64_read(&c.touch_state)==2);
        assert(off_order[0]==2 && off_order[1]==1 && off_order[2]==0);
        assert(o82_unprepare(&c.panel)==0 && disables==3);
        /* Full unprepare/prepare also retains normal restoration on enable. */
        pps_start=transfers+2*c.active->on_count; pps_transfers=0;
        on_batch_calls=on_batch_total=0;
        hs_transfers=normal_transfers=backlight_calls=0; boundary_seen=false;
        assert(o82_prepare(&c.panel)==0 && c.prepared && pps_transfers==2);
        assert(atomic64_read(&c.touch_state)==4);
        assert(!normal_transfers && !hs_transfers);
        video_started=true; drm_panel_enable(&c.panel);
        assert(c.panel.enabled && !backlight_calls && !normal_transfers && !hs_transfers);
        first_boundary(&c.first_frame_work);
        assert(backlight_calls==1 && normal_transfers==4);
        drm_panel_disable(&c.panel); video_started=false;
        assert(o82_unprepare(&c.panel)==0 && !c.prepared && !c.enabled_supplies);
        for(int fault=0;fault<6;fault++) {
            c=context(v,m); failure=fault;
            assert(o82_prepare(&c.panel)==-EIO && !c.prepared && !c.enabled_supplies);
            for(int i=0;i<3;i++) assert(!balance[i] && !loads[i]);
        }
        for(int fault=0;fault<full;fault++) {
            c=context(v,m); transfer_failure=fault;
            assert(o82_prepare(&c.panel)==-EIO && !c.prepared && !c.enabled_supplies);
            for(int i=0;i<3;i++) assert(!balance[i] && !loads[i]);
            assert(settle_ms>=20+100);
        }
        for(int link=0;link<2;link++) {
            c=context(v,m); transfer_short=pps_start+link;
            assert(o82_prepare(&c.panel)==-EIO && !c.prepared && !c.enabled_supplies);
            for(int i=0;i<3;i++) assert(!balance[i] && !loads[i]);
        }
        for(int short_reply=0;short_reply<2;short_reply++) for(int fault=0;fault<20;fault++) {
            c=context(v,m);
            if(fault>=12 && !c.initial_120hz_only && !c.oem_refresh_modes) continue;
            assert(o82_prepare(&c.panel)==0);
            const int before=transfers;
            if(short_reply) transfer_short=before+fault; else transfer_failure=before+fault;
            video_started=true; drm_panel_enable(&c.panel);
            assert(c.panel.enabled && !backlight_calls && !hs_transfers && c.first_frame_work.pending);
            assert(transfers==before);
            first_boundary(&c.first_frame_work);
            assert(!backlight_calls && strstr(last_error,"result=-5 blank_result=0"));
            assert(strstr(last_error,fault<8 ? "stage=timing-switch":fault<12 ? "stage=normal-pixels":"stage=dimming-on"));
            assert(!c.backlight->on && c.first_frame_initialized);
            drm_panel_disable(&c.panel);
            assert(c.prepared && c.enabled_supplies==7);
            assert(disables==0 && transfers==before+fault+1);
            assert(hs_transfers==(fault<8 ? fault+1:8));
            assert(normal_transfers==(fault<8 ? 0:fault<12 ? fault-7:4));
            transfer_failure=transfer_short=-1; hs_transfers=normal_transfers=backlight_calls=0; boundary_seen=false;
            if(fault&1) {
                drm_panel_enable(&c.panel);
                assert(c.panel.enabled && !backlight_calls && !hs_transfers && !normal_transfers && enables==3);
                first_boundary(&c.first_frame_work);
                assert(backlight_calls==1 && normal_transfers==4);
            }
            drm_panel_disable(&c.panel);
            video_started=false;
            assert(o82_unprepare(&c.panel)==0 && !c.prepared && !c.enabled_supplies);
        }
        c=context(v,m); gpio_failure=1;
        assert(o82_prepare(&c.panel)==-EIO && !c.enabled_supplies);
        c=context(v,m); short_write=1;
        assert(o82_prepare(&c.panel)==-EIO && !c.enabled_supplies);
        c=context(v,m); wire_write=1;
        assert(o82_prepare(&c.panel)==0 && c.prepared);
        assert(o82_unprepare(&c.panel)==0 && !c.enabled_supplies);
        c=context(v,m); assert(o82_prepare(&c.panel)==0); disable_failure=1;
        assert(o82_unprepare(&c.panel)==-EIO && c.enabled_supplies==2);
        assert(o82_prepare(&c.panel)==-EBUSY);
        disable_failure=-1; assert(o82_unprepare(&c.panel)==0 && !c.enabled_supplies);
        c=context(v,m); c.connector=NULL;
        assert(o82_prepare(&c.panel)==-EINVAL && enables==0);
        c=context(v,m); c.dsc.initial_dec_delay=0;
        assert(o82_prepare(&c.panel)==-EINVAL && enables==0 && transfers==0);
        c=context(v,m); c.connector->state->crtc->state->adjusted_mode.clock++;
        assert(o82_prepare(&c.panel)==-EINVAL && enables==0);
    }
    struct o82_panel c=context(0,3);
    for(int variant=0;variant<3;variant++) {
        for(int refusal=0;refusal<3;refusal++) {
            c=context(variant,3); assert(o82_prepare(&c.panel)==0);
            const int before=transfers;
            schedule_result=refusal==0 ? 0:refusal==1 ? -EIO:-EINVAL;
            video_started=true; drm_panel_enable(&c.panel);
            assert(!c.panel.enabled && !c.backlight->on && !backlight_calls && !normal_transfers);
            assert(transfers==before && !hs_transfers && scheduled==1 && cancelled==1);
            assert(!c.first_frame_initialized && strstr(last_error,refusal==2 ? "refused: -22":"refused: -5"));
            video_started=false; assert(o82_unprepare(&c.panel)==0 && !c.prepared);
        }
        for(int fault=0;fault<3;fault++) {
            c=context(variant,3); assert(o82_prepare(&c.panel)==0);
            video_started=true; drm_panel_enable(&c.panel);
            if(fault==0) backlight_enable_error=-EIO;
            else positive_brightness=fault==1 ? 0:-1;
            first_boundary(&c.first_frame_work);
            assert(c.panel.enabled && c.first_frame_initialized);
            assert(strstr(last_error,fault==0 ? "result=-5 blank_result=0":"result=-34 blank_result=0"));
            assert(normal_transfers==4 && !c.backlight->on && backlight_calls==1);
            drm_panel_disable(&c.panel); assert(cancelled==1 && !c.first_frame_initialized);
            video_started=false; assert(o82_unprepare(&c.panel)==0);
        }
        c=context(variant,3); backlight_disable_error=-EIO;
        assert(o82_prepare(&c.panel)==-EIO && !enables && !transfers && !operation);
        c=context(variant,3); assert(o82_prepare(&c.panel)==0);
        video_started=true; drm_panel_enable(&c.panel); dispatch_during_cancel=true;
        drm_panel_disable(&c.panel);
        assert(cancelled==1 && !c.first_frame_initialized && !c.first_frame_crtc);
        assert(backlight_calls==1 && normal_transfers==4 && !c.backlight->on);
        video_started=false; assert(o82_unprepare(&c.panel)==0);
        c=context(variant,3); assert(o82_prepare(&c.panel)==0);
        video_started=true; drm_panel_enable(&c.panel); first_boundary(&c.first_frame_work);
        backlight_disable_error=-EIO; drm_panel_disable(&c.panel);
        assert(!c.panel.enabled && !c.first_frame_initialized && !c.first_frame_crtc);
        assert(strstr(last_error,"backlight blank failed: -5") && c.backlight->on);
        video_started=false; assert(o82_unprepare(&c.panel)==0 && !c.prepared && !c.enabled_supplies);
        backlight_disable_error=0; assert(o82_unprepare(&c.panel)==0 && !c.backlight->on);
        c=context(variant,3); assert(o82_prepare(&c.panel)==0);
        video_started=true; drm_panel_enable(&c.panel);
        backlight_enable_error=-EINVAL; backlight_disable_error=-EIO;
        first_boundary(&c.first_frame_work);
        assert(strstr(last_error,"result=-22 blank_result=-5") && normal_transfers==4);
        assert(c.backlight->on);
        drm_panel_disable(&c.panel); assert(!c.panel.enabled && !c.first_frame_initialized);
        assert(strstr(last_error,"backlight blank failed: -5"));
        video_started=false; assert(o82_unprepare(&c.panel)==0 && !c.prepared);
        c=context(variant,3); assert(o82_prepare(&c.panel)==0);
        video_started=true; drm_panel_enable(&c.panel);
        assert(c.first_frame_work.pending && !c.backlight->on);
        /* No IRQ is required to cancel a pending event before direct teardown. */
        video_started=false; assert(o82_unprepare(&c.panel)==0 && cancelled==1);
        assert(!c.first_frame_initialized && !c.first_frame_work.pending && !c.prepared);
        assert(!hs_transfers && !normal_transfers && !backlight_calls);
        const int after_unprepare=transfers;
        assert(o82_unprepare(&c.panel)==0 && cancelled==1 && transfers==after_unprepare);
        drm_panel_disable(&c.panel);
        for(int callback=0;callback<2;callback++) {
            c=context(variant,3); assert(o82_prepare(&c.panel)==0);
            video_started=true; drm_panel_enable(&c.panel);
            assert(c.first_frame_initialized && c.first_frame_work.pending);
            attach_ctx=&c; detached=panel_removed=secondary_removed=0;
            dfps_unregister_calls=0;
            video_started=false;
            if(callback) o82_shutdown(c.dsi[0]); else o82_remove(c.dsi[0]);
            assert(c.removing && !c.prepared && !c.first_frame_initialized && cancelled==1);
            assert(dfps_unregister_calls==(variant==2));
            assert(!c.backlight->on && !backlight_calls && !normal_transfers);
            assert(detached==(callback ? 0:2) && panel_removed==!callback && secondary_removed==!callback);
            const int after_remove=transfers;
            assert(o82_prepare(&c.panel)==-ESHUTDOWN && o82_enable(&c.panel)==-ESHUTDOWN);
            assert(transfers==after_remove && !c.first_frame_initialized);
        }
    }
    /* Full ON metadata is checked before the first chunk, even near its tail. */
    for(int index=0;index<108;index++)for(int gate=0;gate<2;gate++) {
        c=context(1,5);
        struct o82_profile profiles[3];memcpy(profiles,o82_42_02_0b_profiles,sizeof(profiles));
        struct o82_command commands[108];memcpy(commands,profiles[0].on,sizeof(commands));
        profiles[0].on=commands;c.profiles=profiles;
        if(gate)commands[index].downstream_flags^=BIT(6);else commands[index].delay_ms^=1;
        assert(o82_prepare(&c.panel)==-EINVAL&&!c.prepared&&!on_batch_calls&&!on_complete);
        assert(!pps_transfers&&disables==3&&lpm_transfers==6&&!c.enabled_supplies);
    }
    for(int gate=0;gate<7;gate++) {
        c=context(1,5);
        struct o82_profile profiles[3];memcpy(profiles,o82_42_02_0b_profiles,sizeof(profiles));
        struct o82_command commands[108];memcpy(commands,profiles[0].on,sizeof(commands));
        profiles[0].on=commands;c.profiles=profiles;
        switch(gate) {
        case 0:profiles[0].on_count--;break;
        case 1:commands[107].type=0x15;break;
        case 2:commands[107].channel=1;break;
        case 3:commands[107].len=0;break;
        case 4:commands[107].len=18;break;
        case 5:commands[107].data=NULL;break;
        case 6:commands[0].len=17;break;
        }
        assert(o82_prepare(&c.panel)<0&&!on_batch_calls&&!on_complete&&!pps_transfers);
        assert(disables==3&&!c.enabled_supplies);
    }
    /* Any synchronous ON chunk error suppresses later ON/PPS/HS and unwinds. */
    int successful_settle;
    c=context(1,5);assert(o82_prepare(&c.panel)==0);successful_settle=settle_ms;
    assert(on_complete==1&&on_batch_calls==8);assert(o82_unprepare(&c.panel)==0);
    for(int fault=0;fault<8;fault++) {
        c=context(1,5);on_batch_error=fault;
        assert(o82_prepare(&c.panel)==-EIO&&!c.prepared&&!on_complete);
        assert(on_batch_calls==fault+1&&!pps_transfers&&!hs_transfers&&!normal_transfers);
        assert(disables==3&&!c.enabled_supplies&&!c.loaded_supplies&&!c.backlight->on);
        /* OFF/rail unwind adds126ms; command106 settles even on failed DMA. */
        assert(settle_ms==successful_settle+126+(fault<6 ? -120:0));
    }
    /* The isolated TP batch must not discard future OEM delay/grouping changes. */
    for(int index=0;index<4;index++)for(int gate=0;gate<2;gate++) {
        c=context(1,5);assert(o82_prepare(&c.panel)==0);
        struct o82_command commands[4];
        memcpy(commands,c.active->switch_commands,sizeof(commands));
        struct o82_profile changed=*c.active;changed.switch_commands=commands;c.active=&changed;
        if(gate)commands[index].downstream_flags^=BIT(6);else commands[index].delay_ms=1;
        video_started=true;drm_panel_enable(&c.panel);first_boundary(&c.first_frame_work);
        assert(!batch_api_calls&&!hs_transfers&&!normal_transfers&&!backlight_calls&&!c.backlight->on);
        assert(strstr(last_error,"stage=timing-switch")&&strstr(last_error,"result=-22"));
        drm_panel_disable(&c.panel);video_started=false;assert(o82_unprepare(&c.panel)==0);
    }
    for(int fault=0;fault<4;fault++) {
        static const int errors[]={-EOPNOTSUPP,-EIO,-ETIMEDOUT,-EINVAL};
        c=context(1,5);assert(o82_prepare(&c.panel)==0);batch_api_error=errors[fault];
        video_started=true;drm_panel_enable(&c.panel);first_boundary(&c.first_frame_work);
        assert(batch_api_calls==1&&!hs_transfers&&!normal_transfers&&!backlight_calls&&!c.backlight->on);
        assert(strstr(last_error,"stage=timing-switch")&&!disables);
        drm_panel_disable(&c.panel);video_started=false;assert(o82_unprepare(&c.panel)==0);
    }
    /* The mock observes payload order; actual DMA grouping is checked by the host fixture. */
    for(int short_reply=0;short_reply<2;short_reply++)for(int fault=0;fault<8;fault++) {
        c=context(1,5);assert(o82_prepare(&c.panel)==0);
        int before=transfers;
        if(short_reply)transfer_short=before+12+fault;else transfer_failure=before+12+fault;
        video_started=true;drm_panel_enable(&c.panel);first_boundary(&c.first_frame_work);
        assert(dimming_transfers==fault+1 && !post_frame_reads && !c.backlight->on);
        assert(transfers==before+13+fault && strstr(last_error,"stage=dimming-on"));
        assert(strstr(last_error,"result=-5 blank_result=0"));
        transfer_failure=transfer_short=-1;
        drm_panel_disable(&c.panel);video_started=false;assert(o82_unprepare(&c.panel)==0);
    }
    for(int group=0;group<2;group++)for(int fault=0;fault<4;fault++) {
        static const int errors[]={-EOPNOTSUPP,-EIO,-ETIMEDOUT,-EINVAL};
        c=context(1,5);assert(o82_prepare(&c.panel)==0);
        lp_api_fail_call=group;lp_api_error=errors[fault];
        video_started=true;drm_panel_enable(&c.panel);first_boundary(&c.first_frame_work);
        assert(lp_api_calls==group+1 && !post_frame_reads && !c.backlight->on);
        assert(normal_transfers==(group ? 4:0) && !dimming_transfers);
        assert(strstr(last_error,group ? "stage=dimming-on":"stage=normal-pixels"));
        drm_panel_disable(&c.panel);video_started=false;assert(o82_unprepare(&c.panel)==0);
    }
    /* Refuse changed grouping/delays before the API can send a partial group. */
    for(unsigned int count=2;count<=4;count+=2) {
        struct o82_command commands[4]={0};
        for(unsigned int i=0;i<count;i++)commands[i].downstream_flags=i==count-1 ? 0:BIT(6);
        for(unsigned int i=0;i<count;i++)for(int gate=0;gate<2;gate++) {
            c=context(1,5);assert(o82_prepare(&c.panel)==0);
            if(gate)commands[i].downstream_flags^=BIT(6);else commands[i].delay_ms=1;
            assert(o82_lp_batch(&c,commands,count)==-EINVAL && !lp_api_calls);
            commands[i].downstream_flags=i==count-1 ? 0:BIT(6);commands[i].delay_ms=0;
            assert(o82_unprepare(&c.panel)==0);
        }
        c=context(1,5);assert(o82_prepare(&c.panel)==0);
        for(unsigned int invalid=0;invalid<=5;invalid++)if(invalid!=2&&invalid!=4)
            assert(o82_lp_batch(&c,commands,invalid)==-EINVAL && !lp_api_calls);
        c.initial_120hz_only=false;
        assert(o82_lp_batch(&c,commands,count)==-EINVAL && !lp_api_calls);
        c.initial_120hz_only=true;struct o82_profile changed=*c.active;c.active=&changed;
        assert(o82_lp_batch(&c,commands,count)==-EINVAL && !lp_api_calls);
        assert(o82_unprepare(&c.panel)==0);
    }
    c=context(0,3);
    struct device_node node={"unrelated,panel"};
    struct platform_device platform={.dev={.of_node=&node}};
    struct msm_dsi_host h={&platform};
    assert(dsi_populate_dsc_params(&h,&c.dsc)==0 && node_refs==0);
    assert(c.dsc.first_line_bpg_offset==12 && c.dsc.rc_range_params[0].range_max_qp==4);
    node.compatible="xiaomi,o82-42-02-0b"; c.dsc.slice_width=400;
    assert(dsi_populate_dsc_params(&h,&c.dsc)==-EINVAL && node_refs==0);
    platform.dev.of_node=NULL; c.dsc.slice_width=800;
    assert(dsi_populate_dsc_params(&h,&c.dsc)==0 && node_refs==0);
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-sign-compare -Wno-misleading-indentation -fsanitize=undefined -fsanitize-undefined-trap-on-error -I "$kernel/include" "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual O82 lifecycle: all seven OEM modes, preserved initial120/legacy profiles, exact PPS and grouped ON/HS/normal/dimming/OFF, fault unwind, cancellation and profile admission passed\n'
