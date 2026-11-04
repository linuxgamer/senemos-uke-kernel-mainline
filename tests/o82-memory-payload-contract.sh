#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# COPR/host only: compile the actual JSON utility and native C consumers.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=${1:-$(cd -- "$(dirname -- "$0")/.." && pwd)}
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
mkdir -p "$scratch/linux"
cat > "$scratch/linux/types.h" <<'C'
#ifndef TEST_LINUX_TYPES_H
#define TEST_LINUX_TYPES_H
#include_next <linux/types.h>
#include <stdbool.h>
#include <stddef.h>
typedef unsigned char u8;
#endif
C
cat > "$scratch/linux/firmware.h" <<'C'
#ifndef TEST_FIRMWARE_H
#define TEST_FIRMWARE_H
#include <linux/types.h>
struct device { int unused; };
struct firmware { const u8 *data; size_t size; };
int request_firmware_direct(const struct firmware **fw, const char *name, struct device *dev);
void release_firmware(const struct firmware *fw);
#endif
C
printf '#include <asm-generic/errno.h>\n' > "$scratch/linux/errno.h"
printf '#include <string.h>\n' > "$scratch/linux/string.h"
includes=(-I"$scratch" -I"$root" -I"$root/src/display")
warnings=(-UNDEBUG -Wall -Wextra -Werror)
read -ra libs <<< "$(pkg-config --cflags --libs json-c lcms2 openssl)"
for variant in optimized sanitized; do
    cc=gcc; cxx=g++; flags=(-O2)
    if [[ $variant == sanitized ]]; then
        cc=clang; cxx=clang++; flags=(-O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    fi
    "$cc" -std=gnu11 "${warnings[@]}" "${flags[@]}" "${includes[@]}" \
        -c "$root/src/display/dpu_o82_profiles.c" -o "$scratch/profiles-$variant.o"
    "$cc" -std=gnu11 "${warnings[@]}" "${flags[@]}" "${includes[@]}" \
        -c "$root/src/display/dpu_o82_lutbus.c" -o "$scratch/encoder-$variant.o"
    "$cxx" -std=c++20 "${warnings[@]}" "${flags[@]}" "${includes[@]}" -Wl,--wrap=main \
        "$root/tests/o82-memory-payload-contract.cpp" "$scratch/profiles-$variant.o" "$scratch/encoder-$variant.o" \
        "${libs[@]}" -o "$scratch/pipeline-$variant"
    "$scratch/pipeline-$variant"
done
