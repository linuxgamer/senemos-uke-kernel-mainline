#!/usr/bin/env bash
# Compile the actual native profiles for both suppliers; no bootloader DT required.
set -Eeuo pipefail
kernel=${1:?Pass kernel source with Uke clock bindings}
shift
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
mkdir -p "$work/kernel/include" "$work/kernel/arch/arm64/kernel" "$work/generated"
ln -s "$(realpath "$kernel/include/dt-bindings")" "$work/kernel/include/dt-bindings"
UKE_NATIVE_VIDEO_SOURCE="$root/src/video/sm7675-uke-native-video.dtso" \
    bash "$root/src/display/generate-native-panels.sh" "$work/kernel" "$work/generated" \
    "$root/src/display/sm7675-uke-native-display-oem-modes.dtso" auto "$@"
panel=/fragment@208/__overlay__/display-subsystem@ae00000/dsi@ae94000/panel@0
touch=/fragment@240/__overlay__
for variant in 36 42; do
    blob=$work/generated/display-$variant.dtbo
    if [[ $variant == 36 ]]; then suffix=36-02-0a; else suffix=42-02-0b; fi
    [[ $(fdtget -t s "$blob" "$panel" compatible) == "xiaomi,o82-$suffix" ]]
    fdtget "$blob" "$panel" xiaomi,oem-refresh-modes >/dev/null
    if fdtget "$blob" "$panel" xiaomi,initial-60hz-only >/dev/null 2>&1; then exit 1; fi
    [[ $(fdtget -t x "$blob" "$panel" reset-gpios) == 'ffffffff 2 0' ]]
    if [[ $variant == 36 ]]; then supplier=tianma; else supplier=csot; fi
    [[ $(fdtget -t s "$blob" "$touch" novatek,firmware-variant) == "$supplier" ]]
    [[ $(fdtget -t u "$blob" "$touch" novatek,row-map | wc -w) == 40 ]]
    [[ $(fdtget -t u "$blob" "$touch" novatek,column-map | wc -w) == 60 ]]
done
# Panel identity and the paired touch supplier/maps are the only differences.
cp "$work/generated/display-36.dtbo" "$work/compare.dtbo"
fdtput -t s "$work/compare.dtbo" "$panel" compatible xiaomi,o82-42-02-0b
fdtput -t s "$work/compare.dtbo" "$touch" novatek,firmware-variant csot
for property in novatek,row-map novatek,column-map; do
    read -ra map <<< "$(fdtget -t u "$work/generated/display-42.dtbo" "$touch" "$property")"
    fdtput -t u "$work/compare.dtbo" "$touch" "$property" "${map[@]}"
done
dtc -q -I dtb -O dts "$work/compare.dtbo" > "$work/compare.dts"
dtc -q -I dtb -O dts "$work/generated/display-42.dtbo" > "$work/expected.dts"
cmp "$work/compare.dts" "$work/expected.dts"
[[ $(grep -c 'dualdsi_dsc_vid", uke_native_overlay_' "$work/generated/uke-native-display.h") == 2 ]]
cmp "$work/generated/uke-native-display.h" "$work/kernel/arch/arm64/kernel/uke-native-display.h"
printf 'O82 DT generation: distinct supplier identities, shared native/video graph and both embedded overlays passed\n'
