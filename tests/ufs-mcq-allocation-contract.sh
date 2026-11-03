#!/usr/bin/env bash
# Actual core allocation functions; DMA/devres/init are host primitives.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
kernel=$(realpath "$1")
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/test.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef uintptr_t dma_addr_t;
#define GFP_KERNEL 0
#define WARN_ON(v) (!!(v))
#define dev_err(...) ((void)0)
C
grep -E '^#define UFSHCD_NUM_RESERVED' "$kernel/include/ufs/ufshci.h" >> "$work/test.c"
grep -E '^#define SZ_1K' "$kernel/include/linux/sizes.h" >> "$work/test.c"
sed -n '/^enum hctx_type {/,/^};/p' "$kernel/include/linux/blk-mq.h" >> "$work/test.c"
cat >> "$work/test.c" <<'C'
struct device { int unused; };
struct utp_transfer_cmd_desc { char bytes[128]; };
struct utp_transfer_req_desc { char bytes[32]; };
struct utp_task_req_desc { char bytes[32]; };
struct utp_devman_cmd_desc { char bytes[128]; };
struct cq_entry { char bytes[32]; };
struct Scsi_Host { unsigned nr_hw_queues; int can_queue; };
struct ufs_hw_queue { struct utp_transfer_req_desc *sqe_base_addr;struct cq_entry *cqe_base_addr;dma_addr_t sqe_dma_addr,cqe_dma_addr;unsigned max_entries; };
struct ufs_hba {
    struct device *dev;struct Scsi_Host *host;
    struct utp_transfer_cmd_desc *ucdl_base_addr;struct utp_transfer_req_desc *utrdl_base_addr;
    struct utp_task_req_desc *utmrdl_base_addr;struct utp_devman_cmd_desc *devman_ucd_base_addr;
    dma_addr_t ucdl_dma_addr,utrdl_dma_addr,utmrdl_dma_addr,devman_ucd_dma_addr;
    int nutrs,nutmrs,nr_hw_queues;unsigned nr_queues[HCTX_MAX_TYPES];struct ufs_hw_queue *uhq;
};
static struct ufs_hba hba;
static struct Scsi_Host scsi;
static struct device dev;
static struct ufs_hw_queue queues[2];
static struct allocation { void *ptr;size_t bytes;bool active,old,group; } allocations[32];
static int allocated,calls,fail_alloc,misalign,old_frees,mac,init_error,configured;
static bool seeding,group,fail_group,closed;
static struct utp_transfer_cmd_desc *old_ucdl;
static struct utp_transfer_req_desc *old_utrdl;
static size_t ufshcd_get_ucd_size(struct ufs_hba *h) { assert(h==&hba);return sizeof(struct utp_transfer_cmd_desc); }
static size_t ufshcd_get_devman_ucd_size(struct ufs_hba *h) { assert(h==&hba);return sizeof(struct utp_devman_cmd_desc); }
static void *dmam_alloc_coherent(struct device *d,size_t bytes,dma_addr_t *dma,int flags) {
    assert(d==&dev&&!flags&&bytes&&allocated<32);
    if(!seeding&&++calls==fail_alloc)return NULL;
    void *p=NULL;assert(!posix_memalign(&p,1024,bytes));memset(p,seeding?0xa5:0,bytes);
    allocations[allocated++]=(struct allocation){p,bytes,true,seeding,group};
    *dma=(uintptr_t)p+(!seeding&&calls==misalign?1:0);return p;
}
static void dmam_free_coherent(struct device *d,size_t bytes,void *p,dma_addr_t dma) {
    assert(d==&dev&&dma==(uintptr_t)p);
    for(int i=0;i<allocated;i++)if(allocations[i].ptr==p&&allocations[i].active) {
        assert(allocations[i].bytes==bytes);if(allocations[i].old)old_frees++;
        free(p);allocations[i].active=false;return;
    }
    assert(!"double or unknown DMA free");
}
static void *devres_open_group(struct device *d,void *id,int flags) {
    assert(d==&dev&&!id&&!flags&&!group);if(fail_group)return NULL;group=true;return &group;
}
static void devres_close_group(struct device *d,void *id) { assert(d==&dev&&id==&group&&group);closed=true; }
static void devres_remove_group(struct device *d,void *id) {
    assert(d==&dev&&id==&group&&group&&closed);group=false;
    for(int i=0;i<allocated;i++)allocations[i].group=false;
}
static void devres_release_group(struct device *d,void *id) {
    assert(d==&dev&&id==&group&&group);group=false;
    for(int i=0;i<allocated;i++)if(allocations[i].active&&allocations[i].group) {
        assert(!allocations[i].old);free(allocations[i].ptr);allocations[i].active=false;
    }
}
static int ufshcd_get_hba_mac(struct ufs_hba *h) { assert(h==&hba);return mac; }
static int ufshcd_mcq_init(struct ufs_hba *h) {
    assert(h==&hba);h->nr_hw_queues=2;scsi.nr_hw_queues=2;
    h->nr_queues[HCTX_TYPE_DEFAULT]=1;h->nr_queues[HCTX_TYPE_POLL]=1;
    for(int i=0;i<2;i++)queues[i].max_entries=64;
    return init_error;
}
static void ufshcd_host_memory_configure(struct ufs_hba *h) {
    assert(h==&hba);configured++;memset(h->utrdl_base_addr,0x5a,sizeof(struct utp_transfer_req_desc)*h->nutrs);
}
C
for function in ufshcd_memory_alloc; do
    awk -v name="$function" '$0 ~ "^static int " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/ufs/core/ufshcd.c" >> "$work/test.c"
