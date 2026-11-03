#!/usr/bin/env bash
# Host-only requests and replies through the actual battery driver functions.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source directory}
source=$kernel/drivers/power/supply/qcom_battmgr.c
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
#include <limits.h>
typedef uint32_t u32;
typedef int32_t s32;
typedef uint64_t u64;
typedef int spinlock_t;
#define spin_lock_irqsave(l,f) ((void)(l), (f)=0)
#define spin_unlock_irqrestore(l,f) ((void)(l), (void)(f))
static unsigned long jiffies;
#define HZ 1000
typedef uint32_t __le32;
typedef uint16_t __le16;
typedef uint8_t u8;
typedef int64_t s64;
static s64 div_s64(s64 n, int d) { return n / d; }
struct work_struct { int unused; };
struct delayed_work { struct work_struct work; };
struct completion { int done; };
struct mutex { int unused; };
struct device_node { bool uke; };
struct device { struct device *parent; struct device_node *of_node; };
struct platform_device { struct device dev; };
struct of_device_id { const char *compatible; const void *data; };
#define BIT(n) (1UL << (n))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
C
awk '/^enum power_supply_property \{/ {emit=1} emit {print} emit && /^};/ {exit}' \
    "$kernel/include/linux/power_supply.h"
cat <<'C'
enum { POWER_SUPPLY_USB_TYPE_UNKNOWN=0, POWER_SUPPLY_USB_TYPE_SDP=1,
 POWER_SUPPLY_USB_TYPE_DCP=2, POWER_SUPPLY_USB_TYPE_PD=6, POWER_SUPPLY_USB_TYPE_PD_PPS=8 };
union power_supply_propval { int intval; };
struct power_supply { void *drvdata; };
static void *power_supply_get_drvdata(struct power_supply *psy) { return psy->drvdata; }
static void mutex_lock(struct mutex *m) { assert(!m->unused); m->unused=1; }
static void mutex_unlock(struct mutex *m) { assert(m->unused); m->unused=0; }
#define cpu_to_le32(v) ((uint32_t)(v))
#define le32_to_cpu(v) ((uint32_t)(v))
#define dev_warn(...) ((void)0)
#define dev_info(...) ((void)0)
#define dev_info_ratelimited(...) ((void)0)
#define DIV_ROUND_CLOSEST(x,d) ({ typeof(x) v=(x); typeof(d) n=(d); (v>0 ? (v+n/2)/n : (v-n/2)/n); })
static void complete(struct completion *c) { c->done++; }
static void strscpy(char *dst, const char *src, size_t size) {
 size_t n=strnlen(src,size-1); memcpy(dst,src,n); dst[n]=0;
}
C
awk '/^#define PMIC_GLINK_/ {print}
     /^struct pmic_glink_hdr/ {emit=1} emit {print} emit && /^};/ {emit=0}' \
    "$kernel/include/linux/soc/qcom/pmic_glink.h"
awk '/^#define BATTMGR_CHEMISTRY_LEN/ {emit=1}
     /^static void qcom_battmgr_sm8350_callback\(/ {emit=0} emit {print}' "$source"
awk '/^enum \{/ {emit=1} /^struct pmic_glink_data \{/ {emit=1}
     emit {print} emit && /^};/ {emit=0}' "$kernel/drivers/soc/qcom/pmic_glink.c"
awk '/^static const struct pmic_glink_data pmic_glink_uke_data/ {emit=1}
     emit {print} emit && /^MODULE_DEVICE_TABLE/ {exit}' \
    "$kernel/drivers/soc/qcom/pmic_glink.c" | sed '/^MODULE_DEVICE_TABLE/d'
