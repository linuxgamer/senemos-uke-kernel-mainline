#!/usr/bin/env bash
# Prepare native source; the boot producer separately generates its initramfs.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass prepared kernel}")
profile=$(cd -- "$(dirname -- "$0")" && pwd)
output=$kernel/native-generated
mkdir -p "$output"
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$kernel/drivers/gpu/drm/msm/msm_fb.c" "$output/msm-framebuffer-before55.c"
git -C "$kernel" apply --check "$profile/patches/display/0065-msm-framebuffer-pin-state.patch"
git -C "$kernel" apply "$profile/patches/display/0065-msm-framebuffer-pin-state.patch"
CC=clang bash "$profile/tests/msm-framebuffer-pin-contract.sh" "$kernel" "$output/msm-framebuffer-before55.c"
for startup_patch in 0057-llcc-optional-window.patch 0058-fs19xx-current-workqueue.patch 0059-lpass-sort-reg-defaults.patch; do
    git -C "$kernel" apply --check "$profile/patches/boot/$startup_patch"
    git -C "$kernel" apply "$profile/patches/boot/$startup_patch"
done
export UKE_LLCC_PROFILE
UKE_LLCC_PROFILE=$(cat "$profile/llcc-profile")
case $UKE_LLCC_PROFILE in disabled|native-v1) ;; *) echo 'Unknown LLCC package profile' >&2; exit 2;; esac
bash "$profile/tests/wcd939x-status-contract.sh"
bash "$profile/tests/wlan-regulator-lifetime-contract.sh" "$kernel"
CXX=clang++ bash "$profile/tests/wlan-power-contract.sh" "$kernel/drivers/net/wireless/ath/ath11k/ahb.c"
bash "$profile/tests/ucsi-partner-mode-contract.sh" "$kernel/drivers/usb/typec/ucsi/ucsi.c"
bash "$profile/tests/dispcc-dp-votes-contract.sh" "$profile/src/display/uke-dispcc-votes.c"
bash "$profile/tests/dp-aux-ddc-contract.sh" "$kernel/drivers/gpu/drm/msm/dp/dp_aux.c" "$kernel/drivers/gpu/drm/display/drm_dp_helper.c"
bash "$profile/tests/gpu-load-contract.sh" "$kernel/drivers/gpu/drm/msm/msm_gpu_devfreq.c"
bash "$profile/tests/msm-shrinker-policy-contract.sh" "$kernel/drivers/gpu/drm/msm/msm_gem_shrinker.c"
bash "$profile/tests/gpu-fault-capture-contract.sh" "$kernel/drivers/gpu/drm/msm/msm_gpu.c"
export UKE_USB_PROFILE
UKE_USB_PROFILE=$(cat "$profile/usb-profile")
case $UKE_USB_PROFILE in peripheral|typec-v1) ;; *) exit 2;; esac
usb_cpp=()
[[ $UKE_USB_PROFILE != typec-v1 ]] || usb_cpp=(-DUKE_USB_TYPEC=1)
case $(cat "$profile/audio-profile") in
    disabled) ;;
    services-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1);;
    registration-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_CARD=1);;
    hdmi-only) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_HDMI=1);;
    speakers) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_SPEAKERS=1);;
    microphones) usb_cpp+=(-DUKE_AUDIO_SERVICES=1 -DUKE_AUDIO_SPEAKERS=1 -DUKE_AUDIO_MICROPHONES=1);;
    *) printf 'Unknown audio development profile\n' >&2; exit 2;;
esac
install -m644 "$profile/src/audio/uke-audio-card.c" "$kernel/sound/soc/qcom/uke-audio-card.c"
install -m644 "$profile/src/audio/uke-microphone-gain.h" "$kernel/sound/soc/qcom/uke-microphone-gain.h"
install -m644 "$profile/src/audio/uke-dp-eld.h" "$kernel/sound/soc/qcom/uke-dp-eld.h"
alsatplg -c "$profile/src/audio/POCO-Pad-X1-AudioReach.conf" \
    -o "$output/POCO-Pad-X1-AudioReach-tplg.bin"
alsatplg -c "$profile/src/audio/POCO-Pad-X1-HDMI.conf" \
    -o "$output/POCO-Pad-X1-HDMI-tplg.bin"
