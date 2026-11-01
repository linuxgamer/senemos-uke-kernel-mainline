#!/usr/bin/env bash
# COPR-only: exercise the actual panel, bridge and DRM property implementation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=${1:?Pass prepared kernel} panel=${2:?Pass panel source}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
extract() {
    awk -v prefix="$2" 'index($0,prefix)==1 {emit=1;found=1} emit {print}
        emit && /^}/ {exit} END {if(!found)exit 1}' "$1"
}
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint16_t __u16;
typedef uint8_t __u8;
typedef uint32_t __u32;
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define MIPI_DSI_DCS_SHORT_WRITE_PARAM 0x15
#define DRM_MODE_PROP_ATOMIC 0x80000000U
#define HDMI_EOTF_TRADITIONAL_GAMMA_SDR 0
#define EXPORT_SYMBOL(...)
struct o82_panel {int unused;};
C
extract "$panel" 'struct o82_command {' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static int sends, fail_send;
static unsigned char payloads[2][2];
static int o82_send(struct o82_panel *ctx, const struct o82_command *cmd, bool lpm)
{
    (void)ctx;
    assert(sends<2 && lpm && cmd->type==0x15 && cmd->len==2);
    assert(!cmd->last && !cmd->channel && !cmd->downstream_flags && !cmd->delay_ms);
    memcpy(payloads[sends],cmd->data,2);
    return ++sends==fail_send ? -EIO:0;
}
C
extract "$panel" 'static int o82_apply_abm(' >> "$work/check.c"
extract "$kernel/include/uapi/drm/drm_mode.h" 'struct hdr_metadata_infoframe {' >> "$work/check.c"
extract "$kernel/include/uapi/drm/drm_mode.h" 'struct hdr_output_metadata {' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct drm_property {int unused;};
struct drm_mode_object {int unused;};
struct drm_connector {
    void *dev;
    struct drm_property *abm_level_property;
    struct drm_mode_object base;
};
struct drm_prop_enum_list {int type;const char *name;};
static struct drm_property property;
static int allocations, attaches;
static bool allocation_failure;
static struct drm_property *drm_property_create_enum(void *dev,unsigned flags,
        const char *name,const struct drm_prop_enum_list *levels,unsigned count)
{
    (void)dev;
    static const char *const names[] = {"off","min","bias min","bias max","max"};
    assert(flags==DRM_MODE_PROP_ATOMIC && !strcmp(name,"adaptive backlight modulation"));
    assert(count==ARRAY_SIZE(names));
    for(unsigned i=0;i<count;++i)assert(levels[i].type==(int)i && !strcmp(levels[i].name,names[i]));
    ++allocations;
    return allocation_failure ? NULL:&property;
}
static void drm_object_attach_property(struct drm_mode_object *base,struct drm_property *p,uint64_t value)
{
    (void)base;assert(p==&property && !value);++attaches;
}
struct drm_property_blob {size_t length;void *data;};
struct drm_connector_state {
    void *state;
    struct drm_connector *connector;
    unsigned int abm_level;
    struct drm_property_blob *hdr_output_metadata;
};
struct drm_bridge {bool o82_panel;};
struct drm_bridge_state {int unused;};
struct drm_crtc_state {bool mode_changed,connectors_changed;};
#define to_dsi_bridge(b) (b)
static struct drm_connector_state old_state;
C
extract "$kernel/drivers/gpu/drm/drm_connector.c" 'int drm_connector_attach_abm_property(' >> "$work/check.c"
extract "$kernel/drivers/gpu/drm/msm/dsi/dsi_manager.c" 'static int dsi_mgr_bridge_atomic_check(' >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void invalidate(struct drm_connector *connector,
        struct drm_connector_state *old_connector_state,
        struct drm_connector_state *new_connector_state,
        struct drm_crtc_state *new_crtc_state)
{
C
awk '/if \(connector->abm_level_property &&/ {emit=1;found=1}
    emit {print} emit && /new_crtc_state->connectors_changed = true;/ {exit}
    END {if(!found)exit 1}' "$kernel/drivers/gpu/drm/drm_atomic_helper.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
}
static int set_level(struct drm_connector_state *state,uint64_t val)
{
C
# Extract the actual shared-core branches, including the pre-mutation guard.
awk '/} else if \(property == connector->abm_level_property\)/ {emit=1;found=1;next}
     emit && /} else if/ {exit} emit{print} END{if(!found)exit 1}' \
    "$kernel/drivers/gpu/drm/drm_atomic_uapi.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
    return 0;
}
static uint64_t get_level(struct drm_connector_state *state)
{
    uint64_t value=UINT64_MAX, *val=&value;
C
awk '/drm_atomic_connector_get_property\(/ {getter=1}
     getter && /} else if \(property == connector->abm_level_property\)/ {emit=1;found=1;next}
     emit && /} else if/ {exit} emit{print} END{if(!found)exit 1}' \
    "$kernel/drivers/gpu/drm/drm_atomic_uapi.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
    return value;
}
int main(void)
{
    struct o82_panel panel={0};
    const unsigned modes[]={0,1,1,2,3};
    for(unsigned level=0;level<ARRAY_SIZE(modes);++level) {
        sends=fail_send=0;memset(payloads,0,sizeof(payloads));
        assert(!o82_apply_abm(&panel,level) && sends==2);
        assert(payloads[0][0]==0xff && payloads[0][1]==0x10);
        assert(payloads[1][0]==0x55 && payloads[1][1]==modes[level]);
        for(fail_send=1;fail_send<=2;++fail_send) {
            sends=0;assert(o82_apply_abm(&panel,level)==-EIO && sends==fail_send);
        }
    }
    sends=0;
    assert(o82_apply_abm(&panel,5)==-EINVAL && !sends);
    assert(o82_apply_abm(&panel,UINT_MAX)==-EINVAL && !sends);
    struct drm_connector connector={0};
    allocation_failure=true;
    assert(drm_connector_attach_abm_property(&connector)==-ENOMEM);
    assert(!connector.abm_level_property && allocations==1 && !attaches);
    allocation_failure=false;
    assert(!drm_connector_attach_abm_property(&connector));
    assert(connector.abm_level_property==&property && allocations==2 && attaches==1);
    assert(!drm_connector_attach_abm_property(&connector) && allocations==2 && attaches==1);
    struct drm_bridge bridge={.o82_panel=true};
    struct drm_bridge_state bs={0};
    struct drm_crtc_state cs={0};
    struct drm_connector_state state={.connector=&connector};
    for(unsigned before=0;before<=4;++before)for(unsigned after=0;after<=4;++after) {
        old_state.abm_level=before;state.abm_level=after;cs.mode_changed=false;
        cs.connectors_changed=false;
        invalidate(&connector,&old_state,&state,&cs);
        assert(cs.connectors_changed==(before!=after));
        assert(!dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state));
        assert(!cs.mode_changed);
        assert(!set_level(&state,after) && get_level(&state)==after);
    }
    for(uint64_t invalid=5;;invalid=UINT64_MAX) {
        const unsigned previous=state.abm_level;
        assert(set_level(&state,invalid)==-EINVAL && state.abm_level==previous);
        if(invalid==UINT64_MAX)break;
    }
    state.abm_level=5;cs.mode_changed=false;
    assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==-EINVAL && !cs.mode_changed);
    bridge.o82_panel=false;
    assert(!dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state) && !cs.mode_changed);
    connector.abm_level_property=NULL;old_state.abm_level=0;state.abm_level=1;
    cs.connectors_changed=false;
    invalidate(&connector,&old_state,&state,&cs);
    assert(!cs.connectors_changed);
    bridge.o82_panel=true;
    struct hdr_output_metadata hdr={0};
    struct drm_property_blob blob={.length=sizeof(hdr),.data=&hdr};
    state.hdr_output_metadata=&blob;
    for(unsigned level=0;level<=4;++level)for(unsigned eotf=0;eotf<=4;++eotf) {
        state.abm_level=level;hdr.hdmi_metadata_type1.eotf=eotf;cs.mode_changed=false;
        const int expected=level && eotf ? -EOPNOTSUPP:0;
        assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==expected);
        if(expected)assert(!cs.mode_changed);
    }
    state.abm_level=1;hdr.hdmi_metadata_type1.eotf=0;cs.mode_changed=false;
    blob.length=sizeof(hdr)-1;
    assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==-EINVAL && !cs.mode_changed);
    blob.length=sizeof(hdr)+1;
    assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==-EINVAL && !cs.mode_changed);
    blob.length=sizeof(hdr);hdr.metadata_type=1;
    assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==-EOPNOTSUPP && !cs.mode_changed);
    hdr.metadata_type=0;hdr.hdmi_metadata_type1.metadata_type=1;
    assert(dsi_mgr_bridge_atomic_check(&bridge,&bs,&cs,&state)==-EOPNOTSUPP && !cs.mode_changed);
    puts("Actual O82 CABC/DRM: exact paired-LP payload contract, five tiers, atomic set/get, modeset, HDR refusal and fault propagation passed");
}
C
flags=(-std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter)
if [[ ${SANITIZE:-0} == 1 ]]; then flags+=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CC:-cc}" "${flags[@]}" "$work/check.c" -o "$work/check"
"$work/check"
# Invalidation must precede collection of every active plane and connector.
[[ $(awk '/^(int )?drm_atomic_helper_check_modeset\(/ {helper=1}
    helper && /if \(connector->abm_level_property &&/ {early=1}
    helper && /ret = drm_atomic_add_affected_planes/ {print early+0;exit}' \
    "$kernel/drivers/gpu/drm/drm_atomic_helper.c") == 1 ]] || {
    printf 'ABM invalidation must precede affected-plane collection\n' >&2
    exit 1
}
# Admission must precede publication and retain the existing dark rollback.
[[ $(awk '/ret = o82_apply_abm\(/ {abm=1}
    abm && /goto failed_on;/ {rollback=1}
    /ctx->prepared = true;/ {print abm && rollback;exit}' "$panel") == 1 ]] || {
    printf 'ABM admission must precede prepared state and retain dark rollback\n' >&2
    exit 1
}
