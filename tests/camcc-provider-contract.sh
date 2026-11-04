#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Actual provider/VDD/forced-PM functions with host-only hardware boundaries.
set -Eeuo pipefail
[[ $# == 1 ]] || exit 2
kernel=$(realpath -- "$1")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
printf '%s  %s\n' \
    58333db1f02cd0d39d7b96d71ff828d35734eae67165c4b6aa573a1b61d815eb "$kernel/drivers/clk/qcom/vdd-class.c" \
    5d9ac761527a5fa82aa540305690b2b6f4a9a091dcd4a956dae02960b5d95edf "$kernel/drivers/clk/qcom/vdd-level.h" \
    63b02af3ee079df0d063c2a2d2720296a97db8f3f958f694c4f9ef28ff1b7cf9 "$kernel/drivers/clk/qcom/vdd-class.h" \
    3ba6c4baf1adeaa90043f46db08dfc9df2809209b4e29386e9148d26da827a9a "$kernel/drivers/base/power/runtime.c" \
    77e3f7970c89c51890982a711ea6fd72803ce00b04a7e03ae0611c5e83b5469b "$kernel/include/dt-bindings/regulator/qcom,rpmh-regulator-levels.h" | sha256sum -c -
for file in vdd-class.h vdd-level.h; do
    sed '/^#include /d' "$kernel/drivers/clk/qcom/$file" > "$work/$file"
done
cp "$kernel/include/dt-bindings/regulator/qcom,rpmh-regulator-levels.h" "$work/rpmh-levels.h"
sed '/^#include /d' "$kernel/drivers/clk/qcom/vdd-class.c" > "$work/vdd-functions.c"
sed '/^#include /d' "$project/src/camera/provider/camcc-sm7675-power.h" > "$work/provider-power.h"
sed '/^#include /d' "$project/src/camera/provider/camcc-sm7675-owner.h" > "$work/provider-owner.h"
awk '/^static DEFINE_VDD_REGULATORS/ {print}
     /^static struct clk_vdd_class \*cam_cc_sm7675_regulators/ {group=1}
     group {print; if ($0=="};")group=0}' "$project/src/camera/camcc-sm7675-data.h" > "$work/camcc-rails.h"
sed -n '/^#define CAM_CC_SM7675_REGMAP_FORMAT/,/^};/p' \
    "$project/src/camera/camcc-sm7675-data.h" > "$work/camcc-config.h"
awk '/^int pm_runtime_force_(suspend|resume)\(/ {inside=1}
     inside {print; if ($0=="}")inside=0}' "$kernel/drivers/base/power/runtime.c" > "$work/force-pm.c"
read -r -a flags <<< "${CAMCC_TEST_FLAGS:-}"
ulimit -c 0
cp "$work/provider-power.h" "$work/provider-power-candidate.h"
sed '/^#include /d' "$project/tests/fixtures/camcc-power-before-owner.h" > "$work/provider-power.h"
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare \
    -Wno-unused-but-set-variable -I"$work" -DOWNER_BASELINE \
    "$project/tests/fixtures/camcc-provider-check.c" -o "$work/before-owner"
set +e
"$work/before-owner" > "$work/before-owner.log" 2>&1
before_status=$?
set -e
[[ $before_status == 134 ]]
grep -Fq assert_resources_retained "$work/before-owner.log"
printf 'CAMCC owner: original managed resources fail the same failed-probe retention assertion (status %s)\n' "$before_status"
mv "$work/provider-power-candidate.h" "$work/provider-power.h"
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare \
    -Wno-unused-but-set-variable -I"$work" "${flags[@]}" \
    "$project/tests/fixtures/camcc-provider-check.c" -o "$work/provider"
"$work/provider"

[[ ${CAMCC_CLOCKS_TEST:-0} == 1 ]] || exit 0
sha256sum "$kernel/drivers/clk/qcom/clk-regmap.c"
printf '%s  %s\n' 8e1ffc25007a64b61f59b0c20dc6077b5595125b28582c020f47925bbe8da7e4 \
    "$kernel/drivers/clk/qcom/clk-regmap.c" | sha256sum -c -
sed '/^#include /d' "$project/src/camera/provider/camcc-sm7675-clocks.h" > "$work/provider-clocks.h"
awk '/^int clk_(pre_change_regmap|post_change_regmap|prepare_regmap)\(/ ||
     /^void clk_unprepare_regmap\(/ {copy=1}
     copy {print; if ($0=="}")copy=0}' \
    "$kernel/drivers/clk/qcom/clk-regmap.c" > "$work/clocks-voltage.c"
[[ $(grep -Ec '^int clk_(pre_change_regmap|post_change_regmap|prepare_regmap)\(|^void clk_unprepare_regmap\(' "$work/clocks-voltage.c") == 4 ]]
printf '%s  %s\n' 9783b62658f620b8e91d7b8400ec861fafddde547e79cfe1f1a00d9d101ed0d1 \
    "$work/clocks-voltage.c" | sha256sum -c -
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare \
    -Wno-unused-but-set-variable -I"$work" -DCLOCKS_BASELINE \
    "$project/tests/fixtures/camcc-clocks-check.c" -o "$work/before-clocks"
set +e
"$work/before-clocks" > "$work/before-clocks.log" 2>&1
before_status=$?
set -e
[[ $before_status == 134 ]]
grep -Fq 'cam_cc_mx.level_votes[VDD_LOW] == 1' "$work/before-clocks.log"
printf 'CAMCC clocks: native Rivian prepare lacks the required voltage vote (expected status %s)\n' "$before_status"
"${CC:-cc}" -std=gnu11 -O1 -g -Wall -Wextra -Werror \
    -Wno-unused-function -Wno-unused-parameter -Wno-sign-compare \
    -Wno-unused-but-set-variable -I"$work" "${flags[@]}" \
    "$project/tests/fixtures/camcc-clocks-check.c" -o "$work/clocks"
"$work/clocks"
