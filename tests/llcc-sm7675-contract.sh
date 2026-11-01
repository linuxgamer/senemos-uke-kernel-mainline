#!/usr/bin/env bash
# Actual LLCC probe/configuration with host-only MMIO, allocator and slice calls.
set -Eeuo pipefail
kernel=${1:?Pass prepared Linux source}
source_file=$kernel/drivers/soc/qcom/llcc-qcom.c
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef uint32_t u32;
typedef uint8_t u8;
#define EPROBE_DEFER 517
#define BIT(n) (UINT32_C(1) << (n))
#define GENMASK(h,l) ((UINT32_MAX >> (31-(h))) & (UINT32_MAX << (l)))
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define SZ_1K 1024U
#define SZ_2M 2097152U
#define SZ_4K 4096U
#define SZ_8 8U
#define SZ_4 4U
#define __free(x)
#define GFP_KERNEL 0
#define IORESOURCE_MEM 1
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define IS_ERR_OR_NULL(p) (!(p) || IS_ERR(p))
#define ERR_PTR(e) ((void *)(intptr_t)(e))
#define PTR_ERR(p) ((int)(intptr_t)(p))
#define ERR_CAST(p) ((void *)(p))
#define dev_err(...) ((void)0)
#define dev_err_probe(d,e,...) (e)
#define mutex_init(p) ((void)(p))
struct resource { uint64_t start, end; };
struct device { bool *of_node; };
struct platform_device { struct device dev; };
struct regmap { int index; u32 values[0x22000/4]; };
struct llcc_slice_desc { u32 slice_id, uid; size_t slice_size; };
C
awk '/^#define LLCC_/ {print}' "$kernel/include/linux/soc/qcom/llcc-qcom.h" >> "$work/check.c"
awk '/^#define (ATTR|CACHE_LINE|MAX_CAP|LLCC_TRP_|LLCC_LB_|LLCC_VERSION_)/ {print}' "$source_file" >> "$work/check.c"
awk '/^struct (llcc_slice_config|qcom_llcc_config|qcom_sct_config) \{/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.c"
awk '/^enum llcc_reg_offset/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.c"
awk '/^static const (u32 llcc_v2_1_reg_offset|struct llcc_slice_config sm7675_data|struct qcom_llcc_config sm7675_cfg|struct qcom_sct_config sm7675_cfgs)/ {emit=1} emit {print} emit && /^};/ {emit=0}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
struct llcc_drv_data {
    u32 num_banks, version, cfg_size;
    struct regmap **regmaps, *bcast_regmap, *bcast_and_regmap;
    const struct llcc_slice_config *cfg;
    struct llcc_slice_desc *desc;
    const struct llcc_edac_reg_offset *edac_reg_offset;
    int lock, ecc_irq; bool ecc_irq_configured;
    struct device *dev;
};
static struct llcc_drv_data *drv_data;
static struct resource resources[6];
static struct regmap maps[6];
static void *allocations[16];
static unsigned int allocation_count, alloc_calls, alloc_fault, map_calls, map_fault;
static unsigned int read_calls, read_fault, write_calls, write_fault, activated, activation_fault, edac_calls;
static int missing, extra, cfg_fault, map_error;
static u32 hardware_banks, hardware_version;
static bool sm7675;
static struct resource *platform_get_resource(struct platform_device *p, int type, int index) {
    (void)p; assert(type == IORESOURCE_MEM);
    return index == missing || index >= 5 + extra ? NULL : &resources[index];
}
static uint64_t resource_size(struct resource *r) { return r->end-r->start+1; }
static bool of_device_is_compatible(bool *node, const char *name) {
    assert(!strcmp(name,"qcom,sm7675-llcc")); return *node;
}
static void *devm_kcalloc(struct device *d, size_t n, size_t size, int flags) {
    (void)d; (void)flags; if (++alloc_calls == alloc_fault) return NULL;
    assert(allocation_count < ARRAY_SIZE(allocations));
    void *p=calloc(n,size); assert(p); allocations[allocation_count++]=p; return p;
}
static void *devm_kzalloc(struct device *d, size_t size, int f) { return devm_kcalloc(d,1,size,f); }
static char *kasprintf(int flags, const char *format, int i) {
    char *p=devm_kcalloc(NULL,1,32,flags); if (p) snprintf(p,32,format,i); return p;
}
static const struct qcom_sct_config *of_device_get_match_data(struct device *d) { (void)d; return &sm7675_cfgs; }
static int qcom_llcc_get_cfg_index(struct platform_device *p, u8 *index, int count) {
    (void)p; assert(count == 1); *index=0; return cfg_fault;
}
static struct regmap *qcom_llcc_init_mmio(struct platform_device *p, u8 index, const char *name) {
    (void)p; (void)name; map_calls++;
    if (map_calls == map_fault) return ERR_PTR(map_error);
    return index < 5 + extra ? &maps[index] : ERR_PTR(-EINVAL);
}
static int regmap_read(struct regmap *map, u32 reg, u32 *value) {
    if (++read_calls == read_fault) return -EREMOTEIO;
    if (map->index == 0 && reg == 0x3400c) *value=hardware_banks << 28;
    else { assert(map->index == 4 && reg == 0x34000); *value=hardware_version; }
    return 0;
}
static int regmap_write(struct regmap *map, u32 reg, u32 value) {
    assert(map->index == 4 && reg < 0x22000 && !(reg&3));
    if (++write_calls == write_fault) return -EREMOTEIO;
    map->values[reg/4]=value; return 0;
}
static int regmap_update_bits(struct regmap *map, u32 reg, u32 mask, u32 value) {
    return regmap_write(map,reg,(map->values[reg/4]&~mask)|(value&mask));
}
static int llcc_slice_activate(struct llcc_slice_desc *d) {
    if (IS_ERR_OR_NULL(d)) return -EINVAL;
    activated++; return activated == activation_fault ? -ETIMEDOUT : 0;
}
static int _qcom_llcc_cfg_program_v6(const struct llcc_slice_config *c, const struct qcom_llcc_config *cfg) {
    (void)c; (void)cfg; assert(false); return -EINVAL;
}
static int qcom_llcc_get_fw_config(struct platform_device *p) { (void)p; assert(false); return -EINVAL; }
static int platform_get_irq_optional(struct platform_device *p, int i) { (void)p; assert(i==0); return -ENXIO; }
static struct platform_device *platform_device_register_data(struct device *d, const char *name, int id, void *data, size_t size) {
    (void)d; (void)name; (void)id; (void)data; (void)size; edac_calls++; return NULL;
}
static void platform_set_drvdata(struct platform_device *p, void *data) { (void)p; assert(data==drv_data); }
C
awk '/^(static )?(struct llcc_slice_desc \*|int )(llcc_slice_getd|llcc_get_slice_id|_qcom_llcc_cfg_program|qcom_llcc_cfg_program|qcom_llcc_sm7675_resources|qcom_llcc_probe)\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' "$source_file" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
#define FIELD_PREP(mask,value) (((u32)(value) << __builtin_ctz(mask)) & (mask))
enum { REG_A6XX_GBIF_SCACHE_CNTL0, REG_A6XX_GBIF_SCACHE_CNTL1 };
struct msm_gpu { u32 values[2]; unsigned int writes; };
struct adreno_gpu { struct msm_gpu base; };
struct a6xx_gpu { struct adreno_gpu base; struct llcc_slice_desc *llc_slice, *htw_llc_slice; };
static void gpu_write(struct msm_gpu *g, unsigned int reg, u32 value) { assert(reg<2); g->values[reg]=value; g->writes++; }
C
awk '/^static void a7xx_llc_activate\(/ {emit=1} emit {print} emit && /^}/ {emit=0}' \
    "$kernel/drivers/gpu/drm/msm/adreno/a6xx_gpu.c" >> "$work/check.c"
