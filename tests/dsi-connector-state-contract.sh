#!/usr/bin/env bash
# Execute the actual DSI initializer with the Linux 7.3 bridge callback table.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
#define IS_ERR(p) (reinterpret_cast<uintptr_t>(p)>=static_cast<uintptr_t>(-4095L))
#define PTR_ERR(p) static_cast<int>(reinterpret_cast<intptr_t>(p))
#define DRM_ERROR(...) ((void)0)
#define DRM_BRIDGE_ATTACH_NO_CONNECTOR 1
template<class T> static T* error_ptr(int error) {return reinterpret_cast<T*>(static_cast<intptr_t>(error));}
struct drm_connector;
struct drm_connector_state {unsigned max_bpc=0,max_requested_bpc=0;} state;
struct drm_connector_funcs {
    void (*reset)(drm_connector*)=nullptr;
    drm_connector_state* (*atomic_create_state)(drm_connector*);
};
struct drm_connector {drm_connector_state* state;drm_connector_funcs* funcs;};
struct drm_device {void* dev=nullptr;};
struct drm_encoder {};
struct drm_bridge {};
struct drm_panel {} panel;
struct msm_dsi {drm_device* dev;int id=1;};
struct dsi_bridge {drm_bridge base;int id;drm_panel* o82_panel;} allocated_bridge;
static int create_error,creates,bpc_calls,vrr_calls,property_error,vrr_error;
static bool o82=true,connector_error=false;
static drm_connector_state* create_state(drm_connector*) {
    ++creates;return create_error?error_ptr<drm_connector_state>(create_error):&state;
}
static drm_connector_funcs funcs{nullptr,create_state};
static drm_connector connector{nullptr,&funcs};
#define devm_drm_bridge_alloc(dev,type,member,ops) (&allocated_bridge)
static drm_panel* dsi_mgr_o82_panel(msm_dsi*) {return o82?&panel:nullptr;}
static int devm_drm_bridge_add(void*,drm_bridge*) {return 0;}
static int drm_bridge_attach(drm_encoder*,drm_bridge*,void*,int flags) {assert(flags==1);return 0;}
static drm_connector* drm_bridge_connector_init(drm_device*,drm_encoder*) {
    return connector_error?error_ptr<drm_connector>(-EAGAIN):&connector;
}
static int drm_connector_attach_max_bpc_property(drm_connector* c,int min,int max) {
    assert(c->state==&state&&min==10&&max==10);++bpc_calls;
    if(property_error)return property_error;
    c->state->max_bpc=c->state->max_requested_bpc=max;return 0;
}
static int drm_connector_attach_vrr_capable_property(drm_connector*) {++vrr_calls;return vrr_error;}
[[maybe_unused]] static int drm_connector_attach_abm_property(drm_connector*) {return 0;}
CPP
awk '/^int msm_dsi_manager_connector_init\(/ {emit=1} emit{print} emit&&/^}/{exit}' "$kernel/drivers/gpu/drm/msm/dsi/dsi_manager.c" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    drm_device dev;msm_dsi dsi{&dev};drm_encoder encoder;
    for(int error:{-ENOMEM,-EAGAIN,-EINVAL}) {
        connector.state=nullptr;create_error=error;
        assert(msm_dsi_manager_connector_init(&dsi,&encoder)==error);
        assert(!connector.state&&!bpc_calls&&!vrr_calls);
    }
    assert(creates==3);
    create_error=0;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==0);
    assert(creates==4&&bpc_calls==1&&vrr_calls==1&&state.max_bpc==10&&state.max_requested_bpc==10);
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==0&&creates==4);
    property_error=-ENOSPC;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-ENOSPC&&vrr_calls==2);
    property_error=0;vrr_error=-EIO;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-EIO&&vrr_calls==3);
    o82=false;connector.state=nullptr;
    const int before=bpc_calls;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==0&&!connector.state&&bpc_calls==before&&creates==4);
    connector_error=true;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-EAGAIN&&creates==4);
    std::puts("Actual DSI connector: modern state factory with null legacy reset, error propagation, existing state and panel scope passed; host only");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
