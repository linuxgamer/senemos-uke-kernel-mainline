#!/usr/bin/env bash
# Host source preparation after KMS lifecycle/retirement patches; no MMIO.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass the prepared kernel source}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
[[ $(jq -er .version "$kernel/senemos-adaptation/source-lock.json") == 7.3.1 ]]
git -C "$kernel" apply --check "$owner/patches/display/0072-o82-regdma-resource.patch"
git -C "$kernel" apply "$owner/patches/display/0072-o82-regdma-resource.patch"
git -C "$kernel" apply --check "$owner/patches/display/0073-o82-regdma-power.patch"
git -C "$kernel" apply "$owner/patches/display/0073-o82-regdma-power.patch"
# Keep the actual former detach function for the remote negative control only.
sed -n '/^static void _dpu_kms_mmu_destroy(.*)$/,/^}/p' \
    "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c" | \
    sed 's/_dpu_kms_mmu_destroy(/_dpu_kms_mmu_destroy_before(/' > \
    "$kernel/o82-mmu-destroy-before.h"
git -C "$kernel" apply --check "$owner/patches/display/0074-o82-regdma-close.patch"
git -C "$kernel" apply "$owner/patches/display/0074-o82-regdma-close.patch"
git -C "$kernel" apply --check "$owner/patches/display/0075-o82-atomic-color.patch"
git -C "$kernel" apply "$owner/patches/display/0075-o82-atomic-color.patch"
git -C "$kernel" apply --check "$owner/patches/display/0076-o82-sixzone-pa-flush.patch"
git -C "$kernel" apply "$owner/patches/display/0076-o82-sixzone-pa-flush.patch"
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
for file in dpu_o82_platform.c dpu_o82_platform.h dpu_o82_regdma.c dpu_o82_regdma.h \
    dpu_o82_upload.c dpu_o82_upload.h dpu_o82_lutbus.c dpu_o82_lutbus.h \
    dpu_o82_power.c dpu_o82_power.h \
    dpu_o82_color.c dpu_o82_color.h dpu_o82_profiles.c dpu_o82_profiles.h \
    o82-color-firmware.h o82-sixzone-format.h o82-hsic-format.h o82-memory-format.h \
    uke-o82-hdr-format.h o82-regdma.h; do
    install -m644 "$owner/src/display/$file" "$target/$file"
done
install -Dm644 "$owner/src/display/bindings/qcom,sm7675-dpu.yaml" \
    "$kernel/Documentation/devicetree/bindings/display/msm/qcom,sm7675-dpu.yaml"
