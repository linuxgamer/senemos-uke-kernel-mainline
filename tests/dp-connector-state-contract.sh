#!/usr/bin/env bash
# Execute the prepared DP initializer's state and failure boundaries on the host.
set -Eeuo pipefail
source_file=${1:?Pass prepared drivers/gpu/drm/msm/dp/dp_drm.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#define ERR_PTR(e) reinterpret_cast<drm_connector *>(static_cast<intptr_t>(e))
#define IS_ERR(p) (reinterpret_cast<uintptr_t>(p)>=static_cast<uintptr_t>(-4095L))
#define ERR_CAST(p) reinterpret_cast<drm_connector *>(p)
#define BIT(n) (1U << (n))
constexpr unsigned DRM_MODE_COLORIMETRY_BT2020_RGB=9;
struct drm_connector;
struct drm_connector_state { unsigned max_requested_bpc=0, max_bpc=0; } state;
struct drm_connector_funcs {
    void (*reset)(drm_connector *)=nullptr;
    drm_connector_state* (*atomic_create_state)(drm_connector *);
};
struct drm_connector { drm_connector_state *state; drm_connector_funcs *funcs; };
struct device_node { bool uke; } node;
struct device { device_node *of_node; };
struct platform_device { device dev; } pdev{{&node}};
struct drm_encoder {} encoder;
struct drm_device {} drm;
struct msm_dp { drm_device *drm_dev; platform_device *pdev; bool is_edp; } dp{&drm,&pdev,false};
int resets=0,properties=0,subconnectors=0,property_error=0;
int colorspaces=0,color_attachments=0,hdr_attachments=0,color_error=0;
bool allocation_failure=false;
drm_connector_state* create_state(drm_connector*) {
    ++resets;
    return allocation_failure?reinterpret_cast<drm_connector_state *>(static_cast<intptr_t>(-ENOMEM)):&state;
}
drm_connector_funcs funcs{nullptr,create_state};
drm_connector connector{nullptr,&funcs},*bridge_result=&connector;
drm_connector *drm_bridge_connector_init(drm_device *,drm_encoder *) { return bridge_result; }
bool of_device_is_compatible(device_node *n,const char *) { return n->uke; }
int drm_connector_attach_max_bpc_property(drm_connector *c,int min,int max) {
    assert(c->state && min==6 && max==10);
    ++properties;
    if(property_error)return property_error;
    c->state->max_requested_bpc=c->state->max_bpc=max;
    return 0;
}
void drm_connector_attach_dp_subconnector_property(drm_connector *) { ++subconnectors; }
int drm_mode_create_dp_colorspace_property(drm_connector *c,unsigned colors) {
    assert(c->state && colors==BIT(DRM_MODE_COLORIMETRY_BT2020_RGB));
    ++colorspaces;
    return color_error;
}
void drm_connector_attach_colorspace_property(drm_connector *) { ++color_attachments; }
void drm_connector_attach_hdr_output_metadata_property(drm_connector *) { ++hdr_attachments; }
CPP
awk '/^struct drm_connector \*msm_dp_drm_connector_init\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    node.uke=true;
    bridge_result=ERR_PTR(-EAGAIN);
    assert(msm_dp_drm_connector_init(&dp,&encoder)==ERR_PTR(-EAGAIN));
    assert(!resets && !properties && !subconnectors);
    bridge_result=&connector; allocation_failure=true;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==ERR_PTR(-ENOMEM));
    assert(resets==1 && !properties && !subconnectors);
    allocation_failure=false;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==&connector);
    assert(resets==2 && properties==1 && subconnectors==1 && state.max_requested_bpc==10);
    assert(colorspaces==1 && color_attachments==1 && hdr_attachments==1);
    state.max_requested_bpc=8; property_error=-ENOSPC;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==ERR_PTR(-ENOSPC));
    assert(resets==2 && properties==2 && subconnectors==1 && state.max_requested_bpc==8);
    assert(colorspaces==1 && color_attachments==1 && hdr_attachments==1);
    property_error=0; color_error=-ENOMEM;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==ERR_PTR(-ENOMEM));
    assert(properties==3 && colorspaces==2 && subconnectors==1);
    assert(color_attachments==1 && hdr_attachments==1);
    color_error=0;
    node.uke=false; connector.state=nullptr; property_error=0;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==&connector);
    assert(resets==2 && properties==3 && subconnectors==2 && !connector.state);
    assert(colorspaces==2 && color_attachments==1 && hdr_attachments==1);
    dp.is_edp=true;
    assert(msm_dp_drm_connector_init(&dp,&encoder)==&connector && subconnectors==2);
    puts("Actual DP connector state initialization and failure boundaries: passed");
}
CPP
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
