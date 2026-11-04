#!/usr/bin/env bash
# COPR only: verify the actual full kernel module and retained supplier DTs.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Pass the completely prepared kernel}")
output=$(realpath "${2:?Pass the complete kernel output}")
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
msm=$output/drivers/gpu/drm/msm/msm.ko
[[ -s $msm ]]
readelf -h "$msm" | grep -E 'Machine:.*AArch64' >/dev/null
for function in dpu_o82_platform_init dpu_o82_platform_suspend \
    dpu_o82_platform_fini dpu_o82_regdma_init dpu_o82_regdma_can_unmap \
    dpu_o82_regdma_reset_isolated dpu_o82_upload dpu_o82_upload_release \
    dpu_o82_power_upload dpu_o82_power_recover dpu_o82_power_close \
    dpu_o82_color_init dpu_o82_color_connectors_init dpu_o82_color_check \
    dpu_o82_color_commit dpu_o82_color_gc dpu_o82_color_blocked \
    dpu_encoder_o82_stopped dpu_o82_color_fini; do
    llvm-nm --defined-only "$msm" | awk -v name="$function" \
        '$2 ~ /^[tT]$/ && $3==name {found=1} END {exit !found}'
done
if llvm-nm --undefined-only "$msm" | grep -E ' dpu_o82_(platform|regdma|upload|lutbus|power|color|profiles)_'; then
    echo 'Unresolved internal O82 color symbol in the full kernel module' >&2
    exit 1
fi
strings "$msm" | grep -F 'o82_color_profile' >/dev/null
for file in dpu_o82_platform.c dpu_o82_regdma.c dpu_o82_lutbus.c \
    dpu_o82_upload.c dpu_o82_power.c dpu_o82_color.c dpu_o82_profiles.c \
    dpu_o82_profiles.h dpu_o82_lutbus.h o82-color-firmware.h o82-sixzone-format.h o82-hsic-format.h; do
    cmp "$owner/src/display/$file" "$kernel/drivers/gpu/drm/msm/disp/dpu1/$file"
done
for supplier in 36 42; do
    strings "$msm" | grep -F "qcom/sm7675/uke/o82-$supplier-color-v4.bin" >/dev/null
done
bash "$owner/tests/hardware1900-package-contract.sh" "$kernel" "$output"
printf 'Full native MSM module: paired color functions, initial parameter, source identity and both DT resource tuples passed; no physical color/HDR acceptance\n'
