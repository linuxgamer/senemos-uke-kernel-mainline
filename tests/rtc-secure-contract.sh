#!/usr/bin/env bash
# COPR only: exercise the actual RTC callbacks with inert variable/RTC fixtures.
set -Eeuo pipefail
kernel=$(realpath "${1:?patched kernel source}")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/linux"
cat > "$work/linux/types.h" <<'C'
#include <stdint.h>
#include <stdbool.h>
typedef uint32_t u32;
C
cat > "$work/linux/of.h" <<'C'
static bool board=true,soc=true;
static bool of_machine_is_compatible(const char *s){return !strcmp(s,"xiaomi,uke")?board:!strcmp(s,"qcom,sm7675")?soc:false;}
C
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <stdlib.h>
#include <linux/uke-rtc-policy.h>
typedef unsigned long efi_status_t;
#define EFI_SUCCESS 0
#define EFI_NOT_FOUND 14
#define EFI_DEVICE_ERROR 7
#define RTC_TIMESTAMP_EPOCH_GPS 315964800U
#define cpu_to_le32(x) (x)
#define le32_to_cpu(x) (x)
#define QCOM_UEFI_NAME "RTCInfo"
static const int QCOM_UEFI_GUID=1;
#define QCOM_UEFI_ATTRS 7
#define dev_dbg(dev,...) ((void)(dev))
#define dev_info(dev,...) ((void)(dev))
#define dev_err(dev,...) ((void)(dev))
#define abs_diff(a,b) ((a)>(b)?(a)-(b):(b)-(a))
struct device {int unused;};
struct qcom_uefi_rtc_info {u32 offset_gps;unsigned char reserved[8];} __attribute__((packed));
struct pm8xxx_rtc {struct device *dev;bool use_uefi,offset_invalid,offset_dirty;void *nvmem_cell;u32 offset;struct qcom_uefi_rtc_info rtc_info;};
struct rtc_time {u32 secs;};
static struct qcom_uefi_rtc_info stored;
static unsigned writes,reads,locks;
static bool present,corrupt,short_read,readback_fail;
static int lock_error;
static efi_status_t write_status;
static u32 raw=2700000;
static int efivar_lock(void){if(lock_error)return lock_error;assert(!locks);++locks;return 0;}
static void efivar_unlock(void){assert(locks==1);--locks;}
static int efi_status_to_err(efi_status_t s){return s==EFI_NOT_FOUND?-ENOENT:-EIO;}
static efi_status_t efivar_get_variable(const char *name,const int *guid,void *attrs,unsigned long *size,void *data){
 (void)attrs;assert(locks==1&&*size==12&&!strcmp(name,"RTCInfo")&&guid==&QCOM_UEFI_GUID);++reads;
 if(readback_fail&&writes)return EFI_DEVICE_ERROR;
 if(!present)return EFI_NOT_FOUND;
 memcpy(data,&stored,12);if(corrupt)((unsigned char*)data)[11]^=1;if(short_read)*size=8;
 return EFI_SUCCESS;
}
static efi_status_t efivar_set_variable_locked(const char *name,const int *guid,unsigned attrs,unsigned long size,void *data,bool nonblocking){
 assert(!nonblocking);
 assert(locks==1&&size==12&&attrs==7&&!strcmp(name,"RTCInfo")&&guid==&QCOM_UEFI_GUID);++writes;
 if(write_status)return write_status;
 memcpy(&stored,data,12);present=true;return EFI_SUCCESS;
}
static efi_status_t efivar_set_variable(const char *name,const int *guid,unsigned attrs,unsigned long size,void *data){
 int rc=efivar_lock();if(rc)return EFI_DEVICE_ERROR;
 efi_status_t result=efivar_set_variable_locked(name,guid,attrs,size,data,false);efivar_unlock();return result;
}
static int pm8xxx_rtc_read_raw(struct pm8xxx_rtc *d,u32 *value){(void)d;*value=raw;return 0;}
static int pm8xxx_rtc_write_nvmem_offset(struct pm8xxx_rtc *d,u32 v){(void)d;(void)v;assert(0);return -EIO;}
static struct pm8xxx_rtc *dev_get_drvdata(struct device *dev){return (void*)dev;}
static void rtc_time64_to_tm(u32 value,struct rtc_time *tm){tm->secs=value;}
#define QSEECOM_RESULT_INCOMPLETE 1
#define QSEECOM_RESULT_BLOCKED_ON_LISTENER 2
struct qcom_scm_desc {unsigned owner,svc,cmd;};
struct qcom_scm_qseecom_resp {long long result;unsigned long long resp_type,data;};
static struct {struct device *dev;} scm_context,*__scm=&scm_context;
static int qcom_scm_qseecom_call_lock,qsee_status,qsee_result,qsee_locked,warnings;
static void mutex_lock(int *value){assert(value==&qcom_scm_qseecom_call_lock&&!qsee_locked);qsee_locked=1;}
static void mutex_unlock(int *value){assert(value==&qcom_scm_qseecom_call_lock&&qsee_locked);qsee_locked=0;}
static int __qcom_scm_qseecom_call(const struct qcom_scm_desc *desc,struct qcom_scm_qseecom_resp *res){(void)desc;res->result=qsee_result;return qsee_status;}
#define WARN_ON(x) do{if(x)++warnings;}while(0)
C
for function in pm8xxx_rtc_read_uefi_offset pm8xxx_rtc_uke_store pm8xxx_rtc_write_uefi_offset pm8xxx_rtc_update_offset pm8xxx_rtc_read_time; do
 awk -v name="$function" '$0 ~ "^static int "name"\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/rtc/rtc-pm8xxx.c" >> "$work/test.c"
