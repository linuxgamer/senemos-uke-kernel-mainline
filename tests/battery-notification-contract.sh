#!/usr/bin/env bash
# Exercise the actual handler; no firmware, sysfs or system-bus access.
set -Eeuo pipefail
source=${1:?Pass prepared drivers/power/supply/qcom_battmgr.c}
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
typedef uint32_t __le32;
typedef uint16_t __le16;
typedef uint8_t u8;
struct pmic_glink_hdr { __le32 owner, type, opcode; };
enum { QCOM_BATTMGR_OTHER, QCOM_BATTMGR_UKE };
struct power_supply { unsigned changes; };
struct qcom_battmgr {
 int variant;
 void *dev;
 struct power_supply *bat_psy, *usb_psy, *wls_psy;
 struct { bool valid; } info;
};
static unsigned errors;
#define le32_to_cpu(value) (value)
#define dev_warn(...) ((void)0)
#define dev_err(...) ((void)errors++)
#define fallthrough __attribute__((fallthrough))
static void power_supply_changed(struct power_supply *s) { assert(s); s->changes++; }
C
awk '/^#define (BATTMGR_STRING_LEN|BATTMGR_CHEMISTRY_LEN|NOTIF_)/ {print}
 /^struct qcom_battmgr_message / {emit=1}
 emit {print} emit && /^};/ {emit=0}' "$source"
awk '/^static void qcom_battmgr_notification\(/ {emit=1}
 emit {print} emit && /^}/ {found=1;exit} END {if(!found)exit 1}' "$source"
cat <<'C'
int main(void) {
 struct power_supply bat={0}, usb={0}, wls={0};
 struct qcom_battmgr b={.variant=QCOM_BATTMGR_UKE,.bat_psy=&bat,.usb_psy=&usb,.wls_psy=&wls};
 struct qcom_battmgr_message m={.notification=0x50};
 const int len=sizeof(m.hdr)+sizeof(m.notification);
 qcom_battmgr_notification(&b,&m,len);
 assert(bat.changes==1 && usb.changes==0 && wls.changes==0 && errors==0);
 m.notification=0x12340050;
 qcom_battmgr_notification(&b,&m,len);
 assert(bat.changes==2);
 qcom_battmgr_notification(&b,&m,len-1);
 qcom_battmgr_notification(&b,&m,len+1);
 qcom_battmgr_notification(&b,&m,0);
 assert(bat.changes==2 && errors==0);
 b.variant=QCOM_BATTMGR_OTHER;
 m.notification=0x50;
 qcom_battmgr_notification(&b,&m,len);
 assert(bat.changes==2 && errors==1);
 const unsigned battery_events[]={NOTIF_BAT_INFO,NOTIF_BAT_STATUS,NOTIF_BAT_PROPERTY,NOTIF_BAT_CHARGING_STATE};
 for(unsigned i=0;i<sizeof(battery_events)/sizeof(battery_events[0]);i++) {
  m.notification=battery_events[i]; b.info.valid=true;
  qcom_battmgr_notification(&b,&m,len);
  assert(bat.changes==3+i);
  assert(b.info.valid==(battery_events[i]!=NOTIF_BAT_INFO));
 }
 m.notification=NOTIF_USB_PROPERTY; qcom_battmgr_notification(&b,&m,len);
 m.notification=NOTIF_WLS_PROPERTY; qcom_battmgr_notification(&b,&m,len);
 assert(bat.changes==6 && usb.changes==1 && wls.changes==1 && errors==1);
 m.notification=0x66; qcom_battmgr_notification(&b,&m,len);
 assert(bat.changes==6 && errors==2);
 return 0;
}
C
} > "$work/check.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
echo 'Actual battmgr notification routing passed; no firmware or desktop acceptance claimed'
