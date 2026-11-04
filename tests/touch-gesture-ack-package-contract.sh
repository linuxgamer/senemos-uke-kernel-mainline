#!/usr/bin/env bash
# COPR only: require the updated production protocol and complete input module.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Prepared kernel}
output=${2:?Native output}
driver=drivers/input/touchscreen/nt36532-uke
cmp "$owner/src/input/nt36532-uke-protocol.c" "$kernel/$driver/nt36532-uke-protocol.c"
grep -Fxq CONFIG_TOUCHSCREEN_NT36532_UKE=m "$output/.config"
for file in nt36532-uke-protocol.o nt36532-uke-touch.ko; do
 test -s "$output/$driver/$file"
 for symbol in nvt_uke_gesture_enter nvt_uke_coordinate_mode; do
  "${NM:-nm}" "$output/$driver/$file" | awk -v symbol="$symbol" '$NF==symbol {found=1} END {exit !found}'
 done
 strings "$output/$driver/$file" | grep -F 'NT36532 setting 0x%02x ACK timed out' >/dev/null
done
printf 'Native gesture ACK path: actual protocol object and complete input module linked; physical gesture/touch untested\n'