if [[ $(cat "$profile/audio-profile") == microphones ]]; then
    git -C "$kernel" apply --check "$profile/patches/boot/0053-q6apm-uke-mono-capture.patch"
    git -C "$kernel" apply "$profile/patches/boot/0053-q6apm-uke-mono-capture.patch"
    git -C "$kernel" apply --check "$profile/patches/boot/0054-audioreach-read-completion-v2-layout.patch"
    git -C "$kernel" apply "$profile/patches/boot/0054-audioreach-read-completion-v2-layout.patch"
    cp "$kernel/sound/soc/codecs/lpass-tx-macro.c" "$output/lpass-tx-macro-before0055.c"
    git -C "$kernel" apply --check "$profile/patches/boot/0055-lpass-tx-macro-multichannel-state.patch"
    git -C "$kernel" apply "$profile/patches/boot/0055-lpass-tx-macro-multichannel-state.patch"
    CC=clang bash "$profile/tests/lpass-tx-multichannel-contract.sh" "$kernel" "$output/lpass-tx-macro-before0055.c"
    cp "$kernel/sound/soc/qcom/qdsp6/q6apm-dai.c" "$output/q6apm-dai-before0056.c"
    git -C "$kernel" apply --check "$profile/patches/boot/0056-q6apm-uke-raw-microphone-channel-map.patch"
    git -C "$kernel" apply "$profile/patches/boot/0056-q6apm-uke-raw-microphone-channel-map.patch"
    CC=clang bash "$profile/tests/microphone-channel-map-contract.sh" "$kernel" "$output/q6apm-dai-before0056.c"
    CC=clang bash "$profile/tests/audio-graph-response-contract.sh" "$kernel"
    bash "$profile/tests/microphone-pcm-limits-contract.sh" "$kernel"
    sha256sum "$profile/patches/boot/0053-q6apm-uke-mono-capture.patch" >> "$output/abl-source-SHA256SUMS"
    sha256sum "$profile/patches/boot/0054-audioreach-read-completion-v2-layout.patch" >> "$output/abl-source-SHA256SUMS"
    sha256sum "$profile/patches/boot/0055-lpass-tx-macro-multichannel-state.patch" >> "$output/abl-source-SHA256SUMS"
    sha256sum "$profile/patches/boot/0056-q6apm-uke-raw-microphone-channel-map.patch" >> "$output/abl-source-SHA256SUMS"
    cat "$profile/src/audio/POCO-Pad-X1.conf" \
        "$profile/src/audio/POCO-Pad-X1-Microphone-Capture.conf" > "$output/POCO-Pad-X1.conf"
    alsatplg -c "$output/POCO-Pad-X1.conf" -o "$output/POCO-Pad-X1-tplg.bin"
else
    alsatplg -c "$profile/src/audio/POCO-Pad-X1.conf" -o "$output/POCO-Pad-X1-tplg.bin"
fi
cp "$kernel/drivers/regulator/qcom-rpmh-regulator-uke.c" "$output/rpmh-regulator-before-native.c"
bash "$profile/src/boot/prepare-abl-source.sh" "$kernel" "$output"
bash "$profile/src/power/prepare-memlat.sh" "$kernel"
bash "$profile/tests/memlat-policy-contract.sh"
bash "$profile/tests/memlat-dt-contract.sh"
bash "$profile/src/performance/prepare-source.sh" "$kernel"
bash "$profile/src/nfc/prepare-source.sh" "$kernel"
git -C "$kernel" apply --check "$profile/patches/input/0001-smp2p-lid-open-wake.patch"
git -C "$kernel" apply "$profile/patches/input/0001-smp2p-lid-open-wake.patch"
bash "$profile/tests/lid-wake-contract.sh" "$kernel"
git -C "$kernel" apply --check "$profile/patches/boot/0010-qcom-flash-bounded-cleanup.patch"
git -C "$kernel" apply "$profile/patches/boot/0010-qcom-flash-bounded-cleanup.patch"
bash "$profile/tests/light-cleanup.sh" "$kernel/drivers/leds/flash/leds-qcom-flash.c"
git -C "$kernel" apply --check "$profile/patches/boot/0011-qcom-flash-torch-steps.patch"
git -C "$kernel" apply "$profile/patches/boot/0011-qcom-flash-torch-steps.patch"
bash "$profile/tests/light-brightness.sh" "$kernel/drivers/leds/flash/leds-qcom-flash.c"
bash "$profile/src/leds/prepare-source.sh" "$kernel"
bash "$profile/src/display/prepare-source.sh" "$kernel"
reservation_baseline=$output/dpu-reservation-before56
for relative in drivers/gpu/drm/msm/msm_atomic.c drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c; do
    install -Dm644 "$kernel/$relative" "$reservation_baseline/$relative"
