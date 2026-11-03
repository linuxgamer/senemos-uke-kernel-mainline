#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host/COPR fixture only. No target device or MMIO access.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
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
struct drm_gpuvm { unsigned int references; struct drm_device *drm; };
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
void *msm_gem_kernel_new(struct drm_device *dev, size_t bytes, u32 flags,
    struct drm_gpuvm *vm, struct drm_gem_object **bo, u64 *iova);
void msm_gem_kernel_put(struct drm_gem_object *bo, struct drm_gpuvm *vm);
#endif
EOF
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
    "$root/src/display/dpu_o82_lutbus.c" "$root/tests/o82-regdma-transport-contract.c")
includes=(-I"$scratch" -I"$root/src/display")
gcc -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/contract"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/contract"
clang -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/sanitized"
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$scratch/sanitized"
