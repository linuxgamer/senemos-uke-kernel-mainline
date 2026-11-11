#!/usr/bin/env bash
# Refresh or check every source digest pinned by the kernel manifests.
# The manifests pin exact bytes of patches, configs, boot sources and fixtures;
# edit them only through this script instead of hunting manifests by hand.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
check=0
all=0
for arg in "$@"; do
    case $arg in
        --check) check=1 ;;
        --all) all=1 ;;
        *) printf 'Usage: %s [--check] [--all]\n' "${BASH_SOURCE[0]}" >&2; exit 2 ;;
    esac
done
drift=0

version=$(awk '/^version :=/ {print $3}' "$root/Makefile")
manifests=()
if (( all )); then
    manifests=("$root"/manifests/*.json)
else
    for name in "linux-$version.json" boot-payload.json \
                video-linux73-candidate-20261025.json; do
        [[ -f $root/manifests/$name ]] && manifests+=("$root/manifests/$name")
    done
    while IFS= read -r candidate; do
        [[ $(jq -r '.active_series // false' "$candidate") == true ]] && manifests+=("$candidate")
    done < <(find "$root/manifests" -name 'llcc-source-candidate-*.json' -print)
fi

for manifest in "${manifests[@]}"; do
    while IFS=$'\t' read -r path pinned; do
        [[ -n $path ]] || continue
        [[ $path != /* && $path != *..* ]] || continue
        file=$root/$path
        [[ -f $file ]] || continue
        actual=$(sha256sum "$file" | cut -d' ' -f1)
        [[ $actual == "$pinned" ]] && continue
        drift=$((drift + 1))
        printf '%s: %s\n' "$(basename "$manifest")" "$path" >&2
        (( check )) && continue
        tmp=$(mktemp)
        jq --arg p "$path" --arg s "$actual" '
            walk(if type == "object" and (.path? == $p) and (.sha256? != null)
                 then .sha256 = $s else . end)
        ' "$manifest" > "$tmp"
        mv "$tmp" "$manifest"
        printf 'updated %s: %s\n' "$(basename "$manifest")" "$path"
    done < <(jq -r '.. | objects
        | select((.path?|type) == "string" and (.sha256?|type) == "string")
        | [.path, .sha256] | @tsv' "$manifest")
done

if (( check )); then
    if (( drift )); then
        printf 'Run: bash tools/refresh-source-pins.sh\n' >&2
        exit 1
    fi
else
    printf 'refreshed %d pin(s)\n' "$drift"
fi
