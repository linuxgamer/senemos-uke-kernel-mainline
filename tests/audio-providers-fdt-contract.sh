#!/usr/bin/env bash
# Compile a synthetic provider graph and inspect its resolved clock/pin ownership.
set -euo pipefail
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
  compatible = "simple-bus";
  #address-cells = <1>; #size-cells = <1>; ranges;
  remoteproc-adsp@03000000 { glink-edge { qcom,gpr {}; }; };
  i2c { wcd_usbss: usbss {}; };
  slim@6C40000 { status = "disabled"; };
  amp-bus { status = "disabled"; };
 };
};
DTS
printf '/dts-v1/;\n/plugin/;\n#include "%s/src/audio/sm7675-uke-audio-services.dtsi"\n#include "%s/src/audio/sm7675-uke-audio-card.dtsi"\n#include "%s/src/audio/sm7675-uke-audio-providers.dtsi"\n' \
    "$root" "$root" "$root" > "$work/overlay.dts"
cpp -nostdinc -undef -DUKE_AUDIO_CARD=1 -x assembler-with-cpp -I "$kernel/include" \
    "$work/overlay.dts" > "$work/overlay.pp.dts"
dtc -q -@ -I dts -O dtb -o "$work/base.dtb" "$work/base.dts"
dtc -q -@ -I dts -O dtb -o "$work/overlay.dtbo" "$work/overlay.pp.dts"
fdtoverlay -i "$work/base.dtb" -o "$work/result.dtb" "$work/overlay.dtbo"
f=$work/result.dtb
clock=/soc/remoteproc-adsp@03000000/glink-edge/qcom,gpr/service@2/clock-controller
phandle=$(fdtget -t i "$f" "$clock" phandle)
va=$(fdtget -t i "$f" /soc/codec@6d44000 phandle)
test "$(fdtget -t i "$f" /soc/codec@6d44000 clocks)" = "$phandle 57 1 $phandle 102 1 $phandle 103 1"
test "$(fdtget -t i "$f" /soc/codec@6ae0000 clocks)" = "$phandle 57 1 $phandle 102 1 $phandle 103 1 $va"
test "$(fdtget -t i "$f" /soc/codec@6ac0000 clocks)" = "$phandle 64 1 $phandle 102 1 $phandle 103 1 $va"
test "$(fdtget -t i "$f" /soc/codec@6d44000 qcom,dmic-sample-rate)" = 600000
for address in 6d44000 6ae0000 6ac0000; do
 test "$(fdtget -t x "$f" "/soc/codec@$address" reg)" = "$address 1000"
 if fdtget "$f" "/soc/codec@$address" iommus >/dev/null 2>&1; then exit 1; fi
done
pins=/soc/pinctrl@6e80000
test "$(fdtget -t s "$f" "$pins" compatible)" = qcom,sm7675-lpass-lpi-pinctrl
test "$(fdtget -t x "$f" "$pins" reg)" = '6e80000 17000'
test "$(fdtget -t i "$f" "$pins" gpio-reserved-ranges)" = '0 12 13 10'
for state in active sleep; do
 test "$(fdtget -t s "$f" "$pins/codec-reset-$state-state" pins)" = gpio12
 test "$(fdtget -t s "$f" "$pins/codec-reset-$state-state" function)" = gpio
done
test "$(fdtget -t i "$f" "$pins/codec-reset-active-state" drive-strength)" = 16
test "$(fdtget -t i "$f" "$pins/codec-reset-sleep-state" drive-strength)" = 2
fdtget "$f" "$pins/codec-reset-active-state" output-high >/dev/null
fdtget "$f" "$pins/codec-reset-active-state" bias-disable >/dev/null
fdtget "$f" "$pins/codec-reset-sleep-state" input-enable >/dev/null
fdtget "$f" "$pins/codec-reset-sleep-state" bias-pull-down >/dev/null
reset=/soc/i2c/usbss/codec-reset
test "$(fdtget -t s "$f" "$reset" pinctrl-names)" = 'active sleep'
test "$(fdtget -t i "$f" "$reset" '#reset-cells')" = 1
for index in 0 1; do
 state=active; [[ $index != 1 ]] || state="sleep"
 test "$(fdtget -t i "$f" "$reset" "pinctrl-$index")" = "$(fdtget -t i "$f" "$pins/codec-reset-$state-state" phandle)"
done
apm=/soc/remoteproc-adsp@03000000/glink-edge/qcom,gpr/service@1
fdtget "$f" "$apm/dais" xiaomi,registration-only >/dev/null
if fdtget "$f" "$apm/dais" iommus >/dev/null 2>&1; then exit 1; fi
test "$(fdtget -t s "$f" "$apm/bedais" status)" = disabled
for node in slim@6C40000 amp-bus; do
 test "$(fdtget -t s "$f" "/soc/$node" status)" = disabled
done
printf 'Provider FDT: exact clock IDs, macro ranges, GPIO12-only admission, reset states without default selection and closed PCM/amp paths passed; host only.\n'
