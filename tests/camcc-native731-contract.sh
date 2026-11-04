#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Execute only on COPR; import actual source bodies and framework helper contracts.
set -Eeuo pipefail
[[ $# == 1 ]] || exit 2
kernel=$(realpath -- "$1")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^struct cam_cc_clock \{/ {copy=1} copy {print;if($0=="};")exit}' \
    "$project/src/camera/provider/camcc-sm7675-clocks.h" > "$work/clock-state.h"
awk '/^static inline int dev_set_drv_sync_state\(/ {copy=1} copy {print;if($0=="}")exit}' \
    "$kernel/include/linux/device.h" > "$work/device-sync-function.c"
awk '/^static void genpd_set_stay_on\(/ {copy=1} copy {print;if($0=="}")exit}' \
    "$kernel/drivers/pmdomain/core.c" > "$work/genpd-stay-function.c"
printf '%s  %s\n' \
    105f627f098606f82fb739dfb5cb8a9076ef3214826eb1d261289a78a1156434 "$work/device-sync-function.c" \
    b367dc2f87a740bdd1b885e09c17bd65dd1985a3f0881a013395d6b513ed9dc8 "$work/genpd-stay-function.c" | sha256sum -c -
for part in handoff registration; do
    sed '/^#include /d' "$project/src/camera/provider/camcc-sm7675-$part.h" > "$work/native-$part.h"
done
flags=(-std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter
       -Wno-unused-function -Wno-sign-compare -I"$work")
read -r -a extra <<< "${CAMCC_NATIVE_TEST_FLAGS:-}"
"${CC:-clang}" "${flags[@]}" "${extra[@]}" \
    "$project/tests/fixtures/camcc-native-check.c" -o "$work/native"
ASAN_OPTIONS=detect_leaks=1:halt_on_error=1 "$work/native"
printf 'Actual native CAMCC registration/handoff functions passed boundary models; hardware remains unqualified\n'
