#!/usr/bin/env bash
# COPR only: validate the actual correction within the qualified source union.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Pass the prepared complete kernel}")
output=$(realpath -m "${2:?Pass the remote object output}")
profile=$kernel/native-profile
manifest=manifests/ssc-transaction-layer-20261105.json
(cd "$profile"; jq -r '.assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
jq -e '.ssc_transaction_layer==1 and .ssc_qmi_transaction_id_returns_id==true and
 .ssc_transaction_physical_acceptance==false and .ssc_observation_abi==1 and
 .queued_kernel_layer==1 and .o82_memory_layer==1 and .source_check_view_only' \
 "$profile/source-composition.json" >/dev/null
cmp "$profile/src/sensors/uke-ssc-iio.c" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c"
[[ $(git hash-object "$kernel/drivers/soc/qcom/qmi_interface.c") == 16e2e24b60968abad39065e77ca444a1562d65d1 ]]
# This fixture uses the exact upstream wire encoder and real SSC callbacks,
# returning every valid allocated ID and rejecting the former production guard.
bash "$profile/tests/ssc-native-contract.sh" "$kernel"
bash "$kernel/memory-addon/packaging/native/check-coordinated-union731.sh" "$kernel" "$output"
grep -Fx CONFIG_IIO_UKE_SSC=m "$output/.config"
export LOCALVERSION=-12101-unstable
make -s -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$output" KCFLAGS=-Werror -j4 \
 drivers/iio/common/uke-ssc/uke-ssc.o
object=$output/drivers/iio/common/uke-ssc/uke-ssc.o
readelf -h "$object" | grep -E 'Machine:.*AArch64|Type:.*REL'
symbols=$(mktemp)
trap 'find "$symbols" -maxdepth 0 -type f -delete' EXIT
llvm-nm --defined-only "$object" > "$symbols"
for symbol in ssc_probe ssc_service_count_show ssc_last_error_show ssc_last_error_stage_show \
 uke_ssc_encode_request uke_ssc_decode_events uke_ssc_decode_attributes; do
    grep -E "[[:space:]][Tt][[:space:]]+$symbol$" "$symbols"
done
sha256sum "$object" "$kernel/drivers/iio/common/uke-ssc/uke-ssc-iio.c" "$output/.config"
test ! -e "$output/arch/arm64/boot/Image"
test -z "$(find "$output" -type f -name '*.ko' -print -quit)"
printf 'SSC transaction correction: all allocated IDs, original-guard refusal and real AArch64 SSC/MSM/sensor objects qualified together; hardware acceptance pending\n'
