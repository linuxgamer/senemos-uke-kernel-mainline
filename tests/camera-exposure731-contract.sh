#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR worker only: actual exposure function with an I2C fault boundary.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
kernel=$(realpath -- "$1")
baseline=$(realpath -- "$2")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
ulimit -c 0
printf '%s  %s\n' dea565800781f428397acd082c4cb76af2aee63eb51dc006b02000b13777a1ad \
    "$baseline/ov08d10.c" | sha256sum -c -
awk '/^#define OV08D10_(ROWCLK|REG_PAGE|REG_GLOBAL_EFFECTIVE|REG_EXPOSURE_[HML]|EXPOSURE_MAX_MARGIN)[[:space:]]/ {print}' \
    "$baseline/ov08d10.c" > "$work/exposure-constants.h"
[[ $(wc -l < "$work/exposure-constants.h") == 7 ]]
extract() {
    awk '/^static int ov08d10_set_exposure\(/ {copy=1}
         copy {print; if ($0=="}")copy=0}' "$1" > "$work/exposure-function.c"
    [[ $(grep -Fc 'static int ov08d10_set_exposure(' "$work/exposure-function.c") == 1 ]]
}
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror -I"$work")
fixture=$project/tests/fixtures/camera-exposure.c
extract "$baseline/ov08d10.c"
"${CC:-clang}" "${flags[@]}" -O0 -DEXPOSURE_BEFORE -fsanitize=undefined \
    -fno-sanitize-recover=all "$fixture" -o "$work/before"
for scenario in read zero; do
    set +e
    "$work/before" "$scenario" > "$work/before-$scenario.log" 2>&1
    status=$?
    set -e
    expected=134
    diagnostic='ret == -EREMOTEIO && writes == 1 && reads == 1'
    [[ $scenario != zero ]] || { expected=$status; diagnostic='runtime error: division by zero'; }
    if [[ $status == 0 || $status != "$expected" ]] ||
        ! grep -Fq 'Before-control: exposure must' "$work/before-$scenario.log" ||
        ! grep -Fq "$diagnostic" "$work/before-$scenario.log"; then
        printf 'Exposure before-control %s failed (status %s):\n' "$scenario" "$status" >&2
        cat "$work/before-$scenario.log" >&2
        exit 1
    fi
    printf 'OV08D10 actual before-control: %s reproduced (exit %s)\n' "$scenario" "$status"
done
extract "$kernel/drivers/media/i2c/ov08d10.c"
read -r -a extra <<< "${CAMERA_EXPOSURE_TEST_FLAGS:-}"
"${CC:-clang}" "${flags[@]}" "${extra[@]}" "$fixture" -o "$work/candidate"
"$work/candidate"
