#!/usr/bin/env bash
# COPR only: require real production objects and the complete linked module.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=${1:?Prepared kernel}
output=${2:?Native output}
driver=drivers/net/wireless/ath/ath11k
grep -Fxq CONFIG_ATH11K=m "$output/.config"
grep -Fxq CONFIG_ATH11K_AHB=m "$output/.config"
for file in reg.o wmi.o ath11k.ko; do
 test -s "$output/$driver/$file"
done
for file in reg.o ath11k.ko; do
 "${NM:-nm}" "$output/$driver/$file" | awk '$NF=="ath11k_reg_handle_chan_list" {found=1} END {exit !found}'
 strings "$output/$driver/$file" | grep -F 'Country regulatory setting: status %s (%u), alpha2 %c%c, phy %u, %s event' >/dev/null
done
for file in wmi.o ath11k.ko; do
 "${NM:-nm}" "$output/$driver/$file" | awk '$NF=="ath11k_wmi_attach" {found=1} END {exit !found}'
done
test -s "$kernel/native-generated/ath11k-regulatory-before/$driver/wmi.c"
printf 'Native ath11k diagnostics: real WMI/regulatory objects and complete module linked; radio behavior untested\n'
