#!/usr/bin/env bash
# Static contract for the ordered native preparation pass; no network or kernel.
#
# A source preparation step mutates the kernel tree, so invoking it twice applies
# the same patches and the same contracts again. That is how the COPR %prep broke:
# src/video/prepare-source.sh ran before and after the display receipts, the second
# call found include/linux/qcom-uke-video.h already created by its own patch 0012,
# and its re-entry guard exited 1 without printing anything.
set -Eeuo pipefail
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
recipe=${1:-$owner/packaging/native/prepare.sh}
[[ -f $recipe ]] || { printf 'Missing native preparation recipe: %s\n' "$recipe" >&2; exit 1; }

steps=()
while IFS= read -r step; do
    [[ -n $step ]] && steps+=("$step")
done < <(grep -oE 'bash "\$profile/src/[^"]+"' "$recipe" |
    sed -E 's/^bash "\$profile\///; s/"$//')
((${#steps[@]})) || { printf 'No source preparation steps in %s\n' "$recipe" >&2; exit 1; }

duplicates=$(printf '%s\n' "${steps[@]}" | LC_ALL=C sort | uniq -d)
if [[ -n $duplicates ]]; then
    printf 'Source preparation steps run more than once:\n%s\n' "$duplicates" >&2
    exit 1
fi

missing=''
for step in "${steps[@]}"; do
    [[ -f $owner/$step ]] || missing+="$step"$'\n'
done
if [[ -n $missing ]]; then
    printf 'Preparation steps that do not exist:\n%s' "$missing" >&2
    exit 1
fi

# The video overlay is appended to the ABL header written by the boot preparation,
# so the video step must stay after that step. Line order, not the numbers.
boot_line=$(grep -nE 'src/boot/prepare-abl-source\.sh' "$recipe" | head -n1 | cut -d: -f1)
video_line=$(grep -nE 'src/video/prepare-source\.sh' "$recipe" | head -n1 | cut -d: -f1)
if [[ -z $boot_line || -z $video_line ]]; then
    printf 'Missing the boot or the video preparation step\n' >&2
    exit 1
fi
if ((video_line < boot_line)); then
    printf 'The video step (%s) runs before the boot ABL header step (%s)\n' \
        "$video_line" "$boot_line" >&2
    exit 1
fi

printf 'Native preparation runs %d unique source steps once each; video follows the boot header\n' \
    "${#steps[@]}"
