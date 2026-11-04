#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Inspect the actual compiled and packaged modules; never load them.
set -Eeuo pipefail
[[ $# == 3 ]] || exit 2
output=$(realpath -- "$1")
buildroot=$(realpath -- "$2")
release=$3
for sensor in ov08d10 ov13b10; do
    symbol=${sensor^^}
    grep -Fx "CONFIG_VIDEO_$symbol=m" "$output/.config"
    object=$output/drivers/media/i2c/$sensor.o
    module=$buildroot/usr/lib/modules/$release/kernel/drivers/media/i2c/$sensor.ko.zst
    test -s "$object" && test -s "$module"
    llvm-readelf -h "$object" | grep -E 'Machine:.*AArch64'
    modinfo -F alias "$module" > "$output/$sensor-aliases.txt"
    grep -Fq "of:N*T*Covti,$sensor" "$output/$sensor-aliases.txt"
    modinfo -F vermagic "$module" | grep -F "$release "
    test -n "$(modinfo -F signer "$module")"
done
grep -Fq 'acpi*:OVTI13B1:*' "$output/ov13b10-aliases.txt"
printf 'Both native camera sensor modules are built, signed and packaged; no device activation tested\n'
