#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host/COPR fixture only. No target device or MMIO access.
set -Eeuo pipefail
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
mkdir -p "$scratch/linux"
cat > "$scratch/linux/types.h" <<'EOF'
#ifndef TEST_LINUX_TYPES_H
#define TEST_LINUX_TYPES_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint32_t u32;
typedef uint64_t u64;
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
sources=("$root/src/display/dpu_o82_regdma.c" "$root/tests/o82-regdma-transport-contract.c")
includes=(-I"$scratch" -I"$root/src/display")
gcc -std=gnu11 -O2 -UNDEBUG -Wall -Wextra -Werror "${includes[@]}" "${sources[@]}" -o "$scratch/contract"
"$scratch/contract"
clang -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/sanitized"
"$scratch/sanitized"