cat <<'C'
static struct qcom_battmgr_property_request sent;
static struct qcom_battmgr_property_request last_set;
static int requests, set_requests, request_result, request_fail_at, readback_result, generation_change_at;
static unsigned int readback_limit=500000;
static int qcom_battmgr_request(struct qcom_battmgr *b, void *p, size_t n) {
 assert(b && n==sizeof(sent)); memcpy(&sent,p,n); requests++;
 if(sent.hdr.opcode==BATTMGR_USB_PROPERTY_SET) { set_requests++; last_set=sent; }
 if(requests==request_fail_at) return -ETIMEDOUT;
 if(request_result) return request_result;
 if(sent.hdr.opcode==BATTMGR_USB_PROPERTY_GET && sent.property==USB_INPUT_CURR_LIMIT) {
  if(readback_result) return readback_result;
  b->usb.current_limit=readback_limit;
 }
 if(requests==generation_change_at) b->transaction.generation++;
 return 0;
}
static bool uke_root;
static const struct of_device_id *match_result;
static const struct of_device_id *of_match_device(const void *table, const struct device *dev) {
 (void)table; (void)dev; return match_result;
}
static bool of_machine_is_compatible(const char *name) {
 assert(!strcmp(name,"xiaomi,uke")); return uke_root;
}
static bool of_device_is_compatible(const struct device_node *node, const char *name) {
 assert(!strcmp(name,"qcom,usb-snps-eusb2-phy") || !strcmp(name,"qcom,cliffs-adsp-pas")); return node->uke;
}
struct usb_phy { struct device *dev; int (*set_power)(struct usb_phy *, unsigned int); };
struct dwc3 { struct usb_phy *usb2_phy; struct power_supply *usb_psy; unsigned int current_limit, vbus_draw_retries, vbus_draw_generation; unsigned long vbus_draw_deadline; bool vbus_draw_paused; spinlock_t vbus_draw_lock; struct delayed_work vbus_draw_work; };
struct usb_gadget { struct dwc3 *dwc; };
static int scheduled, legacy;
static struct dwc3 *gadget_to_dwc(struct usb_gadget *g) { return g->dwc; }
#define WRITE_ONCE(x, v) ((x)=(v))
static void *system_percpu_wq;
static void mod_delayed_work(void *q, struct delayed_work *w, unsigned int delay) { (void)q; (void)w; assert(delay==0); scheduled++; }
static int usb_phy_set_power(struct usb_phy *p, unsigned int mA) { (void)p; (void)mA; legacy++; return 42; }
static const struct of_device_id qcom_battmgr_of_variants[]={{0}};
C
for name in uke_generation uke_battery_property uke_usb_type uke_validate request_property usb_set_property usb_is_writeable sm8350_callback; do
    awk -v name="qcom_battmgr_$name" '
        $0 ~ "^static (int|void|u32) " name "\\(" {candidate=1;body=0;buffer=""}
        candidate {buffer=buffer $0 ORS}
        candidate && !body && /;$/ {candidate=0;buffer=""}
        candidate && /^\{/ {body=1}
        candidate && body && /^}/ {printf "%s",buffer;found=1;exit}
        END {if(!found)exit 1}' "$source"
