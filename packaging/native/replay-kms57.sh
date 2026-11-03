#!/usr/bin/env bash
# Source-only replay; the complete native preparation verifies these bytes again.
set -Eeuo pipefail
sources=$(realpath "${1:?Parent source directory}")
profile=$(realpath "${2:?Parent native profile}")
fixture=$(realpath -m "${3:?New replay directory}")
[[ ! -e $fixture ]]
mkdir -p "$fixture"
files=(drivers/gpu/drm/msm/{msm_atomic.c,msm_drv.c,msm_io_utils.c,msm_iommu.c,msm_kms.c,msm_kms.h,msm_mmu.h}
 drivers/gpu/drm/msm/disp/msm_disp_snapshot.c
 drivers/gpu/drm/msm/disp/{dpu1/dpu_kms,mdp4/mdp4_kms,mdp5/mdp5_kms}.{c,h})
if [[ $# == 4 ]]; then
 mapfile -t files < <(sed 's/^[0-9a-f]*  //' "${4:?Parent file manifest}")
 [[ ${#files[@]} -gt 0 ]]
fi
paths=();includes=();for file in "${files[@]}";do paths+=("linux-7.3/$file");includes+=("--include=$file");done
tar -xJf "$sources/linux-7.3.0.tar.xz" -C "$fixture" --strip-components=1 "${paths[@]}"
tar -xJf "$sources/senemos-uke-adaptation-7.3.0.tar.xz" -C "$fixture"
git -C "$fixture" init -q
while IFS= read -r patch;do
 git -C "$fixture" apply --allow-empty "${includes[@]}" "$fixture/senemos-adaptation/patches/$patch"
done < "$fixture/senemos-adaptation/patches/series"
apply() { git -C "$fixture" apply --allow-empty "${includes[@]}" "$profile/patches/display/$1"; }
apply 0065-msm-framebuffer-pin-state.patch
apply 7.2.10/0001-native-display-providers.patch
apply 0003-native-display-supply-admission.patch
apply 0004-native-dsi-diagnostics.patch
apply 0006-native-o82-dsc-rate-control.patch
# Exact parent56 active queue; the full native byte comparison detects drift.
while IFS= read -r patch;do
 [[ $patch =~ ^[0-9]{4}-[a-z0-9-]+\.patch$ ]]
 apply "$patch"
done <<'PATCHES'
0007-native-dsc-full-ich-precision.patch
0008-native-o82-video-sequence.patch
0009-native-dsc-initial-lines.patch
0010-native-o82-phy-timing.patch
0011-native-dsi-read-transaction.patch
0012-native-dsi-invalid-rx-diagnostics.patch
0013-native-o82-phy-strength.patch
0014-native-o82-retime-clock-select.patch
0015-native-dpu-video-timing-master.patch
0016-native-o82-host-clock-timing.patch
0018-uke-o82-fll-cold-start.patch
0019-uke-o82-staged-command-broadcast.patch
0020-uke-single-ctl-bonded-video-flush.patch
0021-uke-dsi-mdp-misr-diagnostic.patch
0022-uke-o82-video-command-scheduling.patch
0023-uke-o82-tp-fps-command-batch.patch
0024-uke-o82-on-command-groups.patch
0025-uke-o82-video-hs-timer.patch
0026-native-o82-fifo-phase-diagnostics.patch
0027-uke-o82-preserve-live-link-clocks.patch
0028-uke-o82-command-overflow-cleanup.patch
0029-uke-o82-video-command-frame-block.patch
0030-uke-o82-powered-transfer-clocks.patch
0031-uke-o82-post-start-lp-groups.patch
0032-uke-o82-bonded-bias-replay.patch
0033-uke-o82-oem-refresh-modes.patch
0034-uke-o82-live-refresh-timing.patch
0035-uke-o82-video-avr-experiment.patch
0036-uke-o82-all-mode-avr-experiment.patch
0037-uke-avr-vblank-timestamp.patch
0038-uke-avr-frame-watchdog.patch
0039-uke-o82-stop-source-before-video.patch
0040-uke-o82-experimental-vrr-capability.patch
0041-dpu-frame-watchdog-lifecycle.patch
0042-uke-o82-live-avr-retiming.patch
0043-uke-o82-live-avr-disable-modeset.patch
0044-uke-displayport-10bpc-output.patch
0045-uke-o82-fixed-10bpc-property.patch
0046-uke-o82-partial-mode-vrr-range.patch
0047-uke-o82-retain-touch-cadence-floor.patch
0048-uke-displayport-hdr-atomic-state.patch
0049-uke-displayport-disconnected-lane-limit.patch
0050-uke-connector-state-73.patch
0051-uke-sm7675-color-mixers.patch
0052-uke-firmware-connector-identity.patch
0053-uke-active-output-bits.patch
0054-uke-independent-display-crtcs.patch
0055-ucsi-debugfs-response-bounds.patch
0056-uke-preserve-bonded-panel-resources.patch
0058-uke-displayport-downstream-tmds-budget.patch
0059-uke-displayport-rgb-dsc-fec.patch
0060-uke-dp-clear-fec-detected-status.patch
0061-uke-dp-mst-and-negotiated-lanes.patch
0064-uke-dp-dsc-live-policy-and-recovery.patch
0066-msm-dpu-reservation-ownership.patch
PATCHES
(cd "$fixture";sha256sum "${files[@]}")