done
git -C "$kernel" apply --check "$profile/patches/display/0066-msm-dpu-reservation-ownership.patch"
git -C "$kernel" apply "$profile/patches/display/0066-msm-dpu-reservation-ownership.patch"
CC=clang bash "$profile/tests/dpu-reservation-contract.sh" "$kernel" "$reservation_baseline"
lifecycle_baseline=$output/msm-kms-before57
(cd "$kernel"; sha256sum --check --strict --quiet "$profile/kms57-parent-files.sha256")
while IFS= read -r relative; do
    install -Dm644 "$kernel/$relative" "$lifecycle_baseline/$relative"
done < <(sed 's/^[0-9a-f]*  //' "$profile/kms57-parent-files.sha256")
git -C "$kernel" apply --check "$profile/patches/display/0067-msm-kms-lifecycle-unwind.patch"
git -C "$kernel" apply "$profile/patches/display/0067-msm-kms-lifecycle-unwind.patch"
CC=clang bash "$profile/tests/msm-kms-lifecycle-contract.sh" "$kernel" "$lifecycle_baseline"
CC=clang bash "$profile/tests/msm-kms-unwind-contract.sh" "$kernel" "$lifecycle_baseline"
retirement_baseline=$output/msm-retirement-before58
(cd "$kernel"; sha256sum --check --strict --quiet "$profile/retirement60-parent-files.sha256")
while IFS= read -r relative; do
    install -Dm644 "$kernel/$relative" "$retirement_baseline/$relative"
done < <(sed 's/^[0-9a-f]*  //' "$profile/retirement60-parent-files.sha256")
git -C "$kernel" apply --check "$profile/patches/display/0068-msm-scanout-retirement.patch"
git -C "$kernel" apply "$profile/patches/display/0068-msm-scanout-retirement.patch"
CC=clang bash "$profile/tests/msm-retirement-contract.sh" "$kernel" "$retirement_baseline"
CC=clang bash "$profile/tests/msm-writeback-contract.sh" "$kernel" "$retirement_baseline"
CC=clang bash "$profile/tests/msm-retirement-proof-contract.sh" "$kernel"
CC=clang bash "$profile/tests/o82-avr-contract.sh" "$kernel"
CXX=clang++ bash "$profile/tests/dpu-video-timing-contract.sh" "$kernel"
bash "$profile/tests/altmode-worker-contract.sh" "$kernel/drivers/soc/qcom/pmic_glink_altmode.c"
bash "$profile/tests/dp-altmode-retimer-contract.sh" "$kernel/drivers/soc/qcom/pmic_glink_altmode.c"
bash "$profile/tests/usb-qmp-mux-contract.sh" "$kernel/drivers/phy/qualcomm/phy-qcom-qmp-combo.c"
bash "$profile/tests/dpu-color-topology-contract.sh" "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c"
bash "$profile/tests/firmware-connector-identity-contract.sh" "$kernel/drivers/gpu/drm/sysfb/simpledrm.c"
bash "$profile/tests/output-bits-contract.sh" "$kernel"
bash "$profile/tests/dpu-output-affinity-contract.sh" "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_kms.c"
bash "$profile/tests/ucsi-debugfs-bounds-contract.sh" "$kernel/drivers/usb/typec/ucsi/debugfs.c"
bash "$profile/tests/dpu-mixer-reservation-contract.sh" "$kernel/drivers/gpu/drm/msm/disp/dpu1/dpu_rm.c"
bash "$profile/tests/dp-hdr-contract.sh" "$kernel"
bash "$profile/tests/dsi-connector-state-contract.sh" "$kernel"
bash "$profile/tests/dsi-color-depth-contract.sh" "$kernel/drivers/gpu/drm/msm/dsi/dsi_manager.c"
bash "$profile/tests/dp-connector-state-contract.sh" "$kernel/drivers/gpu/drm/msm/dp/dp_drm.c"
bash "$profile/tests/dp-stream-lifetime-contract.sh" "$kernel"
bash "$profile/tests/dp-mst-payload-contract.sh" "$kernel/drivers/gpu/drm/msm/dp/dp_mst_drm.c"
bash "$profile/tests/dp-mst-control-contract.sh" "$kernel/drivers/gpu/drm/msm/dp/dp_ctrl.c"
bash "$profile/tests/dp-lane-limit-contract.sh" "$kernel"
bash "$profile/src/input/prepare-source.sh" "$kernel"
bash "$profile/src/display/prepare-native-abl-source.sh" "$kernel" "$output" auto
if [[ $(cat "$profile/audio-profile") =~ ^(hdmi-only|speakers|microphones)$ ]]; then
    git -C "$kernel" apply --check "$profile/patches/boot/0009-uke-displayport-dma-scope.patch"
    git -C "$kernel" apply "$profile/patches/boot/0009-uke-displayport-dma-scope.patch"
    bash "$profile/tests/dp-audio-admission-contract.sh" "$kernel"
    sha256sum "$profile/patches/boot/0009-uke-displayport-dma-scope.patch" >> "$output/abl-source-SHA256SUMS"
    if [[ $(jq -er .version "$kernel/senemos-adaptation/source-lock.json") == 7.3.[01] ]]; then
        git -C "$kernel" apply --check "$profile/patches/display/0057-uke-displayport-eld-notification.patch"
        git -C "$kernel" apply "$profile/patches/display/0057-uke-displayport-eld-notification.patch"
        bash "$profile/tests/dp-eld-notification-contract.sh" "$kernel/sound/soc/codecs/hdmi-codec.c"
    fi
