#!/usr/bin/env bash
# Host-only preparation on an isolated, already qualified ordered source tree.
set -Eeuo pipefail
[[ $# == 2 && -d $1 && -d $2 ]] || exit 2
kernel=$(realpath "$1") output=$(realpath "$2")
here=$(cd -- "$(dirname -- "$0")" && pwd)
usb_profile=${UKE_USB_PROFILE:-peripheral}
case $usb_profile in peripheral|typec-v1) ;; *) echo 'Unknown USB source profile' >&2; exit 2;; esac
llcc_profile=${UKE_LLCC_PROFILE:-disabled}
case $llcc_profile in
    disabled) llcc_native=0;;
    native-v1) llcc_native=1;;
    *) echo 'Unknown LLCC source profile' >&2; exit 2;;
esac
version=$(jq -er .version "$kernel/senemos-adaptation/source-lock.json")
case $version in 7.2.9|7.2.10|7.2.11|7.2.12|7.3.0|7.3.1) ;; *) exit 1;; esac
series=$(jq -er '.patch_series // .version' "$kernel/senemos-adaptation/source-lock.json")
case $series in 7.2.9|7.2.10|7.2.11|7.2.12|7.3.0) ;; *) exit 1;; esac
[[ $(awk '/^VERSION =/ {v=$3} /^PATCHLEVEL =/ {p=$3} /^SUBLEVEL =/ {s=$3} END {print v "." p "." s}' "$kernel/Makefile") == "$version" ]]
cmp "$kernel/senemos-applied-patches.txt" <(jq -er '.patches[].path | split("/") | last' "$kernel/senemos-adaptation/source-lock.json")
bash "$here/../../tests/resin-wake-contract.sh" "$kernel"
git -C "$kernel" apply --check "$here/../../patches/boot/0045-gunyah-arm-bounded-boot-watchdog.patch"
git -C "$kernel" apply "$here/../../patches/boot/0045-gunyah-arm-bounded-boot-watchdog.patch"
bash "$here/../../tests/gunyah-boot-watchdog-contract.sh" "$kernel/drivers/watchdog/gunyah_wdt.c"
if [[ $llcc_native == 1 ]]; then
    bash "$here/../../tests/llcc-sm7675-contract.sh" "$kernel"
    bash "$here/../../tests/llcc-gpu-startup-contract.sh" "$kernel/drivers/gpu/drm/msm/adreno/adreno_device.c"
    bash "$here/../../tests/llcc-boot-fdt-contract.sh" "$kernel"
