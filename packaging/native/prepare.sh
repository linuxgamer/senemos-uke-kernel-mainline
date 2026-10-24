#!/usr/bin/env bash
# Prepare native source; the boot producer separately generates its initramfs.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass prepared kernel}")
profile=$(cd -- "$(dirname -- "$0")" && pwd)
output=$kernel/native-generated
mkdir -p "$output"
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
bash "$profile/tests/wcd939x-status-contract.sh"
bash "$profile/tests/gpu-load-contract.sh" "$kernel/drivers/gpu/drm/msm/msm_gpu_devfreq.c"
export UKE_USB_PROFILE
UKE_USB_PROFILE=$(cat "$profile/usb-profile")
case $UKE_USB_PROFILE in peripheral|typec-v1) ;; *) exit 2;; esac
usb_cpp=()
[[ $UKE_USB_PROFILE != typec-v1 ]] || usb_cpp=(-DUKE_USB_TYPEC=1)
case $(cat "$profile/audio-profile") in
    disabled) ;;
    services-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1);;
    *) printf 'Unknown audio development profile\n' >&2; exit 2;;
esac
cp "$kernel/drivers/regulator/qcom-rpmh-regulator-uke.c" "$output/rpmh-regulator-before-native.c"
bash "$profile/src/boot/prepare-abl-source.sh" "$kernel" "$output"
bash "$profile/src/display/prepare-source.sh" "$kernel"
bash "$profile/src/display/prepare-native-abl-source.sh" "$kernel" "$output" 42
# Keep the tested O82-42 source profile and compile a separate, opt-in O82-36
# graph. The latter exposes only the initial 60 Hz mode until a tablet test.
cpp -nostdinc -undef -D__DTS__ -DO82_PANEL_VARIANT=36 -x assembler-with-cpp \
    "${usb_cpp[@]}" \
    -I "$kernel/include" "$profile/src/display/sm7675-uke-native-display.dtso" > "$output/display36.dts"
dtc -q -@ -I dts -O dtb -o "$output/display36.dtbo" "$output/display36.dts"
# Replace only the generated graph with the explicit exact seven-mode profile.
cpp -nostdinc -undef -D__DTS__ -DO82_PANEL_VARIANT=42 -x assembler-with-cpp \
    "${usb_cpp[@]}" \
    -I "$kernel/include" "$profile/src/display/sm7675-uke-native-display-oem-modes.dtso" > "$output/display.dts"
dtc -q -@ -I dts -O dtb -o "$output/display.dtbo" "$output/display.dts"
{
    printf '#define UKE_NATIVE_PANEL_SELECTOR "msm_drm.dsi_display0=qcom,mdss_dsi_o82_42_02_0b_dualdsi_dsc_vid:"\n'
    printf '#define UKE_EXPERIMENTAL_PANEL_SELECTOR "msm_drm.dsi_display0=qcom,mdss_dsi_o82_36_02_0a_dualdsi_dsc_vid:"\n'
    printf 'static unsigned char uke_native_overlay[] __initdata __aligned(8) = {\n'
    od -An -v -tx1 "$output/display.dtbo" | sed -E 's/[a-f0-9]{2}/0x&,/g'
    printf '};\n'
    printf 'static unsigned char uke_native_overlay_36[] __initdata __aligned(8) = {\n'
    od -An -v -tx1 "$output/display36.dtbo" | sed -E 's/[a-f0-9]{2}/0x&,/g'
    printf '};\n'
} > "$kernel/arch/arm64/kernel/uke-native-display.h"
fdtdump "$output/display.dtbo" 2>/dev/null | grep -E '^[[:space:]]+xiaomi,oem-refresh-modes;' >/dev/null
fdtdump "$output/display36.dtbo" 2>/dev/null | grep -E '^[[:space:]]+xiaomi,initial-60hz-only;' >/dev/null
printf 'O82-42 native source and opt-in O82-36 60 Hz candidate prepared; no private boot input\n'
