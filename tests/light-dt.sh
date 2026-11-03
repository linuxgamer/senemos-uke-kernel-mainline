#!/usr/bin/env bash
# Apply only the light overlay to a retained Uke FDT; no tablet write.
set -Eeuo pipefail
[[ $# == 3 ]] || { echo 'Usage: light-dt.sh kernel-headers retained-fdt output' >&2; exit 2; }
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
headers=$(realpath "$1") input=$(realpath "$2") output=$(realpath -m "$3")
[[ -f $headers/include/dt-bindings/leds/common.h && -f $input && ! -e $output ]]
mkdir -p "$output"
pmic=/soc/qcom,spmi@c42d000/qcom,pmxr2230@1
old=$pmic/qcom,flash_led@ee00
[[ $(fdtget -t s "$input" "$old" compatible) == qcom,pm8350c-flash-led ]]
[[ $(fdtget -t u "$input" "$old/qcom,torch_0" qcom,id) == 0 ]]
[[ $(fdtget -t u "$input" "$old/qcom,torch_3" qcom,id) == 3 ]]
for channel in 0 3; do
    [[ $(fdtget -t u "$input" "$old/qcom,torch_$channel" qcom,max-current-ma) == 250 ]]
done
[[ $(fdtget -t x "$input" /soc/qcom,camera-flash0 torch-source) == "$(fdtget -t x "$input" "$old/qcom,torch_0" phandle) $(fdtget -t x "$input" "$old/qcom,torch_3" phandle)" ]]
sha256sum "$input" > "$output/input.sha256"
${CXX:-c++} -std=c++20 -Wall -Wextra -Werror -UNDEBUG -I "$headers/scripts/dtc/libfdt" -I "$root/src/boot" "$root/tests/light-graph.cpp" -l:libfdt.so.1 -o "$output/check-graph"
"$output/check-graph" "$input"
printf '/dts-v1/;\n/plugin/;\n#include "sm7675-uke-lights.dtsi"\n' > "$output/lights.dts"
cpp -P -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$headers/include" -I "$root/src/boot" "$output/lights.dts" > "$output/expanded.dts"
dtc -q -@ -I dts -O dtb -o "$output/lights.dtbo" "$output/expanded.dts"
fdtoverlay -i "$input" -o "$output/candidate.dtb" "$output/lights.dtbo"
file=$output/candidate.dtb
torch=$pmic/led-controller@ee00/led-0
[[ $(fdtget -t s "$file" /torch-control compatible) == senemos,uke-torch ]]
[[ $(fdtget -t x "$file" /torch-control leds) == "$(fdtget -t x "$file" "$torch" phandle)" ]]
[[ $(fdtget -t u "$file" "$torch" led-max-microamp) == 20000 ]]
[[ $(fdtget -t u "$file" "$torch" led-sources) == '1 4' ]]
[[ $(fdtget -t s "$file" "$torch" default-state) == off ]]
[[ $(fdtget -t s "$file" "$torch" label) == uke:white:torch ]]
for prop in flash-max-microamp flash-max-timeout-us linux,default-trigger; do
    if fdtget "$file" "$torch" "$prop" >/dev/null 2>&1; then echo "Unexpected torch property: $prop" >&2; exit 1; fi
done
for leaf in qcom,flash_led@ee00 qcom,leds@ef00 pwms@e800 pwms@e900 pwms@eb00; do
    [[ $(fdtget -t s "$file" "$pmic/$leaf" status) == disabled ]]
done
rgb=$pmic/pwm/multi-led
[[ $(fdtget -t s "$file" "$rgb" default-state) == off ]]
[[ $(fdtget -t s "$file" "$rgb" label) == uke:rgb:status ]]
[[ $(fdtget -t s "$file" /rgb-notifications compatible) == senemos,uke-rgb ]]
[[ $(fdtget -t x "$file" /rgb-notifications leds) == "$(fdtget -t x "$file" "$rgb" phandle)" ]]
if fdtget "$file" "$rgb" linux,default-trigger >/dev/null 2>&1; then exit 1; fi
for channel in 1 2 3; do
    [[ $(fdtget -t u "$file" "$rgb/led@$channel" reg) == "$channel" ]]
    [[ $(fdtget -t u "$file" "$rgb/led@$channel" color) == "$channel" ]]
done
sha256sum --check "$output/input.sha256"
printf '%s\n' 'Own retained Uke graph: exact rear channels, 20 mA torch-only ceiling, RGB order and default-off: PASS (host only)'
