#!/usr/bin/env bash
# Generic binding fixtures only; these are not Uke DT nodes.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
schema=${2:?Pass processed-schema.json}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/valid.dts" <<'DTS'
/dts-v1/;
/plugin/;
/ {
    #address-cells = <1>;
    #size-cells = <1>;
    clock-controller@aaf0000 {
        compatible = "qcom,sm7675-videocc";
        reg = <0x0aaf0000 0x10000>;
        clocks = <&xo>, <&gcc 0>;
        vdd_mm-supply = <&mm>;
        vdd_mxc-supply = <&mxc>;
        vdd_mm_mxc-supply = <&bridge>;
        #clock-cells = <1>;
        #reset-cells = <1>;
        #power-domain-cells = <1>;
    };
};
DTS
sed '/vdd_mm-supply/d' "$work/valid.dts" > "$work/missing-mm.dts"
sed '/vdd_mxc-supply/d' "$work/valid.dts" > "$work/missing-mxc.dts"
sed '/vdd_mm_mxc-supply/d' "$work/valid.dts" > "$work/missing-bridge.dts"
sed '/#clock-cells/i\        power-domains = <\&pd 0>;' "$work/valid.dts" > "$work/mixed-pd.dts"
sed '/#clock-cells/i\        required-opps = <\&opp>;' "$work/valid.dts" > "$work/mixed-opps.dts"
sed 's/qcom,sm7675-videocc/qcom,sm8550-videocc/' "$work/valid.dts" > "$work/foreign-soc.dts"
for name in valid missing-mm missing-mxc missing-bridge mixed-pd mixed-opps foreign-soc; do
    cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$kernel/include" \
        "$work/$name.dts" | dtc -@ -I dts -O dtb -o "$work/$name.dtb"
    dt-validate -s "$schema" -l qcom,sm8450-videocc "$work/$name.dtb" \
        > "$work/$name.log" 2>&1
done
test ! -s "$work/valid.log"
grep -q 'vdd_mm-supply.*required property' "$work/missing-mm.log"
grep -q 'vdd_mxc-supply.*required property' "$work/missing-mxc.log"
grep -q 'vdd_mm_mxc-supply.*required property' "$work/missing-bridge.log"
grep -q 'False schema' "$work/mixed-pd.log"
grep -q 'False schema' "$work/mixed-opps.log"
grep -q 'power-domains.*required property' "$work/foreign-soc.log"
printf 'VIDEOCC regulator binding accepted; six missing/mixed/foreign cases rejected\n'