fi
# Wi-Fi requires the package-owned RF/GENI/SMMU contract; older pairs keep their frozen recipe.
grep -Fxq 0015-uke-wlan-supplies-and-dma.patch "$kernel/senemos-applied-patches.txt"
grep -Fxq 0016-uke-wlan-ordered-rails.patch "$kernel/senemos-applied-patches.txt"
# The second backlight bus requires its own NoC and translated-DMA admission.
grep -Fxq 0023-uke-qup1-backlight-bus.patch "$kernel/senemos-applied-patches.txt"
grep -Fxq 0025-uke-paired-normal-backlight.patch "$kernel/senemos-applied-patches.txt"
grep -Fxq 0026-cliffs-lpass-adsp-interconnect.patch "$kernel/senemos-applied-patches.txt"
grep -Fxq 0036-uke-adreno732-render.patch "$kernel/senemos-applied-patches.txt"
grep -Fxq 0037-uke-gpu-interconnect.patch "$kernel/senemos-applied-patches.txt"
hook_args=(--exclude=drivers/regulator/qcom-rpmh-regulator-uke.c --exclude=drivers/iommu/arm/arm-smmu/arm-smmu-qcom.c)
git -C "$kernel" apply --check "${hook_args[@]}" "$here/../../patches/boot/0001-arm64-uke-abl-dt-hook.patch"
git -C "$kernel" apply "${hook_args[@]}" "$here/../../patches/boot/0001-arm64-uke-abl-dt-hook.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0002-uke-sensor-context-banks.patch"
git -C "$kernel" apply "$here/../../patches/boot/0002-uke-sensor-context-banks.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0003-uke-socinfo-sensor-profile.patch"
git -C "$kernel" apply "$here/../../patches/boot/0003-uke-socinfo-sensor-profile.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0004-uke-bluetooth-power.patch"
git -C "$kernel" apply "$here/../../patches/boot/0004-uke-bluetooth-power.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0005-uke-root-selector.patch"
git -C "$kernel" apply "$here/../../patches/boot/0005-uke-root-selector.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0006-uke-uart-wake-order.patch"
git -C "$kernel" apply "$here/../../patches/boot/0006-uke-uart-wake-order.patch"
bash "$here/../../tests/uart-wake-contract.sh" "$kernel/drivers/tty/serial/qcom_geni_serial.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0007-uke-cpu-hardware-name.patch"
git -C "$kernel" apply "$here/../../patches/boot/0007-uke-cpu-hardware-name.patch"
bash "$here/../../tests/cpu-hardware-name-contract.sh" "$kernel/arch/arm64/kernel/cpuinfo.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0013-sm7675-trng-binding.patch"
git -C "$kernel" apply "$here/../../patches/boot/0013-sm7675-trng-binding.patch"
install -m644 "$here/uke-ufs-mcq.h" "$kernel/drivers/ufs/host/ufs-qcom-uke.h"
git -C "$kernel" apply --check "$here/../../patches/boot/0014-uke-ufs-mcq-resources.patch"
git -C "$kernel" apply "$here/../../patches/boot/0014-uke-ufs-mcq-resources.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0015-ufs-mcq-preserve-sdb-on-allocation-failure.patch"
git -C "$kernel" apply "$here/../../patches/boot/0015-ufs-mcq-preserve-sdb-on-allocation-failure.patch"
bash "$here/../../tests/ufs-mcq-contract.sh" "$kernel"
bash "$here/../../tests/ufs-mcq-allocation-contract.sh" "$kernel"
for audio_patch in 0016-wcd939x-channel-switches.patch 0017-wcd939x-provider-errors.patch \
    0018-wcd939x-coordinated-reset.patch 0019-sm7675-lpass-pinctrl.patch \
    0020-soundwire-probe-errors.patch 0043-wcd939x-micbias-errors.patch \
    0045-wcd939x-uke-supply-order.patch 0046-wcd939x-chip-identification-errors.patch \
    0047-wcd939x-uke-reset-required.patch 0048-uke-soundwire-machine-dependency.patch \
    0049-wcd939x-io-errors.patch \
    0050-soundwire-resume-clock-error.patch; do
    git -C "$kernel" apply --check "$here/../../patches/boot/$audio_patch"
    git -C "$kernel" apply "$here/../../patches/boot/$audio_patch"
done
bash "$here/../../tests/wcd939x-channel-switch-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-probe-error-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-reset-consumer-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-micbias-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-supply-order-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-chip-info-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-io-contract.sh" "$kernel"
bash "$here/../../tests/wcd939x-reset-contract.sh" "$here/../usb/wcd939x-uke-typec.c"
bash "$here/../../tests/usbss-reset-lifetime-contract.sh" "$here/../usb/wcd939x-uke-typec.c"
bash "$here/../../tests/soundwire-probe-error-contract.sh" "$kernel"
bash "$here/../../tests/soundwire-resume-clock-contract.sh" "$kernel"
bash "$here/../../tests/lpass-sm7675-pins-contract.sh" "$kernel"
bash "$here/../../tests/audio-providers-fdt-contract.sh" "$kernel"
bash "$here/../../tests/speaker-audio-fdt-contract.sh" "$kernel"
git -C "$kernel" apply --check "$here/../../patches/boot/0021-bwmon-preserve-applied-vote-on-error.patch"
git -C "$kernel" apply "$here/../../patches/boot/0021-bwmon-preserve-applied-vote-on-error.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0029-sm7675-bwmon-byte-units-and-read-recovery.patch"
git -C "$kernel" apply "$here/../../patches/boot/0029-sm7675-bwmon-byte-units-and-read-recovery.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0030-osm-l3-admit-clocks-lut-and-graph.patch"
git -C "$kernel" apply "$here/../../patches/boot/0030-osm-l3-admit-clocks-lut-and-graph.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0031-opp-restore-bandwidth-and-retry-incomplete-votes.patch"
git -C "$kernel" apply "$here/../../patches/boot/0031-opp-restore-bandwidth-and-retry-incomplete-votes.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0032-sm7675-paired-cpu-l3-bandwidth.patch"
git -C "$kernel" apply "$here/../../patches/boot/0032-sm7675-paired-cpu-l3-bandwidth.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0034-sm7675-l3-bound-initial-icc-floor.patch"
git -C "$kernel" apply "$here/../../patches/boot/0034-sm7675-l3-bound-initial-icc-floor.patch"
bash "$here/../../tests/bwmon-vote-error-contract.sh" "$kernel/drivers/soc/qcom/icc-bwmon.c"
bash "$here/../../tests/bwmon-counter-contract.sh" "$kernel/drivers/soc/qcom/icc-bwmon.c"
bash "$here/../../tests/bwmon-dt-contract.sh"
bash "$here/../../tests/l3-provider-contract.sh" "$kernel"
bash "$here/../../tests/opp-bandwidth-transaction-contract.sh" "$kernel"
bash "$here/../../tests/cpu-bwmon-dt-contract.sh"
# The BCL proposal depends on the matching hwmon core emergency attributes.
for bcl_patch in 0038-hwmon-emergency-attributes.patch \
    0035-qcom-bcl-hwmon-binding.patch 0036-qcom-bcl-hwmon-driver.patch \
    0037-bcl-report-unavailable-voltage.patch 0039-bcl-alarm-wake-lifetime.patch \
    0040-uke-pm7550ba-bcl-admission.patch 0042-bcl-report-empty-current.patch; do
    git -C "$kernel" apply --check "$here/../../patches/boot/$bcl_patch"
    git -C "$kernel" apply "$here/../../patches/boot/$bcl_patch"
