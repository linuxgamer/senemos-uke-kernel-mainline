#!/usr/bin/env bash
# Read generic OEM configuration files only; no touch device or unit calibration.
set -Eeuo pipefail
kernel=${1:?Pass kernel headers} assets=${2:?Pass the pinned OEM touch directory}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror "$root/tests/touch-config-map.cpp" -o "$work/maps"
for variant in 36 42; do
    if [[ $variant == 36 ]]; then
        supplier=tm
        hash=4de42f9c27844695f1b789e59f049550d283a51bb0a8a1d9319f8a2ba5666a33
    else
        supplier=csot
        hash=c02d1956da3714bbd9a19f14ca814731cffd4e2442677a83d5e071ea547a0616
    fi
    printf '%s  %s\n' "$hash" "$assets/$supplier/config.ini" | sha256sum -c --quiet
    printf '/dts-v1/;\n/plugin/;\n#include "sm7675-uke-thp.dtsi"\n' > "$work/input.dts"
    cpp -P -nostdinc -undef -D__DTS__ -DO82_PANEL_VARIANT="$variant" -x assembler-with-cpp \
        -I "$kernel/include" -I "$root/src/input" "$work/input.dts" > "$work/touch.dts"
    dtc -q -@ -I dts -O dtb -o "$work/touch.dtbo" "$work/touch.dts"
    "$work/maps" "$assets/$supplier/config.ini" \
        "$(fdtget -t u "$work/touch.dtbo" /fragment@240/__overlay__ novatek,row-map)" \
        "$(fdtget -t u "$work/touch.dtbo" /fragment@240/__overlay__ novatek,column-map)"
done
printf 'Both pinned touch configurations match all OEM axis-map entries in their compiled DT profiles\n'
