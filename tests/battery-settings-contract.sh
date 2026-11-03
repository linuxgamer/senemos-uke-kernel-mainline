#!/usr/bin/env bash
# Actual diagnostic helper and sysfs wrapper; synthetic host I/O only.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel source}
source=$kernel/drivers/power/supply/qcom_battmgr_uke_control.h
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
grep -Fq '__ATTR(uke_charge_settings, 0400, uke_charge_settings_show, NULL)' "$source"
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
#define PMIC_GLINK_OWNER_BATTMGR 32778
#define PMIC_GLINK_REQ_RESP 1
#define BATTMGR_BAT_PROPERTY_SET 0x31
#define cpu_to_le32(value) (value)
#define lockdep_assert_held(l) ((void)(l))
#define spin_lock_irqsave(l,f) ((void)(l),(f)=0)
#define spin_unlock_irqrestore(l,f) ((void)(l),(void)(f))
struct task_struct { int unused; };
static struct task_struct *get_current(void) { return NULL; }
#define current get_current()
enum { QCOM_BATTMGR_UKE=1, BATT_CHG_CTRL_EN=24,
 BATT_CHG_CTRL_START_THR=25, BATT_CHG_CTRL_END_THR=26,
 BATTMGR_BAT_PROPERTY_GET=0x30 };
enum power_supply_property { POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,
 POWER_SUPPLY_PROP_CHARGE_CONTROL_START_THRESHOLD,
 POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD, POWER_SUPPLY_PROP_OTHER };
union power_supply_propval { int intval; };
struct mutex { bool available,drop_on_unlock; };
struct qcom_battmgr_uke_transaction {
 int lock; bool desynced,suspended,removing;
 u64 instance_ns; u32 generation,firmware_generation,source_generation;
};
struct qcom_battmgr {
 int variant; bool service_up; struct mutex lock;
 struct qcom_battmgr_uke_transaction transaction;
 struct { u64 expires_ns,settings_probe_ns,verified_until_ns,current_until_ns;
  bool enabled,verified,current_verified,standard_clients,may_enable; u32 current_ua; } control;
 struct { u32 charge_ctrl_start,charge_ctrl_end; } info;
};
struct device { struct qcom_battmgr *data; };
struct power_supply { struct qcom_battmgr *data; };
struct qcom_battmgr_property_request {
 struct { u32 owner,type,opcode; } hdr; u32 battery,property,value;
};
struct device_attribute { int unused; };
static u64 clock_ns,request_ns;
static unsigned requests,fail_at,change_at;
static bool privileged,remote_enabled,cache_live,admitted;
static u32 remote_start,remote_end;
static unsigned guard_calls;
static u64 ktime_get_boottime_ns(void) { return clock_ns; }
static bool capable(int cap) { assert(cap==CAP_SYS_ADMIN); return privileged; }
static struct qcom_battmgr *dev_get_drvdata(struct device *dev) { return dev->data; }
static bool mutex_trylock(struct mutex *lock) { return lock->available; }
static void mutex_lock(struct mutex *lock) { assert(lock->available); }
static void mutex_unlock(struct mutex *lock) { assert(lock->available);if(lock->drop_on_unlock)lock->available=false; }
static struct qcom_battmgr *power_supply_get_drvdata(struct power_supply *psy) { return psy->data; }
static bool qcom_battmgr_uke_readback_live(struct qcom_battmgr *b) { (void)b; return cache_live; }
static bool qcom_battmgr_uke_current_live(struct qcom_battmgr *b) { (void)b; return cache_live; }
static bool qcom_battmgr_uke_control_live(struct qcom_battmgr *b,bool owner) { (void)b;(void)owner; return admitted; }
static int qcom_battmgr_bat_get_property(struct power_supply *psy,enum power_supply_property prop,union power_supply_propval *value) {
 (void)psy;assert(prop==POWER_SUPPLY_PROP_OTHER);value->intval=47;return 0;
}
static int qcom_battmgr_uke_control_guard(struct qcom_battmgr *b) { (void)b;guard_calls++;return -EACCES; }
static int qcom_battmgr_uke_threshold_read(struct qcom_battmgr *b) { (void)b;assert(false);return -EIO; }
static void qcom_battmgr_uke_threshold_record(struct qcom_battmgr *b) { (void)b;assert(false); }
static int qcom_battmgr_request(struct qcom_battmgr *b,void *data,size_t size) { (void)b;(void)data;(void)size;assert(false);return -EIO; }
static int qcom_battmgr_set_charge_control(struct qcom_battmgr *b,u32 end,u32 delta) { (void)b;(void)end;(void)delta;assert(false);return -EIO; }
static ssize_t sysfs_emit(char *buf,const char *format,...) {
 va_list args; va_start(args,format); int n=vsnprintf(buf,4096,format,args); va_end(args); return n;
}
static u32 qcom_battmgr_uke_generation(struct qcom_battmgr *b) { return b->transaction.generation; }
static int qcom_battmgr_request_property(struct qcom_battmgr *b,unsigned opcode,unsigned property,int value) {
 assert(opcode==BATTMGR_BAT_PROPERTY_GET && value==0);
 assert(property==BATT_CHG_CTRL_EN+requests); // Exactly three fixed GETs.
 assert(requests<3); requests++; clock_ns+=request_ns;
 if(requests==change_at) b->transaction.generation++;
 if(requests==fail_at) return -EPROTO;
 if(property==BATT_CHG_CTRL_EN) b->control.enabled=remote_enabled;
 if(property==BATT_CHG_CTRL_START_THR) b->info.charge_ctrl_start=remote_start;
 if(property==BATT_CHG_CTRL_END_THR) b->info.charge_ctrl_end=remote_end;
 return 0;
}
C
awk '/^#define CHARGE_CTRL_/ {print}' "$kernel/drivers/power/supply/qcom_battmgr.c"
awk '/^struct qcom_battmgr_uke_settings \{/ {emit=1} emit {print} emit && /^};/ {exit}' "$source"
for function in qcom_battmgr_uke_settings_read qcom_battmgr_uke_observed_threshold qcom_battmgr_uke_control_get_property qcom_battmgr_uke_threshold_pair uke_charge_settings_show; do
 awk -v name="$function" '
  $0 ~ "^static (int|ssize_t) " name "\\(" {candidate=1;body=0;buffer=""}
  candidate {buffer=buffer $0 ORS}
  candidate && !body && /;$/ {candidate=0;buffer=""}
  candidate && /^\{/ {body=1}
  candidate && body && /^}/ {printf "%s",buffer;found=1;exit}
  END {if(!found)exit 1}' "$source"