done
bash "$here/../../tests/bcl-hwmon-contract.sh" "$kernel/drivers/hwmon/qcom-bcl-hwmon.c"
bash "$here/../../tests/bcl-alarm-lifetime-contract.sh" "$kernel/drivers/hwmon/qcom-bcl-hwmon.c"
bash "$here/../../tests/bcl-uke-admission-contract.sh" "$kernel/drivers/hwmon/qcom-bcl-hwmon.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0043-uke-pm8010-firmware-population.patch"
git -C "$kernel" apply "$here/../../patches/boot/0043-uke-pm8010-firmware-population.patch"
install -m644 "$here/../power/uke-pm8010.h" "$kernel/drivers/mfd/uke-pm8010.h"
bash "$here/../../tests/pm8010-population-contract.sh" "$kernel"
git -C "$kernel" apply --check "$here/../../patches/boot/0051-cpufreq-preserve-boost-state-on-error.patch"
git -C "$kernel" apply "$here/../../patches/boot/0051-cpufreq-preserve-boost-state-on-error.patch"
bash "$here/../../tests/cpufreq-boost-error-contract.sh" "$kernel/drivers/cpufreq/cpufreq.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0055-cpufreq-lmh-policy-lifecycle.patch"
git -C "$kernel" apply "$here/../../patches/boot/0055-cpufreq-lmh-policy-lifecycle.patch"
git -C "$kernel" apply --check "$here/../../patches/boot/0060-cpufreq-lmh-ready-lifecycle.patch"
git -C "$kernel" apply "$here/../../patches/boot/0060-cpufreq-lmh-ready-lifecycle.patch"
bash "$here/../../tests/cpufreq-lmh-lifecycle-contract.sh" "$kernel/drivers/cpufreq/qcom-cpufreq-hw.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0052-scmi-protocol-negotiation-opt-out.patch"
git -C "$kernel" apply "$here/../../patches/boot/0052-scmi-protocol-negotiation-opt-out.patch"
bash "$here/../../tests/scmi-no-negotiation-contract.sh" "$kernel/drivers/firmware/arm_scmi/driver.c"
bash "$here/../power/prepare-cpucp-observe.sh" "$kernel"
for cdsp_patch in 0022-mdt-admit-geometry-and-metadata.patch \
    0023-fastrpc-own-coherent-dma-handle.patch 0024-rproc-retry-transport-stop.patch; do
    git -C "$kernel" apply --check "$here/../../patches/boot/$cdsp_patch"
    git -C "$kernel" apply "$here/../../patches/boot/$cdsp_patch"
