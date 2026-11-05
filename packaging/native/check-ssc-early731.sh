#!/usr/bin/env bash
# COPR only: real callback ordering and native SSC object over frozen12203.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Prepared cumulative kernel}")
output=$(realpath -m "${2:?Native object output}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$kernel/native-profile
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
manifest=$owner/manifests/ssc-early-layer-20261105.json
jq -e '.ssc_early_sample_layer==1 and .ssc_early_sample_requires_ack and
 (.ssc_early_sample_physical_acceptance|not) and .ssc_transaction_layer==1 and
 .ssc_qmi_transaction_id_returns_id' "$profile/source-composition.json" >/dev/null
cmp "$profile/src/sensors/uke-ssc-iio.c" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c"

# Reproduce the exact former production source with the new behavioral fixture.
# Each compiler must reach the early-report assertion, rather than fail to build.
cp -a "$owner/original" "$stage/original"
while IFS=$'\t' read -r path digest; do
    [[ $path != tests/ssc-native-contract.c ]] || continue
    printf '%s  %s\n' "$digest" "$stage/original/$path" | sha256sum -c --strict -
done < <(jq -r '.preimages[]|[.path,.sha256]|@tsv' "$manifest")
for compiler in gcc clang; do
    sed "s/for compiler in gcc clang; do/for compiler in $compiler; do/" \
        "$stage/original/tests/ssc-native-contract.sh" > "$stage/original/tests/original-order.sh"
    if (ulimit -c 0; bash "$stage/original/tests/original-order.sh" "$kernel") \
        > "$stage/original-$compiler.log" 2>&1; then
        printf 'Original SSC source unexpectedly retained an early indication: %s\n' "$compiler" >&2
        exit 1
    fi
    grep -q 'early_reports.*Assertion.*sample_sequence == 10' "$stage/original-$compiler.log"
    printf 'Original SSC source loses the pre-acknowledgement indication as required: %s\n' "$compiler"
done
bash "$profile/tests/ssc-native-contract.sh" "$kernel"
bash "$profile/packaging/native/check-cumulative-camera731.sh" "$kernel" "$output" prepared
mkdir -p "$output" "$stage/reference"
for dir in "$output" "$stage/reference"; do
    cp "$profile/native.config" "$dir/.config"
    bash "$kernel/scripts/config" --file "$dir/.config" --set-str INITRAMFS_SOURCE "$output/boot-initramfs.cpio.gz"
    make -s -C "$kernel" O="$dir" ARCH=arm64 LLVM=1 LLVM_IAS=1 olddefconfig
done
cmp "$output/.config" "$stage/reference/.config"
grep -Fx CONFIG_IIO_UKE_SSC=m "$output/.config"
make -s -C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=-12203-unstable -j4 prepare modules_prepare
make -s -C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION=-12203-unstable KCFLAGS=-Werror -j4 \
    drivers/iio/common/uke-ssc/uke-ssc.o
object=$output/drivers/iio/common/uke-ssc/uke-ssc.o
llvm-readelf -h "$object" | grep -E 'Machine:.*AArch64|Type:.*REL'
sha256sum "$object" "$profile/src/sensors/uke-ssc-iio.c" "$output/.config"
test ! -e "$output/arch/arm64/boot/Image"
test -z "$(find "$output" -type f -name '*.ko' -print -quit)"
printf '%s\n' 'PASS: original source loses early samples; acknowledged staging passes real callbacks, all retained controls and native AArch64 SSC linkage with -Werror' \
    'Scope: source/config/object only; no Image, final module, target install, boot or physical ALS acceptance'