done
cat <<'C'
static void initialize(struct qcom_battmgr *b) {
 *b=(struct qcom_battmgr){.variant=QCOM_BATTMGR_UKE,.service_up=true,.lock.available=true,
  .transaction={.instance_ns=71,.generation=7,.firmware_generation=2,.source_generation=3}};
 clock_ns=5*NSEC_PER_SEC; request_ns=1000000;
 requests=fail_at=change_at=0; privileged=remote_enabled=true;cache_live=admitted=false;remote_start=70;remote_end=80;
}
int main(void) {
 struct qcom_battmgr b;initialize(&b);struct device dev={.data=&b};char output[4096];
 assert(get_current()==NULL);
 const unsigned pairs[][2]={{49,80},{96,100},{50,54},{70,70},{80,70},{70,101},{0,80}};
 for(unsigned i=0;i<sizeof(pairs)/sizeof(pairs[0]);i++) {
  guard_calls=0;
  assert(qcom_battmgr_uke_threshold_pair(&b,pairs[i][0],pairs[i][1])==-EINVAL && !guard_calls && !requests);
 }
 const unsigned valid[][2]={{50,55},{70,80},{95,100},{0,100}};
 for(unsigned i=0;i<sizeof(valid)/sizeof(valid[0]);i++) {
  guard_calls=0;
  assert(qcom_battmgr_uke_threshold_pair(&b,valid[i][0],valid[i][1])==-EACCES && guard_calls==1 && !requests);
 }
 struct power_supply psy={.data=&b};union power_supply_propval value={.intval=-1};
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_OTHER,&value) && value.intval==47 && !requests);
#if !CONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS
 assert(uke_charge_settings_show(&dev,NULL,output)==-EOPNOTSUPP && !requests);
 assert(qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value)==-EOPNOTSUPP && !requests);