done
SANITIZE=1 bash "$here/../../tests/mdt-memory-admission-contract.sh" "$kernel/drivers/soc/qcom/mdt_loader.c"
bash "$here/../../tests/mdt-metadata-contract.sh" "$kernel/drivers/soc/qcom/mdt_loader.c"
SANITIZE=1 bash "$here/../../tests/fastrpc-buffer-lifetime-contract.sh" "$kernel/drivers/misc/fastrpc.c"
SANITIZE=1 bash "$here/../../tests/rproc-edge-stop-contract.sh" "$kernel/drivers/remoteproc/qcom_common.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0008-uke-platform-profile.patch"
git -C "$kernel" apply "$here/../../patches/boot/0008-uke-platform-profile.patch"
install -m644 "$here/../power/uke-platform-profile.c" "$kernel/drivers/soc/qcom/uke-platform-profile.c"
install -m644 "$here/uke-abl.c" "$kernel/arch/arm64/kernel/uke-abl.c"
install -m644 "$here/uke-ufs.h" "$kernel/arch/arm64/kernel/uke-ufs.h"
install -m644 "$here/uke-identity.c" "$kernel/arch/arm64/kernel/uke-identity.c"
install -m644 "$here/uke-hardware.h" "$kernel/arch/arm64/kernel/uke-hardware.h"
install -m644 "$here/uke-bwmon.h" "$kernel/arch/arm64/kernel/uke-bwmon.h"
install -m644 "$here/uke-cpu-bwmon.h" "$kernel/arch/arm64/kernel/uke-cpu-bwmon.h"
install -Dm644 "$here/bindings/firmware/xiaomi,uke-ssc-sensors.yaml" "$kernel/Documentation/devicetree/bindings/firmware/xiaomi,uke-ssc-sensors.yaml"
install -Dm644 "$here/bindings/firmware/xiaomi,uke-accessory-profile.yaml" "$kernel/Documentation/devicetree/bindings/firmware/xiaomi,uke-accessory-profile.yaml"
install -m644 "$here/uke-llcc.h" "$kernel/arch/arm64/kernel/uke-llcc.h"
printf '#define UKE_LLCC_NATIVE_PROFILE %s\n' "$llcc_native" > "$kernel/arch/arm64/kernel/uke-llcc-profile.h"
install -m644 "$here/uke-root-selector.h" "$kernel/arch/arm64/kernel/uke-root-selector.h"
install -m644 "$here/uke-bluetooth.h" "$kernel/arch/arm64/kernel/uke-bluetooth.h"
install -m644 "$here/uke-pmic-adc.h" "$kernel/arch/arm64/kernel/uke-pmic-adc.h"
install -m644 "$here/uke-cpu-thermal.h" "$kernel/arch/arm64/kernel/uke-cpu-thermal.h"
install -m644 "$here/uke-clock-debug.h" "$kernel/arch/arm64/kernel/uke-clock-debug.h"
bash "$here/../../tests/clock-debug-fdt-contract.sh" "$kernel"
install -m644 "$here/uke-hall.h" "$kernel/arch/arm64/kernel/uke-hall.h"
install -m644 "$here/uke-lights.h" "$kernel/arch/arm64/kernel/uke-lights.h"
install -m644 "$here/../usb/wcd939x-uke-typec.c" "$kernel/drivers/usb/typec/mux/wcd939x-uke-typec.c"
[[ $(sha256sum "$here/vendor/fdt_check.c" | cut -d ' ' -f1) == "$(jq -er .sha256 "$here/vendor/source.json")" ]]
grep -F 'DTC 1.7.2-g53373d13' "$kernel/scripts/dtc/version_gen.h" >/dev/null
install -m644 "$here/vendor/fdt_check.c" "$kernel/scripts/dtc/libfdt/fdt_check.c"
for name in overlay check; do
    {
        printf '// SPDX-License-Identifier: GPL-2.0-only\n#include <linux/libfdt_env.h>\n'
        # The embedded, source-compiled overlays contain bounded decimal
        # fixup offsets. Upstream libfdt's libc parser needs the kernel API.
        if [[ $name == overlay ]]; then
            printf '#include <linux/kstrtox.h>\n#define strtoul simple_strtoul\n'
        fi
        printf '#include "../scripts/dtc/libfdt/fdt_%s.c"\n' "$name"
    } > "$kernel/lib/fdt_$name.c"
done
header=$kernel/arch/arm64/kernel/uke-abl-overlays.h
: > "$header"
for name in ufs usb lights; do
    source=$here/sm7675-uke-ufs.dtso
    [[ $name != usb ]] || source=$here/sm7675-uke-usb2.dtso
    [[ $name != lights ]] || source=$here/sm7675-uke-lights.dtso
    if [[ $name == usb && $usb_profile == typec-v1 ]]; then source=$here/sm7675-uke-typec.dtso; fi
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$kernel/include" "$source" > "$output/$name.dts"
    dtc -q -@ -I dts -O dtb -o "$output/$name.dtbo" "$output/$name.dts"
    {
        printf 'static unsigned char uke_%s_overlay[] __initdata __aligned(8) = {\n' "$name"
        od -An -v -tx1 "$output/$name.dtbo" | sed -E 's/[a-f0-9]{2}/0x&,/g'
        printf '};\n'
    } >> "$header"
