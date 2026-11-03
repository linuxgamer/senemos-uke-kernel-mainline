#!/usr/bin/env bash
# Execute the candidate's actual stream admission and context setup on the host.
set -Eeuo pipefail
smmu=${1:?Pass the prepared arm-smmu directory}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/check.c" <<'C'
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
typedef uint32_t u32;
typedef uint32_t __be32;
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))
#define BIT(n) (1u << (n))
#define GENMASK(hi, lo) (((1u << ((hi) + 1)) - 1) & ~((1u << (lo)) - 1))
#define FIELD_GET(mask, value) ((value) & (mask))
#define ARM_SMMU_SMR_ID 0xffff
#define ARM_SMMU_DOMAIN_S1 1
#define ARM_SMMU_CB_ACTLR 4
#define dev_err_probe(dev, error, ...) (error)
struct iommu_fwspec { unsigned num_ids; u32 ids[2]; };
struct device { const char *of_node; struct iommu_fwspec *spec; };
struct arm_smmu_device { struct device *dev; unsigned long context_map[1]; unsigned num_context_banks; };
struct arm_smmu_domain {
    struct arm_smmu_device *smmu; unsigned stage;
    struct { unsigned cbndx; } cfg;
    struct { struct { unsigned long aperture_start; } geometry; } domain;
};
struct io_pgtable_cfg { unsigned ias; };
static bool machine, display, refuse;
static unsigned allocations, writes, fallbacks;
static u32 reg, rules[12];
static int rule_bytes;
static struct iommu_fwspec *dev_iommu_fwspec_get(struct device *dev) { return dev->spec; }
static bool of_machine_is_compatible(const char *name) { assert(!strcmp(name,"xiaomi,uke")); return machine; }
static bool of_device_is_compatible(const char *node, const char *name) { return !strcmp(node, name); }
static const void *of_get_property(const char *node, const char *name, int *size) {
    (void)node; assert(!strcmp(name,"qcom,actlr")); *size = rule_bytes;
    return rule_bytes ? rules : NULL;
}
static u32 be32_to_cpu(u32 value) { return __builtin_bswap32(value); }
static bool qcom_uke_display_domain(struct arm_smmu_device *s, struct device *d) {
    (void)s; (void)d; return display;
}
static bool qcom_uke_display_actlr_matches(struct arm_smmu_device *s) { (void)s; return true; }
static bool qcom_uke_sensor_cb(struct device *dev) { (void)dev; return false; }
static bool __attribute__((unused)) qcom_uke_hdmi_dma(struct device *dev) { (void)dev; return false; }
static int __arm_smmu_alloc_bitmap(unsigned long *map, int start, unsigned count) {
    assert(map && start == 2 && count == 16); ++allocations; return 3;
}
static int qcom_uke_display_init_context(struct arm_smmu_domain *d, struct io_pgtable_cfg *c,
                                         struct device *dev) {
    (void)d; (void)c; (void)dev; ++fallbacks; return 17;
}
static void arm_smmu_cb_write(struct arm_smmu_device *s, unsigned cb, unsigned off, u32 value) {
    (void)s; assert(cb == 3 && off == ARM_SMMU_CB_ACTLR && value == 0x103);
    ++writes; if (!refuse) reg = value;
}
static u32 arm_smmu_cb_read(struct arm_smmu_device *s, unsigned cb, unsigned off) {
    (void)s; assert(cb == 3 && off == ARM_SMMU_CB_ACTLR); return reg;
}
C
cat "$smmu/uke-video-smmu.c" >> "$work/check.c"
awk '/^static int qcom_uke_smmu_alloc_context_bank\(/ {emit=1} emit {print} emit && /^}/ {exit}' \
    "$smmu/arm-smmu-qcom.c" >> "$work/check.c"
