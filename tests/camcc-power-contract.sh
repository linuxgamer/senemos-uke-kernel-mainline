#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host-only fault injection into the actual GDSC functions, never hardware.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
kernel=$(realpath -- "$1")
production=$(realpath -- "$2")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
printf '%s  %s\n' \
    04c66019948835d4b0def6f96d940500a85eb3e9c277f69de06c953f7d6475d2 "$kernel/drivers/clk/qcom/gdsc.c" \
    bea8e934482c13e1318ebe59bfd881cb91536e32afd9dae2676da9514d140ae9 "$kernel/drivers/clk/qcom/gdsc.h" | sha256sum -c -
mkdir -p "$work/drivers/clk/qcom"
cp "$kernel/drivers/clk/qcom/"gdsc.{c,h} "$work/drivers/clk/qcom/"
read -r -a flags <<< "${CAMCC_TEST_FLAGS:-}"
for role in baseline candidate; do
    if [[ $role == candidate ]]; then
        for patch in "$project"/src/camera/provider/0001-clk-qcom-gdsc-collapse-error.patch \
                     "$project"/src/camera/provider/0002-clk-qcom-gdsc-controller-pm.patch \
                     "$project"/src/camera/provider/0003-clk-qcom-gdsc-registration-unwind.patch; do
            git -C "$work" apply --check "$patch"
            git -C "$work" apply "$patch"
        done
        if [[ ${CAMCC_STORAGE_TEST:-0} == 1 ]]; then
            patch=$project/src/camera/provider/0004-clk-qcom-gdsc-permanent-storage.patch
            git -C "$work" apply --check "$patch"
            git -C "$work" apply "$patch"
        fi
        cmp "$work/drivers/clk/qcom/gdsc.c" "$production/drivers/clk/qcom/gdsc.c"
        cmp "$work/drivers/clk/qcom/gdsc.h" "$production/drivers/clk/qcom/gdsc.h"
    fi
    sed '/^#include /d' "$work/drivers/clk/qcom/gdsc.h" > "$work/gdsc-header.h"
    sed '/^#include /d' "$work/drivers/clk/qcom/gdsc.c" > "$work/gdsc-functions.c"
    extra=()
    [[ $role != baseline ]] || extra=(-DBASELINE)
    "${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
        -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare -I"$work" \
        "${flags[@]}" "${extra[@]}" "$project/tests/fixtures/camcc-power-check.c" -o "$work/$role"
    "$work/$role"
done
