#!/usr/bin/env bash
# Host-only Cliffs7 DT translation; never selects a boot slot or writes a device.
set -Eeuo pipefail
[[ $# == 2 && -f $1 && ! -e $2 && ! -L $2 ]] || {
    echo 'Usage: prepare-llcc-dt.sh NATIVE_BASE.dtb NEW_CANDIDATE.dtb' >&2; exit 2;
}
input=$(realpath -- "$1")
output=$(realpath -m -- "$2")
[[ -d $(dirname -- "$output") ]]
for tool in fdtget fdtput stat; do command -v "$tool" >/dev/null; done
size=$(stat -c %s -- "$input")
[[ $size =~ ^[0-9]{1,8}$ && $size -ge 40 && $size -le 16777216 ]]
node=/soc/cache-controller@25000000
compat=" $(fdtget -t s "$input" / compatible) "
[[ $compat == *' xiaomi,uke '* && $compat == *' qcom,sm7675 '* ]]
[[ $(fdtget -t x "$input" /soc '#address-cells') == 1 ]]
[[ $(fdtget -t x "$input" /soc '#size-cells') == 1 ]]
[[ $(fdtget -t s "$input" "$node" compatible) == 'qcom,cliffs7-llcc qcom,llcc-v50' ]]
[[ $(fdtget -t x "$input" "$node" reg) == '25000000 800000 25800000 200000' ]]
[[ $(fdtget -t s "$input" "$node" reg-names) == 'llcc_base llcc_broadcast_base' ]]
[[ $(fdtget -t x "$input" "$node" interrupts) == '0 10a 4' ]]
if fdtget -p "$input" "$node" | grep -Fxq status; then
    status=$(fdtget -t s "$input" "$node" status)
    [[ $status == okay || $status == ok ]]
fi
children=$(fdtget -l "$input" "$node")
if [[ -n $children ]]; then
    while IFS= read -r child; do [[ $child == llcc-perfmon ]]; done <<< "$children"
fi
work=$(mktemp -d "$(dirname -- "$output")/.llcc-dt.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
cp -- "$input" "$work/candidate.dtb"
chmod 600 "$work/candidate.dtb"
fdtput -t s "$work/candidate.dtb" "$node" compatible qcom,sm7675-llcc
fdtput -t s "$work/candidate.dtb" "$node" status okay
fdtput -t x "$work/candidate.dtb" "$node" reg \
    25000000 200000 25200000 200000 25400000 200000 \
    25600000 200000 25800000 200000
fdtput -t s "$work/candidate.dtb" "$node" reg-names \
    llcc0_base llcc1_base llcc2_base llcc3_base llcc_broadcast_base
for property in label cap-based-alloc-and-pwr-collapse; do
    if fdtget -p "$work/candidate.dtb" "$node" | grep -Fxq "$property"; then
        fdtput -d "$work/candidate.dtb" "$node" "$property"
    fi
done
if fdtget -l "$work/candidate.dtb" "$node" | grep -Fxq llcc-perfmon; then
    fdtput -r "$work/candidate.dtb" "$node/llcc-perfmon"
fi
[[ $(fdtget -t s "$work/candidate.dtb" "$node" compatible) == qcom,sm7675-llcc ]]
[[ $(fdtget -t x "$work/candidate.dtb" "$node" reg) == \
    '25000000 200000 25200000 200000 25400000 200000 25600000 200000 25800000 200000' ]]
# Publish without overwriting an existing result, including a concurrent creator.
ln -- "$work/candidate.dtb" "$output"
echo 'Cliffs7 native LLCC DT candidate prepared; boot and cache acceptance remain open'
