#!/usr/bin/env bash
# Syntax-only ARM64 check against prepared Linux headers; emits no kernel object.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=$(realpath "${1:?prepared kernel source}")
output=$(realpath "${2:?prepared ARM64 output}")
[[ -f $output/include/generated/autoconf.h ]]
cd "$output"
${CLANG:-clang} --target=aarch64-linux-gnu -D__KERNEL__ -DMODULE \
    -DKBUILD_MODNAME='"leds_uke_rgb"' -DKBUILD_BASENAME='"leds_uke_rgb"' \
    -nostdinc -I "$source/arch/arm64/include" -I arch/arm64/include/generated \
    -I "$source/include" -I include -I "$source/arch/arm64/include/uapi" \
    -I arch/arm64/include/generated/uapi -I "$source/include/uapi" -I include/generated/uapi \
    -include "$source/include/linux/compiler-version.h" -include "$source/include/linux/kconfig.h" \
    -include "$source/include/linux/compiler_types.h" -std=gnu11 -fms-anonymous-structs \
    -mgeneral-regs-only -fno-strict-aliasing -fshort-wchar -Werror=implicit-function-declaration \
    -Werror=incompatible-pointer-types -Wno-unused-parameter -Wno-address-of-packed-member \
    -fsyntax-only "$root/src/leds/leds-uke-rgb.c"
printf '%s\n' 'Actual RGB consumer: ARM64 Linux header/API syntax check passed; no Image, module object or RPM built'
