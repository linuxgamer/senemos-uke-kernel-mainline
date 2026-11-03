#!/usr/bin/env bash
# Synthetic binding nodes; all physical target validation is separate.
set -Eeuo pipefail
schema=${1:?Pass the processed schema JSON}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cat > "$work/valid.dts" <<'DTS'
/dts-v1/;
/ {
    #address-cells = <1>;
    #size-cells = <1>;
    interrupt-parent = <&gic>;
    gic: interrupt-controller { interrupt-controller; #interrupt-cells = <3>; #address-cells = <0>; };
    cc: clock-controller { #clock-cells = <1>; #reset-cells = <1>; #power-domain-cells = <1>; };
    icc: interconnect { #interconnect-cells = <1>; };
    iommu: iommu { #iommu-cells = <2>; };
    mem: firmware-memory { reg = <0x90000000 0x800000>; };
    video-codec@aa00000 {
        compatible = "qcom,sm7675-iris";
        reg = <0xaa00000 0xf0000>;
        interrupts = <0 174 4>;
        power-domains = <&cc 0>, <&cc 1>;
        power-domain-names = "venus", "vcodec0";
        clocks = <&cc 0>, <&cc 1>, <&cc 2>;
        clock-names = "iface", "core", "vcodec0_core";
        resets = <&cc 0>, <&cc 1>, <&cc 2>, <&cc 3>;
        reset-names = "bus", "xo", "core", "vcodec";
        interconnects = <&icc 0 &icc 1>, <&icc 2 &icc 3>;
        interconnect-names = "cpu-cfg", "video-mem";
        iommus = <&iommu 0x1940 0>, <&iommu 0x1947 0>;
        dma-coherent;
        memory-region = <&mem>;
        operating-points-v2 = <&opps>;
        opps: opp-table {
            compatible = "operating-points-v2";
            opp-192000000 { opp-hz = /bits/ 64 <192000000>; };
        };
    };
};
DTS
sed 's/"bus", "xo", "core", "vcodec"/"bus", "xo", "core"/' "$work/valid.dts" > "$work/missing-vcodec.dts"
sed 's/power-domains = <\&cc 0>, <\&cc 1>;/power-domains = <\&cc 0>;/;s/"venus", "vcodec0"/"venus"/' "$work/valid.dts" > "$work/missing-domain.dts"
sed 's/power-domains = <\&cc 0>, <\&cc 1>;/power-domains = <\&cc 0>, <\&cc 1>, <\&cc 2>, <\&cc 3>;/;s/"venus", "vcodec0"/"venus", "vcodec0", "mxc", "mmcx"/' "$work/valid.dts" > "$work/mixed-ownership.dts"
sed '/memory-region =/d' "$work/valid.dts" > "$work/missing-memory.dts"
sed 's/qcom,sm7675-iris/qcom,sm8650-iris/;s/, <\&cc 3>;/;/;s/, "vcodec"/ /' "$work/mixed-ownership.dts" > "$work/legacy.dts"
# The legacy domain list must remain four entries; only trim its reset list.
sed -i 's/power-domains =.*/power-domains = <\&cc 0>, <\&cc 1>, <\&cc 2>, <\&cc 3>;/' "$work/legacy.dts"
for name in valid missing-vcodec missing-domain mixed-ownership missing-memory legacy; do
    dtc -q -I dts -O dtb -o "$work/$name.dtb" "$work/$name.dts"
    dt-validate -s "$schema" -l qcom,sm8550-iris "$work/$name.dtb" > "$work/$name.log" 2>&1
done
if [[ -s $work/valid.log || -s $work/legacy.log ]]; then cat "$work/valid.log" "$work/legacy.log"; exit 1; fi
grep -q 'reset-names' "$work/missing-vcodec.log"
grep -q 'power-domain' "$work/missing-domain.log"
grep -q 'power-domain' "$work/mixed-ownership.log"
grep -q 'memory-region.*required property' "$work/missing-memory.log"
printf 'SM7675 Iris binding: native and legacy nodes accepted; four incomplete/mixed cases refused\n'
