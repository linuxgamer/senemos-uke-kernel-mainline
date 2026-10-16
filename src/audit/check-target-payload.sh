#!/usr/bin/env bash
# Host-side scan of an already extracted target payload. Never runs target files.
set -euo pipefail
[[ $# == 1 && -d $1 ]] || { echo 'Usage: check-target-payload.sh EXTRACTED_TARGET_DIRECTORY' >&2; exit 2; }
for tool in realpath find od tr readelf; do
  command -v "$tool" >/dev/null || { printf 'Missing host audit tool: %s\n' "$tool" >&2; exit 2; }
done
root=$(realpath -- "$1")
failed=0
while IFS= read -r -d '' path; do
  if [[ -f $path && ! -L $path ]] && [[ $(od -An -tx1 -N4 -- "$path" | tr -d ' \n') == 7f454c46 ]]; then
    if ! readelf -d -- "$path" >/dev/null 2>&1; then
      printf 'Unreadable target ELF rejected: %s\n' "${path#"$root/"}" >&2; failed=1
    fi
  fi
done < <(find "$root" -mindepth 1 \( -type f -o -type l \) -print0)
((failed==0)) || exit 1
echo 'Extracted target payload: ELF files are readable'
