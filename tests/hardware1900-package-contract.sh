#!/usr/bin/env bash
# COPR only: inspect the real resulting modules and both compiled supplier DTs.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Pass the prepared kernel source}")
output=$(realpath "${2:?Pass the complete kernel output}")
ssc=$output/drivers/iio/common/uke-ssc/uke-ssc.ko
msm=$output/drivers/gpu/drm/msm/msm.ko
[[ -s $ssc && -s $msm ]]
nm "$ssc" | awk '$1=="U" && $2=="device_is_bound" {found=1} END {exit !found}'
for function in dpu_o82_platform_init dpu_o82_platform_suspend dpu_o82_regdma_init dpu_o82_regdma_can_unmap; do
    nm "$msm" | awk -v name="$function" '$2 ~ /^[tT]$/ && $3==name {found=1} END {exit !found}'
done
if nm -u "$msm" | grep -E ' dpu_o82_(platform|regdma)_'; then
    echo 'Unresolved internal O82 REGDMA symbol' >&2; exit 1
fi
node=/fragment@208/__overlay__/display-subsystem@ae00000/display-controller@ae01000
for supplier in 36 42; do
    overlay=$kernel/native-generated/display-$supplier.dtbo
    [[ $(fdtget -t s "$overlay" "$node" compatible) == qcom,sm7675-dpu ]]
    [[ $(fdtget -t s "$overlay" "$node" reg-names) == 'mdp vbif regdma' ]]
    [[ $(fdtget -t x "$overlay" "$node" reg) == 'ae01000 8f000 aeb0000 1074 af80000 7000' ]]
done
printf 'Combined SSC/REGDMA: linked ADSP admission and DPU helpers, both supplier DT resource tuples passed; native sensor publication and HDR output remain unqualified\n'
