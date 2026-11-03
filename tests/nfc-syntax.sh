#!/usr/bin/env bash
# Compile the real tag driver against prepared ARM64 Linux headers.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
source=$(realpath "${1:?prepared kernel source}")
output=$(realpath "${2:?prepared ARM64 output}")
[[ -f $output/include/generated/autoconf.h ]]
mkdir -p "$root/build"
cd "$output"
${CLANG:-clang} --target=aarch64-linux-gnu -D__KERNEL__ -DMODULE \
    -DKBUILD_MODNAME='"fm19511_uke"' -DKBUILD_BASENAME='"fm19511_uke"' \
    -nostdinc -I "$source/arch/arm64/include" -I arch/arm64/include/generated \
    -I "$source/include" -I include -I "$source/arch/arm64/include/uapi" \
    -I arch/arm64/include/generated/uapi -I "$source/include/uapi" -I include/generated/uapi \
    -include "$source/include/linux/compiler-version.h" -include "$source/include/linux/kconfig.h" \
    -include "$source/include/linux/compiler_types.h" -std=gnu11 -fms-anonymous-structs \
    -O2 -mgeneral-regs-only -fno-strict-aliasing -fshort-wchar \
    -Werror=implicit-function-declaration -Werror=incompatible-pointer-types \
    -Wno-unused-parameter -Wno-address-of-packed-member \
    -c "$root/src/nfc/fm19511-uke.c" -o "$root/build/fm19511-uke.o"
printf 'FM19511 driver ARM64 object compiled; no module load or physical NFC result\n'
