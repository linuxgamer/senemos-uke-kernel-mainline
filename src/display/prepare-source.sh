#!/usr/bin/env bash
# Isolated host preparation only; does not change configuration, DT or devices.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
kernel=$(realpath "$1")
here=$(cd -- "$(dirname -- "$0")" && pwd)
version=$(jq -er .version "$kernel/senemos-adaptation/source-lock.json")
case $version in 7.2.9|7.2.10|7.2.11|7.2.12|7.3.0|7.3.1) ;; *) exit 1;; esac
[[ $(awk '/^VERSION =/ {v=$3} /^PATCHLEVEL =/ {p=$3} /^SUBLEVEL =/ {s=$3} END {print v "." p "." s}' "$kernel/Makefile") == "$version" ]]
cmp "$kernel/senemos-applied-patches.txt" <(jq -er '.patches[].path | split("/") | last' "$kernel/senemos-adaptation/source-lock.json")
patch=$here/../../patches/display/7.2.10/0001-native-display-providers.patch
paths=(
    drivers/gpu/drm/msm/disp/dpu1/catalog/dpu_10_1_sm7675.h
    drivers/gpu/drm/panel/panel-xiaomi-o82.c
    drivers/gpu/drm/panel/o82-data.h
    drivers/clk/qcom/uke-dispcc-votes.c
    drivers/interconnect/qcom/cliffs-display-icc.h
    drivers/iommu/arm/arm-smmu/uke-display-smmu.c
    drivers/gpu/drm/msm/uke-mdss-handoff.c
    include/linux/qcom-uke-display.h
    include/linux/uke-o82-touch.h
    include/drm/uke-o82-mode.h
    include/drm/uke-o82-avr.h
)
if [[ $version == 7.3.0 || $version == 7.3.1 ]]; then
    paths+=(drivers/gpu/drm/msm/dp/dp_dsc.c drivers/gpu/drm/msm/dp/dp_dsc.h)
fi
for path in "${paths[@]}"; do [[ ! -e $kernel/$path ]]; done
git -C "$kernel" apply --check "$patch"
git -C "$kernel" apply "$patch"
supplies=$here/../../patches/display/0003-native-display-supply-admission.patch
git -C "$kernel" apply --check "$supplies"
git -C "$kernel" apply "$supplies"
diagnostics=$here/../../patches/display/0004-native-dsi-diagnostics.patch
git -C "$kernel" apply --check "$diagnostics"
git -C "$kernel" apply "$diagnostics"
dsc=$here/../../patches/display/0006-native-o82-dsc-rate-control.patch
git -C "$kernel" apply --check "$dsc"
git -C "$kernel" apply "$dsc"
for candidate in 0007-native-dsc-full-ich-precision.patch 0008-native-o82-video-sequence.patch \
                 0009-native-dsc-initial-lines.patch 0010-native-o82-phy-timing.patch \
                 0011-native-dsi-read-transaction.patch \
                 0012-native-dsi-invalid-rx-diagnostics.patch \
                 0013-native-o82-phy-strength.patch \
                 0014-native-o82-retime-clock-select.patch \
                 0015-native-dpu-video-timing-master.patch \
                 0016-native-o82-host-clock-timing.patch \
                 0018-uke-o82-fll-cold-start.patch \
                 0019-uke-o82-staged-command-broadcast.patch \
                 0020-uke-single-ctl-bonded-video-flush.patch \
                 0021-uke-dsi-mdp-misr-diagnostic.patch \
                 0022-uke-o82-video-command-scheduling.patch \
                 0023-uke-o82-tp-fps-command-batch.patch \
                 0024-uke-o82-on-command-groups.patch \
                 0025-uke-o82-video-hs-timer.patch \
                 0026-native-o82-fifo-phase-diagnostics.patch \
                 0027-uke-o82-preserve-live-link-clocks.patch \
                 0028-uke-o82-command-overflow-cleanup.patch \
                 0029-uke-o82-video-command-frame-block.patch \
                 0030-uke-o82-powered-transfer-clocks.patch \
                 0031-uke-o82-post-start-lp-groups.patch \
                 0032-uke-o82-bonded-bias-replay.patch \
                 0033-uke-o82-oem-refresh-modes.patch \
                 0034-uke-o82-live-refresh-timing.patch \
                 0035-uke-o82-video-avr-experiment.patch \
                 0036-uke-o82-all-mode-avr-experiment.patch \
                 0037-uke-avr-vblank-timestamp.patch \
                 0038-uke-avr-frame-watchdog.patch \
                 0039-uke-o82-stop-source-before-video.patch \
                 0040-uke-o82-experimental-vrr-capability.patch \
                 0041-dpu-frame-watchdog-lifecycle.patch \
                 0042-uke-o82-live-avr-retiming.patch \
                 0043-uke-o82-live-avr-disable-modeset.patch \
                 0044-uke-displayport-10bpc-output.patch \
                 0045-uke-o82-fixed-10bpc-property.patch \
                 0046-uke-o82-partial-mode-vrr-range.patch \
                 0047-uke-o82-retain-touch-cadence-floor.patch \
                 0048-uke-displayport-hdr-atomic-state.patch \
                 0049-uke-displayport-disconnected-lane-limit.patch \
                 0050-uke-connector-state-73.patch \
                 0051-uke-sm7675-color-mixers.patch \
                 0052-uke-firmware-connector-identity.patch \
                 0053-uke-active-output-bits.patch \
                 0054-uke-independent-display-crtcs.patch \
                 0055-ucsi-debugfs-response-bounds.patch \
                 0056-uke-preserve-bonded-panel-resources.patch \
                 0058-uke-displayport-downstream-tmds-budget.patch; do
    patch=$here/../../patches/display/$candidate
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
done
if [[ $version == 7.3.0 || $version == 7.3.1 ]]; then
    patch=$here/../../patches/display/0059-uke-displayport-rgb-dsc-fec.patch
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
    patch=$here/../../patches/display/0060-uke-dp-clear-fec-detected-status.patch
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
    patch=$here/../../patches/display/0061-uke-dp-mst-and-negotiated-lanes.patch
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
    patch=$here/../../patches/display/0064-uke-dp-dsc-live-policy-and-recovery.patch
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
fi
for path in "${paths[@]}"; do
    source=${path##*/}
    [[ $source != uke-o82-mode.h ]] || source=o82-mode.h
    [[ $source != uke-o82-avr.h ]] || source=o82-avr.h
    install -m644 "$here/$source" "$kernel/$path"
done
printf 'Native display providers staged; kernel config and DT activation unchanged\n'
