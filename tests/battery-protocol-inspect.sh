#!/usr/bin/env bash
# Actual fixed-GET helper and sysfs wrapper; host-only synthetic I/O.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel source}
source=$kernel/drivers/power/supply/qcom_battmgr.c
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
grep -Fq '__ATTR(uke_charge_protocols, 0400, uke_charge_protocols_show, NULL)' "$source"
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <errno.h>
#include <sys/types.h>
typedef unsigned long long u64;
typedef uint32_t u32;
#define NSEC_PER_SEC 1000000000ULL
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define IS_ENABLED(x) (x)
#define CAP_SYS_ADMIN 21
#define lockdep_assert_held(l) assert((l)->held)
#define spin_lock_irqsave(l,f) ((void)(l),(f)=0)
#define spin_unlock_irqrestore(l,f) ((void)(l),(void)(f))
enum { QCOM_BATTMGR_UKE=1, USB_ADAP_TYPE=7, UKE_USB_REAL_TYPE=11, BATTMGR_USB_PROPERTY_GET=0x32 };
struct mutex { bool available,held; };
struct qcom_battmgr_uke_transaction {
 int lock; bool desynced,suspended,removing;
 u64 instance_ns; u32 generation,firmware_generation,source_generation;
};
struct qcom_battmgr {
 int variant; bool service_up; struct mutex lock;
 struct qcom_battmgr_uke_transaction transaction;
 struct { u64 expires_ns,verified_until_ns,current_until_ns; bool verified,current_verified; } control;
 struct { u64 protocol_probe_ns; u32 adapter_type,real_type; } usb;
};
struct device { struct qcom_battmgr *data; };
struct device_attribute { int unused; };
static u64 clock_ns,request_ns;
static unsigned requests,fail_at,change_at,change_kind;
static bool privileged;
static u64 ktime_get_boottime_ns(void) { return clock_ns; }
static bool capable(int cap) { assert(cap==CAP_SYS_ADMIN); return privileged; }
static struct qcom_battmgr *dev_get_drvdata(struct device *dev) { return dev->data; }
static bool mutex_trylock(struct mutex *lock) { if(!lock->available)return false;assert(!lock->held);lock->held=true;return true; }
static void mutex_unlock(struct mutex *lock) { assert(lock->held);lock->held=false; }
static u32 qcom_battmgr_uke_generation(struct qcom_battmgr *b) { return b->transaction.generation; }
static int sysfs_emit(char *buf,const char *fmt,...) { va_list a;va_start(a,fmt);int n=vsnprintf(buf,4096,fmt,a);va_end(a);return n; }
static int qcom_battmgr_request_property(struct qcom_battmgr *b,u32 opcode,u32 property,u32 value) {
 assert(b->lock.held&&opcode==0x32&&value==0&&property==(requests?11U:7U));
 requests++;clock_ns+=request_ns;
 if(requests==fail_at)return -EREMOTEIO;
 if(requests==change_at){
  switch(change_kind){
  case 0:b->transaction.generation++;break;
  case 1:b->transaction.firmware_generation++;break;
  case 2:b->transaction.source_generation++;break;
  case 3:b->transaction.instance_ns++;break;
  case 4:b->service_up=false;break;
  case 5:b->transaction.desynced=true;break;
  case 6:b->transaction.suspended=true;break;
  case 7:b->transaction.removing=true;break;
  }
 }
 if(property==7)b->usb.adapter_type=128;else b->usb.real_type=130;
 return 0;
}
C
awk '/^struct qcom_battmgr_uke_protocols \{/ {emit=1} emit{print} emit&&/^};/{exit}' "$source"
for function in qcom_battmgr_uke_protocols_read uke_charge_protocols_show; do
 awk -v name="$function" '
  $0 ~ "^static (int|ssize_t) " name "\\(" {copy=1}
  copy {print} copy&&/^}/{found=1;exit}
  END {if(!found)exit 1}' "$source"
done
cat <<'C'
static struct qcom_battmgr fresh(void) {
 clock_ns=10000000000ULL;request_ns=1000000;requests=fail_at=change_at=change_kind=0;privileged=true;
 return (struct qcom_battmgr){.variant=1,.service_up=true,.lock={.available=true,.held=true},
  .transaction={.instance_ns=42,.generation=7,.firmware_generation=2,.source_generation=3}};
}
int main(void) {
 struct qcom_battmgr b=fresh();struct qcom_battmgr_uke_protocols out={.instance=99};
#if !CONFIG_BATTERY_QCOM_BATTMGR_UKE_PROTOCOL_DIAGNOSTICS
 assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EOPNOTSUPP&&!requests&&out.instance==99);
 b.lock.held=false;struct device dev={&b};char text[4096];
 assert(uke_charge_protocols_show(&dev,NULL,text)==-EOPNOTSUPP&&!requests&&!b.lock.held);
#else
 assert(!qcom_battmgr_uke_protocols_read(&b,&out)&&requests==2);
 assert(out.instance==42&&out.generation==7&&out.firmware==2&&out.source==3&&out.adapter_type==128&&out.real_type==130);
 assert(b.control.expires_ns==0&&!b.control.verified&&!b.control.current_verified);
 requests=0;assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EAGAIN&&!requests);
 clock_ns=b.usb.protocol_probe_ns-1;assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EAGAIN&&!requests);
 for(unsigned i=1;i<=2;i++) {
  b=fresh();fail_at=i;out.instance=99;
  assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EREMOTEIO&&requests==i&&out.instance==99);
  for(unsigned kind=0;kind<8;kind++){
   b=fresh();change_at=i;change_kind=kind;out.instance=99;
   assert(qcom_battmgr_uke_protocols_read(&b,&out)==-ESTALE&&out.instance==99);
  }
 }
 for(unsigned i=0;i<4;i++) {
  b=fresh();
  if(i==0)b.service_up=false;
  if(i==1)b.transaction.desynced=true;
  if(i==2)b.transaction.suspended=true;
  if(i==3)b.transaction.removing=true;
  assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EHOSTDOWN&&!requests);
 }
 for(unsigned i=0;i<3;i++) {
  b=fresh();if(i==0)b.control.expires_ns=clock_ns+1;
  if(i==1){b.control.verified=true;b.control.verified_until_ns=clock_ns+1;}
  if(i==2){b.control.current_verified=true;b.control.current_until_ns=clock_ns+1;}
  assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EBUSY&&!requests);
 }
 b=fresh();b.variant=2;assert(qcom_battmgr_uke_protocols_read(&b,&out)==-EOPNOTSUPP&&!requests);
 b=fresh();request_ns=2000000000ULL;assert(qcom_battmgr_uke_protocols_read(&b,&out)==-ESTALE);
 b=fresh();b.lock.held=false;struct device dev={&b};char text[4096];
 privileged=false;assert(uke_charge_protocols_show(&dev,NULL,text)==-EPERM&&!requests);
 privileged=true;b.lock.available=false;assert(uke_charge_protocols_show(&dev,NULL,text)==-EBUSY&&!requests);
 b.lock.available=true;assert(uke_charge_protocols_show(&dev,NULL,text)>0&&requests==2&&!b.lock.held);
 assert(!strcmp(text,"1 42 7 2 3 10002000000 128 130\n"));
#endif
 puts("Fixed USB7/USB11 GET, default-off, permissions, lease, rate, epoch and error checks passed; host only");
}
C
} > "$work/test.c"
for compiled in 0 1; do
 "${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  -DCONFIG_BATTERY_QCOM_BATTMGR_UKE_PROTOCOL_DIAGNOSTICS="$compiled" "$work/test.c" -o "$work/test"
 "$work/test"
done
