#!/usr/bin/env bash
# Verify the actual combined output; no tag memory or IR transmission is used.
set -Eeuo pipefail
output=$(realpath "${1:?Pass the actual kernel output directory}")
bash "$(dirname -- "$0")/nfc-ir-package-contract.sh" "$output"
grep -Fx CONFIG_PM_SLEEP=y "$output/.config"
for protocol in JVC NEC RC5 RC6 RCMM SANYO SHARP SONY; do
    grep -Fx "CONFIG_IR_${protocol}_DECODER=m" "$output/.config"
    name=${protocol,,}
    test -s "$output/drivers/media/rc/ir-$name-decoder.ko"
done
for callback in fm19511_ioctl fm19511_suspend fm19511_resume; do
    nm "$output/drivers/misc/fm19511-uke.ko" |
        awk -v callback="$callback" '$2 ~ /^[tT]$/ && ($3==callback || index($3,callback".")==1) {found=1} END {exit !found}'
done
strings "$output/drivers/iio/common/uke-ssc/uke-ssc.ko" | grep -Fx 'sns_sensor_temperature.proto'
strings "$output/vmlinux" | grep -Fx 'sensor-temperature'
printf 'Combined native package: tag UAPI/PM callbacks, eight IR codec modules and SSC temperature identity verified; RF/optical/sensor acceptance separate\n'
