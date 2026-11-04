#!/usr/bin/env bash
# COPR-only native Linux API check. No kernel Image or device operation.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
archive=$owner/referances/releases/linux-7.3.1.tar.xz
mkdir -p "${archive%/*}"
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.xz -o "$archive"
printf '%s  %s\n' fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231 \
    "$archive" | sha256sum -c -
tar -xJf "$archive" -C "$scratch"
kernel=$scratch/linux-7.3.1
bash "$owner/src/sensors/prepare-source.sh" "$kernel"
bash "$owner/tests/ssc-native-contract.sh" "$kernel"
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 defconfig
"$kernel/scripts/config" --file "$scratch/out/.config" -d RUST -d DEBUG_INFO_BTF \
    -e IIO -e IIO_BUFFER -m QRTR -m QCOM_QMI_HELPERS -m IIO_UKE_SSC
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 olddefconfig
grep -Fx CONFIG_IIO_UKE_SSC=m "$scratch/out/.config"
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 -j4 prepare
make -C "$kernel" O="$scratch/out" ARCH=arm64 KCFLAGS=-Werror -j4 \
    drivers/iio/common/uke-ssc/uke-ssc.o
test -s "$scratch/out/drivers/iio/common/uke-ssc/uke-ssc-iio.o"
test -s "$scratch/out/drivers/iio/common/uke-ssc/uke-ssc-protocol.o"
nm "$scratch/out/drivers/iio/common/uke-ssc/uke-ssc.o" | \
    awk '$2 ~ /^[tT]$/ && $3 == "ssc_probe" {found=1} END {exit !found}'
for attribute in service_count lookup_fault suspended client_connected declared_sensors \
    discovered_sensors ready_sensors registered_sensors last_error last_error_stage; do
    nm "$scratch/out/drivers/iio/common/uke-ssc/uke-ssc.o" | \
        awk -v symbol="ssc_${attribute}_show" \
            '$2 ~ /^[tT]$/ && $3 == symbol {found=1} END {exit !found}'
done
test -r "$kernel/Documentation/ABI/testing/sysfs-driver-uke-ssc"
printf '%s\n' 'All ten read-only SSC controller callbacks compile in the actual native object; no controller query or sensor sample was performed'
printf '%s\n' 'Native SSC protocol and QMI/IIO consumer compile against exact Linux 7.3.1 AArch64 headers; full module linkage and hardware remain unverified'