done
printf '%s\n' "$usb_profile" > "$output/usb-profile"
printf '%s\n' "$llcc_profile" > "$output/llcc-profile"
(cd "$output"; sha256sum ufs.dtbo usb.dtbo lights.dtbo > overlay-SHA256SUMS)
sha256sum "$here/uke-abl.c" "$here/uke-ufs.h" "$here/uke-identity.c" "$here/uke-hardware.h" "$here/uke-bluetooth.h" "$here/vendor/fdt_check.c" "$here/vendor/source.json" \
    "$here/uke-pmic-adc.h" "$here/uke-cpu-thermal.h" "$here/uke-hall.h" \
    "$here/../../patches/boot/0001-arm64-uke-abl-dt-hook.patch" \
    "$here/../../patches/boot/0002-uke-sensor-context-banks.patch" \
    "$here/../../patches/boot/0003-uke-socinfo-sensor-profile.patch" \
    "$here/../../patches/boot/0004-uke-bluetooth-power.patch" \
    "$here/../../patches/boot/0013-sm7675-trng-binding.patch" \
    "$here/uke-ufs-mcq.h" "$here/../../patches/boot/0014-uke-ufs-mcq-resources.patch" \
    "$here/../../patches/boot/0015-ufs-mcq-preserve-sdb-on-allocation-failure.patch" \
    "$here/../../patches/$series/0036-uke-adreno732-render.patch" \
    "$here/../../patches/$series/0037-uke-gpu-interconnect.patch" \
    "$here/sm7675-uke-adreno732.dtsi" "$header" > "$output/abl-source-SHA256SUMS"
sha256sum "$here/sm7675-uke-pinctrl.dtsi" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/uke-bwmon.h" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/uke-cpu-bwmon.h" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/uke-root-selector.h" "$here/../../patches/boot/0005-uke-root-selector.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0045-gunyah-arm-bounded-boot-watchdog.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0006-uke-uart-wake-order.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0007-uke-cpu-hardware-name.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0008-uke-platform-profile.patch" \
    "$here/../power/uke-platform-profile.c" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/uke-llcc.h" "$kernel/arch/arm64/kernel/uke-llcc-profile.h" \
    "$output/llcc-profile" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../audio/sm7675-uke-audio-providers.dtsi" \
    "$here/../audio/sm7675-uke-speaker-audio.dtsi" \
    "$here/../audio/sm7675-uke-microphone-audio.dtsi" >> "$output/abl-source-SHA256SUMS"
for audio_patch in 0016-wcd939x-channel-switches.patch 0017-wcd939x-provider-errors.patch \
    0018-wcd939x-coordinated-reset.patch 0019-sm7675-lpass-pinctrl.patch \
    0020-soundwire-probe-errors.patch 0043-wcd939x-micbias-errors.patch \
    0045-wcd939x-uke-supply-order.patch 0046-wcd939x-chip-identification-errors.patch \
    0047-wcd939x-uke-reset-required.patch 0048-uke-soundwire-machine-dependency.patch \
    0049-wcd939x-io-errors.patch \
    0050-soundwire-resume-clock-error.patch; do
    sha256sum "$here/../../patches/boot/$audio_patch" >> "$output/abl-source-SHA256SUMS"
done
sha256sum "$here/../../patches/boot/0021-bwmon-preserve-applied-vote-on-error.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0029-sm7675-bwmon-byte-units-and-read-recovery.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0030-osm-l3-admit-clocks-lut-and-graph.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0031-opp-restore-bandwidth-and-retry-incomplete-votes.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0032-sm7675-paired-cpu-l3-bandwidth.patch" >> "$output/abl-source-SHA256SUMS"
sha256sum "$here/../../patches/boot/0034-sm7675-l3-bound-initial-icc-floor.patch" >> "$output/abl-source-SHA256SUMS"
for cdsp_patch in 0022-mdt-admit-geometry-and-metadata.patch \
    0023-fastrpc-own-coherent-dma-handle.patch 0024-rproc-retry-transport-stop.patch \
    0025-cliffs-nsp-crypto-suppliers.patch 0026-cliffs-proxy-and-pas-stop-ownership.patch \
    0027-remoteproc-early-stop.patch 0028-cliffs-proxy-per-rail-ownership.patch; do
    sha256sum "$here/../../patches/boot/$cdsp_patch" >> "$output/abl-source-SHA256SUMS"
done
sha256sum "$here/uke-clock-debug.h" "$here/../power/prepare-cpucp-observe.sh" \
    "$here/../power/uke-cpucp-observe.c" \
    "$here/../../patches/boot/0051-cpufreq-preserve-boost-state-on-error.patch" \
    "$here/../../patches/boot/0052-scmi-protocol-negotiation-opt-out.patch" \
    "$here/../../patches/boot/0055-cpufreq-lmh-policy-lifecycle.patch" \
    "$here/../../patches/boot/0060-cpufreq-lmh-ready-lifecycle.patch" >> "$output/abl-source-SHA256SUMS"
