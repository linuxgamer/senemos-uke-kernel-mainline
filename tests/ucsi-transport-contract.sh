#!/usr/bin/env bash
# Execute actual transport bookkeeping and cached reads without a GLINK sender.
set -Eeuo pipefail
source_file=${1:?Pass prepared drivers/usb/typec/ucsi/ucsi_glink.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
typedef unsigned long long u64;
typedef uint32_t u32;
typedef uint8_t u8;
#define HZ 100
#define UC_UCSI_READ_BUF_REQ 0x11
#define READ_ONCE(value) (value)
#define spin_lock_irqsave(lock,flags) do {(void)(lock);(flags)=0;} while(0)
#define spin_unlock_irqrestore(lock,flags) do {(void)(lock);(void)(flags);} while(0)
struct pmic_glink_hdr { u32 owner,type,opcode; };
struct device { void *data; };
struct device_attribute {};
struct ucsi { unsigned version; };
struct pmic_glink_ucsi {
    int state_lock,response;
    struct device *dev;
    struct ucsi *ucsi;
    bool pd_running,stopping,quarantined,firmware_error_known;
    u32 pending_opcode,request_opcode,firmware_error;
    int response_error,result_error;
    size_t response_len;
    u64 service_generation,instance_ns,request_ns,completed_ns,reply_ns,notification_ns,request_generation;
    u8 read_buf[64];
};
static u64 now=100;
static unsigned long wait_result=1;
static int decoded_error;
static u32 decoded_firmware;
static u64 ktime_get_boottime_ns(void) { return now; }
static void reinit_completion(int *value) { *value=0; }
static void complete(int *value) { *value=1; }
static unsigned long wait_for_completion_timeout(int *value,unsigned long timeout) {
    (void)value; assert(timeout==5*HZ); return wait_result;
}
static int ucsi_glink_decode_read(const void *p,size_t len,unsigned version,size_t *size,u32 *error) {
    (void)p;(void)len;(void)version;*size=4;*error=decoded_firmware;return decoded_error;
}
static int ucsi_glink_decode_write(const void *p,size_t len,u32 *error) {
    (void)p;(void)len;*error=decoded_firmware;return decoded_error;
}
#define dev_err_ratelimited(...) ((void)0)
static void *dev_get_drvdata(struct device *dev) { return dev->data; }
static int sysfs_emit(char *buf,const char *format,...) __attribute__((format(printf,2,3)));
static int sysfs_emit(char *buf,const char *format,...) {
    va_list args;va_start(args,format);int bytes=vsnprintf(buf,4096,format,args);va_end(args);return bytes;
}
C
for name in pmic_glink_ucsi_begin pmic_glink_ucsi_wait pmic_glink_ucsi_ack uke_transport_state_show; do
    awk -v name="$name" '$0 ~ "^static .* " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$source_file" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
int main(void) {
    struct ucsi core={0};
    struct pmic_glink_ucsi state={.pd_running=true,.service_generation=7,.instance_ns=1,.ucsi=&core};
    struct device dev={.data=&state};
    char output[4096];u8 packet[32]={0};
    assert(!pmic_glink_ucsi_begin(&state,0x11));
    assert(state.request_ns==100 && state.request_generation==7 && !state.completed_ns);
    assert(state.result_error==-EINPROGRESS && !state.firmware_error_known);
    decoded_error=-EREMOTEIO;decoded_firmware=0x12345678;now=110;
    pmic_glink_ucsi_ack(&state,0x12,packet,sizeof(packet));
    assert(!state.reply_ns && !state.firmware_error_known); /* Unmatched reply. */
    pmic_glink_ucsi_ack(&state,0x11,packet,sizeof(packet));
    assert(state.reply_ns==110 && state.firmware_error_known && state.firmware_error==0x12345678);
    now=120;assert(pmic_glink_ucsi_wait(&state,0)==-EREMOTEIO && !state.quarantined);
    assert(state.completed_ns==120 && state.result_error==-EREMOTEIO);
    now=130;assert(!pmic_glink_ucsi_begin(&state,0x12));
    assert(!state.reply_ns && !state.firmware_error_known && !state.firmware_error);
    decoded_error=-EPROTO;decoded_firmware=0;
    pmic_glink_ucsi_ack(&state,0x12,packet,sizeof(packet));
    assert(!state.firmware_error_known);
    now=140;assert(pmic_glink_ucsi_wait(&state,0)==-EPROTO && state.quarantined);
    struct pmic_glink_ucsi before=state;
    assert(uke_transport_state_show(&dev,NULL,output)>0);
    assert(!memcmp(&state,&before,sizeof(state)));
    assert(strstr(output,"quarantined=1") && strstr(output,"result_errno=-71"));
    assert(strstr(output,"firmware_error_known=0") && strstr(output,"service_generation=7"));
    now=150;assert(pmic_glink_ucsi_begin(&state,0x11)==-EPIPE);
    assert(state.completed_ns==150 && state.result_error==-EPIPE);
    state.quarantined=false;state.pd_running=false;now=160;
    assert(pmic_glink_ucsi_begin(&state,0x11)==-ENOTCONN && state.completed_ns==160);
    state.pd_running=true;state.service_generation=8;now=170;
    assert(!pmic_glink_ucsi_begin(&state,0x11));
    wait_result=0;now=180;
    assert(pmic_glink_ucsi_wait(&state,0)==-ETIMEDOUT && state.quarantined);
    assert(state.result_error==-ETIMEDOUT && state.completed_ns==180 && !state.firmware_error_known);
    state.quarantined=false;wait_result=1;now=190;
    assert(!pmic_glink_ucsi_begin(&state,0x11));
    assert(pmic_glink_ucsi_wait(&state,-EIO)==-EIO && state.quarantined);
    state.service_generation=9;
    assert(uke_transport_state_show(&dev,NULL,output)>0);
    assert(strstr(output,"service_generation=9") && strstr(output,"request_generation=8"));
    state.quarantined=false;now=200;decoded_error=0;decoded_firmware=0;
    assert(!pmic_glink_ucsi_begin(&state,0x11));
    packet[sizeof(struct pmic_glink_hdr)]=0x5a;
    pmic_glink_ucsi_ack(&state,0x11,packet,sizeof(packet));
    assert(state.firmware_error_known && !state.firmware_error && state.read_buf[0]==0x5a);
    now=210;assert(!pmic_glink_ucsi_wait(&state,0) && !state.quarantined);
    assert(state.completed_ns==210 && !state.pending_opcode && !state.result_error);
    puts("Actual UCSI transport errors, unknown firmware status, epochs and non-mutating cached read: passed");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter "$work/check.c" -o "$work/check"
"$work/check"
