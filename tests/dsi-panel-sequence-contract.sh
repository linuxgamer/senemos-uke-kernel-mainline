#!/usr/bin/env bash
# Execute the prepared DSI manager callbacks with host-only fault injection.
set -Eeuo pipefail
manager=${1:?Pass prepared dsi_manager.c with the O82 sequence candidate}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
extract() {
    awk -v signature="$1" '
        $0 == signature { emit=1; found=1 }
        emit { print }
        emit && /^}/ { exit }
        END { if (!found) exit 1 }
    ' "$manager"
}
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstring>
#include <string>
#include <vector>
#define DSI_1 1
#define DSI_MAX 2
#define MIPI_DSI_MODE_VIDEO 1
#define container_of(ptr,type,member) ((type *)((char *)(ptr)-offsetof(type,member)))
#define DBG(...) ((void)0)
#define dev_err(dev,...) ((void)(dev))
#define pr_err(...) ((void)0)
struct drm_bridge;
struct drm_atomic_commit;
struct drm_bridge_funcs {void (*atomic_disable)(drm_bridge *,drm_atomic_commit *);void (*atomic_post_disable)(drm_bridge *,drm_atomic_commit *);};
struct drm_bridge {const drm_bridge_funcs *funcs;};
struct drm_encoder {drm_bridge *bridge;};
static int bridge_refs;
static drm_bridge *drm_bridge_chain_get_first_bridge(drm_encoder *e) {if(e->bridge)++bridge_refs;return e->bridge;}
static void drm_bridge_put(drm_bridge *b) {if(b)--bridge_refs;}
struct drm_panel { bool prepared; } panel;
struct device_node { const char *compatible; } remote{"xiaomi,o82-36-02-0a"};
struct device { device_node *of_node; };
struct platform_device { device dev; } platform;
struct mipi_dsi_host { int id; unsigned long flags; } hosts[2]{{0,1},{1,1}};
struct msm_dsi_phy_shared_timings {};
struct msm_dsi_phy_clk_request {unsigned long bitclk_rate,escclk_rate;};
struct msm_dsi { platform_device *pdev; mipi_dsi_host *host; int phy; } devices[2]{{&platform,&hosts[0],0},{&platform,&hosts[1],1}};
static bool bonded=true,uke=true,sm7675=true,missing_node=false,missing_secondary=false;
static bool clocks_ready[2];
static bool dma_blocked[2];
static bool intf_active;
static int master=0,node_puts=0;
static drm_panel *found_panel=&panel;
static std::string fault;
static std::vector<std::string> events;
static int event(const std::string &name) { events.push_back(name); return fault==name ? -5 : 0; }
static std::string link(const char *name, mipi_dsi_host *host) { return std::string(name)+std::to_string(host->id); }
#define IS_BONDED_DSI() bonded
#define IS_MASTER_DSI_LINK(id) (master==(id))
static msm_dsi *dsi_mgr_get_dsi(int id) { return id==1 && missing_secondary ? nullptr:&devices[id]; }
static int dsi_mgr_phy_enable(int,msm_dsi_phy_shared_timings *) { return event("phy_on"); }
static void dsi_mgr_phy_disable(int) { event("phy_off"); }
static int msm_dsi_host_power_on(mipi_dsi_host *host,msm_dsi_phy_shared_timings *,bool,int) {
    int ret=event(link("power",host)); if(!ret) clocks_ready[host->id]=true; return ret;
}
static int msm_dsi_host_power_off(mipi_dsi_host *host) {
    int ret=event(link("off",host));if(!ret)clocks_ready[host->id]=false;return ret;
}
static void msm_dsi_host_get_phy_clk_req(mipi_dsi_host *host,msm_dsi_phy_clk_request *request,bool is_bonded) {
    assert(host->id==0 && is_bonded && clocks_ready[0] && clocks_ready[1]);
    if(!event("clk_req")) {request->bitclk_rate=1189188000UL; request->escclk_rate=19200000UL;}
}
static int msm_dsi_phy_sync_retime(int phy,int peer,const msm_dsi_phy_clk_request *request) {
    assert(phy==0 && peer==1 && clocks_ready[0] && clocks_ready[1]);
    int ret=event("retime");
    return ret ? ret:request->bitclk_rate==1189188000UL ? 0:-EINVAL;
}
static void msm_dsi_host_enable_irq(mipi_dsi_host *host) { event(link("irq",host)); }
static void msm_dsi_host_disable_irq(mipi_dsi_host *host) { event(link("noirq",host)); }
static int msm_dsi_host_enable(mipi_dsi_host *host) { return event(link("video",host)); }
static int msm_dsi_host_disable(mipi_dsi_host *host) { assert(!intf_active);return event(link("stop",host)); }
static bool msm_dsi_host_dma_blocked(mipi_dsi_host *host) {return dma_blocked[host->id];}
static void msm_dsi_phy_pll_save_state(int) { event("save_pll"); }
static bool of_machine_is_compatible(const char *name) { return !strcmp(name,"xiaomi,uke") ? uke : sm7675; }
static unsigned long msm_dsi_host_get_mode_flags(mipi_dsi_host *host) { return host->flags; }
static device_node *of_graph_get_remote_node(device_node *,int,int) { return missing_node ? nullptr : &remote; }
static bool of_device_is_compatible(device_node *node,const char *name) { return node && !strcmp(node->compatible,name); }
static drm_panel *of_drm_find_panel(device_node *) { return found_panel; }
static void of_node_put(device_node *node) { if(node) ++node_puts; }
CPP
{
    extract 'struct dsi_bridge {'
    printf '#define to_dsi_bridge(x) container_of(x, struct dsi_bridge, base)\n'
    for callback in \
        'static int dsi_mgr_bridge_get_id(struct drm_bridge *bridge)' \
        'static int dsi_mgr_bridge_power_on(struct drm_bridge *bridge)' \
        'static int dsi_mgr_bridge_power_off(struct drm_bridge *bridge)' \
        'static int dsi_mgr_bridge_enable_hosts(struct drm_bridge *bridge)' \
        'static void dsi_mgr_bridge_pre_enable(struct drm_bridge *bridge,' \
        'static void dsi_mgr_bridge_enable(struct drm_bridge *bridge,' \
        'static int dsi_mgr_bridge_stop_video(struct drm_bridge *bridge)' \
        'static void dsi_mgr_bridge_post_disable(struct drm_bridge *bridge,' \
        'static struct drm_panel *dsi_mgr_o82_panel(struct msm_dsi *msm_dsi)'; do
        extract "$callback"
    done
    printf 'static const struct drm_bridge_funcs dsi_mgr_bridge_funcs = {\n'
    sed -n '/^static const struct drm_bridge_funcs dsi_mgr_bridge_funcs = {/,/^};/p' "$manager" | \
        sed -n '/^[[:space:]]*\.atomic_\(disable\|post_disable\) =/p'
    printf '};\n'
    extract 'int msm_dsi_manager_uke_video_stop(struct drm_encoder *encoder)'
    cat <<'CPP'
static void expect(std::initializer_list<const char *> expected) {
    std::vector<std::string> wanted;
    for (const char *name : expected) wanted.emplace_back(name);
    assert(events==wanted);
    events.clear();
}
static void prepare(bool success=true) {
    event("reset"); event("panel_on"); event("pps"); panel.prepared=success;
}
static void unprepare() { event("panel_off"); panel.prepared=false; }
int main() {
    for (const char *compatible : {"xiaomi,o82-36-02-0a","xiaomi,o82-42-02-0b"}) {
        remote.compatible=compatible;
        assert(dsi_mgr_o82_panel(&devices[0])==&panel);
    }
    assert(node_puts==2);
    uke=false; assert(dsi_mgr_o82_panel(&devices[0])==nullptr); uke=true;
    sm7675=false; assert(dsi_mgr_o82_panel(&devices[0])==nullptr); sm7675=true;
    hosts[0].flags=0; assert(dsi_mgr_o82_panel(&devices[0])==nullptr); hosts[0].flags=1;
    remote.compatible="xiaomi,another-panel"; assert(dsi_mgr_o82_panel(&devices[0])==nullptr);
    remote.compatible="xiaomi,o82-36-02-0a";
    missing_node=true; assert(dsi_mgr_o82_panel(&devices[0])==nullptr); missing_node=false;
    found_panel=reinterpret_cast<drm_panel *>(-517L);
    assert(dsi_mgr_o82_panel(&devices[0])==found_panel); found_panel=&panel;

    dsi_bridge bridge{{},0,&panel,false,false};
    bridge.base.funcs=&dsi_mgr_bridge_funcs;
    drm_encoder encoder{&bridge.base};
    assert(!dsi_mgr_bridge_funcs.atomic_disable);
    dsi_mgr_bridge_enable(&bridge.base, nullptr); expect({});
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
    expect({"phy_on","power0","power1","clk_req","retime","irq0","irq1"});
    dsi_mgr_bridge_enable(&bridge.base, nullptr); expect({});
    prepare(); dsi_mgr_bridge_enable(&bridge.base, nullptr);
    expect({"reset","panel_on","pps","video0","video1"});
    assert(bridge.video_enabled);
    intf_active=true;
    if(dsi_mgr_bridge_funcs.atomic_disable)dsi_mgr_bridge_funcs.atomic_disable(&bridge.base, nullptr);
    intf_active=false; // The DPU stops both source timing engines here.
    assert(!msm_dsi_manager_uke_video_stop(&encoder));
    assert(!bridge_refs);unprepare();
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"stop1","stop0","panel_off","save_pll","noirq0","noirq1","off1","off0","phy_off"});
    assert(!bridge.powered && !bridge.video_enabled);
    assert(!msm_dsi_manager_uke_video_stop(&encoder));
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr); expect({});

    // A failed stop must preserve command clocks and propagate the exact error.
    for(const char *failure:{"stop1","stop0","dma0","dma1","missing"}) {
        dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);events.clear();
        prepare();dsi_mgr_bridge_enable(&bridge.base, nullptr);events.clear();
        fault=failure;dma_blocked[0]=fault=="dma0";dma_blocked[1]=fault=="dma1";
        missing_secondary=fault=="missing";
        int ret=msm_dsi_manager_uke_video_stop(&encoder);
        assert(ret==(fault=="missing" ? -ENODEV : -EIO));
        assert(bridge.powered&&bridge.video_enabled&&clocks_ready[0]&&clocks_ready[1]&&!bridge_refs);
        dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
        assert(bridge.powered&&clocks_ready[0]&&clocks_ready[1]);
        for(const auto &name:events)assert(name!="off0"&&name!="off1"&&name!="phy_off");
        events.clear();fault.clear();dma_blocked[0]=dma_blocked[1]=missing_secondary=false;
        assert(!msm_dsi_manager_uke_video_stop(&encoder));events.clear();
        unprepare();dsi_mgr_bridge_post_disable(&bridge.base, nullptr);events.clear();
    }
    drm_bridge foreign{};encoder.bridge=&foreign;
    assert(!msm_dsi_manager_uke_video_stop(&encoder)&&!bridge_refs);expect({});
    encoder.bridge=nullptr;assert(!msm_dsi_manager_uke_video_stop(&encoder)&&!bridge_refs);
    encoder.bridge=&bridge.base;

    // Every host/PHY power failure must suppress the later enable callback.
    for (const char *failure : {"phy_on","power0","power1"}) {
        fault=failure; dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
        panel.prepared=true; dsi_mgr_bridge_enable(&bridge.base, nullptr);
        assert(!bridge.powered && !bridge.video_enabled);
        for (const auto &name : events) assert(name!="video0" && name!="video1");
        if (fault=="phy_on") expect({"phy_on"});
        else if (fault=="power0") expect({"phy_on","power0","phy_off"});
        else expect({"phy_on","power0","power1","off0","phy_off"});
        dsi_mgr_bridge_post_disable(&bridge.base, nullptr); expect({});
        panel.prepared=false;
    }
    // Refused post-link synchronization must unwind BOTH hosts before the PHY.
    for(const char *failure:{"retime","clk_req"}) {
        fault=failure; dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
        assert(!bridge.powered && !bridge.video_enabled && !clocks_ready[0] && !clocks_ready[1]);
        expect({"phy_on","power0","power1","clk_req","retime","off1","off0","phy_off"});
        panel.prepared=true; dsi_mgr_bridge_enable(&bridge.base, nullptr); expect({});
        dsi_mgr_bridge_post_disable(&bridge.base, nullptr); expect({}); panel.prepared=false;
    }
    fault.clear(); missing_secondary=true;
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
    assert(!bridge.powered && !clocks_ready[0]);
    expect({"phy_on","power0","off0","phy_off"}); missing_secondary=false;
    bonded=false; dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
    assert(!bridge.powered && !clocks_ready[0]);
    expect({"phy_on","power0","off0","phy_off"}); bonded=true;
    fault.clear(); dsi_mgr_bridge_pre_enable(&bridge.base, nullptr); events.clear();
    prepare(false); dsi_mgr_bridge_enable(&bridge.base, nullptr);
    expect({"reset","panel_on","pps"});
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"save_pll","noirq0","noirq1","off1","off0","phy_off"});

    // Failed ON preparation may automatically unwind while DMA is quarantined.
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);events.clear();prepare(false);events.clear();
    fault="off1";dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"save_pll","noirq0","noirq1","off1"});
    assert(bridge.powered&&!bridge.video_enabled&&clocks_ready[0]&&clocks_ready[1]);
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"save_pll","noirq0","noirq1","off1"});
    assert(bridge.powered&&clocks_ready[0]&&clocks_ready[1]);
    fault.clear();dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"save_pll","noirq0","noirq1","off1","off0","phy_off"});
    assert(!bridge.powered);
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);events.clear();prepare(false);events.clear();
    dma_blocked[0]=dma_blocked[1]=true;
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);expect({});
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);expect({});
    assert(bridge.powered&&clocks_ready[0]&&clocks_ready[1]);
    dsi_bridge blocked_slave{{},1,nullptr,true,false};
    dsi_mgr_bridge_post_disable(&blocked_slave.base, nullptr);expect({});
    dsi_mgr_bridge_pre_enable(&blocked_slave.base, nullptr);expect({});
    assert(blocked_slave.powered&&clocks_ready[0]&&clocks_ready[1]);
    dma_blocked[0]=dma_blocked[1]=false;
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"save_pll","noirq0","noirq1","off1","off0","phy_off"});

    // Failed second video enable unwinds the first, keeping command power for OFF.
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr); events.clear(); prepare(); events.clear();
    fault="video1"; dsi_mgr_bridge_enable(&bridge.base, nullptr);
    expect({"video0","video1","stop0"});
    assert(!bridge.video_enabled && bridge.powered);
    fault.clear(); unprepare(); dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"panel_off","save_pll","noirq0","noirq1","off1","off0","phy_off"});
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr); events.clear(); prepare(); events.clear();
    fault="video0"; dsi_mgr_bridge_enable(&bridge.base, nullptr); expect({"video0"});
    assert(!bridge.video_enabled && bridge.powered);
    fault.clear(); unprepare(); dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"panel_off","save_pll","noirq0","noirq1","off1","off0","phy_off"});

    dsi_bridge slave{{},1,&panel,false,false};
    dsi_mgr_bridge_pre_enable(&slave.base, nullptr); dsi_mgr_bridge_enable(&slave.base, nullptr);
    expect({}); dsi_mgr_bridge_post_disable(&slave.base, nullptr); expect({"phy_off"});

    // Non-O82 bonded and standalone hosts keep their previous callback order.
    bridge.o82_panel=nullptr;
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr); dsi_mgr_bridge_enable(&bridge.base, nullptr);
    expect({"phy_on","power0","power1","irq0","irq1","video0","video1"});
    assert(!msm_dsi_manager_uke_video_stop(&encoder)); expect({});
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"stop0","stop1","noirq0","noirq1","save_pll","off0","off1","phy_off"});
    fault="video1"; dsi_mgr_bridge_pre_enable(&bridge.base, nullptr);
    expect({"phy_on","power0","power1","irq0","irq1","video0","video1","stop0","noirq0","noirq1","off1","off0","phy_off"});
    fault.clear();
    bonded=false;
    dsi_mgr_bridge_pre_enable(&bridge.base, nullptr); dsi_mgr_bridge_enable(&bridge.base, nullptr);
    expect({"phy_on","power0","irq0","video0"});
    dsi_mgr_bridge_post_disable(&bridge.base, nullptr);
    expect({"stop0","noirq0","save_pll","off0","phy_off"});
}
CPP
} >> "$work/check.cpp"
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror \
    -Wno-missing-field-initializers -Wno-unused-parameter -fsanitize=undefined \
    -fsanitize-undefined-trap-on-error "$work/check.cpp" -o "$work/check"
"$work/check"
printf 'Real DSI callbacks: both source timing engines must stop before DSI reset and panel OFF; failed stops preserve power, bridge references balance and generic paths stay unchanged\n'
