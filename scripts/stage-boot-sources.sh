#!/usr/bin/env bash
# Stage the exact reviewed source-only boot recipe.
set -Eeuo pipefail
[[ $# == 1 && -d $1 ]] || exit 2
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
destination=$(realpath "$1") lock=$root/manifests/boot-payload.json
work=$(mktemp -d); trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work/boot-recipe/src/boot" "$work/boot-recipe/patches/boot" "$work/boot-recipe/configs"
while IFS=$'\t' read -r path expected; do
    [[ $path != /* && $path != *..* && -f $root/$path ]]
    [[ $(sha256sum "$root/$path" | cut -d ' ' -f1) == "$expected" ]] || {
        printf 'Boot recipe source hash mismatch: %s\n' "$path" >&2
        exit 1
    }
    install -Dm644 "$root/$path" "$work/boot-recipe/$path"
done < <(jq -er '.source_assets[] | [.path,.sha256] | @tsv' "$lock")
cp "$lock" "$work/boot-recipe/lock.json"
tar --sort=name --mtime="@$(jq -er .source_date_epoch "$lock")" --owner=0 --group=0 --numeric-owner \
    -cJf "$destination/senemos-uke-boot-recipe.tar.xz" -C "$work" boot-recipe
cp "$lock" "$destination/boot-payload.json"
