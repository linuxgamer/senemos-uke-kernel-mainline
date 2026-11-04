#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR/host only: actual kernel loader with a synthetic firmware provider.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
mkdir -p "$scratch/linux"
cat > "$scratch/linux/types.h" <<'EOF'
#ifndef TEST_LINUX_TYPES_H
#define TEST_LINUX_TYPES_H
#include <stdbool.h>
#include <stddef.h>
typedef unsigned char u8;
#endif
EOF
cat > "$scratch/linux/firmware.h" <<'EOF'
#ifndef TEST_FIRMWARE_H
#define TEST_FIRMWARE_H
#include "types.h"
struct device { int unused; };
struct firmware { const u8 *data; size_t size; };
int request_firmware_direct(const struct firmware **fw, const char *name, struct device *dev);
void release_firmware(const struct firmware *fw);
#endif
EOF
cat > "$scratch/linux/errno.h" <<'EOF'
#include <asm-generic/errno.h>
EOF
cat > "$scratch/linux/string.h" <<'EOF'
#include <string.h>
EOF
sources=("$root/src/display/dpu_o82_profiles.c" "$root/tests/o82-profile-loader-contract.c")
includes=(-I"$scratch" -I"$root/src/display")
gcc -std=gnu11 -O2 -UNDEBUG -Wall -Wextra -Werror "${includes[@]}" "${sources[@]}" -o "$scratch/contract"
"$scratch/contract"
clang -std=gnu11 -O1 -g -UNDEBUG -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer "${includes[@]}" "${sources[@]}" -o "$scratch/sanitized"
"$scratch/sanitized"
