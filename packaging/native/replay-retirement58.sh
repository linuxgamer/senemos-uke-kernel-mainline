#!/usr/bin/env bash
# Replay only the parent files; native preparation independently matches them.
set -Eeuo pipefail
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
sources=$(realpath "${1:?Parent sources}")
profile=$(realpath "${2:?Parent profile}")
fixture=$(realpath -m "${3:?New replay directory}")
manifest=${4:-$owner/manifests/retirement58-parent-files.sha256}
bash "$owner/packaging/native/replay-kms57.sh" "$sources" "$profile" "$fixture" "$manifest" > /dev/null
includes=();files=()
while read -r hash path;do
 [[ $hash =~ ^[0-9a-f]{64}$ && $path == drivers/gpu/drm/msm/* && $path != *..* ]]
 includes+=("--include=$path");files+=("$path")
done < "$manifest"
git -C "$fixture" apply --allow-empty "${includes[@]}" "$profile/patches/display/0067-msm-kms-lifecycle-unwind.patch"
(cd "$fixture";sha256sum "${files[@]}")
