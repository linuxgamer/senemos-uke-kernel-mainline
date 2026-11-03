#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR only; compile the actual byte encoder with synthetic private-table inputs.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/linux"
cat > "$work/linux/types.h" <<'C'
#include <stdbool.h>
#include <stddef.h>
typedef unsigned char u8;
C
cat > "$work/linux/errno.h" <<'C'
#include <asm-generic/errno.h>
C
sources=("$root/src/display/dpu_o82_lutbus.c" "$root/tests/o82-lutbus-contract.c")
flags=(-std=gnu11 -UNDEBUG -Wall -Wextra -Werror -I"$work" -I"$root/src/display")
gcc "${flags[@]}" -O2 "${sources[@]}" -o "$work/check"
"$work/check"
clang "${flags[@]}" -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all \
    "${sources[@]}" -o "$work/sanitized"
"$work/sanitized"
