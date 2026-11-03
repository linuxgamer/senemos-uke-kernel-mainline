#!/usr/bin/env bash
# Actual fixed firmware/IIO/wet-policy helpers with synthetic host I/O only.
set -Eeuo pipefail
source=${1:?Pass prepared kernel source}/drivers/power/supply/qcom_battmgr_uke_control.h
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
{
cat <<'C'
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <errno.h>
typedef uint64_t u64; typedef uint32_t u32; typedef int32_t s32; typedef int64_t s64;
#define NSEC_PER_SEC 1000000000ULL
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define spin_lock_irqsave(l,f) ((void)(l),(f)=0)
#define spin_unlock_irqrestore(l,f) ((void)(l),(void)(f))
#define cpu_to_le32(v) (v)
#define IS_ERR(p) ((intptr_t)(p)<0)
#define PTR_ERR(p) ((int)(intptr_t)(p))
enum { BATTMGR_USB_PROPERTY_GET=0x32,BATTMGR_USB_PROPERTY_SET=0x33,
 UKE_INPUT_SUSPEND_GET=0x50,UKE_INPUT_SUSPEND_SET=0x51,UKE_INPUT_SUSPEND_PROPERTY=53,
 USB_MOISTURE_EN=8,USB_MOISTURE_STATUS=9,USB_ONLINE=0,
 PMIC_GLINK_OWNER_BATTMGR=32778,PMIC_GLINK_REQ_RESP=1,
 BATTMGR_BAT_PROPERTY_GET=0x30,BATT_HEALTH=1,BATT_PRESENT=2,BATT_TEMP=12,BATT_VOLT_NOW=7,BATT_CURR_NOW=9,POWER_SUPPLY_HEALTH_GOOD=1 };
struct qcom_battmgr_property_request { struct {u32 owner,type,opcode;} hdr; u32 battery,property,value; };
struct qcom_battmgr_uke_transaction { int lock;u64 instance_ns;u32 generation,firmware_generation,source_generation;bool desynced,suspended,removing; };
struct device { struct device *parent; };
struct qcom_battmgr {
 struct device *dev;bool service_up;struct qcom_battmgr_uke_transaction transaction;
 struct {u32 moisture_enabled,moisture_status;bool online;} usb;
 struct {u32 health,temperature,voltage_now;s32 current_now;} status;
 struct {bool present;} info;
 struct {int external_min[3],external_max[3];bool moisture_uncertain,moisture_enabling,safety_request;
 u32 moisture_generation,input_suspended;int temperature_min,temperature_max;u32 voltage_min_uv,voltage_max_uv,current_abs_max_ua;} control;
 struct {u64 received_ns,dry_since_ns,dry_last_ns,inhibit_readback_ns;u32 generation,firmware,source,enabled,moisture,dry_samples,faults;
 bool wet_latched,inhibit_owned,inhibit_verified,inhibit_uncertain;} protection;
};
enum iio_chan_type {IIO_TEMP,IIO_VOLTAGE};struct iio_channel {unsigned index;};
static struct iio_channel channels[3]={{0},{1},{2}};
static int temperatures[3],sensor_failure,type_failure,missing_sensor;
static unsigned channel_releases,requests,writes,fail_at,change_at;
static u64 clock_ns,request_ns;
static bool lease,remote_online,remote_enabled,remote_wet,remote_inhibit,ignore_set;
static bool remote_present;
static int remote_health,remote_temperature;static u32 remote_voltage;
static u64 ktime_get_boottime_ns(void){return clock_ns;}
static u32 qcom_battmgr_uke_generation(struct qcom_battmgr *b){return b->transaction.generation;}
static int qcom_battmgr_uke_control_check(struct qcom_battmgr *b){(void)b;return lease?0:-EACCES;}
static struct iio_channel *iio_channel_get(struct device *d,const char *name){
 (void)d;const char *names[]={"charger","connector","connector2"};
 for(unsigned i=0;i<3;i++)if(!strcmp(name,names[i]))return missing_sensor==(int)i?(void *)(intptr_t)-ENODEV:&channels[i];
 assert(0);return NULL;
}
static int iio_get_channel_type(struct iio_channel *c,enum iio_chan_type *t){*t=type_failure==(int)c->index?IIO_VOLTAGE:IIO_TEMP;return 0;}
static int iio_read_channel_processed(struct iio_channel *c,int *t){if(sensor_failure==(int)c->index)return -EIO;*t=temperatures[c->index];return 0;}
static void iio_channel_release(struct iio_channel *c){assert(c);channel_releases++;}
static int step(struct qcom_battmgr *b){requests++;clock_ns+=request_ns;if(requests==change_at)b->transaction.generation++;return requests==fail_at?-ETIMEDOUT:0;}
static int qcom_battmgr_request_property(struct qcom_battmgr *b,unsigned op,unsigned p,int value){
 assert(!value);int r=step(b);if(r)return r;
 if(op==BATTMGR_USB_PROPERTY_GET){
  if(p==8)b->usb.moisture_enabled=remote_enabled;
  else if(p==9)b->usb.moisture_status=remote_wet;
  else {assert(p==0);b->usb.online=remote_online;}
 }else{assert(op==BATTMGR_BAT_PROPERTY_GET);
  if(p==BATT_HEALTH)b->status.health=remote_health;
  else if(p==BATT_PRESENT)b->info.present=remote_present;
  else if(p==BATT_TEMP)b->status.temperature=remote_temperature;
  else if(p==9)b->status.current_now=500000;
  else{assert(p==BATT_VOLT_NOW);b->status.voltage_now=remote_voltage;}
 }return 0;
}
static int qcom_battmgr_request(struct qcom_battmgr *b,void *data,size_t length){
 const struct qcom_battmgr_property_request *r=data;assert(length==sizeof(*r));
 assert(r->hdr.owner==PMIC_GLINK_OWNER_BATTMGR && r->hdr.type==PMIC_GLINK_REQ_RESP);
 if(r->hdr.opcode==BATTMGR_USB_PROPERTY_SET){assert(b->control.moisture_enabling && r->property==8 && r->value==1);writes++;}
 else {assert(b->control.safety_request && r->property==53);
  assert(r->hdr.opcode==UKE_INPUT_SUSPEND_GET || r->hdr.opcode==UKE_INPUT_SUSPEND_SET);
  if(r->hdr.opcode==UKE_INPUT_SUSPEND_SET){assert(r->value<=1);writes++;}
 }
 int error=step(b);if(error)return error;
 if(r->hdr.opcode==BATTMGR_USB_PROPERTY_SET){if(!ignore_set)remote_enabled=true;}
 else if(r->hdr.opcode==UKE_INPUT_SUSPEND_SET){if(!ignore_set)remote_inhibit=r->value;}
 else b->control.input_suspended=remote_inhibit;
 return 0;
}
C
awk '/^struct qcom_battmgr_uke_protection \{/ {emit=1} emit {print} emit && /^};/ {exit}' "$source"
for function in qcom_battmgr_uke_protection_read qcom_battmgr_uke_external_guard qcom_battmgr_uke_protection_guard qcom_battmgr_uke_moisture_enable qcom_battmgr_uke_input_suspend qcom_battmgr_uke_charge_faults qcom_battmgr_uke_wet_guard_step qcom_battmgr_uke_wet_guard; do
 awk -v name="$function" '$0 ~ "^static (int|u32) " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$source"
done
cat <<'C'
static void initialize(struct qcom_battmgr *b){
 static struct device parent,device={.parent=&parent};
 *b=(struct qcom_battmgr){.dev=&device,.service_up=true,.transaction={.instance_ns=42,.generation=7,.firmware_generation=2,.source_generation=3},
 .control={.external_min={1000,2000,3000},.external_max={40000,41000,42000},.temperature_min=100,.temperature_max=400,.voltage_min_uv=3000000,.voltage_max_uv=4400000,.current_abs_max_ua=2000000}};
 for(unsigned i=0;i<3;i++)temperatures[i]=25000;
 sensor_failure=type_failure=missing_sensor=-1;channel_releases=requests=writes=fail_at=change_at=0;
 clock_ns=2*NSEC_PER_SEC;request_ns=0;lease=remote_enabled=true;
 remote_online=remote_wet=remote_inhibit=ignore_set=false;
 remote_health=1;remote_temperature=250;remote_voltage=4000000;
 remote_present=true;
}
static void dry(struct qcom_battmgr *b){remote_wet=false;for(unsigned i=0;i<18;i++){clock_ns+=2*NSEC_PER_SEC;assert(!qcom_battmgr_uke_wet_guard(b));}}
int main(void){
 struct qcom_battmgr b;struct qcom_battmgr_uke_protection p;
 initialize(&b);assert(!qcom_battmgr_uke_protection_read(&b,&p)&&requests==2&&p.enabled&&!p.moisture);
 initialize(&b);change_at=1;assert(qcom_battmgr_uke_protection_read(&b,&p)==-ESTALE);
 initialize(&b);request_ns=3*NSEC_PER_SEC;assert(qcom_battmgr_uke_protection_read(&b,&p)==-ESTALE);
 for(unsigned i=1;i<=2;i++){initialize(&b);fail_at=i;assert(qcom_battmgr_uke_protection_read(&b,&p)==-ETIMEDOUT);}
 initialize(&b);assert(!qcom_battmgr_uke_protection_guard(&b)&&channel_releases==3);
 initialize(&b);remote_wet=true;assert(qcom_battmgr_uke_protection_guard(&b)==-EACCES&&b.protection.wet_latched);
 initialize(&b);remote_enabled=false;assert(qcom_battmgr_uke_protection_guard(&b)==-EACCES);
 for(unsigned i=0;i<3;i++){
  initialize(&b);temperatures[i]=b.control.external_min[i];assert(!qcom_battmgr_uke_external_guard(&b));
  initialize(&b);temperatures[i]=b.control.external_max[i];assert(qcom_battmgr_uke_external_guard(&b)==-ERANGE);
  initialize(&b);missing_sensor=i;assert(qcom_battmgr_uke_external_guard(&b)==-ENODEV);
  initialize(&b);sensor_failure=i;assert(qcom_battmgr_uke_external_guard(&b)==-EIO);
  initialize(&b);type_failure=i;assert(qcom_battmgr_uke_external_guard(&b)==-ENODATA);
  initialize(&b);b.control.external_min[i]=b.control.external_max[i];assert(qcom_battmgr_uke_external_guard(&b)==-EACCES);
 }
 initialize(&b);remote_enabled=false;remote_online=true;assert(qcom_battmgr_uke_moisture_enable(&b)==-EBUSY&&!writes);
 initialize(&b);remote_enabled=false;assert(!qcom_battmgr_uke_moisture_enable(&b)&&writes==1&&remote_enabled&&!b.control.moisture_enabling);
 initialize(&b);remote_enabled=false;ignore_set=true;assert(qcom_battmgr_uke_moisture_enable(&b)==-EREMOTEIO&&b.control.moisture_uncertain);
 assert(qcom_battmgr_uke_moisture_enable(&b)==-EUCLEAN&&writes==1);
 initialize(&b);remote_wet=true;assert(!qcom_battmgr_uke_wet_guard(&b)&&remote_inhibit&&b.protection.inhibit_owned&&b.protection.inhibit_verified&&writes==1);
 assert(!qcom_battmgr_uke_wet_guard(&b)&&writes==1);
 remote_wet=false;assert(!qcom_battmgr_uke_wet_guard(&b)&&b.protection.wet_latched&&remote_inhibit);
 dry(&b);assert(!remote_inhibit&&!b.protection.wet_latched&&writes==2);
 initialize(&b);remote_wet=remote_inhibit=true;assert(!qcom_battmgr_uke_wet_guard(&b)&&!b.protection.inhibit_owned);
 dry(&b);assert(remote_inhibit&&!b.protection.wet_latched&&!writes);
 initialize(&b);remote_wet=true;fail_at=9;assert(qcom_battmgr_uke_wet_guard(&b)==-ETIMEDOUT&&b.protection.inhibit_uncertain);
 const unsigned previous=writes;assert(qcom_battmgr_uke_wet_guard(&b)==-EUCLEAN&&writes==previous);
 initialize(&b);remote_wet=true;assert(!qcom_battmgr_uke_wet_guard(&b));remote_wet=false;
 assert(!qcom_battmgr_uke_wet_guard(&b));
 for(unsigned i=0;i<14;i++){clock_ns+=2*NSEC_PER_SEC;assert(!qcom_battmgr_uke_wet_guard(&b));}
 clock_ns+=2*NSEC_PER_SEC;remote_temperature=400;
 assert(!qcom_battmgr_uke_wet_guard(&b)&&remote_inhibit&&b.protection.wet_latched&&b.protection.faults==2);
 assert(!b.protection.dry_since_ns&&!b.protection.dry_samples);
 initialize(&b);remote_wet=true;assert(!qcom_battmgr_uke_wet_guard(&b));
 b.transaction.source_generation++;assert(!qcom_battmgr_uke_protection_read(&b,&p));
 assert(!b.protection.inhibit_verified&&!b.protection.inhibit_owned&&b.protection.wet_latched);
 initialize(&b);temperatures[1]=41000;
 assert(!qcom_battmgr_uke_wet_guard(&b)&&remote_inhibit&&!b.protection.wet_latched&&b.protection.faults==1);
 temperatures[1]=25000;dry(&b);assert(!remote_inhibit&&!b.protection.faults);
 initialize(&b);remote_voltage=4500000;assert(!qcom_battmgr_uke_wet_guard(&b)&&remote_inhibit&&b.protection.faults==4);
 initialize(&b);lease=false;assert(qcom_battmgr_uke_wet_guard(&b)==-EACCES&&!requests);
}
C
} > "$work/protection.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wstrict-prototypes "$work/protection.c" -o "$work/protection"
"$work/protection"
printf '%s\n' 'Actual moisture/thermal/input-suspend helpers: wet latch, clear dwell, ownership, stale/error and uncertain-write refusals passed; host only'
