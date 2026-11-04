#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host/COPR fixture only. No target device or MMIO access.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
kernel=$(realpath "${2:?Pass the prepared kernel for the actual shared register helpers}")
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
mkdir -p "$scratch/linux" "$scratch/drm"
cat > "$scratch/linux/types.h" <<'EOF'
#ifndef TEST_LINUX_TYPES_H
#define TEST_LINUX_TYPES_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t u32;
typedef uint64_t u64;
typedef uint8_t u8;
#define __iomem
#define BIT(n) (1U << (n))
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x,v) ((x)=(v))
#define GENMASK(h, l) ((~0U >> (31 - (h))) & (~0U << (l)))
#endif
EOF
cat > "$scratch/linux/mutex.h" <<'EOF'
#ifndef TEST_LINUX_MUTEX_H
#define TEST_LINUX_MUTEX_H
#include <assert.h>
struct mutex { int locked; };
static inline void mutex_init(struct mutex *m) { m->locked = 0; }
static inline void mutex_lock(struct mutex *m) { assert(!m->locked); m->locked = 1; }
static inline void mutex_unlock(struct mutex *m) { assert(m->locked); m->locked = 0; }
#define lockdep_assert_held(m) assert((m)->locked)
#endif
EOF
cat > "$scratch/linux/err.h" <<'EOF'
#include "types.h"
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((intptr_t)(p))
EOF
cat > "$scratch/drm/drm_gpuvm.h" <<'EOF'
#ifndef TEST_GPUVM_H
#define TEST_GPUVM_H
#include "linux/types.h"
struct drm_gpuvm { unsigned int references; struct drm_device *drm; bool managed; struct msm_mmu *mmu; };
struct drm_gpuvm *drm_gpuvm_get(struct drm_gpuvm *vm);
void drm_gpuvm_put(struct drm_gpuvm *vm);
bool drm_gpuvm_range_valid(struct drm_gpuvm *vm, u64 address, u64 bytes);
#endif
EOF
cat > "$scratch/msm_gem.h" <<'EOF'
#ifndef TEST_MSM_GEM_H
#define TEST_MSM_GEM_H
#include "linux/types.h"
#include "drm/drm_gpuvm.h"
struct drm_device { unsigned int token; };
struct drm_gem_object { struct drm_device *dev; };
#define MSM_BO_WC 4
#define to_msm_vm(vm) (vm)
struct msm_mmu;
struct msm_mmu_funcs { void (*detach)(struct msm_mmu *); };
struct msm_mmu { const struct msm_mmu_funcs *funcs; };
void *msm_gem_kernel_new(struct drm_device *dev, size_t bytes, u32 flags,
    struct drm_gpuvm *vm, struct drm_gem_object **bo, u64 *iova);
