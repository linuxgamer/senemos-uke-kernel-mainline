#!/usr/bin/env bash
# Actual MCQ mapping/callbacks and core completion handler with host primitives.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
kernel=$(realpath "$1")
driver=$kernel/drivers/ufs/host/ufs-qcom.c
header=$kernel/drivers/ufs/host/ufs-qcom.h
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32;
typedef uint64_t resource_size_t;
typedef int irqreturn_t;
#define __iomem
#define BIT(n) (1U << (n))
#define GENMASK(h,l) ((~0U >> (31-(h))) & (~0U << (l)))
#define FIELD_GET(mask,v) (((v) & (mask)) >> __builtin_ctz(mask))
#define IORESOURCE_MEM 0x200
#define GFP_KERNEL 0
#define ERR_PTR(v) ((void *)(intptr_t)(v))
#define PTR_ERR(v) ((int)(intptr_t)(v))
#define IS_ERR(v) ((uintptr_t)(v) >= (uintptr_t)-4095)
#define dev_err(...) ((void)0)
#define IRQ_HANDLED 1
#define HCTX_TYPE_POLL 2
#define for_each_set_bit(i,addr,n) for((i)=0;(i)<(int)(n);(i)++) if(*(addr)&(1UL<<(i)))
C
sed -n '/^\/\* Qualcomm MCQ Configuration/,/^\/\* QCOM UFS host controller/p' "$header" | sed '$d' >> "$work/test.c"
sed -n '/^enum ufshcd_mcq_opr {/,/^};/p' "$kernel/include/ufs/ufshcd.h" >> "$work/test.c"
grep -E '^#define MCQ_QCFG_SIZE' "$kernel/include/ufs/ufshcd.h" >> "$work/test.c"
grep -E '^#define (INT_AGGR_COUNTER_AND_TIMER_RESET|UFSHCD_MCQ_CQIS_TAIL_ENT_PUSH_STS)' "$kernel/include/ufs/ufshci.h" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
struct resource { const char *name; unsigned long flags; resource_size_t start,end; };
struct device { int unused; };
struct platform_device { struct device dev; struct resource resources[5]; };
struct ufs_qcom_host { void *mcq_uke_sqd,*mcq_uke_vs; u32 mcq_uke_opr_offset; };
struct ufshcd_mcq_opr_info_t { unsigned long offset,stride; void *base; };
struct ufs_hw_queue { int id; };
struct ufs_hba {
    struct device *dev; void *mcq_base; u32 mcq_capabilities,nr_hw_queues;
    struct ufshcd_mcq_opr_info_t mcq_opr[OPR_MAX];
    unsigned nr_queues[3]; struct ufs_hw_queue uhq[32];
};
static struct platform_device pdev;
static struct ufs_qcom_host host;
static struct ufs_hba hba;
static bool uke,sm7675,group_open,group_closed,fail_group;
static int map_calls,live_maps,released,fail_map,callback_error;
static unsigned char config_bytes[0x4000],opr_bytes[0x2000],vs_bytes[16],generic_bytes[0x8000];
static struct resource mapped_config;
static const void *read_address;
static unsigned cqis[32],polls[32],ack[32],iacr[32];
static struct platform_device *to_platform_device(struct device *dev) { assert(dev==&pdev.dev);return &pdev; }
static struct ufs_qcom_host *ufshcd_get_variant(struct ufs_hba *h) { assert(h==&hba);return &host; }
static resource_size_t resource_size(const struct resource *r) { return r->end-r->start+1; }
static struct resource *platform_get_resource_byname(struct platform_device *p,unsigned flags,const char *name) {
    assert(p==&pdev&&flags==IORESOURCE_MEM);
    for(unsigned i=0;i<5;i++)if(p->resources[i].name&&!strcmp(p->resources[i].name,name))return &p->resources[i];
    return NULL;
}
static bool of_machine_is_compatible(const char *name) { return !strcmp(name,"xiaomi,uke")?uke:sm7675; }
static void *devres_open_group(struct device *dev,void *id,int flags) {
    assert(dev==&pdev.dev&&!id&&!flags&&!group_open);if(fail_group)return NULL;
    group_open=true;return &group_open;
}
static void devres_close_group(struct device *dev,void *id) { assert(dev==&pdev.dev&&id==&group_open&&group_open);group_closed=true; }
static void devres_remove_group(struct device *dev,void *id) { assert(dev==&pdev.dev&&id==&group_open&&group_closed);group_open=false; }
static void devres_release_group(struct device *dev,void *id) {
    assert(dev==&pdev.dev&&id==&group_open&&group_open);group_open=false;live_maps=0;released++;
}
static void *devm_ioremap_resource(struct device *dev,const struct resource *r) {
    assert(dev==&pdev.dev&&r->flags==IORESOURCE_MEM);
    if(++map_calls==fail_map)return ERR_PTR(-EBUSY);
    live_maps++;
    if(!strcmp(r->name,"mcq")) { mapped_config=*r;return uke?config_bytes:generic_bytes; }
    if(!strcmp(r->name,"mcq_sqd"))return opr_bytes;
    assert(!strcmp(r->name,"mcq_vs"));return vs_bytes;
}
static u32 readl(const void *address) { u32 value;read_address=address;memcpy(&value,address,sizeof value);return value; }
C
if grep -q '^#include "ufs-qcom-uke.h"' "$driver"; then
    cat "$kernel/drivers/ufs/host/ufs-qcom-uke.h" >> "$work/test.c"
