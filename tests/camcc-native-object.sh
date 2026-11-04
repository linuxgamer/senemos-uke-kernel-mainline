#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR only. Compile complete built-in and inspection variants, without linking.
set -Eeuo pipefail
[[ $# == 4 ]] || exit 2
kernel=$(realpath -- "$1")
output=$(realpath -m -- "$2")
config=$(realpath -- "$3")
release=$4
[[ $release =~ ^7\.3\.1-[1-9][0-9]{3,4}$ ]]
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$output"
test ! -e "$output/arch/arm64/boot/Image"
cp "$config" "$output/.config"
bash "$kernel/scripts/config" --file "$output/.config" --set-str INITRAMFS_SOURCE ''
make -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" \
    LOCALVERSION="-${release#7.3.1-}" olddefconfig prepare modules_prepare
stage=$output/camcc-native-object
mkdir -p "$stage"
cp "$project/src/camera/camcc-sm7675.c" "$stage/camcc-native-builtin.c"
cp "$project/src/camera/camcc-sm7675.c" "$stage/camcc-native-inspect.c"
printf '%s\n' 'obj-y += camcc-native-builtin.o camcc-native-inspect.o' \
    'CFLAGS_camcc-native-inspect.o += -DUKE_CAMCC_OBJECT_TEST' \
    "ccflags-y += -I$project/src/camera -I$project/src/camera/include -I$kernel/drivers/clk/qcom" > "$stage/Makefile"
make -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" M="$stage" \
    LOCALVERSION="-${release#7.3.1-}" KCFLAGS=-Werror -j4 \
    camcc-native-builtin.o camcc-native-inspect.o
for variant in builtin inspect; do
    llvm-readelf -h "$stage/camcc-native-$variant.o" | grep -E 'Machine:.*AArch64'
done
llvm-readelf -SW "$stage/camcc-native-builtin.o" | grep -F '.initcall'
test -z "$(llvm-readelf -SW "$stage/camcc-native-inspect.o" | grep -F '.initcall' || true)"
test ! -e "$output/arch/arm64/boot/Image"
printf 'Complete permanent CAMCC built-in/inspection objects compiled; neither is linked or installed\n'
