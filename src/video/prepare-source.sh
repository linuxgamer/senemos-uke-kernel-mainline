#!/usr/bin/env bash
# Native source preparation only; no donor code, firmware or device access.
set -Eeuo pipefail
kernel=$(realpath "${1:?Pass the prepared Linux 7.3 kernel source}")
root=$(cd -- "$(dirname -- "$0")/../.." && pwd)
manifest=$root/manifests/video-linux73-candidate-20261025.json
jq -e '.upstream_version == "7.3.0"' "$manifest" >/dev/null
version=$(awk '/^VERSION =/{v=$3} /^PATCHLEVEL =/{p=$3} /^SUBLEVEL =/{s=$3} END{print v "." p "." s}' "$kernel/Makefile")
case $version in 7.3.0|7.3.1) ;; *) exit 1;; esac
[[ ! -e $kernel/include/linux/qcom-uke-video.h ]]
# The mainline 7.3 preparation does not integrate the native display provider,
# but the Cliffs video routes live in its interconnect header and its DPU/DSI
# sources pull the display clock votes. Add that prerequisite first.
if [[ ! -e $kernel/drivers/interconnect/qcom/cliffs-display-icc.h ]]; then
    display=$kernel/native-profile
    [[ -d $display ]] || { echo 'native display profile is missing' >&2; exit 1; }
    patch=$display/patches/display/7.2.10/0001-native-display-providers.patch
    [[ -f $patch ]] || patch=$display/patches/display/0001-native-display-providers.patch
    [[ -e $kernel/drivers/interconnect/qcom/cliffs-display-icc.h ]] ||
        install -m644 "$display/src/display/cliffs-display-icc.h" \
            "$kernel/drivers/interconnect/qcom/cliffs-display-icc.h"
    git -C "$kernel" apply --check "$patch"
    git -C "$kernel" apply "$patch"
    [[ -e $kernel/drivers/clk/qcom/uke-dispcc-votes.c ]] ||
        install -m644 "$display/src/display/uke-dispcc-votes.c" \
            "$kernel/drivers/clk/qcom/uke-dispcc-votes.c"
fi
mkdir -p "$kernel/native-generated"
: > "$kernel/native-generated/video-source-SHA256SUMS"
while IFS=$'\t' read -r path expected; do
    [[ $path == patches/video/*.patch && $path != *'..'* && $expected =~ ^[a-f0-9]{64}$ ]]
    [[ $(sha256sum "$root/$path" | cut -d' ' -f1) == "$expected" ]]
    git -C "$kernel" apply --check "$root/$path"
    git -C "$kernel" apply "$root/$path"
    printf '%s  %s\n' "$expected" "$path" >> "$kernel/native-generated/video-source-SHA256SUMS"
done < <(jq -er '.patches[] | [.path,.sha256] | @tsv' "$manifest")
iris=$kernel/drivers/media/platform/qcom/iris
for fixture in iris-2p-lifecycle iris-boot-status iris-power-domain iris-resource-fault \
               iris-va-order iris-fw-memory iris-fw-lifetime iris-fw-queue \
               iris-sm7675-power iris-oneshot-irq iris-sm7675-caps iris-vp9-nonshow \
               iris-capture-cache iris-serial-budget iris-decode-order-stage; do
    bash "$root/tests/$fixture-contract.sh" "$iris"
done
bash "$root/tests/iris-smmu-contract.sh" "$kernel/drivers/iommu/arm/arm-smmu"
bash "$root/tests/video-reset-error-contract.sh" "$kernel/drivers/clk/qcom"
bash "$root/tests/videocc-vote-contract.sh" "$kernel/drivers/clk/qcom/uke-videocc-votes.c"
bash "$root/tests/videocc-retention-contract.sh" "$kernel/drivers/clk/qcom/videocc-sm8550.c"
bash "$root/tests/video-icc-topology-contract.sh" "$kernel"
bash "$root/tests/video-gcc-config-contract.sh" "$kernel/drivers/clk/qcom/gcc-cliffs.c"
printf 'Native Cliffs source prepared; firmware and target acceptance remain separate\n'
