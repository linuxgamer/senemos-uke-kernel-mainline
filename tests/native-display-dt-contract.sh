#!/usr/bin/env bash
# Offline overlay graph only; actual native entry is covered by the C++ fixtures.
set -Eeuo pipefail
[[ $# -ge 3 && $# -le 4 && -s $1 && -s $2 && ! -e $3 ]] || exit 2
input=$1 overlay=$2 out=$3 initial_rate=${4:-60}
[[ $initial_rate == 60 || $initial_rate == 120 ]] || exit 2
mkdir -p "$out"
cp "$input" "$out/input.dtb"
framebuffer=$(fdtget -t s "$input" /chosen stdout-path)
[[ $framebuffer == /chosen/framebuffer@* ]]
primary=/soc/qcom,qupv3_0_geni_se@ac0000/i2c@a80000/ktz8866@11
[[ $(fdtget -t s "$input" "$primary" compatible) == xiaomi,uke-ktz8866-primary ]]
fdtput -t s "$out/input.dtb" /__symbols__ uke_primary_backlight "$primary"
for rail in vsp vsn; do
    fdtput -t s "$out/input.dtb" /__symbols__ "display_panel_$rail" "/soc/display_gpio_regulator_$rail"
done
fdtoverlay -i "$out/input.dtb" -o "$out/native.dtb" "$overlay"
fdtput -d "$out/native.dtb" "$framebuffer" backlight
[[ $(fdtget -t s "$out/native.dtb" "$framebuffer" status) == okay ]]
[[ $(fdtget -t s "$out/native.dtb" /chosen stdout-path) == "$framebuffer" ]]
mdss=/soc/display-subsystem@ae00000
dpu=$mdss/display-controller@ae01000
dsi0=$mdss/dsi@ae94000
dsi1=$mdss/dsi@ae96000
panel=$dsi0/panel@0
[[ $(fdtget -t s "$out/native.dtb" "$mdss" compatible) == qcom,sm7675-mdss ]]
[[ $(fdtget -t x "$out/native.dtb" "$mdss" interrupts) == '0 53 4' ]]
[[ $(fdtget -t s "$out/native.dtb" "$dpu" compatible) == qcom,sm7675-dpu ]]
[[ $(fdtget -t x "$out/native.dtb" "$dpu" reg) == 'ae01000 8f000 aeb0000 1074' ]]
smmu=$(fdtget -t x "$input" /soc/apps-smmu@15000000 phandle)
[[ $(fdtget -t x "$out/native.dtb" "$dpu" iommus) == "$smmu 1c00 2" ]]
[[ $(fdtget -t x "$out/native.dtb" "$panel" backlight) == "$(fdtget -t x "$input" "$primary" phandle)" ]]
tlmm=$(fdtget -t x "$input" /soc/pinctrl@f000000 phandle)
[[ $(fdtget -t x "$out/native.dtb" "$panel" reset-gpios) == "$tlmm 2 0" ]]
for dsi in "$dsi0" "$dsi1"; do
    endpoint=$dsi/ports/port@1/endpoint
    [[ $(fdtget -t x "$out/native.dtb" "$endpoint" data-lanes) == '0 1 2 3' ]]
    remote=$(fdtget -t x "$out/native.dtb" "$endpoint" remote-endpoint)
    [[ -n $remote && $remote != 0 && $remote != ffffffff ]]
done
for id in 0 1; do
    old_dsi=/soc/qcom,mdss_dsi_ctrl$id@$(printf '%x' "$((0xae94000 + id*0x2000))")
    old_phy=/soc/qcom,mdss_dsi_phy$id@$(printf '%x' "$((0xae95500 + id*0x2000))")
    new_dsi=$mdss/dsi@$(printf '%x' "$((0xae94000 + id*0x2000))")
    new_phy=$mdss/phy@$(printf '%x' "$((0xae95000 + id*0x2000))")
    [[ $(fdtget -t s "$out/native.dtb" "$new_phy" compatible) == 'xiaomi,uke-o82-dsi-phy-4nm qcom,sm7675-dsi-phy-4nm' ]]
    [[ $(fdtget -t x "$out/native.dtb" "$new_dsi" vdda-supply) == "$(fdtget -t x "$input" "$old_dsi" vdda-1p2-supply)" ]]
    [[ $(fdtget -t x "$out/native.dtb" "$new_phy" vdds-supply) == "$(fdtget -t x "$input" "$old_phy" vdda-0p9-supply)" ]]
done
phy0=$(fdtget -t x "$out/native.dtb" "$mdss/phy@ae95000" phandle)
[[ $(fdtget -t x "$out/native.dtb" "$dsi1" assigned-clock-parents) == "$phy0 0 $phy0 1" ]]
for node in /soc/qcom,mdss_mdp@ae00000 /soc/qcom,mdss_dsi_ctrl0@ae94000 /soc/qcom,mdss_dsi_ctrl1@ae96000 /soc/qcom,mdss_dsi_phy0@ae95500 /soc/qcom,mdss_dsi_phy1@ae97500 /soc/qcom,dp_display@ae154000; do
    [[ $(fdtget -t s "$out/native.dtb" "$node" status) == disabled ]]
done
for property in reg qcom,handoff-smrs qcom,actlr; do
    [[ $(fdtget -t x "$out/native.dtb" /soc/apps-smmu@15000000 "$property") == "$(fdtget -t x "$input" /soc/apps-smmu@15000000 "$property")" ]]
done
memories=0
for node in $(fdtget -l "$input" /); do
    case $node in memory|memory@*) ;; *) continue;; esac
    [[ $(fdtget -t x "$out/native.dtb" "/$node" reg) == "$(fdtget -t x "$input" "/$node" reg)" ]]
    ((memories+=1))
done
((memories>0))
for node in $(fdtget -l "$input" /reserved-memory); do
    for property in $(fdtget -p "$input" "/reserved-memory/$node"); do
        [[ $(fdtget -t bx "$out/native.dtb" "/reserved-memory/$node" "$property") == "$(fdtget -t bx "$input" "/reserved-memory/$node" "$property")" ]]
    done
done
[[ $(fdtget -t s "$out/native.dtb" "$panel" compatible) == xiaomi,o82-* ]]
fdtget "$out/native.dtb" "$panel" "xiaomi,initial-${initial_rate}hz-only" >/dev/null
other_rate=120
[[ $initial_rate == 120 ]] && other_rate=60
if fdtget "$out/native.dtb" "$panel" "xiaomi,initial-${other_rate}hz-only" >/dev/null 2>&1; then
    printf 'Conflicting initial panel mode profiles\n' >&2
    exit 1
fi
if [[ $initial_rate == 120 ]]; then
    [[ $(fdtget -t s "$out/native.dtb" "$panel" compatible) == xiaomi,o82-42-02-0b ]]
fi
printf 'Offline native DPU/dual-DSI graph, %s Hz initial profile, exact resources, paired backlight and preserved SMMU handoff rules: passed\n' "$initial_rate"