cat "$here/fixtures/llcc-sm7675-policy.inc" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static void reset(void) {
    for (unsigned int i=0;i<allocation_count;i++) free(allocations[i]);
    allocation_count=alloc_calls=alloc_fault=map_calls=map_fault=0;
    read_calls=read_fault=write_calls=write_fault=activated=activation_fault=edac_calls=0;
    missing=-1; extra=cfg_fault=0; hardware_banks=4; hardware_version=0x05000000; sm7675=true;
    map_error=-ENOMEM;
    drv_data=ERR_PTR(-EPROBE_DEFER);
    memset(maps,0,sizeof(maps));
    for (int i=0;i<6;i++) resources[i]=(struct resource){0x25000000U+i*(uint64_t)SZ_2M,0x251fffffU+i*(uint64_t)SZ_2M};
    for (int i=0;i<6;i++) maps[i].index=i;
}
#define CHECK_FIELD(n) assert(sm7675_data[i].n == expected_policy[i].n)
int main(void) {
    struct platform_device p={{&sm7675}};
    assert(ARRAY_SIZE(sm7675_data)==17 && ARRAY_SIZE(sm7675_data)==ARRAY_SIZE(expected_policy));
    for (unsigned int i=0;i<ARRAY_SIZE(sm7675_data);i++) {
        CHECK_FIELD(usecase_id); CHECK_FIELD(slice_id); CHECK_FIELD(max_cap); CHECK_FIELD(priority);
        CHECK_FIELD(fixed_size); CHECK_FIELD(bonus_ways); CHECK_FIELD(res_ways); CHECK_FIELD(cache_mode);
        CHECK_FIELD(probe_target_ways); CHECK_FIELD(dis_cap_alloc); CHECK_FIELD(retain_on_pc); CHECK_FIELD(activate_on_init);
        CHECK_FIELD(write_scid_en); CHECK_FIELD(write_scid_cacheable_en); CHECK_FIELD(stale_en); CHECK_FIELD(stale_cap_en);
        CHECK_FIELD(mru_uncap_en); CHECK_FIELD(mru_rollover); CHECK_FIELD(alloc_oneway_en); CHECK_FIELD(ovcap_en);
        CHECK_FIELD(ovcap_prio); CHECK_FIELD(vict_prio); CHECK_FIELD(parent_slice_id);
    }
    for (int i=0;i<5;i++) {
        reset(); missing=i; assert(qcom_llcc_probe(&p)==-EINVAL && !map_calls && !alloc_calls && !write_calls);
        reset(); resources[i].start+=4; resources[i].end+=4;
        assert(qcom_llcc_probe(&p)==-EINVAL && !map_calls && !write_calls);
        reset(); resources[i].end-=4; assert(qcom_llcc_probe(&p)==-EINVAL && !map_calls && !write_calls);
        reset(); resources[i].end+=4; assert(qcom_llcc_probe(&p)==-EINVAL && !map_calls && !write_calls);
    }
    reset(); extra=1; assert(qcom_llcc_probe(&p)==-EINVAL && !map_calls && !write_calls);
    for (u32 banks=0;banks<16;banks++) if(banks!=4) {
        reset(); hardware_banks=banks; assert(qcom_llcc_probe(&p)==-EINVAL && map_calls==1 && !write_calls);
    }
    const u32 bad_versions[]={0,0x04010000,0x04ffffff,0x06000000,UINT32_MAX};
    for (unsigned int i=0;i<ARRAY_SIZE(bad_versions);i++) {
        reset(); hardware_version=bad_versions[i]; assert(qcom_llcc_probe(&p)==-ENODEV && !write_calls);
    }
    for (unsigned int i=1;i<=2;i++) {
        reset(); read_fault=i; assert(qcom_llcc_probe(&p)==-EREMOTEIO && !write_calls);
    }
    for (unsigned int i=1;i<=5;i++) {
        reset(); map_fault=i; assert(qcom_llcc_probe(&p)==-ENOMEM && !write_calls);
    }
    /* Allocations 3..5 are the kernel's temporary bank-name strings. */
    const unsigned int allocation_faults[]={1,2,6};
    for(unsigned int i=0;i<ARRAY_SIZE(allocation_faults);i++) {
        reset(); alloc_fault=allocation_faults[i]; assert(qcom_llcc_probe(&p)==-ENOMEM && !write_calls);
    }
    for (unsigned int i=3;i<=5;i++) {
        reset(); alloc_fault=i; assert(qcom_llcc_probe(&p)==0); /* Optional regmap display names. */
    }
    reset(); cfg_fault=-EPROBE_DEFER; assert(qcom_llcc_probe(&p)==-EPROBE_DEFER && !write_calls);
    reset(); assert(qcom_llcc_probe(&p)==0 && activated==4 && !edac_calls && drv_data->num_banks==4);
    assert(llcc_slice_getd(LLCC_GPU)->slice_id==9 && llcc_slice_getd(LLCC_GPU)->slice_size==3200);
    assert(llcc_slice_getd(LLCC_GPUHTW)->slice_id==11 && llcc_slice_getd(LLCC_GPUHTW)->slice_size==256);
    assert(maps[4].values[LLCC_TRP_ATTR1_CFGn(9)/4] == ((3200*1024/4/64)<<16 | 1<<4));
    assert(maps[4].values[LLCC_TRP_ATTR0_CFGn(12)/4]==0xff);
    assert(maps[4].values[LLCC_TRP_ATTR2_CFGn(12)/4]==0);
    unsigned int successful_writes=write_calls; assert(successful_writes==238);
    struct a6xx_gpu gpu={.llc_slice=llcc_slice_getd(LLCC_GPU),.htw_llc_slice=llcc_slice_getd(LLCC_GPUHTW)};
    a7xx_llc_activate(&gpu); assert(gpu.base.base.writes==2 && activated==6);
    for (unsigned int shift=0;shift<30;shift+=5) assert(((gpu.base.base.values[1]>>shift)&31)==9);
    assert(gpu.base.base.values[0]==((9<<10)|BIT(8)));
    gpu.base.base=(struct msm_gpu){0}; activation_fault=activated+1;
    a7xx_llc_activate(&gpu); assert(!gpu.base.base.writes);
    gpu.llc_slice=ERR_PTR(-ENODEV); gpu.htw_llc_slice=ERR_PTR(-ENODEV);
    a7xx_llc_activate(&gpu); assert(!gpu.base.base.writes);
    for (unsigned int i=1;i<=successful_writes;i++) {
        reset(); write_fault=i; assert(qcom_llcc_probe(&p)==-EREMOTEIO && write_calls==i && IS_ERR(drv_data));
    }
    for (unsigned int i=1;i<=4;i++) {
        reset(); activation_fault=i; assert(qcom_llcc_probe(&p)==-ETIMEDOUT && activated==i && IS_ERR(drv_data));
    }
    reset(); hardware_version=0x0501ffff; assert(qcom_llcc_probe(&p)==0);
    reset();
    const u32 policy_registers[]={LLCC_TRP_SCID_DIS_CAP_ALLOC,LLCC_TRP_WRSC_EN,LLCC_TRP_WRSC_CACHEABLE_EN,
        LLCC_TRP_ALGO_CFG1,LLCC_TRP_ALGO_CFG2,LLCC_TRP_ALGO_CFG3,LLCC_TRP_ALGO_CFG4,LLCC_TRP_ALGO_CFG5,
        LLCC_TRP_ALGO_CFG6,LLCC_TRP_ALGO_CFG7,LLCC_TRP_ALGO_CFG8};
    for (unsigned int i=0;i<ARRAY_SIZE(policy_registers);i++) maps[4].values[policy_registers[i]/4]=BIT(0);
    assert(qcom_llcc_probe(&p)==0);
    for (unsigned int i=0;i<ARRAY_SIZE(policy_registers);i++) assert(maps[4].values[policy_registers[i]/4]&BIT(0));
    reset(); sm7675=false; resources[0].start+=4; hardware_version=0x04010000;
    assert(qcom_llcc_probe(&p)==0); /* Existing platforms do not gain the Cliffs7 checks. */
    assert(map_calls==5 && !drv_data->bcast_and_regmap);
    reset(); assert(qcom_llcc_probe(&p)==0 && map_calls==5 && !drv_data->bcast_and_regmap);
    reset(); sm7675=false; extra=1;
    assert(qcom_llcc_probe(&p)==0 && map_calls==6 && drv_data->bcast_and_regmap==&maps[5]);
    const int optional_faults[]={-ENOMEM,-EIO,-EPROBE_DEFER};
    for(unsigned int i=0;i<ARRAY_SIZE(optional_faults);i++) {
        reset(); sm7675=false; extra=1; map_fault=6; map_error=optional_faults[i];
        assert(qcom_llcc_probe(&p)==optional_faults[i] && !write_calls);
    }
    reset(); sm7675=false; extra=1; map_fault=6; map_error=-EINVAL;
    assert(qcom_llcc_probe(&p)==0 && !drv_data->bcast_and_regmap); /* Retain legacy EINVAL fallback. */
    reset(); sm7675=false; extra=1; hardware_version=0x04000000;
    assert(qcom_llcc_probe(&p)==0 && map_calls==5 && !drv_data->bcast_and_regmap);
    reset(); puts("Actual LLCC probe/config and A7xx cache fields: 17 OEM slices, resources, banks/version, faults, unrelated SCID preservation and legacy guard scope passed");
}
C
# O0 avoids GCC alias-based false positives across the interposed regmap calls.
"${CC:-gcc}" -std=gnu11 -O0 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare -Wno-missing-field-initializers \
    ${LLCC_TEST_CFLAGS:-} "$work/check.c" -o "$work/check"
"$work/check"
