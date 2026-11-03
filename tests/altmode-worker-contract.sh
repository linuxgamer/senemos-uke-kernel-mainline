#!/usr/bin/env bash
# Execute the actual PAN worker with delayed-display and lifecycle fault fixtures.
set -Eeuo pipefail
source_file=${1:?Pass the prepared drivers/soc/qcom/pmic_glink_altmode.c}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cerrno>
using u64=uint64_t;
#define ALTMODE_EVENT_COUNT 32
#define ALTMODE_PAN_ACK 0x11
#define USB_TYPEC_DP_SID 0xff01
#define USB_TYPEC_TBT_SID 0x8087
#define MUX_CTRL_STATE_NO_CONN 0
#define MUX_CTRL_STATE_USB3_ONLY 1
#define MUX_CTRL_STATE_TUNNELING 4
enum drm_connector_status { connector_status_connected=1, connector_status_disconnected=2, connector_status_unknown=3 };
enum drm_connector_dp_event { DRM_CONNECTOR_NO_EXTRA_STATUS,DRM_CONNECTOR_DP_IRQ_HPD };
#define spin_lock_irqsave(lock,flags) do {(void)(lock);(flags)=0;} while(0)
#define spin_unlock_irqrestore(lock,flags) do {(void)(lock);(void)(flags);} while(0)
#define dev_err_ratelimited(...) do {} while(0)
#define dev_dbg(dev, ...) do { if (0) printf(__VA_ARGS__); } while(0)
struct work_struct {};
struct bridge { int dev; } bridge;
struct pmic_glink_altmode_event {
    u64 generation=1;
    unsigned orientation=1,svid=USB_TYPEC_DP_SID,mode=3;
    unsigned hpd_state=1,hpd_irq=0,mux_ctrl=3,tbt_data=0;
};
struct pmic_glink_altmode {
    int dev=0,event_lock=0;
    bool uke=true;
    bool online=true,stopping=false,quarantined=false;
    u64 generation=1;
};
struct pmic_glink_altmode_port {
    work_struct work;
    pmic_glink_altmode *altmode;
    pmic_glink_altmode_event events[ALTMODE_EVENT_COUNT];
    unsigned head=0,count=1,index=0;
    bool overflow=false;
    drm_connector_status hpd_status=connector_status_unknown;
    unsigned orientation=0,svid=0,mode=0,hpd_state=0,hpd_irq=0,mux_ctrl=0,tbt_data=0;
    void *typec_switch=nullptr;
    struct bridge *bridge=&::bridge;
    pmic_glink_altmode_port(pmic_glink_altmode *am):altmode(am) {}
};
#define work_to_altmode_port(w) reinterpret_cast<pmic_glink_altmode_port *>(w)
static unsigned acks,switches,connected,disconnected,safe_calls,irq_events;
static bool consumed,lose_service_on_ack;
static int ack_error,mux_error;
static int pmic_glink_altmode_request(pmic_glink_altmode *am,unsigned cmd,unsigned port) {
    assert(cmd==ALTMODE_PAN_ACK && port==0);
    ++acks;
    if(ack_error) {am->quarantined=true;return ack_error;}
    consumed=true;
    if(lose_service_on_ack) {am->online=false;++am->generation;}
    return 0;
}
static int typec_switch_set(void *,unsigned) {
    assert(consumed);++switches;return mux_error;
}
static int pmic_glink_altmode_safe(pmic_glink_altmode *,pmic_glink_altmode_port *) {
    ++safe_calls;return 0;
}
static int pmic_glink_altmode_enable_dp(pmic_glink_altmode *,pmic_glink_altmode_port *,unsigned,bool,bool) {return 0;}
static int pmic_glink_altmode_enable_tbt(pmic_glink_altmode *,pmic_glink_altmode_port *) {return 0;}
static int pmic_glink_altmode_enable_usb4(pmic_glink_altmode *,pmic_glink_altmode_port *) {return 0;}
static int pmic_glink_altmode_enable_usb(pmic_glink_altmode *,pmic_glink_altmode_port *) {return 0;}
static void drm_aux_hpd_bridge_notify_extra(int *,int status,drm_connector_dp_event event) {
    if(event==DRM_CONNECTOR_DP_IRQ_HPD){assert(status==connector_status_connected);++irq_events;}
    if(status==connector_status_connected) {
        assert(consumed);++connected;
    } else {assert(status==connector_status_disconnected);++disconnected;}
    // The real display callback may block on AUX; consumption must precede it.
    consumed=false;
}
static void reset() {
    acks=switches=connected=disconnected=safe_calls=irq_events=0;
    consumed=lose_service_on_ack=false;ack_error=mux_error=0;
}
CPP
awk '/^static void pmic_glink_altmode_(hpd_notify|worker)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    reset();pmic_glink_altmode am;pmic_glink_altmode_port port{&am};
    port.count=2;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==1 && !disconnected && !safe_calls && !port.count);
    reset();am={};port={&am};port.count=2;port.events[1].hpd_irq=1;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==2 && !disconnected);
    assert(irq_events==1);
    reset();am={};port={&am};port.count=2;port.events[1].orientation=2;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==2 && !disconnected);
    reset();am={};port={&am};port.count=2;port.events[1].hpd_state=0;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==1 && disconnected==1);
    reset();am={};am.uke=false;port={&am};port.count=2;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==2 && !disconnected);
    reset();am={};port={&am};ack_error=-ETIMEDOUT;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==1 && !switches && !connected && disconnected==1 && safe_calls==1 && am.quarantined);
    reset();am={};port={&am};port.events[0].generation=0;
    pmic_glink_altmode_worker(&port.work);
    assert(!acks && !switches && !connected && !disconnected);
    reset();am={};port={&am};lose_service_on_ack=true;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==1 && !switches && !connected && disconnected==1 && safe_calls==1);
    reset();am={};port={&am};mux_error=-EIO;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==1 && switches==1 && !connected && disconnected==1);
    mux_error=0;port.count=1;
    pmic_glink_altmode_worker(&port.work);
    assert(acks==2 && switches==2 && connected==1 && disconnected==1);
    puts("Actual PAN worker: every event ACKed/applied, duplicate HPD suppressed, IRQ/route changes, ACK loss, generation and mux errors passed; host only");
}
CPP
"${CXX:-c++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
