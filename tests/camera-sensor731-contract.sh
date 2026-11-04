#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Run only on the COPR worker; import actual baseline and corrected functions.
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
printf '%s  %s\n' f3ea8784ee3a5cccda14e2b9f727eba4bd974b52c6656962f3c9ab6f82b447f6 \
    "$baseline/ov13b10.c" | sha256sum -c -
extract() {
    awk '/^static int ov08d10_get_hwcfg\(/ {copy=1}
         copy {print; if ($0=="}")copy=0}' "$1" > "$work/sensor-hwcfg-function.c"
    [[ $(grep -Fc 'static int ov08d10_get_hwcfg(' "$work/sensor-hwcfg-function.c") == 1 ]]
}
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror -I"$work")
extract "$baseline/ov08d10.c"
"${CC:-clang}" "${flags[@]}" -O0 -fsanitize=undefined \
    -fno-sanitize-recover=all -DSENSOR_BEFORE \
    "$project/tests/fixtures/camera-sensor-hwcfg.c" -o "$work/before"
set +e
"$work/before" > "$work/before.log" 2>&1
before_status=$?
set -e
if [[ $before_status == 0 ]] ||
    ! grep -Fq 'Before-control: debug enabled with unset current mode' "$work/before.log" ||
    ! grep -Eq 'runtime error: member access within null pointer of type .*ov08d10_mode' "$work/before.log"; then
    printf 'OV08D10 before-control failed to identify the expected NULL access (status %s):\n' "$before_status" >&2
    cat "$work/before.log" >&2
    exit 1
fi
printf 'OV08D10 actual before-control: UBSan identified the expected NULL access, exit %s\n' "$before_status"
extract "$kernel/drivers/media/i2c/ov08d10.c"
read -r -a extra <<< "${CAMERA_SENSOR_TEST_FLAGS:-}"
"${CC:-clang}" "${flags[@]}" "${extra[@]}" \
    "$project/tests/fixtures/camera-sensor-hwcfg.c" -o "$work/candidate"
"$work/candidate"
grep -Fq '.of_match_table = ov13b10_of_match' "$kernel/drivers/media/i2c/ov13b10.c"
grep -Fq 'ovti,ov13b10' "$kernel/drivers/media/i2c/ov13b10.c"
grep -Fq 'OVTI13B1' "$kernel/drivers/media/i2c/ov13b10.c"
test -s "$kernel/Documentation/devicetree/bindings/media/i2c/ovti,ov13b10.yaml"
