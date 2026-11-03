#!/usr/bin/env bash
# Synthetic overlay and active-profile checks; no device access.
set -Eeuo pipefail
kernel=${1:?Pass prepared kernel tree}
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
  apps_smmu: iommu@15000000 { compatible = "qcom,sm7675-boot-smmu"; reg = <0x15000000 0x1000>; #iommu-cells = <2>; };
  uke_dp: displayport@af54000 { compatible = "qcom,sm7675-dp"; reg = <0xaf54000 0x1000>; #sound-dai-cells = <0>; };
  i2c@88c000 { reg = <0x88c000 0x1000>; status = "disabled"; };
  slim@6C40000 { reg = <0x6c40000 0x1000>; status = "disabled"; };
  remoteproc-adsp@03000000 {
   reg = <0x3000000 0x1000>;
   glink-edge { qcom,gpr { #address-cells = <1>; #size-cells = <0>; }; };
  };
 };
};
DTS
printf '/dts-v1/;\n/plugin/;\n#include "%s/src/audio/sm7675-uke-audio-services.dtsi"\n#include "%s/src/audio/sm7675-uke-hdmi-audio.dtsi"\n' "$root" "$root" > "$work/hdmi.dts"
cpp -nostdinc -undef -I "$kernel/include" -x assembler-with-cpp "$work/hdmi.dts" > "$work/hdmi.pp.dts"
dtc -q -@ -I dts -O dtb -o "$work/base.dtb" "$work/base.dts"
dtc -q -@ -I dts -O dtb -o "$work/hdmi.dtbo" "$work/hdmi.pp.dts"
fdtoverlay -i "$work/base.dtb" -o "$work/result.dtb" "$work/hdmi.dtbo"
gpr=/soc/remoteproc-adsp@03000000/glink-edge/qcom,gpr
fe=$gpr/service@1/dais
be=$gpr/service@1/bedais
test "$(fdtget -t s "$work/result.dtb" "$fe" status)" = okay
test "$(fdtget -t s "$work/result.dtb" "$be" status)" = okay
fdtget "$work/result.dtb" "$fe" xiaomi,hdmi-only >/dev/null
if fdtget "$work/result.dtb" "$fe" xiaomi,registration-only >/dev/null 2>&1; then exit 1; fi
smmu=$(fdtget -t x "$work/result.dtb" /soc/iommu@15000000 phandle)
test "$(fdtget -t x "$work/result.dtb" "$fe" iommus)" = "$smmu 1001 80 $smmu 1061 0"
test "$(fdtget -t s "$work/result.dtb" /sound-uke compatible)" = xiaomi,uke-hdmi-audio-card
test "$(fdtget -l "$work/result.dtb" /sound-uke)" = hdmi-dai-link
test "$(fdtget -t x "$work/result.dtb" /sound-uke/hdmi-dai-link/cpu sound-dai)" = "$(fdtget -t x "$work/result.dtb" "$be" phandle) 68"
test "$(fdtget -t x "$work/result.dtb" /sound-uke/hdmi-dai-link/codec sound-dai)" = "$(fdtget -t x "$work/result.dtb" /soc/displayport@af54000 phandle)"
for node in i2c@88c000 slim@6C40000; do
 test "$(fdtget -t s "$work/result.dtb" "/soc/$node" status)" = disabled
done
overlay=$kernel/native-generated/display.dtbo
if [[ -f $overlay ]]; then
 node=$(fdtget -t s "$overlay" /__symbols__ uke_q6apm_dais)
 fdtget "$overlay" "$node" xiaomi,hdmi-only >/dev/null
 test "$(fdtget -t s "$overlay" "$node" status)" = okay
fi
printf 'DP audio FDT: exact audio SIDs, one DP104 backend and disabled physical internal buses passed; host only\n'
