#!/usr/bin/env bash
# COPR only. Actual built-in controller; no hardware-success inference.
set -Eeuo pipefail
[[ $# == 3 ]] || exit 2
output=$(realpath "$1")
root=$(realpath "$2")
release=$3
[[ $release =~ ^7\.3\.1-[1-9][0-9]{3,4}$ ]]
grep -Fx 'CONFIG_SM_CAMCC_7675=y' "$output/.config"
llvm-readelf -h "$output/drivers/clk/qcom/camcc-sm7675.o" | grep -E 'Machine:.*AArch64'
llvm-nm --defined-only "$output/vmlinux" | awk '$NF=="cam_cc_native_driver" {found=1} END {exit !found}'
grep -Fx 'kernel/drivers/clk/qcom/camcc-sm7675.ko' "$output/modules.builtin"
test ! -e "$root/usr/lib/modules/$release/kernel/drivers/clk/qcom/camcc-sm7675.ko.zst"
grep -aqF 'firmware-enabled-refused' "$output/arch/arm64/boot/Image"
printf 'Actual permanent CAMCC AArch64 object, vmlinux driver, builtin inventory and CRM mode reporting checked; no unloadable module or physical result\n'