void msm_gem_kernel_put(struct drm_gem_object *bo, struct drm_gpuvm *vm);
#endif
EOF
cat > "$scratch/linux/array_size.h" <<'EOF'
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
EOF
cat > "$scratch/linux/platform_device.h" <<'EOF'
#ifndef TEST_PLATFORM_H
#define TEST_PLATFORM_H
struct device { unsigned int token; };
struct platform_device { struct device dev; };
#endif
EOF
cat > "$scratch/linux/pm_runtime.h" <<'EOF'
#include "platform_device.h"
int pm_runtime_resume_and_get(struct device *dev);
int pm_runtime_put_sync(struct device *dev);
void pm_runtime_get_noresume(struct device *dev);
EOF
cat > "$scratch/dpu_hw_top.h" <<'EOF'
#ifndef TEST_TOP_H
#define TEST_TOP_H
#include "linux/types.h"
#define DPU_CLK_CTRL_REG_DMA 1
struct dpu_hw_blk_reg_map { void *blk_addr; };
struct dpu_clk_ctrl_reg { u32 reg_off,bit_off; };
struct dpu_mdp_cfg { struct dpu_clk_ctrl_reg clk_ctrls[2]; };
struct dpu_hw_mdp {
    struct dpu_hw_blk_reg_map hw;
    const struct dpu_mdp_cfg *caps;
    struct { bool (*setup_clk_force_ctrl)(struct dpu_hw_mdp *,unsigned int,bool); } ops;
};
#endif
EOF
cat > "$scratch/dpu_hw_vbif.h" <<'EOF'
#ifndef TEST_VBIF_H
#define TEST_VBIF_H
#include "dpu_hw_top.h"
struct dpu_vbif_cfg { u32 qos_rp_remap_size, xin_halt_timeout; };
struct dpu_hw_vbif {
    struct dpu_hw_blk_reg_map hw;
    const struct dpu_vbif_cfg *cap;
    struct {
        bool (*set_qos_remap)(struct dpu_hw_vbif *,u32,u32,u32);
        void (*set_halt_ctrl)(struct dpu_hw_vbif *,u32,bool);
    } ops;
};
#endif
EOF
cat > "$scratch/dpu_hw_catalog.h" <<'EOF'
#ifndef TEST_CATALOG_H
#define TEST_CATALOG_H
#include "linux/types.h"
enum { DSPP_0 = 1, DSPP_1, DSPP_2 };
struct dpu_dspp_cfg { u32 id,base,len; };
struct dpu_mdss_cfg { u32 dspp_count; const struct dpu_dspp_cfg *dspp; };
#endif
EOF
cat > "$scratch/dpu_kms.h" <<'EOF'
#ifndef TEST_KMS_H
#define TEST_KMS_H
#include "msm_gem.h"
#include "linux/platform_device.h"
#include "dpu_hw_top.h"
#include "dpu_hw_vbif.h"
#include "dpu_hw_catalog.h"
struct dpu_kms {
    struct drm_device *dev;
    struct platform_device *pdev;
    struct { struct drm_gpuvm *vm; } base;
    struct dpu_o82_regdma *o82_regdma;
    struct dpu_hw_mdp *hw_mdp;
    struct dpu_hw_vbif *hw_vbif;
    void *mmio;
    const struct dpu_mdss_cfg *catalog;
};
#endif
EOF
{
    printf '%s\n' 'static int dpu_hw_clock_lock, dpu_vbif_qos_lock, dpu_vbif_halt_lock;' \
        '#define spin_lock_irqsave(p,f) do { assert(!*(p)); *(p)=1; (f)=0; } while(0)' \
        '#define spin_unlock_irqrestore(p,f) do { assert(*(p)&&(f)==0); *(p)=0; } while(0)' \
        '#define DPU_REG_READ(c,off) readl((c)->blk_addr+(off))' \
        '#define DPU_REG_WRITE(c,off,value) writel((value),(c)->blk_addr+(off))'
    sed -n '/^bool dpu_hw_clk_force_ctrl(/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_util.c"
    grep -E '^#define VBIF_XINL_QOS_(RP|LVL)_REMAP_000' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_vbif.c"
    sed -n '/^static bool dpu_hw_set_qos_remap(/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_vbif.c"
    grep -E '^#define VBIF_XIN_HALT_CTRL[01]' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_vbif.c"
    sed -n '/^static void dpu_hw_set_halt_ctrl(/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_hw_vbif.c"
    sed -n '/^int dpu_o82_platform_suspend(/,/^}/p' "$root/src/display/dpu_o82_platform.c"
    printf '%s\n' 'static void msleep(unsigned int milliseconds);' \
        'static void dpu_o82_color_fini(struct dpu_kms *kms);' \
        'static void test_drain_error(struct device *dev, int error);' \
        '#define dev_err_once(dev,fmt,error) test_drain_error(dev,error)'
    sed -n '/^void dpu_o82_platform_fini(/,/^}/p' "$root/src/display/dpu_o82_platform.c"
    sed -n '/^static void _dpu_kms_mmu_destroy(.*)$/,/^}/p' \
        "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c"
    cat "$kernel/o82-mmu-destroy-before.h"
} > "$scratch/shared-helpers.h"
grep -q '^bool dpu_hw_clk_force_ctrl(' "$scratch/shared-helpers.h"
grep -q '^static bool dpu_hw_set_qos_remap(' "$scratch/shared-helpers.h"
grep -q '^static void _dpu_kms_mmu_destroy_before(' "$scratch/shared-helpers.h"
cat > "$scratch/linux/io.h" <<'EOF'
#include "types.h"
u32 readl(const volatile void *address);
void writel(u32 value, volatile void *address);
void test_wmb(void);
#define wmb() test_wmb()
EOF
cat > "$scratch/linux/dma-mapping.h" <<'EOF'
void test_dma_wmb(void);
#define dma_wmb() test_dma_wmb()
EOF
cat > "$scratch/linux/errno.h" <<'EOF'
#include <asm-generic/errno.h>
EOF
cat > "$scratch/linux/iopoll.h" <<'EOF'
#define readl_poll_timeout(address, value, condition, delay, timeout) ({ \
    unsigned int test_remaining = (timeout) / (delay) + 1; \
    int test_ret = -ETIMEDOUT; \
    do { value = readl(address); if (condition) { test_ret = 0; break; } \
    } while (--test_remaining); test_ret; })
EOF
cat > "$scratch/dpu_hw_ctl.h" <<'EOF'
#include "linux/types.h"
struct dpu_hw_ctl { unsigned int idx; struct { void *blk_addr; } hw; };
EOF
sources=("$root/src/display/dpu_o82_regdma.c" "$root/src/display/dpu_o82_upload.c"
    "$root/src/display/dpu_o82_power.c"
    "$root/src/display/dpu_o82_lutbus.c" "$root/tests/o82-regdma-transport-contract.c")
includes=(-I"$scratch" -I"$root/src/display")
gcc -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/contract"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/contract"
clang -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/sanitized"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/sanitized"
for binary in contract sanitized; do
    set +e
    (ulimit -c 0; O82_UNSAFE_DETACH=1 "$scratch/$binary") > "$scratch/negative.log" 2>&1
    status=$?
    set -e
    [[ $status == 134 ]]
    grep -Fx 'Expected negative control: MMU detach still owns REGDMA resources' "$scratch/negative.log"
done
printf '%s\n' 'Both compilers rejected the actual former MMU detach path at the ownership guard'
