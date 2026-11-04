#!/usr/bin/env bash
# COPR only. Verify the actual signed module and absence of the new DT matches.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
root=$(realpath "$1")
release=$2
[[ $release =~ ^7\.3\.1-[1-9][0-9]{3,4}$ ]]
module=$root/usr/lib/modules/$release/kernel/drivers/media/platform/qcom/camss/qcom-camss.ko.zst
test -s "$module"
modinfo -F alias "$module" | grep -Fx 'of:N*T*Cqcom,sm7675-camssC*'
[[ $(modinfo -F vermagic "$module") == "$release "* ]]
test -n "$(modinfo -F signer "$module")"
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
zstd -dc "$module" > "$work/qcom-camss.ko"
llvm-nm --defined-only "$work/qcom-camss.ko" | awk '$NF=="csiphy_ops_sm7675" {found=1} END {exit !found}'
count=0
test -d "$root/usr/lib/modules/$release/dtb"
while IFS= read -r -d '' dtb; do
 count=$((count+1))
 if grep -aqE 'qcom,sm7675-camss|qcom,sm7675-camcc' "$dtb"; then
  printf 'Unexpected native camera activation compatible in packaged DT\n' >&2
  exit 1
 fi
done < <(find "$root/usr/lib/modules/$release/dtb" -type f -name '*.dtb' -print0)
[[ $count -gt 0 ]]
printf 'SM7675 CAMSS OF alias, vermagic and signer checked in actual module; new camera matches absent from %s packaged DTB(s); no device result\n' "$count"
