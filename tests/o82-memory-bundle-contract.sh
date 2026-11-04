#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR/host only; no private profile, hardware access or installed executable.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
mkdir -p "$scratch/linux"
cat > "$scratch/linux/types.h" <<'C'
#ifndef TEST_LINUX_TYPES_H
#define TEST_LINUX_TYPES_H
#include <stdbool.h>
#include <stddef.h>
typedef unsigned char u8;
#endif
C
cat > "$scratch/linux/firmware.h" <<'C'
#ifndef TEST_FIRMWARE_H
#define TEST_FIRMWARE_H
#include "types.h"
struct device { int unused; };
struct firmware { const u8 *data; size_t size; };
int request_firmware_direct(const struct firmware **fw, const char *name, struct device *dev);
void release_firmware(const struct firmware *fw);
#endif
C
cat > "$scratch/linux/errno.h" <<'C'
#include <asm-generic/errno.h>
C
cat > "$scratch/linux/string.h" <<'C'
#include <string.h>
C
sources=("$root/src/display/dpu_o82_profiles.c" "$root/src/display/dpu_o82_lutbus.c"
    "$root/tests/o82-memory-bundle-contract.c")
flags=(-std=gnu11 -UNDEBUG -Wall -Wextra -Werror -I"$scratch" -I"$root/src/display")
gcc "${flags[@]}" -O2 "${sources[@]}" -o "$scratch/optimized"
"$scratch/optimized"
clang "${flags[@]}" -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    -fno-omit-frame-pointer "${sources[@]}" -o "$scratch/sanitized"
"$scratch/sanitized"
