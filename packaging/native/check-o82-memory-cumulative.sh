#!/usr/bin/env bash
# COPR only: actual MSM object on complete12101 plus touch, geometry and memory.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Pass the prepared cumulative source}")
out=$(realpath -m "${2:?Pass the remote object directory}")
addon=$(cd -- "$(dirname -- "$0")/../.." && pwd)
manifest=manifests/o82-memory-cumulative-source-20261105.json
(cd "$addon"; jq -r '.archive_assets[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
profile=$kernel/native-profile
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
[[ $(cat "$profile/source-commit") == bba194e74ab97dcb848887fa62430c20f9d755d9 ]]
jq -e '.source_check_view_only and .o82_memory_layer==1 and
 .qualified_touch_layer==1 and .touch_order_check==11260818 and
 .camera_geometry_source=="9398700a6375a309f572d588a9e448cdbc4b0736" and
 .camera_geometry_three_argument_pad_api and .camera_geometry_private_mutex_and_per_file_try and
 .camcc_probe_observation_abi==1 and .ssc_observation_abi==1 and
 .o82_private_color_bundle_version==5 and .o82_lutbus_max_bytes==41488 and
 .o82_color_initial_preset=="" and .native_hdr_advertised==false' \
 "$profile/source-composition.json" >/dev/null
printf '%s  %s\n' 739882b3a07fc6a701bae81ac6623a4b576871bd4289de3a095acabc20d49d34 \
 "$profile/native.config" | sha256sum -c --strict -
while read -r relative; do
    cmp "$addon/$relative" "$profile/$relative"
    if [[ $relative == src/display/* && $relative != *.sh ]]; then
        cmp "$profile/$relative" "$target/${relative##*/}"
    fi
done < <(jq -r '.imports[].path' "$addon/manifests/o82-memory-layer-20261105.json")
printf '%s  %s\n' df7ce54741d6a08c09ff607b86ce33c2057bb05c52b4d1a21d98b5be3395700e \
 "$kernel/drivers/media/i2c/ov08d10.c" | sha256sum -c --strict -
bash "$addon/tests/o82-touch-integrated731-contract.sh" "$kernel"
bash "$addon/tests/o82-profile-loader-contract.sh" "$addon"
bash "$addon/tests/o82-memory-bundle-contract.sh" "$addon"
bash "$addon/tests/o82-lutbus-contract.sh"
bash "$addon/tests/o82-regdma-transport-contract.sh" "$addon" "$kernel"
bash "$addon/tests/o82-atomic-contract.sh" "$addon" "$kernel"
mkdir -p "$out"
cp "$profile/native.config" "$out/.config"
export ARCH=arm64 LLVM=1 LLVM_IAS=1
bash "$kernel/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE ''
make -s -C "$kernel" O="$out" olddefconfig
grep -Fx CONFIG_DRM_MSM=m "$out/.config"
printf '%s  %s\n' 81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90 \
 "$kernel/drivers/gpu/drm/msm/registers/gen_header.py" | sha256sum -c --strict -
# The pinned upstream generator executes only in this remote COPR worker.
make -s -C "$kernel" O="$out" KCFLAGS=-Werror -j4 drivers/gpu/drm/msm/msm.o
linked=$out/drivers/gpu/drm/msm/msm.o
test -s "$linked"
readelf -h "$linked" | grep -E 'Machine:.*AArch64'
for function in dpu_o82_lutbus_build dpu_o82_power_upload dpu_o82_profiles_load \
 dpu_o82_profiles_input dpu_o82_color_commit dpu_o82_upload; do
    llvm-nm --defined-only "$linked" | awk -v name="$function" \
      '$2 ~ /^[tT]$/ && $3==name {found=1} END {exit !found}'
done
llvm-nm --undefined-only "$linked" > "$out/memory-undefined.txt"
if grep -E ' dpu_o82_(platform|regdma|upload|lutbus|power|color|profiles)_' "$out/memory-undefined.txt"; then exit 1; fi
if grep -E '__(add|sub|mul|div)(sf|df|tf)3|__float.*(sf|df|tf)|__aeabi_.*(f|d)' "$out/memory-undefined.txt"; then exit 1; fi
for supplier in 36 42; do
    strings "$linked" | grep -Fx "qcom/sm7675/uke/o82-$supplier-color-v5.bin"
    strings "$linked" | grep -Fx "qcom/sm7675/uke/o82-$supplier-color-v4.bin"
done
node=/fragment@208/__overlay__/display-subsystem@ae00000/display-controller@ae01000
for supplier in 36 42; do
    overlay=$kernel/native-generated/display-$supplier.dtbo
    [[ $(fdtget -t s "$overlay" "$node" compatible) == qcom,sm7675-dpu ]]
    [[ $(fdtget -t x "$overlay" "$node" reg) == 'ae01000 8f000 aeb0000 1074 af80000 7000' ]]
done
printf '%s  %s\n' 739882b3a07fc6a701bae81ac6623a4b576871bd4289de3a095acabc20d49d34 \
 "$profile/native.config" | sha256sum -c --strict -
test ! -e "$out/arch/arm64/boot/Image"
test -z "$(find "$out" -type f -name '*.ko' -print -quit)"
printf 'Actual cumulative12101/touch/geometry MSM object links all memory/v5 code; both DT resources and raw configuration retained\n'
printf 'Only source/native-object qualification; no Image, module, firmware, boot delivery or physical acceptance\n'
