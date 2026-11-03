#!/usr/bin/env bash
# Synthetic DT and binding checks; no private DT, image or device operations.
set -Eeuo pipefail
schema=${1:?Pass processed LLCC schema}
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'result=$?; if ((result)); then for log in "$work"/*.log; do test ! -f "$log" || cat "$log" >&2; done; fi; rm -rf -- "$work"' EXIT
cat > "$work/base.dts" <<'DTS'
/dts-v1/;
/ {
    compatible = "xiaomi,uke", "qcom,sm7675";
    model = "Synthetic Uke LLCC source fixture";
    #address-cells = <2>;
    #size-cells = <2>;
    chosen { bootargs = "preserved-fixture"; };
    memory@80000000 { device_type = "memory"; reg = <0 0x80000000 0 0x10000000>; };
    soc {
        compatible = "simple-bus";
        #address-cells = <1>;
        #size-cells = <1>;
        ranges = <0 0 0 0xffffffff>;
        intc: interrupt-controller { interrupt-controller; #interrupt-cells = <3>; #address-cells = <0>; };
        llcc: cache-controller@25000000 {
            compatible = "qcom,cliffs7-llcc", "qcom,llcc-v50";
            reg = <0x25000000 0x800000>, <0x25800000 0x200000>;
            reg-names = "llcc_base", "llcc_broadcast_base";
            interrupt-parent = <&intc>;
            interrupts = <0 266 4>;
            label = "cache_cont";
            cap-based-alloc-and-pwr-collapse;
            llcc-perfmon { compatible = "qcom,llcc-perfmon"; };
        };
    };
};
DTS
dtc -q -@ -I dts -O dtb -o "$work/base.dtb" "$work/base.dts"
original=$(sha256sum "$work/base.dtb")
bash "$project/src/performance/prepare-llcc-dt.sh" "$work/base.dtb" "$work/native.dtb"
[[ $(sha256sum "$work/base.dtb") == "$original" ]]
[[ $(stat -c %a "$work/native.dtb") == 600 ]]
dt-validate -s "$schema" -l qcom,llcc "$work/native.dtb" > "$work/valid.log" 2>&1
test ! -s "$work/valid.log"
cp "$work/native.dtb" "$work/legacy.dtb"
fdtput -t s "$work/legacy.dtb" /soc/cache-controller@25000000 compatible qcom,sdm845-llcc
dt-validate -s "$schema" -l qcom,llcc "$work/legacy.dtb" > "$work/legacy.log" 2>&1
test ! -s "$work/legacy.log"
cp "$work/base.dtb" "$work/no-metadata.dtb"
fdtput -r "$work/no-metadata.dtb" /soc/cache-controller@25000000/llcc-perfmon
fdtput -d "$work/no-metadata.dtb" /soc/cache-controller@25000000 label
fdtput -d "$work/no-metadata.dtb" /soc/cache-controller@25000000 cap-based-alloc-and-pwr-collapse
bash "$project/src/performance/prepare-llcc-dt.sh" "$work/no-metadata.dtb" "$work/no-metadata-native.dtb"
dt-validate -s "$schema" -l qcom,llcc "$work/no-metadata-native.dtb" > "$work/no-metadata.log" 2>&1
test ! -s "$work/no-metadata.log"
node=/soc/cache-controller@25000000
[[ $(fdtget -t s "$work/native.dtb" /chosen bootargs) == preserved-fixture ]]
[[ $(fdtget -t x "$work/native.dtb" /memory@80000000 reg) == '0 80000000 0 10000000' ]]
[[ $(fdtget -t x "$work/native.dtb" "$node" phandle) == "$(fdtget -t x "$work/base.dtb" "$node" phandle)" ]]
for mode in foreign-soc generic-cliffs wrong-cells wrong-base wrong-irq disabled extra-child; do
    cp "$work/base.dtb" "$work/$mode.dtb"
    case $mode in
        foreign-soc) fdtput -t s "$work/$mode.dtb" / compatible xiaomi,uke qcom,sm8650;;
        generic-cliffs) fdtput -t s "$work/$mode.dtb" "$node" compatible qcom,cliffs-llcc qcom,llcc-v50;;
        wrong-cells) fdtput -t x "$work/$mode.dtb" /soc '#address-cells' 2;;
        wrong-base) fdtput -t x "$work/$mode.dtb" "$node" reg 25000004 800000 25800000 200000;;
        wrong-irq) fdtput -t x "$work/$mode.dtb" "$node" interrupts 0 10b 4;;
        disabled) fdtput -t s "$work/$mode.dtb" "$node" status disabled;;
        extra-child) fdtput -c "$work/$mode.dtb" "$node/unreviewed";;
    esac
    before=$(sha256sum "$work/$mode.dtb")
    if bash "$project/src/performance/prepare-llcc-dt.sh" "$work/$mode.dtb" "$work/$mode-output.dtb"; then
        echo "Unexpected DT admission: $mode" >&2; exit 1;
    fi
    [[ ! -e $work/$mode-output.dtb && $(sha256sum "$work/$mode.dtb") == "$before" ]]
done
for mode in empty oversized; do
    truncate -s 0 "$work/$mode.dtb"
    [[ $mode != oversized ]] || truncate -s 16777217 "$work/$mode.dtb"
    if bash "$project/src/performance/prepare-llcc-dt.sh" "$work/$mode.dtb" "$work/$mode-output.dtb"; then exit 1; fi
    [[ ! -e $work/$mode-output.dtb ]]
done
for mode in missing-region swapped-names extra-region; do
    cp "$work/native.dtb" "$work/$mode.dtb"
    case $mode in
        missing-region) fdtput -t x "$work/$mode.dtb" "$node" reg 25000000 200000;;
        swapped-names) fdtput -t s "$work/$mode.dtb" "$node" reg-names llcc1_base llcc0_base llcc2_base llcc3_base llcc_broadcast_base;;
        extra-region) fdtput -t x "$work/$mode.dtb" "$node" reg 25000000 200000 25200000 200000 25400000 200000 25600000 200000 25800000 200000 25a00000 200000;;
    esac
    dt-validate -s "$schema" -l qcom,llcc "$work/$mode.dtb" > "$work/$mode.log" 2>&1
    test -s "$work/$mode.log"
done
if bash "$project/src/performance/prepare-llcc-dt.sh" "$work/base.dtb" "$work/native.dtb"; then exit 1; fi
ln -s "$work/unused.dtb" "$work/linked.dtb"
if bash "$project/src/performance/prepare-llcc-dt.sh" "$work/base.dtb" "$work/linked.dtb"; then exit 1; fi
[[ ! -e $work/unused.dtb && $(sha256sum "$work/base.dtb") == "$original" ]]
echo 'LLCC DT: exact translation, source/sentinels preserved, seven admission/two size/three schema refusals, no-clobber passed'