cat >> "$work/check.c" <<'C'
static struct iommu_fwspec spec;
static struct device supplier, video;
static struct arm_smmu_device smmu;
static struct arm_smmu_domain domain;
static struct io_pgtable_cfg cfg;
static void set_rule(unsigned n, u32 id, u32 mask, u32 value) {
    rules[n * 3] = __builtin_bswap32(id);
    rules[n * 3 + 1] = __builtin_bswap32(mask);
    rules[n * 3 + 2] = __builtin_bswap32(value);
}
static void reset(void) {
    spec = (struct iommu_fwspec){2, {0x1940, 0x1947}};
    supplier = (struct device){"qcom,sm7675-boot-smmu", NULL};
    video = (struct device){"qcom,sm7675-iris", &spec};
    smmu = (struct arm_smmu_device){&supplier, {0}, 16};
    domain = (struct arm_smmu_domain){.smmu = &smmu, .stage = ARM_SMMU_DOMAIN_S1, .cfg = {3}};
    cfg.ias = 32; machine = true; display = refuse = false;
    allocations = writes = fallbacks = reg = 0; rule_bytes = 6 * sizeof(u32);
    set_rule(0, 0x1940, 0, 0x103); set_rule(1, 0x1947, 0, 0x103);
}
static int allocate(void) { return qcom_uke_smmu_alloc_context_bank(&domain, &smmu, &video, 2); }
int main(void) {
    reset(); assert(allocate() == 3 && allocations == 1 && !writes);
    assert(qcom_uke_init_context(&domain, &cfg, &video) == 0 && writes == 1 && !fallbacks);
    assert(domain.domain.geometry.aperture_start == 0x25800000);
    reset(); spec.ids[0] = 0x1947; spec.ids[1] = 0x1940; assert(allocate() == 3);
    reset(); rule_bytes = 11; assert(allocate() == -EINVAL && !allocations);
    reset(); rule_bytes = 3 * sizeof(u32); assert(allocate() == -EINVAL);
    reset(); set_rule(1, 0x1947, 0, 0x101); assert(allocate() == -EINVAL);
    reset(); set_rule(2, 0x1940, 7, 0x103); rule_bytes = 9 * sizeof(u32);
    assert(allocate() == -EINVAL);
    const u32 invalid[] = {0x1941, 0x1943, 0x1944, 0x11940, 0x40};
    for (unsigned i = 0; i < ARRAY_SIZE(invalid); ++i) {
        reset(); spec.ids[0] = invalid[i]; assert(allocate() == -EOPNOTSUPP && !allocations);
    }
    reset(); spec.num_ids = 1; assert(allocate() == -EOPNOTSUPP);
    reset(); video.of_node = "qcom,sm8650-iris"; assert(allocate() == -EOPNOTSUPP);
    reset(); machine = false; assert(allocate() == -EOPNOTSUPP);
    reset(); supplier.of_node = "qcom,sm7675-usb-smmu"; assert(allocate() == -EOPNOTSUPP);
    reset(); domain.stage = 2;
    assert(qcom_uke_init_context(&domain, &cfg, &video) == -EOPNOTSUPP && !writes);
    reset(); cfg.ias = 31;
    assert(qcom_uke_init_context(&domain, &cfg, &video) == -EOPNOTSUPP && !writes);
    reset(); refuse = true;
    assert(qcom_uke_init_context(&domain, &cfg, &video) == -EACCES && writes == 1);
    assert(!domain.domain.geometry.aperture_start);
    reset(); spec.num_ids = 1; spec.ids[0] = 0x40; video.of_node = "usb";
    assert(allocate() == 3);
    assert(qcom_uke_init_context(&domain, &cfg, &video) == 17 && fallbacks == 1 && !writes);
}
C
"${CC:-gcc}" -std=gnu11 -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare \
    "$work/check.c" -o "$work/check"
"$work/check"
printf 'Actual Uke video SMMU: exact streams/ACTLR, DMA aperture, refusals and legacy delegation passed\n'
