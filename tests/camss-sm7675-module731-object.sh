#!/usr/bin/env bash
# COPR only. Link all actual native CAMSS objects before the full kernel build.
set -Eeuo pipefail
[[ $# == 3 ]] || exit 2
kernel=$(realpath "$1")
output=$(realpath "$2")
release=$3
[[ $release =~ ^7\.3\.1-[1-9][0-9]{3,4}$ ]]
test -f "$output/include/generated/autoconf.h"
grep -Fx 'CONFIG_VIDEO_QCOM_CAMSS=m' "$output/.config"
test ! -e "$output/arch/arm64/boot/Image"
stage=$output/camss-sm7675-module-object
mkdir -p "$stage"
cp "$kernel/drivers/media/platform/qcom/camss/Makefile" "$stage/"
cp "$kernel/drivers/media/platform/qcom/camss/"*.c "$stage/"
cp "$kernel/drivers/media/platform/qcom/camss/"*.h "$stage/"
make -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" M="$stage" \
 LOCALVERSION="-${release#7.3.1-}" KCFLAGS=-Werror -j4 qcom-camss.o
llvm-readelf -h "$stage/qcom-camss.o" | grep -E 'Machine:.*AArch64'
llvm-nm --defined-only "$stage/qcom-camss.o" | awk '$NF=="csiphy_ops_sm7675" {found=1} END {exit !found}'
test ! -e "$output/arch/arm64/boot/Image"
printf 'Complete native CAMSS composite linked with SM7675 PHY operations before full kernel build; no device activation\n'
