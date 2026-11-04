#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Native COPR worker only; full actual GDSC functions with boundary fault models.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
baseline=$(realpath -- "$1")
production=$(realpath -- "$2")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
ulimit -c 0
printf '%s  %s\n' \
    04c66019948835d4b0def6f96d940500a85eb3e9c277f69de06c953f7d6475d2 "$baseline/drivers/clk/qcom/gdsc.c" \
    bea8e934482c13e1318ebe59bfd881cb91536e32afd9dae2676da9514d140ae9 "$baseline/drivers/clk/qcom/gdsc.h" | sha256sum -c -
mkdir -p "$work/drivers/clk/qcom"
cp "$baseline/drivers/clk/qcom/"gdsc.{c,h} "$work/drivers/clk/qcom/"
for patch in "$project"/src/camera/provider/000[123]-clk-qcom-gdsc-*.patch; do
    git -C "$work" apply --check "$patch"
    git -C "$work" apply "$patch"
done
printf '%s  %s\n' \
    f757ba3287aa1972f112d53e826aff617dcd253165005683058fb3ad7eff0bf8 "$work/drivers/clk/qcom/gdsc.c" \
    9cc382ce50464bfb1cdb2eaa6136fbc411932fb0af1f2f1d9e6d43915696e9c7 "$work/drivers/clk/qcom/gdsc.h" | sha256sum -c -
cp "$work/drivers/clk/qcom/gdsc.c" "$work/before.c"
patch=$project/src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch
git -C "$work" apply --check "$patch"
git -C "$work" apply "$patch"
cmp "$work/drivers/clk/qcom/gdsc.c" "$production/drivers/clk/qcom/gdsc.c"
cmp "$work/drivers/clk/qcom/gdsc.h" "$production/drivers/clk/qcom/gdsc.h"
# Only the appended descriptor field is provided to the before-control.
# Its complete old functions still publish managed storage, exposing the UAF.
sed '/^#include /d' "$work/drivers/clk/qcom/gdsc.h" > "$work/gdsc-header.h"
sed '/^#include /d' "$work/before.c" > "$work/gdsc-functions.c"
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-function
       -Wno-unused-parameter -Wno-sign-compare -DGDSC_STORAGE_TEST -I"$work")
fixture=$project/tests/fixtures/camcc-power-check.c
"${CC:-clang}" "${flags[@]}" -O0 -fsanitize=address -fno-omit-frame-pointer \
    -DGDSC_STORAGE_BEFORE "$fixture" -o "$work/before"
set +e
ASAN_OPTIONS=detect_leaks=0:halt_on_error=1 "$work/before" > "$work/before.log" 2>&1
status=$?
set -e
if [[ $status == 0 ]] ||
    ! grep -Fq 'Before-control: managed probe cleanup with a retained published provider' "$work/before.log" ||
    ! grep -Fq 'AddressSanitizer: heap-use-after-free' "$work/before.log"; then
    printf 'GDSC storage before-control did not identify the expected UAF (status %s):\n' "$status" >&2
    cat "$work/before.log" >&2
    exit 1
fi
printf 'GDSC actual before-control: ASan identified published-provider use-after-free (exit %s)\n' "$status"
sed '/^#include /d' "$production/drivers/clk/qcom/gdsc.c" > "$work/gdsc-functions.c"
read -r -a extra <<< "${GDSC_STORAGE_TEST_FLAGS:-}"
"${CC:-clang}" "${flags[@]}" "${extra[@]}" "$fixture" -o "$work/candidate"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$work/candidate"
printf 'GDSC permanent provider storage: actual production source/header match and lifetime assertions passed\n'
