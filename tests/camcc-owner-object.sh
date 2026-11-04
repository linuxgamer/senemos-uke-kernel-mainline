#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Native object only; never linked, installed or registered as a driver.
set -Eeuo pipefail
[[ $# == 3 ]] || exit 2
kernel=$(realpath -- "$1")
output=$(realpath -- "$2")
buildroot=$(realpath -- "$3")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
stage=$output/camcc-owner-object
mkdir -p "$stage"
cp "$project/tests/fixtures/camcc-provider-object.c" "$stage/"
printf '%s\n' 'obj-m += camcc-provider-object.o' \
    "ccflags-y += -I$project/src/camera -I$project/src/camera/include -I$kernel/drivers/clk/qcom" > "$stage/Makefile"
sha256sum "$output/arch/arm64/boot/Image" > "$stage/retained-image.sha256"
make -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" M="$stage" \
    KCFLAGS=-Werror -j4 camcc-provider-object.o
llvm-readelf -h "$stage/camcc-provider-object.o" | grep -E 'Machine:.*AArch64'
sha256sum -c "$stage/retained-image.sha256"
test -z "$(find "$buildroot" -type f -name '*camcc-provider-object*' -print -quit)"
printf 'CAMCC owner: actual catalog/power/resource-owner object compiles for AArch64; Image unchanged and test object not installed\n'
