#!/usr/bin/env bash
# Exercise the actual DSI initializer's fixed-depth and failure boundaries.
set -Eeuo pipefail
manager=${1:?Pass prepared drivers/gpu/drm/msm/dsi/dsi_manager.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#define ERR_PTR(e) reinterpret_cast<drm_connector *>(static_cast<intptr_t>(e))
#define IS_ERR(p) (reinterpret_cast<uintptr_t>(p)>=static_cast<uintptr_t>(-4095L))
#define PTR_ERR(p) static_cast<int>(reinterpret_cast<intptr_t>(p))
#define DRM_ERROR(...) ((void)0)
#define DRM_BRIDGE_ATTACH_NO_CONNECTOR 1
struct drm_connector;
struct drm_connector_state { unsigned max_requested_bpc=0, max_bpc=0; } state;
struct drm_connector_funcs { void (*reset)(drm_connector *); };
struct drm_connector { drm_connector_state *state; drm_connector_funcs *funcs; };
struct drm_panel {} panel;
struct device {} device;
struct drm_device { struct device *dev; } drm{&device};
struct drm_encoder {} encoder;
struct drm_bridge {};
struct dsi_bridge { drm_bridge base; int id; drm_panel *o82_panel; } allocated_bridge;
struct msm_dsi { drm_device *dev; int id; } dsi{&drm,0};
int resets=0,properties=0,vrr_properties=0,property_error=0,vrr_error=0;
int add_error=0,attach_error=0;
bool allocation_failure=false;
void reset(drm_connector *c) { ++resets; if(!allocation_failure)c->state=&state; }
drm_connector_funcs funcs{reset};
drm_connector connector{nullptr,&funcs},*bridge_result=&connector;
drm_panel *selected_panel=&panel;
drm_panel *dsi_mgr_o82_panel(msm_dsi *) { return selected_panel; }
#define devm_drm_bridge_alloc(...) (&allocated_bridge)
int devm_drm_bridge_add(struct device *,drm_bridge *) { return add_error; }
int drm_bridge_attach(drm_encoder *,drm_bridge *,void *,int) { return attach_error; }
drm_connector *drm_bridge_connector_init(drm_device *,drm_encoder *) { return bridge_result; }
int drm_connector_attach_max_bpc_property(drm_connector *c,int min,int max) {
    assert(c->state && min==10 && max==10);
    ++properties;
    if(property_error)return property_error;
    c->state->max_requested_bpc=c->state->max_bpc=max;
    return 0;
}
int drm_connector_attach_vrr_capable_property(drm_connector *) {
    ++vrr_properties;return vrr_error;
}
CPP
awk '/^int msm_dsi_manager_connector_init\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$manager" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    bridge_result=ERR_PTR(-EAGAIN);
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-EAGAIN);
    assert(!resets && !properties && !vrr_properties);
    bridge_result=&connector; allocation_failure=true;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-ENOMEM);
    assert(resets==1 && !properties && !vrr_properties);
    allocation_failure=false;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==0);
    assert(resets==2 && properties==1 && vrr_properties==1);
    assert(state.max_requested_bpc==10 && state.max_bpc==10);
    property_error=-ENOSPC;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-ENOSPC);
    assert(resets==2 && properties==2 && vrr_properties==1);
    property_error=0; vrr_error=-EINVAL;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-EINVAL);
    assert(properties==3 && vrr_properties==2);
    selected_panel=nullptr; connector.state=nullptr;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==0);
    assert(resets==2 && properties==3 && vrr_properties==2 && !connector.state);
    selected_panel=&panel; add_error=-ENODEV;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-ENODEV);
    add_error=0; attach_error=-EIO;
    assert(msm_dsi_manager_connector_init(&dsi,&encoder)==-EIO);
    assert(properties==3 && vrr_properties==2);
    puts("Actual O82 fixed 10-bpc capability, foreign panel and failure boundaries: passed");
}
CPP
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