done
awk '/^int ufshcd_mcq_memory_alloc\(/ {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/ufs/core/ufs-mcq.c" >> "$work/test.c"
for function in ufshcd_release_sdb_queue ufshcd_alloc_mcq; do
    awk -v name="$function" '$0 ~ "^static (void|int) " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' "$kernel/drivers/ufs/core/ufshcd.c" >> "$work/test.c"
done
cat >> "$work/test.c" <<'C'
static void reset(void) {
    for(int i=0;i<allocated;i++)if(allocations[i].active)free(allocations[i].ptr);
    allocated=calls=fail_alloc=misalign=old_frees=init_error=configured=0;
    group=fail_group=closed=false;mac=64;
    memset(&hba,0,sizeof hba);memset(&scsi,0,sizeof scsi);memset(queues,0,sizeof queues);
    hba.dev=&dev;hba.host=&scsi;hba.nutrs=32;hba.nutmrs=1;hba.nr_hw_queues=1;
    hba.nr_queues[HCTX_TYPE_DEFAULT]=1;hba.uhq=queues;scsi.nr_hw_queues=1;scsi.can_queue=31;
    seeding=true;
    hba.ucdl_base_addr=dmam_alloc_coherent(&dev,128*31,&hba.ucdl_dma_addr,0);
    hba.utrdl_base_addr=dmam_alloc_coherent(&dev,32*32,&hba.utrdl_dma_addr,0);
    hba.utmrdl_base_addr=dmam_alloc_coherent(&dev,32,&hba.utmrdl_dma_addr,0);
    hba.devman_ucd_base_addr=dmam_alloc_coherent(&dev,128,&hba.devman_ucd_dma_addr,0);
    seeding=false;old_ucdl=hba.ucdl_base_addr;old_utrdl=hba.utrdl_base_addr;
}
static void restored(void) {
    assert(!old_frees&&!group&&hba.nutrs==32&&scsi.can_queue==31);
    assert(hba.ucdl_base_addr==old_ucdl&&hba.utrdl_base_addr==old_utrdl);
    assert(hba.ucdl_dma_addr==(uintptr_t)old_ucdl&&hba.utrdl_dma_addr==(uintptr_t)old_utrdl);
    assert(hba.nr_hw_queues==1&&scsi.nr_hw_queues==1&&hba.nr_queues[HCTX_TYPE_DEFAULT]==1&&!hba.nr_queues[HCTX_TYPE_POLL]);
    for(int i=0;i<allocated;i++)assert(allocations[i].active==allocations[i].old);
    for(int i=0;i<2;i++)assert(!queues[i].sqe_base_addr&&!queues[i].cqe_base_addr&&!queues[i].sqe_dma_addr&&!queues[i].cqe_dma_addr);
    for(unsigned i=0;i<128*31;i++)assert(((unsigned char *)old_ucdl)[i]==0xa5);
    for(unsigned i=0;i<32*32;i++)assert(((unsigned char *)old_utrdl)[i]==0xa5);
}
int main(void) {
    for(int i=1;i<=6;i++) { reset();fail_alloc=i;assert(ufshcd_alloc_mcq(&hba)==-ENOMEM);restored(); }
    for(int i=1;i<=2;i++) { reset();misalign=i;assert(ufshcd_alloc_mcq(&hba)==-ENOMEM);restored(); }
    reset();fail_group=true;assert(ufshcd_alloc_mcq(&hba)==-ENOMEM);restored();
    reset();init_error=-ENODEV;assert(ufshcd_alloc_mcq(&hba)==-ENODEV);restored();
    reset();mac=-EIO;assert(ufshcd_alloc_mcq(&hba)==-EIO);restored();
    for(int i=1;i<=4;i++) { reset();mac=32;fail_alloc=i;assert(ufshcd_alloc_mcq(&hba)==-ENOMEM);restored(); }
    reset();assert(!ufshcd_alloc_mcq(&hba));
    assert(hba.nutrs==64&&scsi.can_queue==63&&old_frees==2&&configured==1&&!group);
    assert(hba.ucdl_base_addr!=old_ucdl&&hba.utrdl_base_addr!=old_utrdl);
    for(int i=0;i<2;i++)assert(queues[i].sqe_base_addr&&queues[i].cqe_base_addr);
    reset();mac=32;assert(!ufshcd_alloc_mcq(&hba));
    assert(hba.nutrs==32&&scsi.can_queue==31&&!old_frees&&!configured&&!group);
    assert(hba.ucdl_base_addr==old_ucdl&&hba.utrdl_base_addr==old_utrdl);
    reset();for(int i=0;i<allocated;i++)if(allocations[i].active)free(allocations[i].ptr);
    puts("Actual MCQ/SDB DMA allocation transaction: 15 error paths, old-buffer/queue restoration and 32/64-tag success passed; host only");
}
C
${CC:-clang} -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function -fsanitize=address,undefined "$work/test.c" -o "$work/test"
ASAN_OPTIONS=detect_leaks=1 "$work/test"
