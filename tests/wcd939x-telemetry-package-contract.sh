#!/usr/bin/env bash
# COPR only: verify the real codec object and complete linked module.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Prepared pinned kernel source}")
output=$(realpath "${2:?Native kernel build output}")
grep -Fxq CONFIG_SND_SOC_WCD939X=m "$output/.config"
object=$output/sound/soc/codecs/wcd939x.o
module=$output/sound/soc/codecs/snd-soc-wcd939x.ko
[[ -s $object && -s $module ]]
for symbol in wcd939x_get_hph_type wcd939x_hph_impedance_get \
 hph_type_detect_controls impedance_detect_controls; do
 nm "$object" | awk -v name="$symbol" '$2 ~ /^[tTrRdD]$/ && $3==name {found=1} END {exit !found}'
 nm "$module" | awk -v name="$symbol" '$2 ~ /^[tTrRdD]$/ && $3==name {found=1} END {exit !found}'
done
cmp "$kernel/native-profile/src/sensors/uke-ssc-iio.c" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c"
cmp "$kernel/native-profile/src/sensors/uke-ssc-protocol.c" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-protocol.c"
printf 'Native WCD939x telemetry: real control/getter objects and complete codec module linked; qualified SSC sources retained; hardware untested\n'
