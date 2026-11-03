#!/usr/bin/env bash
# Check the compiled overlay against an existing retained provider graph.
set -Eeuo pipefail
[[ $# == 3 && -s $1 && -d $2 && ! -e $3 ]] || exit 2
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$3"
cpp -nostdinc -undef -D__DTS__ -x assembler-with-cpp -I "$2/include" "$root/src/boot/sm7675-uke-ufs.dtso" > "$3/ufs.dts"
dtc -q -@ -I dts -O dtb -o "$3/ufs.dtbo" "$3/ufs.dts"
fdtoverlay -i "$1" -o "$3/ufs.dtb" "$3/ufs.dtbo"
host=/soc/ufshc@1d84000
[[ $(fdtget -t x "$3/ufs.dtb" "$host" reg) == '1d84000 3000 1d88000 11000 1da5000 2000 1da4000 10' ]]
[[ $(fdtget -t s "$3/ufs.dtb" "$host" reg-names) == 'std ice mcq_sqd mcq_vs' ]]
[[ $(fdtget -t s "$3/ufs.dtb" "$host" clock-names) == 'core_clk bus_aggr_clk iface_clk core_clk_unipro ref_clk tx_lane0_sync_clk rx_lane0_sync_clk rx_lane1_sync_clk ice_core_clk' ]]
gcc_path=$(fdtget -t s "$3/ufs.dtb" /__symbols__ gcc)
gcc=$(fdtget -t x "$3/ufs.dtb" "$gcc_path" phandle)
read -ra clocks <<< "$(fdtget -t x "$3/ufs.dtb" "$host" clocks)"
[[ ${#clocks[@]} == 18 && ${clocks[16]} == "$gcc" && ${clocks[17]} == 72 ]]
[[ $(fdtget -t x "$3/ufs.dtb" "$host" freq-table-hz) == '5f5e100 18054ac0 0 0 0 0 5f5e100 18054ac0 0 0 0 0 0 0 0 0 5f5e100 18054ac0' ]]
for label in gcc_ufs_mem_phy_gdsc gcc_ufs_phy_gdsc; do
    path=$(fdtget -t s "$3/ufs.dtb" /__symbols__ "$label")
    [[ $(fdtget -t s "$3/ufs.dtb" "$path" compatible) == qcom,sm7675-ufs-gdsc ]]
    [[ -z $(fdtget "$3/ufs.dtb" "$path" regulator-always-on) ]]
done
echo 'Compiled UFS ICE/MCQ resources, native clock and retained GDSC checks passed; host only'