done
awk '/^static const u8 sm8350_bat_prop_map\[\]/ {emit=1} emit {print} emit && /^};/ {exit}' "$source"
awk '/^static int qcom_battmgr_bat_sm8350_update\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$source"
awk '/^static int dwc3_gadget_vbus_draw\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/usb/dwc3/gadget.c"
cat <<'C'
static void select_variant(struct qcom_battmgr *battmgr, struct device *dev) {
 const struct of_device_id *match;
C
awk '/match = of_match_device\(qcom_battmgr_of_variants/ {emit=1}
     emit && /ret = qcom_battmgr_charge_control_thresholds_init/ {exit}
     emit {print}' "$source"
cat <<'C'
}
struct rproc_policy { bool auto_boot, recovery_disabled; };
static void select_rproc_policy(struct rproc_policy *rproc, struct device *dev) {
 const struct rproc_policy baseline={0}, *desc=&baseline;
 struct platform_device platform={.dev=*dev}, *pdev=&platform;
C
awk '/rproc->auto_boot = desc->auto_boot;/ {emit=1} emit {print} emit && /^\t}/ {exit}' "$kernel/drivers/remoteproc/qcom_q6v5_pas.c"
cat <<'C'
}
static void reply(struct qcom_battmgr *b, unsigned int opcode,
                  unsigned int property, uint32_t value, uint32_t error) {
 struct qcom_battmgr_message m={.hdr.opcode=opcode};
 m.intval.property=property; m.intval.value=value; m.intval.result=error;
 b->ack.done=0; b->error=0;
 qcom_battmgr_sm8350_callback(b,&m,sizeof(m.hdr)+sizeof(m.intval));
 assert(b->ack.done==(b->variant==QCOM_BATTMGR_UKE?0:1));
}
int main(void) {
 assert(pmic_glink_uke_data.client_mask==BIT(PMIC_GLINK_CLIENT_BATT));
 assert(!strcmp(pmic_glink_uke_data.charger_pdr_service_name,"tms/servreg"));
 assert(!strcmp(pmic_glink_uke_data.charger_pdr_service_path,"msm/adsp/charger_pd"));
 assert(!strcmp(pmic_glink_of_match[0].compatible,"xiaomi,uke-pmic-glink"));
 assert(pmic_glink_of_match[0].data==&pmic_glink_uke_data);
 assert(pmic_glink_adsp_data.client_mask==(BIT(PMIC_GLINK_CLIENT_BATT)|BIT(PMIC_GLINK_CLIENT_ALTMODE)|BIT(PMIC_GLINK_CLIENT_UCSI)));
 struct qcom_battmgr b={.variant=QCOM_BATTMGR_UKE};
 b.status.voltage_now=4000000; b.status.current_now=500000;
 int power_requests=requests;
 assert(qcom_battmgr_bat_sm8350_update(&b,POWER_SUPPLY_PROP_POWER_NOW)==0);
 assert(b.status.power_now==2000000 && requests==power_requests+2 && sent.property==9 && !b.lock.unused);
 b.status.current_now=-500000;
 assert(qcom_battmgr_bat_sm8350_update(&b,POWER_SUPPLY_PROP_POWER_NOW)==0 && b.status.power_now==-2000000);
 b.status.current_now=0;
 assert(qcom_battmgr_bat_sm8350_update(&b,POWER_SUPPLY_PROP_POWER_NOW)==0 && !b.status.power_now);
 b.status.voltage_now=UINT_MAX; b.status.current_now=INT_MAX;
 assert(qcom_battmgr_bat_sm8350_update(&b,POWER_SUPPLY_PROP_POWER_NOW)==-ERANGE && !b.status.power_now && !b.lock.unused);
 b.status.voltage_now=4000000; b.status.current_now=500000;
 for (int fail=1;fail<=2;fail++) {
  request_fail_at=requests+fail;
  assert(qcom_battmgr_bat_sm8350_update(&b,POWER_SUPPLY_PROP_POWER_NOW)==-ETIMEDOUT && !b.status.power_now && !b.lock.unused);
 }
 request_fail_at=0;
 /* Independent wire IDs from the pinned Uke OEM enum, including its inserted ID 12. */
 const int wire[]={0,1,2,3,4,5,6,7,8,9,10,11,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27};
 for (unsigned int i=0;i<sizeof(wire)/sizeof(wire[0]);i++) {
  assert(qcom_battmgr_uke_battery_property(i,true)==wire[i]);
  assert(qcom_battmgr_uke_battery_property(wire[i],false)==(int)i);
  if (i==BATT_POWER_NOW) {
   int count=requests;
   assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_GET,i,0)==-ENODATA && requests==count);
   continue;
  }
  assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_GET,i,0)==0);
  assert(sent.property==(unsigned int)wire[i] && sent.hdr.owner==32778 && sent.value==0);
 }
 int before=requests;
 for (int id=-1;id<=30;id++) {
  if (id<0 || id>26) assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_GET,id,0)==-EINVAL);
 }
 assert(requests==before);
 assert(qcom_battmgr_uke_battery_property(12,false)==-EINVAL);
 assert(qcom_battmgr_uke_battery_property(28,false)==-EINVAL);
 assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_SET,10,900)==-EOPNOTSUPP && requests==before);
 request_result=-ETIMEDOUT;
 assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_GET,12,0)==-ETIMEDOUT);
 request_result=0;
 assert(qcom_battmgr_request_property(&b,BATTMGR_USB_PROPERTY_GET,12,0)==0 && sent.property==12);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,13,2550,0); assert((int)b.status.temperature==255);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,13,(uint32_t)-500,0); assert((int)b.status.temperature==-50);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,15,8850,0); assert(b.info.charge_count==8850000);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,15,(uint32_t)-100,0); assert((int)b.info.charge_count==-100000);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,15,8850,0);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,15,2147484,0); assert(b.error==-ERANGE && b.info.charge_count==8850000);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,9,(uint32_t)-500000,0); assert(b.status.current_now==500000);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,9,500000,0); assert(b.status.current_now==-500000);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,9,(uint32_t)INT_MIN,0); assert(b.error==-ERANGE && b.status.current_now==-500000);
 b.variant=QCOM_BATTMGR_SM8350;
 reply(&b,BATTMGR_BAT_PROPERTY_GET,14,8850,0); assert(b.info.charge_count==8850);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,9,(uint32_t)-500000,0); assert(b.status.current_now==-500000);
 b.variant=QCOM_BATTMGR_UKE;
 reply(&b,BATTMGR_BAT_PROPERTY_GET,4,1250,0); assert(b.status.percent==12);
 /* Cycle zero is a reported count, not a transport-unavailable sentinel. */
 reply(&b,BATTMGR_BAT_PROPERTY_GET,16,7,0); assert(!b.error && b.info.cycle_count==7);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,16,0,0); assert(!b.error && !b.info.cycle_count);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,16,INT_MAX,0); assert(!b.error && b.info.cycle_count==INT_MAX);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,16,UINT_MAX,0); assert(b.error==-ENODATA && b.info.cycle_count==INT_MAX);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,16,0,EPERM); assert(b.error==-EREMOTEIO && b.info.cycle_count==INT_MAX);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,12,1000000,0); assert(b.error==-ENODATA && (int)b.status.temperature==-50);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,28,9,0); assert(b.error==-ENODATA);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,13,1000,EPERM); assert(b.error==-EREMOTEIO && (int)b.status.temperature==-50);
 struct qcom_battmgr_message m={.hdr.opcode=BATTMGR_BAT_PROPERTY_GET};
 m.strval.property=19; strcpy(m.strval.model,"OEM protocol fixture");
 b.ack.done=0;
 qcom_battmgr_sm8350_callback(&b,&m,sizeof(m.hdr)+sizeof(m.strval));
 assert(!strcmp(b.info.model_number,"OEM protocol fixture") && b.ack.done==0);
 b.ack.done=0; b.error=0;
 qcom_battmgr_sm8350_callback(&b,&m,sizeof(m.hdr)+sizeof(m.intval));
 assert(b.error==-ENODATA && b.ack.done==0);
 reply(&b,BATTMGR_USB_PROPERTY_GET,0,1,0); assert(b.usb.online);
 reply(&b,BATTMGR_USB_PROPERTY_GET,0,2,0); assert(b.error==-ENODATA && b.usb.online);
 reply(&b,BATTMGR_USB_PROPERTY_GET,USB_MOISTURE_EN,1,0);assert(!b.error&&b.usb.moisture_enabled==1);
 reply(&b,BATTMGR_USB_PROPERTY_GET,USB_MOISTURE_STATUS,1,0);assert(!b.error&&b.usb.moisture_status==1);
 reply(&b,BATTMGR_USB_PROPERTY_GET,USB_MOISTURE_STATUS,2,0);assert(b.error==-ENODATA&&b.usb.moisture_status==1);
 b.transaction.receipt_ns=42; b.transaction.generation=7;
 b.transaction.firmware_generation=2; b.transaction.source_generation=3;
 for (u32 raw=0;raw<=8;raw++) {
  reply(&b,BATTMGR_USB_PROPERTY_GET,6,raw,0);
  assert(!b.error && b.usb.usb_type==raw && b.usb.type_raw==raw);
 }
 const u32 ambiguous[]={9,10,11,127,128,129,130,131,132,UINT_MAX};
 for (unsigned i=0;i<ARRAY_SIZE(ambiguous);i++) {
  reply(&b,BATTMGR_USB_PROPERTY_GET,6,ambiguous[i],0);
  assert(!b.error && b.usb.usb_type==POWER_SUPPLY_USB_TYPE_UNKNOWN && b.usb.type_raw==ambiguous[i]);
  assert(b.usb.type_received_ns==42 && b.usb.type_generation==7 && b.usb.type_firmware==2 && b.usb.type_source==3);
 }
 /* Wire7 independently confirms the adapter; it never replaces wire6. */
 reply(&b,BATTMGR_USB_PROPERTY_GET,USB_ADAP_TYPE,POWER_SUPPLY_USB_TYPE_SDP,0);
 assert(!b.error && b.usb.adapter_type==POWER_SUPPLY_USB_TYPE_SDP && b.usb.usb_type==POWER_SUPPLY_USB_TYPE_UNKNOWN);
 {
  const u32 reported[]={0,9,128,129,130,131,132,UINT32_MAX};
  for(unsigned i=0;i<ARRAY_SIZE(reported);i++){
   reply(&b,BATTMGR_USB_PROPERTY_GET,UKE_USB_REAL_TYPE,reported[i],0);
   assert(!b.error&&b.usb.real_type==reported[i]);
  }
  reply(&b,BATTMGR_USB_PROPERTY_GET,UKE_USB_REAL_TYPE,130,EIO);
  assert(b.error==-EREMOTEIO&&b.usb.real_type==UINT32_MAX);
  b.variant=QCOM_BATTMGR_SM8350;
  reply(&b,BATTMGR_USB_PROPERTY_GET,UKE_USB_REAL_TYPE,130,0);
  assert(b.error==-EOPNOTSUPP&&b.usb.real_type==UINT32_MAX);
  b.variant=QCOM_BATTMGR_UKE;
 }
 struct power_supply usb={.drvdata=&b};
 union power_supply_propval budget={.intval=500000};
 assert(qcom_battmgr_usb_is_writeable(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT));
 before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN && requests==before);
 b.service_up=true; b.usb.usb_type=POWER_SUPPLY_USB_TYPE_SDP; b.usb.current_max=500000;
 /* Reproduce SET0 ACK followed by a retained 500mA limit. */
 int set_before=set_requests;
 before=requests;
 b.usb.current_limit=500000; budget.intval=0;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EREMOTEIO);
 assert(requests==before+6 && set_requests==set_before+1 && last_set.value==0);
 budget.intval=500000; before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==0);
 assert(requests==before+6 && last_set.property==5 && last_set.value==500000);
 assert(sent.hdr.opcode==BATTMGR_USB_PROPERTY_GET && sent.property==5);
 readback_limit=100000;
 assert(!qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget));
 readback_limit=0; budget.intval=0;
 assert(!qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget));
 readback_limit=500000; budget.intval=500000;
 before=requests; set_before=set_requests; request_fail_at=before+6;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EREMOTEIO);
 assert(requests==before+6 && set_requests==set_before+1); request_fail_at=0;
 before=requests; set_before=set_requests; readback_result=-EAGAIN;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EREMOTEIO);
 assert(requests==before+6 && set_requests==set_before+1); readback_result=0;
 before=requests; set_before=set_requests; generation_change_at=before+6;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EREMOTEIO);
 assert(requests==before+6 && set_requests==set_before+1); generation_change_at=0;
 before=requests; set_before=set_requests; generation_change_at=before+4;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN);
 assert(requests==before+4 && set_requests==set_before); generation_change_at=0;
 before=requests; set_before=set_requests; request_fail_at=before+5;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-ETIMEDOUT);
 assert(requests==before+5 && set_requests==set_before+1); request_fail_at=0;
 const u32 adapters[]={0,2,3,6,8,UINT_MAX};
 for (unsigned i=0;i<ARRAY_SIZE(adapters);i++) {
  reply(&b,BATTMGR_USB_PROPERTY_GET,USB_ADAP_TYPE,adapters[i],0);
  before=requests;
  assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==(adapters[i]?-EINVAL:-EAGAIN));
  assert(requests==before+4 && sent.hdr.opcode==BATTMGR_USB_PROPERTY_GET && sent.property==USB_CURR_MAX);
 }
 reply(&b,BATTMGR_USB_PROPERTY_GET,USB_ADAP_TYPE,POWER_SUPPLY_USB_TYPE_SDP,0);
 before=requests; request_fail_at=before+3;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-ETIMEDOUT);
 assert(requests==before+3 && sent.property==USB_ADAP_TYPE && !b.lock.unused);request_fail_at=0;
 for (int invalid=0;invalid<3;invalid++) {
  before=requests; budget.intval=invalid==0?-1:invalid==1?500001:1000000;
  assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EINVAL && requests==before);
 }
 budget.intval=500000; b.usb.current_max=100000;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EINVAL);
 b.usb.current_max=500000; b.usb.online=false;
 before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN && requests==before+4);
 b.usb.online=true; b.usb.usb_type=POWER_SUPPLY_USB_TYPE_UNKNOWN;
 before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN && requests==before+4);
 b.usb.usb_type=POWER_SUPPLY_USB_TYPE_SDP; b.usb.current_max=0;
 before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN && requests==before+4);
 b.usb.current_max=500000; b.usb.usb_type=POWER_SUPPLY_USB_TYPE_PD;
 before=requests;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EINVAL && requests==before+4);
 b.usb.usb_type=POWER_SUPPLY_USB_TYPE_UNKNOWN;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EAGAIN);
 b.usb.usb_type=POWER_SUPPLY_USB_TYPE_SDP; request_result=-ETIMEDOUT;
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-ETIMEDOUT && !b.lock.unused);
 request_result=0;
 reply(&b,BATTMGR_USB_PROPERTY_SET,5,500000,EPERM); assert(b.error==-EREMOTEIO);
 m.hdr.opcode=0x50; b.ack.done=0;
 qcom_battmgr_sm8350_callback(&b,&m,sizeof(m.hdr)+sizeof(m.intval)); assert(!b.ack.done);
 m.hdr.opcode=0xdead;
 qcom_battmgr_sm8350_callback(&b,&m,sizeof(m.hdr)+sizeof(m.intval)); assert(!b.ack.done);
 b.variant=QCOM_BATTMGR_SM8350;
 assert(!qcom_battmgr_usb_is_writeable(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT));
 assert(qcom_battmgr_usb_set_property(&usb,POWER_SUPPLY_PROP_INPUT_CURRENT_LIMIT,&budget)==-EOPNOTSUPP);
 assert(qcom_battmgr_request_property(&b,BATTMGR_BAT_PROPERTY_GET,12,0)==0 && sent.property==12);
 reply(&b,BATTMGR_BAT_PROPERTY_GET,12,2550,0); assert(b.status.temperature==255);
 struct device d={0};
 struct of_device_id matched={.data=(void *)QCOM_BATTMGR_SM8550};
 uke_root=false; match_result=NULL; select_variant(&b,&d); assert(b.variant==QCOM_BATTMGR_SM8350);
 match_result=&matched; select_variant(&b,&d); assert(b.variant==QCOM_BATTMGR_SM8550);
 uke_root=true; select_variant(&b,&d); assert(b.variant==QCOM_BATTMGR_UKE && b.unit==QCOM_BATTMGR_UNIT_mAh);
 match_result=NULL; select_variant(&b,&d); assert(b.variant==QCOM_BATTMGR_UKE);
 struct device_node node={.uke=true}; struct device phydev={.of_node=&node};
 struct usb_phy phy={.dev=&phydev}; struct dwc3 dwc={.usb2_phy=&phy,.usb_psy=&usb};
 struct usb_gadget gadget={.dwc=&dwc};
 assert(dwc3_gadget_vbus_draw(&gadget,500)==0 && dwc.current_limit==500 && scheduled==1 && !legacy);
 dwc.usb_psy=NULL;
 assert(dwc3_gadget_vbus_draw(&gadget,500)==-EOPNOTSUPP && scheduled==1);
 node.uke=false;
 assert(dwc3_gadget_vbus_draw(&gadget,500)==42 && legacy==1 && scheduled==1);
 node.uke=true; phy.set_power=usb_phy_set_power;
 assert(dwc3_gadget_vbus_draw(&gadget,500)==42 && legacy==2);
 struct rproc_policy r={0}; uke_root=false; node.uke=true;
 select_rproc_policy(&r,&phydev); assert(!r.auto_boot && !r.recovery_disabled);
 uke_root=true; node.uke=false;
 select_rproc_policy(&r,&phydev); assert(!r.auto_boot && !r.recovery_disabled);
 node.uke=true;
 select_rproc_policy(&r,&phydev); assert(r.auto_boot && r.recovery_disabled);
}
C
} > "$work/check.c"
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
echo 'Uke battery: OEM IDs, signed readings, retained SDP budget, terminal post-SET errors and unchanged foreign paths passed; charging hardware is unverified'