#else
 struct qcom_battmgr_uke_settings result,unchanged;
 memset(&result,0xa5,sizeof(result));unchanged=result;
 assert(!qcom_battmgr_uke_settings_read(&b,&result,true) && requests==3);
 assert(result.instance==71 && result.generation==7 && result.firmware==2 && result.source==3);
 assert(result.received_ns==clock_ns && result.enabled==1 && result.start==70 && result.end==80);
 assert(!b.control.expires_ns && !b.control.verified && !b.control.current_verified);
 requests=0;assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EAGAIN && !requests);
 clock_ns=6*NSEC_PER_SEC;
 assert(!qcom_battmgr_uke_settings_read(&b,&result,true) && requests==3);
 initialize(&b);remote_enabled=false;remote_start=remote_end=0;
 assert(!qcom_battmgr_uke_settings_read(&b,&result,true));
 assert(!result.enabled && !result.start && !result.end);
 for(unsigned fail=1;fail<=3;fail++) {
  initialize(&b);fail_at=fail;result=unchanged;
  assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EPROTO && requests==fail);
  assert(!memcmp(&result,&unchanged,sizeof(result)));
 }
 for(unsigned change=1;change<=3;change++) {
  initialize(&b);change_at=change;result=unchanged;
  assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-ESTALE && requests==change);
  assert(!memcmp(&result,&unchanged,sizeof(result)));
 }
 for(unsigned state=0;state<5;state++) {
  initialize(&b);
  if(state==0)b.service_up=false;
  if(state==1)b.transaction.desynced=true;
  if(state==2)b.transaction.suspended=true;
  if(state==3)b.transaction.removing=true;
  if(state==4)b.transaction.instance_ns=0;
  assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EHOSTDOWN && !requests);
 }
 initialize(&b);b.control.expires_ns=clock_ns+1;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EBUSY && !requests);
 initialize(&b);b.control.verified=true;b.control.verified_until_ns=clock_ns+1;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EBUSY && !requests);
 initialize(&b);b.control.current_verified=true;b.control.current_until_ns=clock_ns+1;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EBUSY && !requests);
 initialize(&b);b.variant=0;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-EOPNOTSUPP && !requests);
 initialize(&b);remote_end=101;result=unchanged;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-ENODATA);
 assert(!memcmp(&result,&unchanged,sizeof(result)));
 initialize(&b);remote_start=90;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-ENODATA);
 initialize(&b);request_ns=2*NSEC_PER_SEC;result=unchanged;
 assert(qcom_battmgr_uke_settings_read(&b,&result,true)==-ESTALE);
 assert(!memcmp(&result,&unchanged,sizeof(result)));
 initialize(&b);privileged=false;
 assert(uke_charge_settings_show(&dev,NULL,output)==-EPERM && !requests);
 initialize(&b);b.lock.available=false;
 assert(uke_charge_settings_show(&dev,NULL,output)==-EBUSY && !requests);
 initialize(&b);
 assert(uke_charge_settings_show(&dev,NULL,output)>0 && requests==3);
 assert(!strncmp(output,"1 71 7 2 3 ",11) && strstr(output," 1 70 80\n"));
 initialize(&b);privileged=false;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_START_THRESHOLD,&value) && value.intval==70 && requests==3);
 requests=0;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value) && value.intval==80 && requests==3);
 assert(!b.control.expires_ns && !b.control.verified && !b.control.standard_clients);
 initialize(&b);b.lock.drop_on_unlock=true;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value) && value.intval==80 && requests==3);
 initialize(&b);remote_enabled=false;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_START_THRESHOLD,&value) && value.intval==0);
 requests=0;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value) && value.intval==100);
 for(unsigned fail=1;fail<=3;fail++) {
  initialize(&b);fail_at=fail;value.intval=-1;
  assert(qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value)==-EPROTO && value.intval==-1);
 }
 initialize(&b);change_at=2;value.intval=-1;
 assert(qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value)==-ESTALE && value.intval==-1);
 initialize(&b);b.control.expires_ns=clock_ns+1;
 assert(qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value)==-EBUSY && !requests);
 initialize(&b);b.control.standard_clients=true;cache_live=admitted=true;b.control.enabled=true;
 b.info.charge_ctrl_start=65;b.info.charge_ctrl_end=75;
 assert(!qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CHARGE_CONTROL_END_THRESHOLD,&value) && value.intval==75 && !requests);
 initialize(&b);value.intval=-1;
 assert(qcom_battmgr_uke_control_get_property(&psy,POWER_SUPPLY_PROP_CONSTANT_CHARGE_CURRENT,&value)==-ENODATA && !requests && value.intval==-1);
#endif
 return 0;
}
C
} > "$work/settings.c"
for enabled in 0 1; do
 "${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
  -DCONFIG_BATTERY_QCOM_BATTMGR_UKE_THRESHOLDS="$enabled" "$work/settings.c" -o "$work/settings-$enabled"
 "$work/settings-$enabled"
done
printf '%s\n' 'Actual read-only settings, root/lease/rate/lifecycle/error boundaries passed off/on; no firmware or device access'
