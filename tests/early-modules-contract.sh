#!/usr/bin/env bash
# Exercise the actual staging loop on regular files; no kernel or device is run.
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
sed -n '/^while IFS= read -r path; do$/,/^done < "\$here\/early-modules.list"$/p' \
    "$root/src/boot/build-payload.sh" > "$work/loop.sh"
[[ $(grep -c '^while IFS= read -r path; do$' "$work/loop.sh") == 1 ]]
grep -Fxq 'done < "$here/early-modules.list"' "$work/loop.sh"
export source_modules=$work/modules target=$work/target here=$work/profile
mkdir -p "$source_modules/kernel/drivers/fixture" "$target/kernel" "$here"
printf 'module fixture\n' > "$source_modules/kernel/drivers/fixture/required.ko.zst"
printf '%s\n' drivers/fixture/required.ko.zst lib/raid/raid6/raid6_pq.ko.zst lib/zstd/zstd_compress.ko.zst > "$here/early-modules.list"
printf '%s\n' kernel/lib/raid/raid6/raid6_pq.ko kernel/lib/zstd/zstd_compress.ko > "$source_modules/modules.builtin"
bash -Eeuo pipefail "$work/loop.sh"
cmp "$source_modules/kernel/drivers/fixture/required.ko.zst" "$target/kernel/drivers/fixture/required.ko.zst"
[[ ! -e $target/kernel/lib ]]
reject() { if bash -Eeuo pipefail "$work/loop.sh" > "$work/refusal.log" 2>&1; then exit 1; fi; }
printf '%s\n' kernel/wrong/path/raid6_pq.ko kernel/lib/zstd/zstd_compress.ko > "$source_modules/modules.builtin"
reject
printf '%s\n' drivers/fixture/missing.ko.zst > "$here/early-modules.list"
reject
printf '%s\n' ../outside.ko.zst > "$here/early-modules.list"
reject
echo 'Actual early-module loop copies modules, admits exact built-in dependencies and refuses missing or malformed paths; regular files only.'
