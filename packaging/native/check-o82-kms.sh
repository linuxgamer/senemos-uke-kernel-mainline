#!/usr/bin/env bash
# COPR only: real retained KMS integration, without an Image or module build.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
kernel=$(realpath "${1:?Pass the completely prepared retained kernel}")
out=$(realpath -m "${2:?Pass the remote object output directory}")
addon=$(cd -- "$(dirname -- "$0")/../.." && pwd)
profile=$kernel/native-profile
[[ $(cat "$profile/source-commit") == 31313e89f719b935bcd1301d48d807bd1dc27163 ]]
printf 'Retained kernel source: '; cat "$profile/source-commit"
printf 'REGDMA extension source: '; cat "$addon/source-commit"
bash "$addon/tests/o82-platform-contract.sh"
bash "$addon/tests/o82-lutbus-contract.sh"
bash "$addon/tests/o82-regdma-transport-contract.sh" "$addon" "$kernel"
bash "$addon/tests/o82-atomic-contract.sh" "$addon" "$kernel"
# Check the real caller's order and unwind, in addition to testing the helpers.
awk '
 /dpu_kms->hw_vbif = hw;/ {vbif=NR}
 /rc = dpu_o82_platform_init\(dpu_kms\);/ {init=NR}
 init && /goto err_mmu_destroy;/ && !unwind {unwind=NR}
 /static int __maybe_unused dpu_runtime_suspend/ {suspend=1}
 suspend && /rc = dpu_o82_platform_suspend\(dpu_kms\);/ {guard=NR}
 suspend && /return rc;/ && guard && !refuse {refuse=NR}
 suspend && /clk_bulk_disable_unprepare/ {clocks=NR;suspend=0}
 END {exit !(vbif && init==vbif+1 && unwind==init+2 && guard && refuse>guard && clocks>refuse)}
' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c"
awk '
 /^static void _dpu_kms_mmu_destroy\(/ && !/;$/ {mmu=1}
 /^static void _dpu_kms_hw_destroy\(/ {hw=1}
 /^err_mmu_destroy:/ {unwind=1}
 mmu && /dpu_o82_platform_fini\(dpu_kms\);/ {drain_mmu=NR}
 mmu && /mmu->funcs->detach\(mmu\);/ {detach=NR}
 hw && /dpu_o82_platform_fini\(dpu_kms\);/ {drain_hw=NR}
 hw && /dpu_kms->hw_intr = NULL;/ {destroy_hw=NR}
 unwind && /dpu_o82_platform_fini\(dpu_kms\);/ {drain_unwind=NR}
 unwind && /dpu_kms->hw_vbif = NULL;/ {clear_unwind=NR;unwind=0}
 /^}/ {mmu=hw=0}
 END {exit !(drain_mmu && drain_mmu<detach && drain_hw && drain_hw<destroy_hw &&
             drain_unwind && drain_unwind<clear_unwind)}
' "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c"
mkdir -p "$out"
cp "$profile/native.config" "$out/.config"
export ARCH=arm64 LLVM=1 LLVM_IAS=1
bash "$kernel/scripts/config" --file "$out/.config" --set-str INITRAMFS_SOURCE ''
make -s -C "$kernel" O="$out" olddefconfig
grep -Fx CONFIG_DRM_MSM=m "$out/.config"
grep -Fx CONFIG_DRM_MSM_DPU=y "$out/.config"
# Upstream MSM gen_header.py is the existing pinned, host-only build dependency.
printf '%s  %s\n' 81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90 \
    "$kernel/drivers/gpu/drm/msm/registers/gen_header.py" | sha256sum -c -
# msm-display-y is an input list; the real composite target is msm.o.
make -C "$kernel" O="$out" KCFLAGS=-Werror -j4 drivers/gpu/drm/msm/msm.o
linked=$out/drivers/gpu/drm/msm/msm.o
[[ -s $linked ]]
readelf -h "$linked" | grep -E 'Machine:.*AArch64'
for function in dpu_o82_platform_init dpu_o82_platform_suspend dpu_o82_regdma_init \
    dpu_o82_regdma_can_unmap dpu_o82_upload dpu_o82_upload_release \
    dpu_o82_power_upload dpu_o82_power_recover dpu_o82_power_close \
    dpu_o82_platform_fini dpu_o82_regdma_reset_isolated \
    dpu_o82_color_init dpu_o82_color_connectors_init dpu_o82_color_check \
    dpu_o82_color_commit dpu_o82_color_gc dpu_o82_color_blocked \
    dpu_encoder_o82_stopped dpu_o82_color_fini; do
    llvm-nm --defined-only "$linked" | awk -v name="$function" '$2 ~ /^[tT]$/ && $3==name {found=1} END {exit !found}'
done
! llvm-nm --undefined-only "$linked" | grep -E ' dpu_o82_(platform|regdma|upload|lutbus|power|color|profiles)_'
# Rebuild the actual paired overlays after the retained preparation, changing
# only the explicitly declared base DT. No retained hash receipt is rewritten.
install -m644 "$addon/src/display/sm7675-uke-native-display.dtso" \
    "$profile/src/display/sm7675-uke-native-display.dtso"
usb_cpp=()
case $(cat "$profile/usb-profile") in
    peripheral) ;; typec-v1) usb_cpp+=(-DUKE_USB_TYPEC=1);; *) exit 1;;
esac
case $(cat "$profile/audio-profile") in
    disabled) ;;
    services-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1);;
    registration-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_CARD=1);;
    hdmi-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_HDMI=1);;
    speakers) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_SPEAKERS=1);;
    microphones) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_SPEAKERS=1 -DUKE_AUDIO_MICROPHONES=1);;
    *) exit 1;;
esac
UKE_NATIVE_VIDEO_SOURCE="$profile/src/video/sm7675-uke-native-video.dtso" \
    bash "$profile/src/display/generate-native-panels.sh" "$kernel" "$kernel/native-generated" \
    "$profile/src/display/sm7675-uke-native-display-oem-modes.dtso" auto "${usb_cpp[@]}"
node=/fragment@208/__overlay__/display-subsystem@ae00000/display-controller@ae01000
for supplier in 36 42; do
    overlay=$kernel/native-generated/display-$supplier.dtbo
    [[ $(fdtget -t s "$overlay" "$node" compatible) == qcom,sm7675-dpu ]]
    [[ $(fdtget -t s "$overlay" "$node" reg-names) == 'mdp vbif regdma' ]]
    [[ $(fdtget -t x "$overlay" "$node" reg) == 'ae01000 8f000 aeb0000 1074 af80000 7000' ]]
    [[ $(fdtget -t s "$overlay" "$node" clock-names) == 'bus nrt_bus iface lut core vsync' ]]
    printf 'O82-%s compiled overlay: exact MDP/VBIF/REGDMA ranges and clock names passed\n' "$supplier"
done
dt-doc-validate "$kernel/Documentation/devicetree/bindings/display/msm/qcom,sm7675-dpu.yaml"
printf '%s\n' 'Actual retained KMS hooks and linked MSM object passed; both supplier DT resource tuples and binding document passed; no DMA, HDR output or physical acceptance'