fi
for function in ufs_qcom_mcq_config_resource ufs_qcom_op_runtime_config ufs_qcom_get_outstanding_cqs; do
    awk -v name="$function" '$0 ~ "^static int " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$driver" >> "$work/test.c"
done
cat >> "$work/test.c" <<'C'
static int ufshcd_vops_get_outstanding_cqs(struct ufs_hba *h,unsigned long *mask) {
    return callback_error?callback_error:ufs_qcom_get_outstanding_cqs(h,mask);
}
static u32 ufshcd_mcq_read_cqis(struct ufs_hba *h,int i) { assert(h==&hba&&i<32);return cqis[i]; }
static void ufshcd_mcq_write_cqis(struct ufs_hba *h,u32 value,int i) { assert(h==&hba&&i<32);ack[i]=value;cqis[i]&=~value; }
static u32 ufshcd_mcq_read_mcqiacr(struct ufs_hba *h,int i) { assert(h==&hba&&i<32);return iacr[i]; }
static void ufshcd_mcq_write_mcqiacr(struct ufs_hba *h,u32 value,int i) { assert(h==&hba&&i<32);iacr[i]=value; }
static void ufshcd_mcq_poll_cqe_lock(struct ufs_hba *h,struct ufs_hw_queue *q) { assert(h==&hba&&q->id<32);polls[q->id]++; }
C
awk '/^static irqreturn_t ufshcd_handle_mcq_cq_events\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/ufs/core/ufshcd.c" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
static void reset(void) {
    memset(&pdev,0,sizeof pdev);memset(&host,0,sizeof host);memset(&hba,0,sizeof hba);
    const struct resource resources[]={
        {"std",IORESOURCE_MEM,0x1d84000,0x1d86fff},
        {"ice",IORESOURCE_MEM,0x1d88000,0x1d98fff},
        {"mcq_sqd",IORESOURCE_MEM,0x1da5000,0x1da6fff},
        {"mcq_vs",IORESOURCE_MEM,0x1da4000,0x1da400f},
    };
    memcpy(pdev.resources,resources,sizeof resources);
    hba.dev=&pdev.dev;hba.mcq_capabilities=0xe0U<<16;hba.nr_hw_queues=9;hba.nr_queues[HCTX_TYPE_POLL]=1;
    uke=sm7675=true;group_open=group_closed=fail_group=false;
    map_calls=live_maps=released=fail_map=callback_error=0;read_address=NULL;
    memset(cqis,0,sizeof cqis);memset(polls,0,sizeof polls);memset(ack,0,sizeof ack);memset(iacr,0,sizeof iacr);
    for(int i=0;i<32;i++)hba.uhq[i].id=i;
}
static void rejected(int result) {
    assert(result<0&&!hba.mcq_base&&!host.mcq_uke_sqd&&!host.mcq_uke_vs);
    assert(!host.mcq_uke_opr_offset&&!live_maps&&!group_open);
}
static void accepted(void) {
    assert(!ufs_qcom_mcq_config_resource(&hba));
    assert(hba.mcq_base==config_bytes&&host.mcq_uke_sqd==opr_bytes&&host.mcq_uke_vs==vs_bytes);
    assert(live_maps==3&&!released&&!group_open&&host.mcq_uke_opr_offset==0x21000);
    assert(resource_size(&mapped_config)==hba.nr_hw_queues*0x40);
    assert(!ufs_qcom_op_runtime_config(&hba));
    for(unsigned i=0;i<OPR_MAX;i++) {
        assert(hba.mcq_opr[i].offset==0x21000+0x40*i&&hba.mcq_opr[i].stride==0x100);
        assert(hba.mcq_opr[i].base==opr_bytes+0x40*i);
        assert(0x100*(hba.nr_hw_queues-1)+0x40*i+0x24<sizeof opr_bytes);
    }
}
int main(void) {
    reset();accepted();assert(mapped_config.start==0x1da0000&&mapped_config.end==0x1da023f);
    unsigned long mask=0;u32 status=BIT(0)|BIT(6)|BIT(8);memcpy(vs_bytes+8,&status,4);
    assert(!ufs_qcom_get_outstanding_cqs(&hba,&mask)&&mask==status&&read_address==vs_bytes+8);
    cqis[0]=cqis[6]=cqis[8]=UFSHCD_MCQ_CQIS_TAIL_ENT_PUSH_STS;
    assert(ufshcd_handle_mcq_cq_events(&hba,false)==IRQ_HANDLED);
    assert(polls[0]==1&&polls[6]==1&&!polls[8]&&ack[0]&&ack[6]&&!ack[8]);
    callback_error=-EIO;
    for(int i=0;i<9;i++)cqis[i]=UFSHCD_MCQ_CQIS_TAIL_ENT_PUSH_STS;
    assert(ufshcd_handle_mcq_cq_events(&hba,true)==IRQ_HANDLED);
    for(int i=0;i<8;i++)assert(polls[i]&&ack[i]&&(iacr[i]&INT_AGGR_COUNTER_AND_TIMER_RESET));
    assert(!polls[8]&&!ack[8]&&!iacr[8]);
    for(int fault=0;fault<12;fault++) {
        reset();int i=fault/3;
        if(fault%3==0)pdev.resources[i].start++;
        if(fault%3==1)pdev.resources[i].end++;
        if(fault%3==2)pdev.resources[i].name=NULL;
        rejected(ufs_qcom_mcq_config_resource(&hba));assert(!map_calls);
    }
    for(int fault=0;fault<8;fault++) {
        reset();
        if(fault==0)sm7675=false;
        if(fault==1)hba.nr_hw_queues=0;
        if(fault==2)hba.nr_hw_queues=33;
        if(fault==3)hba.nr_hw_queues=UINT32_MAX;
        if(fault==4)hba.mcq_capabilities=0;
        if(fault==5)hba.mcq_capabilities=0xa7U<<16;
        if(fault==6)hba.mcq_capabilities=0xffU<<16;
        if(fault==7)fail_group=true;
        rejected(ufs_qcom_mcq_config_resource(&hba));assert(!map_calls);
    }
    for(int i=1;i<=3;i++) {
        reset();fail_map=i;rejected(ufs_qcom_mcq_config_resource(&hba));assert(released==1&&map_calls==i);
    }
    reset();hba.nr_hw_queues=32;hba.mcq_capabilities=0xa8U<<16;accepted();assert(mapped_config.start==0x1d99000);
    reset();hba.nr_hw_queues=8;hba.mcq_capabilities=0xffU<<16;accepted();assert(mapped_config.end==0x1da3fff);
    reset();hba.mcq_capabilities|=BIT(31)|0x1234;accepted();assert(mapped_config.start==0x1da0000);
    reset();uke=false;rejected(ufs_qcom_mcq_config_resource(&hba));assert(!map_calls);
    reset();uke=false;pdev.resources[4]=(struct resource){"mcq",IORESOURCE_MEM,0x1da0000,0x1da7fff};
    assert(!ufs_qcom_mcq_config_resource(&hba)&&hba.mcq_base==generic_bytes&&!host.mcq_uke_sqd&&!host.mcq_uke_vs);
    assert(!ufs_qcom_op_runtime_config(&hba)&&hba.mcq_opr[OPR_SQD].base==generic_bytes+0x5000);
    memcpy(generic_bytes+0x4008,&status,4);assert(!ufs_qcom_get_outstanding_cqs(&hba,&mask)&&mask==status&&read_address==generic_bytes+0x4008);
    puts("Actual MCQ resource/queue bounds, 24 refusal paths, mapping cleanup, generic path and core IRQ/poll exclusion passed; host only");
}
C
${CC:-clang} -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined "$work/test.c" -o "$work/test"
ASAN_OPTIONS=detect_leaks=1 "$work/test"