fi
bash "$profile/src/video/prepare-source.sh" "$kernel"
# NSP shares SH1 with the native display and video paths prepared above.
for cdsp_patch in 0025-cliffs-nsp-crypto-suppliers.patch \
    0026-cliffs-proxy-and-pas-stop-ownership.patch 0027-remoteproc-early-stop.patch \
    0028-cliffs-proxy-per-rail-ownership.patch; do
    git -C "$kernel" apply --check "$profile/patches/boot/$cdsp_patch"
    git -C "$kernel" apply "$profile/patches/boot/$cdsp_patch"
done
bash "$profile/tests/uke-rpmh-resource-contract.sh" "$kernel/drivers/regulator/qcom-rpmh-regulator-uke.c" before-nfc
git -C "$kernel" apply --check "$profile/patches/boot/0033-uke-nfc-regulator-resource.patch"
git -C "$kernel" apply "$profile/patches/boot/0033-uke-nfc-regulator-resource.patch"
bash "$profile/tests/uke-rpmh-resource-contract.sh" "$kernel/drivers/regulator/qcom-rpmh-regulator-uke.c" before-audio
git -C "$kernel" apply --check "$profile/patches/boot/0044-uke-microphone-bob-supply.patch"
git -C "$kernel" apply "$profile/patches/boot/0044-uke-microphone-bob-supply.patch"
sha256sum "$profile/patches/boot/0044-uke-microphone-bob-supply.patch" >> "$output/abl-source-SHA256SUMS"
bash "$profile/tests/qup-interconnect-contract.sh" "$kernel/drivers/interconnect/qcom/qnoc-cliffs-usb.c" 1
bash "$profile/tests/uke-rpmh-resource-contract.sh" "$kernel/drivers/regulator/qcom-rpmh-regulator-uke.c" native
SANITIZE=1 bash "$profile/tests/wpss-proxy-contract.sh" "$kernel/drivers/remoteproc/qcom_q6v5_pas.c"
bash "$profile/tests/pas-stop-ownership-contract.sh" "$kernel/drivers/remoteproc/qcom_q6v5_pas.c"
bash "$profile/tests/rproc-early-stop-contract.sh" "$kernel/drivers/remoteproc/remoteproc_core.c"
bash "$profile/tests/sysmon-stop-preparation-contract.sh" "$kernel/drivers/remoteproc/qcom_sysmon.c"
# Each supplier gets the same video/audio/USB graph and its own panel compatible.
UKE_NATIVE_VIDEO_SOURCE="$profile/src/video/sm7675-uke-native-video.dtso" \
    bash "$profile/src/display/generate-native-panels.sh" "$kernel" "$output" \
    "$profile/src/display/sm7675-uke-native-display-oem-modes.dtso" auto "${usb_cpp[@]}"
