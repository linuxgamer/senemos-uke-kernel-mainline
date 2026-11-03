#!/usr/bin/env bash
# Actual guard-function host fixture, including Linux's current macro.
# Prepared only; no sysfs, firmware, tablet or device discovery.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel source}
source=$kernel/drivers/power/supply/qcom_battmgr_uke_control.h
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <limits.h>
typedef int64_t s64; typedef uint64_t u64; typedef uint32_t u32; typedef int32_t s32;
#define NSEC_PER_SEC 1000000000ULL
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define spin_lock_irqsave(l,f) ((void)(l),(f)=0)
#define spin_unlock_irqrestore(l,f) ((void)(l),(void)(f))
struct task_struct { int unused; };
struct task_struct *get_current(void) { return NULL; }
#define current get_current()
enum { BATT_HEALTH=1, BATT_PRESENT=2, BATT_VOLT_NOW=7, BATT_CURR_NOW=9, BATT_TEMP=12,
 BATTMGR_BAT_PROPERTY_GET=0x30, BATTMGR_USB_PROPERTY_GET=0x32, USB_ONLINE=0, USB_TYPE=6,
 POWER_SUPPLY_HEALTH_GOOD=1 };
struct qcom_battmgr {
 struct { unsigned generation; int lock; } transaction;
 struct { int health,current_now; unsigned voltage_now,temperature; } status;
 struct { bool present; } info;
 struct { bool online; unsigned usb_type; } usb;
 struct { unsigned usb_type,current_abs_max_ua,voltage_min_uv,voltage_max_uv,measurement_generation,measured_voltage;
  int temperature_min,temperature_max,measured_temperature,measured_current; u64 measurement_ns; } control;
};
static u64 clock_ns;
static bool lease;
static unsigned requests, fail_at, change_at;
static u64 per_request_ns;
static u64 ktime_get_boottime_ns(void) { return clock_ns; }
static u32 qcom_battmgr_uke_generation(struct qcom_battmgr *b) { return b->transaction.generation; }
static int qcom_battmgr_uke_control_check(struct qcom_battmgr *b) { (void)b; return lease?0:-EACCES; }
static int protection_error;
static int qcom_battmgr_uke_protection_guard(struct qcom_battmgr *b) { (void)b;return protection_error; }
static int qcom_battmgr_request_property(struct qcom_battmgr *b, unsigned opcode, unsigned property, int value) {
 assert(!value); requests++; clock_ns+=per_request_ns;
 if(requests==change_at) b->transaction.generation++;
 if(requests==fail_at) return -ETIMEDOUT;
 if(opcode==BATTMGR_USB_PROPERTY_GET) assert(property==USB_ONLINE || property==USB_TYPE);
 else assert(opcode==BATTMGR_BAT_PROPERTY_GET);
 return 0;
}
C
awk '/^static int qcom_battmgr_uke_control_guard\(/ {emit=1}
 emit {print} emit && /^}/ {exit}' "$source"
cat <<'C'
static void initialize(struct qcom_battmgr *b) {
 *b=(struct qcom_battmgr){.transaction.generation=7,.status={.health=1,.current_now=500000,.voltage_now=4000000,.temperature=250},.info.present=true,
 .usb={.online=true,.usb_type=1},.control={.usb_type=1,.current_abs_max_ua=2000000,.voltage_min_uv=3000000,.voltage_max_uv=4500000,.temperature_min=100,.temperature_max=400}};
 clock_ns=2*NSEC_PER_SEC; lease=true; requests=fail_at=change_at=0; per_request_ns=0;
 protection_error=0;
}
int main(void) {
 struct qcom_battmgr b; initialize(&b);
 assert(!qcom_battmgr_uke_control_guard(&b) && requests==7 && b.control.measurement_ns==2*NSEC_PER_SEC);
 assert(b.control.measured_current==500000 && b.control.measurement_generation==7);
 initialize(&b); b.status.current_now=-500000;
 assert(!qcom_battmgr_uke_control_guard(&b) && b.control.measured_current==-500000);
 initialize(&b); b.status.current_now=INT_MIN;
 assert(qcom_battmgr_uke_control_guard(&b)==-ERANGE && !b.control.measurement_ns);
 initialize(&b); b.status.temperature=400;
 assert(qcom_battmgr_uke_control_guard(&b)==-ERANGE && !b.control.measurement_ns);
 initialize(&b); b.status.temperature=100; assert(!qcom_battmgr_uke_control_guard(&b));
 initialize(&b); b.usb.online=false; assert(qcom_battmgr_uke_control_guard(&b)==-ERANGE);
 initialize(&b); b.usb.usb_type=2; assert(qcom_battmgr_uke_control_guard(&b)==-ERANGE);
 for(unsigned fail=1;fail<=7;fail++) {
  initialize(&b); fail_at=fail;
  assert(qcom_battmgr_uke_control_guard(&b)==-ETIMEDOUT && requests==fail && !b.control.measurement_ns);
 }
 initialize(&b); change_at=4; assert(qcom_battmgr_uke_control_guard(&b)==-ESTALE && !b.control.measurement_ns);
 initialize(&b); per_request_ns=NSEC_PER_SEC;
 assert(qcom_battmgr_uke_control_guard(&b)==-ESTALE && !b.control.measurement_ns);
 initialize(&b); lease=false; assert(qcom_battmgr_uke_control_guard(&b)==-EACCES && !requests);
 initialize(&b); protection_error=-EACCES;assert(qcom_battmgr_uke_control_guard(&b)==-EACCES&&!b.control.measurement_ns);
}
C
} > "$work/guard.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wstrict-prototypes "$work/guard.c" -o "$work/guard"
"$work/guard"
printf '%s\n' 'Actual guard under Linux current macro, age/epoch, signed-current and error contracts passed; no device result'
