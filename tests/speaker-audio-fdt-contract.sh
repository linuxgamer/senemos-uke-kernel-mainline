#!/usr/bin/env bash
# Synthetic overlay check for the internal-speaker profile; no device access.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
profile=${2:-speakers}
case $profile in speakers|microphones) ;; *) exit 2;; esac
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
cat > "$work/base.dts" <<'DTS'
/dts-v1/;
/ {
 compatible = "xiaomi,uke";
 #address-cells = <1>; #size-cells = <1>;
 soc {
  #address-cells = <1>; #size-cells = <1>; ranges;
  wcd_usbss: usbss {};
  intc: interrupt-controller { interrupt-controller; #interrupt-cells = <4>; };
  pmxr2230_l7: regulator-l7 { compatible = "regulator-fixed"; regulator-name = "l7"; regulator-min-microvolt = <1800000>; regulator-max-microvolt = <1800000>; };
  pmxr2230_bob: regulator-bob { compatible = "regulator-fixed"; regulator-name = "bob"; regulator-min-microvolt = <3296000>; regulator-max-microvolt = <3296000>; };
  apps_smmu: iommu@15000000 { compatible = "qcom,sm7675-boot-smmu"; reg = <0x15000000 0x1000>; #iommu-cells = <2>; };
  tlmm: pinctrl@f000000 { compatible = "qcom,cliffs-pinctrl"; reg = <0xf000000 0x1000>; gpio-controller; #gpio-cells = <2>; };
  gpi_dma1: dma-controller@a00000 { reg = <0xa00000 0x1000>; #dma-cells = <3>; };
  uke_dp: displayport@af54000 { compatible = "qcom,sm7675-dp"; reg = <0xaf54000 0x1000>; #sound-dai-cells = <0>; };
  qup1: qcom,qupv3_1_geni_se@8c0000 {
   reg = <0x8c0000 0x1000>; #address-cells = <1>; #size-cells = <1>; ranges;
   i2c@88c000 {
    compatible = "qcom,i2c-geni"; reg = <0x88c000 0x4000>;
    #address-cells = <1>; #size-cells = <0>; status = "disabled";
    uke_amp_tl: fs19xx_smartpa@34 { compatible = "foursemi,fs16xx"; reg = <0x34>; reset-gpio = <&tlmm 30 0>; status = "ok"; };
    uke_amp_tr: fs19xx_smartpa@35 { compatible = "foursemi,fs16xx"; reg = <0x35>; reset-gpio = <&tlmm 149 0>; status = "ok"; };
    uke_amp_bl: fs19xx_smartpa@36 { compatible = "foursemi,fs16xx"; reg = <0x36>; reset-gpio = <&tlmm 124 0>; status = "ok"; };
    uke_amp_br: fs19xx_smartpa@37 { compatible = "foursemi,fs16xx"; reg = <0x37>; reset-gpio = <&tlmm 123 0>; status = "ok"; };
   };
  };
  remoteproc-adsp@03000000 {
   reg = <0x3000000 0x1000>;
   glink-edge { qcom,gpr { #address-cells = <1>; #size-cells = <0>; }; };
  };
 };
};
DTS
printf '/dts-v1/;\n/plugin/;\n#include "%s/src/audio/sm7675-uke-audio-services.dtsi"\n#include "%s/src/audio/sm7675-uke-speaker-audio.dtsi"\n' "$root" "$root" > "$work/spk.dts"
if [[ $profile == microphones ]]; then
 printf '#include "%s/src/audio/sm7675-uke-microphone-audio.dtsi"\n' "$root" >> "$work/spk.dts"
fi
cpp -nostdinc -undef -DUKE_AUDIO_SERVICES=1 -I "$kernel/include" -x assembler-with-cpp "$work/spk.dts" > "$work/spk.pp.dts"
dtc -q -@ -I dts -O dtb -o "$work/base.dtb" "$work/base.dts"
dtc -q -@ -I dts -O dtb -o "$work/spk.dtbo" "$work/spk.pp.dts"
fdtoverlay -i "$work/base.dtb" -o "$work/result.dtb" "$work/spk.dtbo"
bus=/soc/qcom,qupv3_1_geni_se@8c0000/i2c@88c000
test "$(fdtget -t s "$work/result.dtb" "$bus" status)" = okay
test "$(fdtget -t s "$work/result.dtb" "$bus" compatible)" = qcom,geni-i2c
dma=$(fdtget -t x "$work/result.dtb" /soc/dma-controller@a00000 phandle)
test "$(fdtget -t x "$work/result.dtb" "$bus" dmas)" = "$dma 0 3 3 $dma 1 3 3"
tlmm=$(fdtget -t x "$work/result.dtb" /soc/pinctrl@f000000 phandle)
for entry in 34:30:TopLeft 35:149:TopRight 36:124:BottomLeft 37:123:BottomRight; do
 IFS=: read -r addr gpio prefix <<< "$entry"
 amp=$bus/fs19xx_smartpa@$addr
 test "$(fdtget -t s "$work/result.dtb" "$amp" compatible)" = foursemi,fs19xx
 test "$(fdtget -t x "$work/result.dtb" "$amp" reset-gpios)" = "$tlmm $(printf '%x' "$gpio") 1"
 test "$(fdtget -t s "$work/result.dtb" "$amp" sound-name-prefix)" = "$prefix"
 test "$(fdtget -t u "$work/result.dtb" "$amp" '#sound-dai-cells')" = 0
done
lpi=/soc/pinctrl@6e80000
test "$(fdtget -t s "$work/result.dtb" "$lpi" compatible)" = qcom,sm7675-lpass-lpi-pinctrl
test "$(fdtget -t x "$work/result.dtb" "$lpi" reg)" = "6e80000 17000"
test "$(fdtget -t s "$work/result.dtb" "$lpi" clock-names)" = 'core audio'
pins=$lpi/tdm-active-state
test "$(fdtget -t s "$work/result.dtb" "$pins/clk-pins" pins)" = gpio6
test "$(fdtget -t s "$work/result.dtb" "$pins/clk-pins" function)" = i2s1_clk
test "$(fdtget -t s "$work/result.dtb" "$pins/ws-pins" pins)" = gpio7
test "$(fdtget -t s "$work/result.dtb" "$pins/ws-pins" function)" = i2s1_ws
test "$(fdtget -t s "$work/result.dtb" "$pins/sd0-pins" pins)" = gpio8
test "$(fdtget -t s "$work/result.dtb" "$pins/sd1-pins" pins)" = gpio9
gpr=/soc/remoteproc-adsp@03000000/glink-edge/qcom,gpr
fe=$gpr/service@1/dais
be=$gpr/service@1/bedais
test "$(fdtget -t s "$work/result.dtb" "$fe" status)" = okay
test "$(fdtget -t s "$work/result.dtb" "$be" status)" = okay
fdtget "$work/result.dtb" "$fe" xiaomi,hdmi-only >/dev/null
if fdtget "$work/result.dtb" "$fe" xiaomi,registration-only >/dev/null 2>&1; then exit 1; fi
smmu=$(fdtget -t x "$work/result.dtb" /soc/iommu@15000000 phandle)
test "$(fdtget -t x "$work/result.dtb" "$fe" iommus)" = "$smmu 1001 80 $smmu 1061 0"
card=/sound-uke
if [[ $profile == microphones ]]; then
 test "$(fdtget -t s "$work/result.dtb" $card compatible)" = xiaomi,uke-microphone-audio-card
 test "$(fdtget -l "$work/result.dtb" $card | sort | tr '\n' ' ')" = 'hdmi-dai-link microphone-dai-link speaker-dai-link '
else
 test "$(fdtget -t s "$work/result.dtb" $card compatible)" = xiaomi,uke-speaker-audio-card
 test "$(fdtget -l "$work/result.dtb" $card | sort | tr '\n' ' ')" = 'hdmi-dai-link speaker-dai-link '
fi
test "$(fdtget -t s "$work/result.dtb" $card model)" = POCO-Pad-X1
test "$(fdtget -t x "$work/result.dtb" $card/hdmi-dai-link/cpu sound-dai)" = "$(fdtget -t x "$work/result.dtb" "$be" phandle) 68"
# SECONDARY_TDM_RX_0 is 40 (0x28); the card checks the same identity.
test "$(fdtget -t x "$work/result.dtb" $card/speaker-dai-link/cpu sound-dai)" = "$(fdtget -t x "$work/result.dtb" "$be" phandle) 28"
codecs=$(fdtget -t x "$work/result.dtb" $card/speaker-dai-link/codec sound-dai)
want=
for addr in 34 35 36 37; do
 want="$want$(fdtget -t x "$work/result.dtb" "$bus/fs19xx_smartpa@$addr" phandle) "
done
test "$codecs " = "$want"
test "$(fdtget -t x "$work/result.dtb" $card pinctrl-0)" = "$(fdtget -t x "$work/result.dtb" "$pins" phandle)"
[[ -z ${3:-} ]] || cp "$work/result.dtb" "$3"
printf 'Speaker audio FDT: amp bus, four active-low resets, LPI TDM pins and retained playback links passed; host only\n'
