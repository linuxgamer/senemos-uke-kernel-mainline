#!/usr/bin/env bash
# COPR only: one real MSM object contains memory/v5 and the qualified GMU IRQ.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Pass the prepared complete source}")
output=$(realpath -m "${2:?Pass the object output}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
manifest=$owner/manifests/coordinated-union731-20261105.json
(cd "$owner"; jq -r '.archive_assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
jq -e '.queued_kernel_layer==1 and .gmu_irq_owned_acknowledgement and
 .gmu_irq_reference_source=="a85f0f660dd947d2737dca18ce043674ce55a45e" and
 .source_check_view_only and .o82_memory_layer==1 and
 .o82_color_initial_preset=="" and .native_hdr_advertised==false' "$kernel/native-profile/source-composition.json" >/dev/null
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^static irqreturn_t a6xx_hfi_irq\(/ {emit=1} emit{print} emit&&/^}/{exit}' \
 "$kernel/drivers/gpu/drm/msm/adreno/a6xx_gmu.c" > "$work/irq.inc"
awk '/^static int a6xx_hfi_wait_for_msg_interrupt\(/ {emit=1} emit{print} emit&&/^}/{exit}' \
 "$kernel/drivers/gpu/drm/msm/adreno/a6xx_hfi.c" > "$work/wait.inc"
printf '%s  %s\n' 27090a6a64d647b12b24125bfe0ae5c3b22abbbc88f9c7202c8c921377a39ae3 "$work/irq.inc" \
 89cd584b2e2f874b7afa8e1a036a07ac5ae77a0802a82aa5e964a150751b3741 "$work/wait.inc" | sha256sum -c --strict -
export LOCALVERSION=-12101-unstable
bash "$owner/tests/camera-geometry731-object.sh" "$kernel" "$output" "$kernel/native-profile/native.config"
# The retained checker checks all twelve imports, actual touch/v4/v5/power/
# atomic paths, both supplier DT resources and six defined native symbols.
bash "$owner/packaging/native/check-o82-memory-cumulative.sh" "$kernel" "$output"
object=$output/drivers/gpu/drm/msm/msm.o
readelf -h "$object" | grep -E 'Type:.*REL'
llvm-nm --defined-only "$object" > "$work/symbols"
for symbol in a6xx_hfi_irq a6xx_gmu_resume a6xx_hfi_set_freq msm_gpu_fault_crashstate_capture; do
    grep -E "[[:space:]][Tt][[:space:]]+$symbol$" "$work/symbols"
done
# The pinned input predates this worker's Kconfig normalization. Independently
# normalize the same immutable input and object-only initramfs setting, then
# compare the complete effective configuration without an option allowlist.
reference=$work/reference-config
mkdir "$reference"
install -m644 "$kernel/native-profile/native.config" "$reference/.config"
bash "$kernel/scripts/config" --file "$reference/.config" --set-str INITRAMFS_SOURCE ''
make -s -C "$kernel" ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$reference" olddefconfig
if ! cmp -s "$reference/.config" "$output/.config"; then
    diff -u --label expected-effective-config --label object-effective-config \
        "$reference/.config" "$output/.config" || true
    exit 1
fi
printf 'Complete effective config matches independent olddefconfig of pinned input; no feature exclusions\n'
sha256sum "$kernel/native-profile/native.config" "$reference/.config" "$output/.config"
for flag in CONFIG_DRM_MSM=m CONFIG_DRM_MSM_KMS=y CONFIG_DRM_MSM_GPU_STATE=y CONFIG_LTO_NONE=y; do
    grep -Fx "$flag" "$output/.config"
done
sha256sum "$object" "$kernel/drivers/gpu/drm/msm/adreno/a6xx_gmu.c" "$kernel/drivers/media/i2c/ov08d10.c"
test ! -e "$output/arch/arm64/boot/Image"
test -z "$(find "$output" -type f -name '*.ko' -print -quit)"
printf 'Coordinated union: one real AArch64 MSM object links memory/v5 and corrected GMU with qualified touch/geometry, both DT suppliers and retained feature configuration; no Image/final module/device operation\n'
