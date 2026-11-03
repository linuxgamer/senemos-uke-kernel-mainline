#!/usr/bin/env bash
# Run actual queue allocation/teardown with platform-hook and allocation faults.
set -Eeuo pipefail
iris=${1:?Pass the prepared Iris directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
typedef uint32_t u32;
#define SZ_4K 4096
#define GFP_KERNEL 0
#define DMA_ATTR_WRITE_COMBINE 1
#define IFACEQ_QUEUE_SIZE 4096
#define IFACEQ_NUMQ 3
#define IFACEQ_CMDQ_ID 0
#define IFACEQ_MSGQ_ID 1
#define IFACEQ_DBGQ_ID 2
#define SFR_SIZE SZ_4K
#define ALIGN(n, a) (((n) + (a) - 1) & ~((a) - 1))
#define dev_err(...) ((void)0)
struct iris_core;
struct vpu_ops { int (*fw_memory_init)(struct iris_core *); int (*fw_memory_deinit)(struct iris_core *); };
struct platform { const struct vpu_ops *vpu_ops; };
struct queue { unsigned value; };
struct iris_hfi_queue_header { unsigned value; };
struct iris_hfi_queue_table_header {
    u32 version; void *device_addr; char name[64];
    u32 size, qhdr0_offset, qhdr_size, num_q, num_active_q;
    struct iris_hfi_queue_header q_hdr[3];
};
struct iris_core {
    void *dev; const struct platform *iris_platform_data;
    void *iface_q_table_vaddr, *sfr_vaddr;
    uintptr_t iface_q_table_daddr, sfr_daddr;
    struct queue command_queue, message_queue, debug_queue;
};
static unsigned allocs, frees, queue_inits, queue_deinits, memory_inits, memory_deinits;
static int allocation_fault, memory_error, cleanup_error;
static void *live[2];
static void *dma_alloc_attrs(void *dev, size_t size, uintptr_t *dma, int gfp, int attrs) {
    (void)dev; assert(gfp == GFP_KERNEL && attrs == DMA_ATTR_WRITE_COMBINE);
    unsigned i = allocs++;
    assert(i < 2);
    if (allocation_fault == (int)i + 1) return NULL;
    live[i] = calloc(1, size); assert(live[i]); *dma = (uintptr_t)live[i]; return live[i];
}
static void dma_free_attrs(void *dev, size_t size, void *ptr, uintptr_t dma, int attrs) {
    (void)dev; assert(size && ptr && dma == (uintptr_t)ptr && attrs == DMA_ATTR_WRITE_COMBINE);
    assert(ptr == live[0] || ptr == live[1]);
    if (ptr == live[0]) live[0] = NULL; else live[1] = NULL;
    ++frees; free(ptr);
}
static void iris_hfi_queue_init(struct iris_core *c, unsigned id, struct queue *q) {
    (void)c; assert(q && id == queue_inits++);
}
static void iris_hfi_queue_deinit(struct queue *q) { assert(q); ++queue_deinits; }
static void strscpy(char *dst, const char *src, size_t size) {
    assert(strlen(src) < size); strcpy(dst, src);
}
static int memory_init(struct iris_core *c) { (void)c; ++memory_inits; return memory_error; }
static int memory_deinit(struct iris_core *c) {
    (void)c; assert(!frees); ++memory_deinits; return cleanup_error;
}
C
for function in iris_hfi_queues_init iris_hfi_queues_deinit; do
    awk -v name="$function" '$0 ~ "^int " name "\\(" {emit=1} emit {print} emit && /^}/ {exit}' \
        "$iris/iris_hfi_queue.c" >> "$work/check.c"
done
cat >> "$work/check.c" <<'C'
static struct vpu_ops ops = {memory_init, memory_deinit};
static struct platform data = {&ops};
static struct iris_core core;
static void reset(void) {
    assert(!live[0] && !live[1]);
    allocs = frees = queue_inits = queue_deinits = memory_inits = memory_deinits = 0;
    allocation_fault = memory_error = cleanup_error = 0;
    core = (struct iris_core){.iris_platform_data = &data};
}
int main(void) {
    reset(); allocation_fault = 1;
    assert(iris_hfi_queues_init(&core) == -ENOMEM && allocs == 1 && !frees && !memory_inits);
    reset(); allocation_fault = 2;
    assert(iris_hfi_queues_init(&core) == -ENOMEM && frees == 1 && !memory_inits);
    assert(!core.iface_q_table_vaddr && !core.iface_q_table_daddr);
    reset(); memory_error = -EREMOTEIO;
    assert(iris_hfi_queues_init(&core) == -EREMOTEIO && memory_inits == 1 && frees == 2);
    assert(!core.iface_q_table_vaddr && !core.sfr_vaddr && !queue_inits);
    reset(); assert(iris_hfi_queues_init(&core) == 0 && queue_inits == 3);
    assert(*(u32 *)core.sfr_vaddr == SFR_SIZE);
    cleanup_error = -EIO;
    assert(iris_hfi_queues_deinit(&core) == -EIO && !frees && !queue_deinits);
    assert(core.iface_q_table_vaddr && core.sfr_vaddr);
    cleanup_error = 0;
    assert(iris_hfi_queues_deinit(&core) == 0 && frees == 2 && queue_deinits == 3);
    assert(!core.iface_q_table_vaddr && !core.sfr_vaddr && !core.iface_q_table_daddr && !core.sfr_daddr);
    reset(); ops = (struct vpu_ops){0};
    assert(iris_hfi_queues_init(&core) == 0 && !memory_inits);
    assert(iris_hfi_queues_deinit(&core) == 0 && frees == 2 && !memory_deinits);
    assert(iris_hfi_queues_deinit(&core) == 0 && frees == 2);
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual HFI queue hooks: allocation faults, retained ownership, cleanup retry and legacy path passed\n'