done
awk '/^static int qcom_scm_qseecom_call\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/firmware/qcom/qcom_scm.c" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static void reset(void){present=corrupt=short_read=readback_fail=false;lock_error=0;write_status=EFI_SUCCESS;writes=reads=locks=0;memset(&stored,0,sizeof(stored));board=soc=true;raw=2700000;}
int main(void){
 assert(uke_rtc_qseecom_approved(0x1402000));assert(!uke_rtc_qseecom_approved(0x1402001));
 board=false;assert(!uke_rtc_qseecom_approved(0x1402000));board=true;soc=false;assert(!uke_rtc_qseecom_approved(0x1402000));soc=true;
 struct qcom_scm_desc desc={0};struct qcom_scm_qseecom_resp response={0};
 qsee_result=QSEECOM_RESULT_INCOMPLETE;assert(qcom_scm_qseecom_call(&desc,&response)==-EOPNOTSUPP&&!warnings&&!qsee_locked);
 qsee_result=QSEECOM_RESULT_BLOCKED_ON_LISTENER;assert(qcom_scm_qseecom_call(&desc,&response)==-EOPNOTSUPP&&!warnings&&!qsee_locked);
 board=false;assert(!qcom_scm_qseecom_call(&desc,&response)&&warnings==1);board=true;
 qsee_result=0;qsee_status=-EIO;assert(qcom_scm_qseecom_call(&desc,&response)==-EIO&&!qsee_locked);qsee_status=0;
 assert(!qcom_scm_qseecom_call(&desc,&response)&&!qsee_locked);
 struct rtc_time tm;
 reset();struct pm8xxx_rtc d={.use_uefi=true};
 assert(!pm8xxx_rtc_read_uefi_offset(&d)&&d.offset_invalid&&!writes);
 assert(pm8xxx_rtc_read_time((void*)&d,&tm)==-ENODATA);
 const u32 utc=1793730000;
 assert(!pm8xxx_rtc_update_offset(&d,utc)&&!d.offset_invalid&&writes==1&&!locks);
 assert(!pm8xxx_rtc_read_time((void*)&d,&tm)&&tm.secs==utc);
 struct pm8xxx_rtc rebooted={.use_uefi=true};++raw;
 assert(!pm8xxx_rtc_read_uefi_offset(&rebooted));
 assert(!pm8xxx_rtc_read_time((void*)&rebooted,&tm)&&tm.secs==utc+1);
 memset(stored.reserved,0xa5,8);assert(!pm8xxx_rtc_read_uefi_offset(&rebooted));
 unsigned old=writes;assert(!pm8xxx_rtc_update_offset(&rebooted,utc+2)&&writes==old+1);
 for(unsigned i=0;i<8;i++)assert(stored.reserved[i]==0xa5);
 old=writes;assert(!pm8xxx_rtc_update_offset(&rebooted,utc+2)&&writes==old);
 for(unsigned fault=0;fault<5;fault++){
  reset();struct pm8xxx_rtc failed={.use_uefi=true,.offset_invalid=true};
  switch(fault){case 0:write_status=EFI_DEVICE_ERROR;break;case 1:corrupt=true;break;case 2:short_read=true;break;case 3:readback_fail=true;break;case 4:lock_error=-EBUSY;break;}
  assert(pm8xxx_rtc_update_offset(&failed,utc)<0&&failed.offset_invalid&&!failed.offset&&!locks);
  if(fault==4)assert(!writes&&!reads);
 }
 reset();present=true;struct pm8xxx_rtc factory={.use_uefi=true};
 assert(!pm8xxx_rtc_read_uefi_offset(&factory));
 assert(pm8xxx_rtc_read_time((void*)&factory,&tm)==-ENODATA&&factory.offset_invalid);
 assert(!pm8xxx_rtc_update_offset(&factory,utc));
 reset();board=false;struct pm8xxx_rtc foreign={.use_uefi=true};
 assert(pm8xxx_rtc_read_uefi_offset(&foreign)==-ENOENT&&!foreign.offset_invalid&&!writes);
 puts("Secure RTC: exact board/SOC/version, unsupported callback refusal, uninitialized calendar, provisioning, simulated reboot, reserved bytes, idempotence and five persistence failures passed; no PMIC or firmware operation");
}
C
"${CC:-cc}" -std=gnu11 -O2 -Wall -Wextra -Werror -UNDEBUG -I"$work" -I"$kernel/include" "$work/test.c" -o "$work/check"
"$work/check"
