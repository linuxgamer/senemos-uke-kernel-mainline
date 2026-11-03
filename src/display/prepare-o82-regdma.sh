#!/usr/bin/env bash
# Host source preparation after KMS lifecycle/retirement patches; no MMIO.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass the prepared kernel source}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
[[ $(jq -er .version "$kernel/senemos-adaptation/source-lock.json") == 7.3.1 ]]
git -C "$kernel" apply --check "$owner/patches/display/0072-o82-regdma-resource.patch"
git -C "$kernel" apply "$owner/patches/display/0072-o82-regdma-resource.patch"
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
for file in dpu_o82_platform.c dpu_o82_platform.h dpu_o82_regdma.c dpu_o82_regdma.h o82-regdma.h; do
    install -m644 "$owner/src/display/$file" "$target/$file"
done
install -Dm644 "$owner/src/display/bindings/qcom,sm7675-dpu.yaml" \
    "$kernel/Documentation/devicetree/bindings/display/msm/qcom,sm7675-dpu.yaml"
