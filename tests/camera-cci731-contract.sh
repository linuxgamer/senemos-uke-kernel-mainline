#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# COPR only: actual probe/reset/IRQ bodies with modeled Linux and MMIO edges.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
before=$(realpath "$1")/drivers/i2c/busses/i2c-qcom-cci.c
after=$(realpath "$2")/drivers/i2c/busses/i2c-qcom-cci.c
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
printf '%s  %s\n' 45b2dc46ea637f411a39f9352156e91d85a191b4fd3d2bfb44d5b7fc81d57693 "$before" | sha256sum -c --strict
for variant in before after; do
 source=${!variant}
 for function in cci_probe cci_reset cci_isr; do
  awk -v name="$function" '$0 ~ "^static (int|irqreturn_t) " name "\\(" {copy=1} copy {print} copy && /^}/ {exit}' \
   "$source" > "$work/$variant-$function.h"
 done
done
printf '%s\n' \
 '29bdf746b531383dfd58ade465de93640f3e0dd2fa997bb73bde4860289ad67a  before-cci_probe.h' \
 '70b824e8d8ed0ca21d9465192ede54ca7fa94f0d64c514cfd6ceef70cba9c28a  after-cci_probe.h' \
 'a19d47514e76b4276c000694ee953f41c4fbd5a8a972c98b8fd4b5f07821d868  before-cci_isr.h' \
 'a19d47514e76b4276c000694ee953f41c4fbd5a8a972c98b8fd4b5f07821d868  after-cci_isr.h' \
 'f450a228d8e7c3269619159af7f7ad071efa8e341903e8497223a5eaa33114d2  before-cci_reset.h' \
 'f450a228d8e7c3269619159af7f7ad071efa8e341903e8497223a5eaa33114d2  after-cci_reset.h' \
 > "$work/functions.sha256"
(cd "$work"; sha256sum -c --strict functions.sha256)
# Import the unchanged source register definitions instead of duplicating them.
awk '/^#define/ {copy=1} copy {print; if ($0 !~ /\\$/) copy=0}' "$before" > "$work/cci-registers.h"
read -ra flags <<< "${CAMERA_CCI_TEST_FLAGS:-}"
# Imported kernel bodies use signed loop variables with unsigned master counts.
# Keep the real types and the kernel's warning policy for that existing code.
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter -Wno-sign-compare \
 "${flags[@]}" -I"$work" "$project/tests/fixtures/camera-cci-reset-check.c" -o "$work/check"
ulimit -c 0
set +e
"$work/check" before > "$work/before.log" 2>&1
status=$?
set -e
[[ $status != 0 ]]
grep -F 'Original master-1-only probe reaches an uninitialized completion' "$work/before.log"
grep -F 'Assertion' "$work/before.log"
printf 'Original CCI completion control reproduced (exit %s)\n' "$status"
"$work/check"
