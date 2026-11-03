#!/usr/bin/env bash
# Inspect the configured, fully linked module without operating the SSC service.
set -Eeuo pipefail
output=$(realpath "${1:?Pass the actual kernel output directory}")
for config in IIO_UKE_SSC QCOM_QMI_HELPERS QRTR IIO_KFIFO_BUF; do
    grep -Fx "CONFIG_${config}=m" "$output/.config"
done
module=$output/drivers/iio/common/uke-ssc/uke-ssc.ko
test -s "$module"
modinfo -F alias "$module" | grep -Fx 'of:N*T*Cxiaomi,uke-ssc-iioC*'
dependencies=$(modinfo -F depends "$module")
for dependency in qmi_helpers kfifo_buf; do
    case ,$dependencies, in
        *,"$dependency",*) ;;
        *) printf 'Missing SSC module dependency: %s\n' "$dependency" >&2; exit 1;;
    esac
done
test -s "$output/net/qrtr/qrtr.ko"
modinfo -F alias "$output/net/qrtr/qrtr.ko" | grep -Fx 'net-pf-42'
nm "$module" | awk '$2 ~ /^[tT]$/ && $3 ~ /^ssc_probe([.][[:alnum:]_.]+)?$/ {found=1} END {exit !found}'
strings "$output/vmlinux" | grep -Fx 'xiaomi,uke-ssc-iio'
printf 'Native SSC package: full module linkage, provider dependencies, OF autoload alias and early DT identity verified; hardware untested\n'