for variant in 36 42; do
    fdtdump "$output/display-$variant.dtbo" 2>/dev/null | grep -E '^[[:space:]]+xiaomi,oem-refresh-modes;' >/dev/null
done
if [[ $(cat "$profile/audio-profile") == hdmi-only ]]; then
    bash "$profile/tests/dp-audio-fdt-contract.sh" "$kernel"
    bash "$profile/tests/dp-audio-topology-contract.sh"
fi
if [[ $(cat "$profile/audio-profile") =~ ^(speakers|microphones)$ ]]; then
    bash "$profile/tests/speaker-audio-fdt-contract.sh" "$kernel"
    bash "$profile/tests/speaker-audio-topology-contract.sh"
fi
if [[ $(cat "$profile/audio-profile") == microphones ]]; then
    bash "$profile/tests/microphone-audio-fdt-contract.sh" "$kernel"
    bash "$profile/tests/microphone-audio-topology-contract.sh"
    bash "$profile/tests/microphone-audio-card-contract.sh"
fi
# Preserve the historical KMS source receipts before this explicit AVR opt-in.
git -C "$kernel" apply --check "$profile/patches/display/0069-o82-requested-vrr-floor.patch"
git -C "$kernel" apply "$profile/patches/display/0069-o82-requested-vrr-floor.patch"
bash "$profile/tests/o82-vrr-floor-contract.sh" "$kernel"
# Optional panel CABC control follows the frozen KMS source receipts above.
git -C "$kernel" apply --check "$profile/patches/display/0070-o82-adaptive-backlight.patch"
git -C "$kernel" apply "$profile/patches/display/0070-o82-adaptive-backlight.patch"
CC=clang bash "$profile/tests/o82-panel-contract.sh" "$profile/src/display/panel-xiaomi-o82.c" \
    "$profile/src/display/o82-data.h" "$kernel"
bash "$profile/tests/o82-abm-contract.sh" "$kernel" "$profile/src/display/panel-xiaomi-o82.c"
CC=clang SANITIZE=1 bash "$profile/tests/o82-abm-contract.sh" "$kernel" "$profile/src/display/panel-xiaomi-o82.c"
sha256sum "$profile/patches/display/0070-o82-adaptive-backlight.patch" >> "$output/abl-source-SHA256SUMS"
# Extend the scoped host/manager policy only after the historical source receipts.
git -C "$kernel" apply --check "$profile/patches/display/0071-o82-panel-variants.patch"
git -C "$kernel" apply "$profile/patches/display/0071-o82-panel-variants.patch"
bash "$profile/tests/o82-variants-contract.sh" "$kernel"
bash "$profile/tests/o82-variants-dt-contract.sh" "$kernel" "${usb_cpp[@]}"
sha256sum "$profile/patches/display/0071-o82-panel-variants.patch" >> "$output/abl-source-SHA256SUMS"
printf 'Exact seven-mode O82-36/O82-42 native source prepared; hardware validation remains variant-specific\n'
# Retain the independently verified USB role/PM correction from release1020.
cp "$kernel/drivers/usb/dwc3/dwc3-qcom.c" "$output/dwc3-qcom-before-role-pm.c"
git -C "$kernel" apply --check "$profile/patches/usb/0001-qcom-system-role-pm.patch"
git -C "$kernel" apply "$profile/patches/usb/0001-qcom-system-role-pm.patch"
CC=clang bash "$profile/tests/usb-role-pm-contract.sh" \
    "$kernel/drivers/usb/dwc3/dwc3-qcom.c" "$output/dwc3-qcom-before-role-pm.c"
