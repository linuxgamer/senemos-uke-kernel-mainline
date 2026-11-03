#!/usr/bin/env bash
# Host-only integration; the experimental Kconfig symbols default off.
set -Eeuo pipefail
[[ $# == 1 && -f $1/arch/arm64/kernel/head.S ]] || exit 64
kernel=$(realpath "$1")
here=$(cd -- "$(dirname -- "$0")" && pwd)
patch=$here/../../patches/boot/0013-uke-el2-entry.patch
git -C "$kernel" apply --check "$patch"
git -C "$kernel" apply "$patch"
install -m644 "$here/uke-el2-entry.S" "$kernel/arch/arm64/kernel/uke-el2-entry.S"
