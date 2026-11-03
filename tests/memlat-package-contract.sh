#!/usr/bin/env bash
# Verify the actual configured and linked built-in provider in the remote output.
set -Eeuo pipefail
output=${1:?Pass the actual kernel output directory}
grep -Fxq CONFIG_QCOM_UKE_MEMLAT=y "$output/.config"
test -s "$output/drivers/soc/qcom/uke-memlat.o"
nm "$output/vmlinux" | awk '$2 ~ /^[tT]$/ && $3 ~ /^uke_memlat_probe([.][[:alnum:]_.]+)?$/ {found=1} END {exit !found}'
strings "$output/vmlinux" | grep -Fx 'xiaomi,uke-memlat'
printf 'Uke MEMLAT built-in policy, linked probe and exact OF match verified; hardware untested\n'
