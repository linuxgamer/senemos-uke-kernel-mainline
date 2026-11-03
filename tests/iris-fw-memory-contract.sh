#!/usr/bin/env bash
# Compile the actual memory owner with host DMA/IOMMU fault injection.
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
#include <stdbool.h>
typedef uint32_t u32;
typedef uint64_t dma_addr_t;
typedef uint64_t phys_addr_t;
#define SZ_4K 4096
#define GFP_KERNEL 0
#define BIT(n) (1u << (n))
#define GENMASK(hi, lo) (((1u << ((hi) + 1)) - 1) & ~((1u << (lo)) - 1))
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define upper_32_bits(n) ((n) >> 32)
#define lower_32_bits(n) ((u32)(n))
#define IS_ALIGNED(n, a) (!((n) & ((a) - 1)))
#define IOMMU_READ 1
#define IOMMU_WRITE 2
#define IOMMU_MMIO 4
struct iommu_domain { struct { unsigned long aperture_start; } geometry; };
struct iris_fw_memory;
struct platform { uint64_t dma_mask; };
struct iris_core {
    void *dev;
    unsigned char *reg_base;
    const struct platform *iris_platform_data;
    struct iris_fw_memory *fw_memory;
};
static struct iommu_domain domain = {{0x25800000}};
static const uint32_t addresses[] = {0xffae0000, 0xffadf000, 0xffade000};
static const uint64_t physicals[] = {0x0aae0000, 0x00508000, 0x17421000};
static int allocation_fault, map_fault, unmap_fault, occupied;
static bool no_domain;
static unsigned allocs, frees, maps, unmaps, dma_allocs, dma_frees, writes, barriers, errors;
static bool active[3];
static unsigned char registers[0xf0000];
static dma_addr_t dma_address;
static void *kzalloc(size_t size, int flags) {
    assert(flags == GFP_KERNEL);
    ++allocs;
    return allocation_fault == 1 ? NULL : calloc(1, size);
}
static void kfree(void *ptr) { assert(ptr); ++frees; free(ptr); }
static struct iommu_domain *iommu_get_domain_for_dev(void *dev) {
    (void)dev; return no_domain ? NULL : &domain;
}
static int index_of(unsigned long iova) {
    for (int i = 0; i < 3; ++i) if (iova == addresses[i]) return i;
    assert(false); return -1;
}
static int iommu_map(struct iommu_domain *d, unsigned long iova, phys_addr_t pa,
                     size_t size, int flags, int gfp) {
    int i = index_of(iova);
    assert(d == &domain && pa == physicals[i] && size == SZ_4K);
    assert(flags == (IOMMU_READ | IOMMU_WRITE | IOMMU_MMIO) && gfp == GFP_KERNEL);
    ++maps;
    if (occupied == i + 1) return -EEXIST;
    if (map_fault == i + 1) return -EREMOTEIO;
    assert(!active[i]); active[i] = true; return 0;
}
static size_t iommu_unmap(struct iommu_domain *d, unsigned long iova, size_t size) {
    int i = index_of(iova);
    assert(d == &domain && size == SZ_4K && active[i]);
    ++unmaps;
    if (unmap_fault == i + 1) return 0;
    active[i] = false; return size;
}
static void *dma_alloc_coherent(void *dev, size_t size, dma_addr_t *address, int flags) {
    (void)dev; assert(size == SZ_4K && flags == GFP_KERNEL); ++dma_allocs;
    *address = dma_address;
    return allocation_fault == 2 ? NULL : malloc(size);
}
static void dma_free_coherent(void *dev, size_t size, void *ptr, dma_addr_t address) {
    (void)dev; assert(size == SZ_4K && ptr && address == dma_address);
    ++dma_frees; free(ptr);
}
#define dev_err(...) (++errors)
static void dma_wmb(void) { ++barriers; }
static void writel(u32 value, void *where) {
    uintptr_t offset = (unsigned char *)where - registers;
    const u32 offsets[] = {0xa0060, 0xa0024, 0xa0028};
    const u32 values[] = {(u32)dma_address, 0xffade000, 0x3000};
    assert(writes < 3 && barriers == 1);
    assert(offset == offsets[writes] && value == values[writes]);
    ++writes;
}
C
sed '/^\/\* Native PM references/,$d; /^#include /d' "$iris/iris_sm7675_memory.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct platform data = {.dma_mask = 0xdfffffff};
static struct iris_core core;
static void reset(void) {
    assert(!core.fw_memory);
    memset(active, 0, sizeof(active));
    allocation_fault = map_fault = unmap_fault = occupied = 0; no_domain = false;
    allocs = frees = maps = unmaps = dma_allocs = dma_frees = writes = barriers = errors = 0;
    data.dma_mask = 0xdfffffff; dma_address = 0x30000000;
    core = (struct iris_core){NULL, registers, &data, NULL};
}
static void clean(void) {
    assert(!core.fw_memory);
    for (unsigned i = 0; i < 3; ++i) assert(!active[i]);
}
int main(void) {
    reset();
    assert(iris_sm7675_program_bootup_registers(&core) == -EINVAL && !writes && !barriers);
    allocation_fault = 1;
    assert(iris_sm7675_fw_memory_init(&core) == -ENOMEM && !frees && !maps); clean();
    reset(); no_domain = true;
    assert(iris_sm7675_fw_memory_init(&core) == -ENODEV && frees == 1 && !maps); clean();
    reset(); data.dma_mask = 0xffffffff;
    assert(iris_sm7675_fw_memory_init(&core) == -EINVAL && !allocs); clean();
    for (int failure = 1; failure <= 3; ++failure) {
        reset(); map_fault = failure;
        assert(iris_sm7675_fw_memory_init(&core) == -EREMOTEIO);
        assert(maps == (unsigned)failure && unmaps == (unsigned)failure - 1);
        assert(frees == 1 && !dma_allocs); clean();
    }
    reset(); occupied = 2;
    assert(iris_sm7675_fw_memory_init(&core) == -EEXIST && unmaps == 1); clean();
    reset(); allocation_fault = 2;
    assert(iris_sm7675_fw_memory_init(&core) == -ENOMEM && unmaps == 3 && !dma_frees); clean();
    const dma_addr_t invalid[] = {0x100000000ULL, 0x30000001, 0xe0000000, 0x10000000};
    for (unsigned i = 0; i < ARRAY_SIZE(invalid); ++i) {
        reset(); dma_address = invalid[i];
        assert(iris_sm7675_fw_memory_init(&core) == -ERANGE && unmaps == 3 && dma_frees == 1);
        clean();
    }
    reset();
    assert(iris_sm7675_fw_memory_init(&core) == 0);
    u32 *payload = core.fw_memory->mmap;
    assert(payload[0] == 1);
    for (unsigned i = 0; i < 3; ++i) {
        assert(payload[sm7675_fw_regions[i].payload_index] == addresses[i]);
        assert(payload[sm7675_fw_regions[i].payload_index + 1] == SZ_4K);
    }
    assert(!payload[1] && !payload[13] && !payload[14] && !payload[1023]);
    assert(iris_sm7675_fw_memory_init(&core) == -EBUSY && allocs == 1 && maps == 3);
    assert(iris_sm7675_program_bootup_registers(&core) == 0 && writes == 3);
    core.fw_memory->power = 1;
    assert(iris_sm7675_fw_memory_deinit(&core) == -EBUSY && !unmaps && !dma_frees);
    core.fw_memory->power = 0; core.fw_memory->off_step = 1;
    assert(iris_sm7675_fw_memory_deinit(&core) == -EBUSY && !unmaps);
    core.fw_memory->off_step = 0; core.fw_memory->power_error = -EIO;
    assert(iris_sm7675_fw_memory_deinit(&core) == -EBUSY && !unmaps);
    core.fw_memory->power_error = 0;
    assert(iris_sm7675_fw_memory_deinit(&core) == 0 && dma_frees == 1 && frees == 1); clean();
    assert(iris_sm7675_fw_memory_deinit(&core) == 0 && unmaps == 3);
    reset(); map_fault = 3; unmap_fault = 1;
    assert(iris_sm7675_fw_memory_init(&core) == -EREMOTEIO && errors == 1);
    assert(core.fw_memory && core.fw_memory->mapped == 1 && !frees);
    assert(iris_sm7675_program_bootup_registers(&core) == -EINVAL && !writes);
    unmap_fault = 0;
    assert(iris_sm7675_fw_memory_deinit(&core) == 0); clean();
    reset(); assert(iris_sm7675_fw_memory_init(&core) == 0); unmap_fault = 2;
    assert(iris_sm7675_fw_memory_deinit(&core) == -EIO && errors == 1);
    assert(core.fw_memory && core.fw_memory->mapped == 2 && !dma_frees && !frees);
    unmap_fault = 0;
    assert(iris_sm7675_fw_memory_deinit(&core) == 0 && dma_frees == 1 && frees == 1); clean();
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual firmware memory owner: maps, payload, boot writes, failures and retained/retry cleanup passed\n'
