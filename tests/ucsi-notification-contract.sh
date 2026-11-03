#!/usr/bin/env bash
# Execute the actual callback against observed and malformed GLINK headers.
set -Eeuo pipefail
ulimit -c 0
source_file=${1:?Pass prepared drivers/usb/typec/ucsi/ucsi_glink.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.cpp" <<'CPP'
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <initializer_list>
using u32=uint32_t;
static uint64_t mock_now=100;
static uint64_t ktime_get_boottime_ns() { return mock_now; }
#define PMIC_GLINK_OWNER_USBC 32779
#define MSG_TYPE_REQ_RESP 1
#define MSG_TYPE_NOTIFY 2
#define UC_UCSI_READ_BUF_REQ 0x11
#define UC_UCSI_WRITE_BUF_REQ 0x12
#define UC_UCSI_USBC_NOTIFY_IND 0x13
#define UC_NOTIFY_RECEIVER_UCSI 0
#define le32_to_cpu(value) (value)
#define spin_lock_irqsave(lock,flags) do {(void)(lock);(flags)=0;} while(0)
#define spin_unlock_irqrestore(lock,flags) do {(void)(lock);(void)(flags);} while(0)
struct pmic_glink_hdr { u32 owner,type,opcode; };
struct ucsi_notify_ind_msg { pmic_glink_hdr hdr;u32 notification,receiver,reserved; };
struct work_struct {};
struct pmic_glink_ucsi {
    int state_lock=0;
    bool pd_running=true,stopping=false,quarantined=false;
    uint64_t notification_ns=0;
    work_struct notify_work;
};
static unsigned acks=0,notifications=0;
static void pmic_glink_ucsi_ack(pmic_glink_ucsi *,u32 opcode,const void *,size_t) {
    assert(opcode==0x11 || opcode==0x12);++acks;
}
static void schedule_work(work_struct *) { ++notifications; }
CPP
# Spell C's implicit void-pointer conversions explicitly for the C++ harness.
awk '/^static void pmic_glink_ucsi_callback\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" |
    sed -e 's/\*ucsi = priv;/\*ucsi = static_cast<pmic_glink_ucsi *>(priv);/' \
        -e 's/\*hdr = data;/\*hdr = static_cast<const pmic_glink_hdr *>(data);/' \
        -e 's/\*notify = data;/\*notify = static_cast<const ucsi_notify_ind_msg *>(data);/' >> "$work/check.cpp"
cat >> "$work/check.cpp" <<'CPP'
int main() {
    pmic_glink_ucsi state;
    ucsi_notify_ind_msg message{{32779,2,0x13},0,0,0};
    pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    assert(notifications==1 && !acks);
    assert(state.notification_ns==100);
    mock_now=110;
    message.hdr.type=1;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    assert(notifications==2);
    assert(state.notification_ns==110);mock_now=120;
    for (u32 type:{0u,3u,UINT32_MAX}) {
        message.hdr.type=type;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    }
    assert(notifications==2);
    message.hdr.type=2;
    for (size_t len=0;len<sizeof(message);len++) pmic_glink_ucsi_callback(&message,len,&state);
    pmic_glink_ucsi_callback(nullptr,0,&state);
    pmic_glink_ucsi_callback(&message,sizeof(message)+1,&state);
    assert(notifications==2);
    message.receiver=1;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    message.receiver=0;message.hdr.owner=32778;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    message.hdr.owner=32779;state.pd_running=false;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    state.pd_running=true;state.stopping=true;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    state.stopping=false;state.quarantined=true;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    state.quarantined=false;assert(notifications==2);
    assert(state.notification_ns==110);
    unsigned expected_acks=0;
    for (u32 opcode:{0x11u,0x12u}) {
        message.hdr.opcode=opcode;message.hdr.type=2;
        pmic_glink_ucsi_callback(&message,sizeof(message.hdr),&state);assert(acks==expected_acks);
        message.hdr.type=1;pmic_glink_ucsi_callback(&message,sizeof(message.hdr),&state);
        assert(acks==++expected_acks);
    }
    assert(acks==2 && notifications==2);
    message.hdr.opcode=0xff;pmic_glink_ucsi_callback(&message,sizeof(message),&state);
    assert(acks==2 && notifications==2);
    puts("Actual UCSI type-2 notification, reply-type and lifecycle boundaries: passed");
}
CPP
"${CXX:-clang++}" -std=c++20 -O2 -Wall -Wextra -Werror "$work/check.cpp" -o "$work/check"
"$work/check"
