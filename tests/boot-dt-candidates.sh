#!/usr/bin/env bash
# Host-only stock graph fixture: no flashing, runtime RAM or board selection.
set -Eeuo pipefail
[[ $# == 2 && -d $1 && -d $2 ]]
receipt=$(realpath "$1") kernel=$(realpath "$2")
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/build"
fixture=$(mktemp -d "$root/build/boot-dt-test-XXXXXX")
trap 'rm -rf "$fixture"' EXIT
bash "$root/build.sh" --prepare-boot-dt "$receipt" "$kernel" "$fixture/candidates" --usb2-peripheral
for index in 0 1 2 3; do
    candidate=$fixture/candidates/stock-ufs-$index.dtb
    for label in gcc_ufs_mem_phy_gdsc gcc_ufs_phy_gdsc gcc_usb30_prim_gdsc; do
        node=$(fdtget -t s "$candidate" /__symbols__ "$label")
        gcc=$(fdtget -t s "$candidate" /__symbols__ gcc)
        [[ $(fdtget -t x "$candidate" "$node" qcom,clock-controller) == "$(fdtget -t x "$candidate" "$gcc" phandle)" ]]
        [[ $(fdtget -t x "$candidate" "$node" reg | awk '{print $2}') == 8 ]]
    done
    aggre1=$(fdtget -t s "$candidate" /__symbols__ aggre1_noc)
    [[ $(fdtget -t x "$candidate" /soc/ufshc@1d84000 interconnects | awk '{print $1}') == "$(fdtget -t x "$candidate" "$aggre1" phandle)" ]]
    [[ $(fdtget -t s "$candidate" /soc/ssusb@a600000 compatible) == qcom,sm7675-dwc3 ]]
    [[ $(fdtget -t s "$candidate" /soc/apps-smmu@15000000 compatible) == 'qcom,sm7675-boot-smmu qcom,sm7675-usb-smmu' ]]
    [[ $(fdtget -t s "$candidate" / compatible) == 'xiaomi,uke qcom,sm7675 qcom,cliffs' ]]
    [[ $(fdtget -t x "$candidate" /memory reg) == "$(fdtget -t x "$receipt/derived/merged-$index.dtb" /memory reg)" ]]
done
jq -e '.launchable==false and .selected_dtb_index==null and .boot_tested==false and .hardware_tested==false and .esp32_host_qualified==false and .usb2_peripheral_source_candidate==true' "$fixture/candidates/manifest.json" >/dev/null
if bash "$root/build.sh" --prepare-boot-dt "$receipt" "$kernel" "$fixture/candidates" >/dev/null 2>&1; then
    echo 'Existing candidate output was overwritten' >&2; exit 1
fi
if bash "$root/build.sh" --prepare-boot-dt "$receipt" "$kernel" "$fixture/host" --usb2-host >/dev/null 2>&1; then
    echo 'Unadmitted host role was accepted' >&2; exit 1
fi
mkdir "$fixture/foreign"
jq '.scope="runtime-device-tree"' "$receipt/manifest.json" > "$fixture/foreign/manifest.json"
if bash "$root/build.sh" --prepare-boot-dt "$fixture/foreign" "$kernel" "$fixture/rejected" >/dev/null 2>&1; then
    echo 'Foreign receipt scope was accepted' >&2; exit 1
fi
mkdir "$fixture/unsupported-kernel"
printf 'VERSION = 8\nPATCHLEVEL = 0\nSUBLEVEL = 0\n' > "$fixture/unsupported-kernel/Makefile"
if bash "$root/build.sh" --prepare-boot-dt "$receipt" "$fixture/unsupported-kernel" "$fixture/wrong-version" >/dev/null 2>&1; then
    echo 'Unsupported kernel version was accepted' >&2; exit 1
fi
cp -a --reflink=auto "$receipt" "$fixture/corrupt"
printf tamper >> "$fixture/corrupt/derived/merged-0.dtb"
if bash "$root/build.sh" --prepare-boot-dt "$fixture/corrupt" "$kernel" "$fixture/corrupt-output" >/dev/null 2>&1; then
    echo 'Corrupted merged input was accepted' >&2; exit 1
fi
echo 'Four DT provider/clock/role fixtures and receipt/output/host/corruption rejection checks passed'
