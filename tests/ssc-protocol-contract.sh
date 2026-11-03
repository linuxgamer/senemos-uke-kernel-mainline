#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
# Compilation belongs to the remote worker, never the tablet.
test ! -e /etc/senemos/kernel-update.conf
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/include/linux"
cat > "$stage/include/linux/types.h" <<'TYPES'
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int64_t s64;
TYPES
for compiler in gcc clang; do
    "$compiler" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
        -fsanitize=address,undefined -fno-omit-frame-pointer \
        -I"$stage/include" -I"$root/src/sensors" \
        "$root/src/sensors/uke-ssc-protocol.c" "$root/tests/ssc-protocol-contract.c" \
        -lm -o "$stage/check"
    ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 "$stage/check"
done
