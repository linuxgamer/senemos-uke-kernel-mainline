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
