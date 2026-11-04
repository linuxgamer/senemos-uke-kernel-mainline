#!/usr/bin/env bash
# COPR only. Real native helper and stable generic callback, modeled MMIO only.
set -Eeuo pipefail
[[ $# == 1 ]] || exit 2
kernel=$(realpath "$1")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source=$kernel/drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c
printf '%s  %s\n' 7b1fc8f45d02bd861455ab90ca509e3a688e1714290121e6f7319c8a10091d71 "$source" | sha256sum -c -
oem=$project/referances/camera-phy221
printf '%s  %s\n' \
 5d5bc215b97bdec610ec4698c49a297c0ccdfab211fb4c3380b8555ef63ca99a "$oem/cam_csiphy_2_2_1_hwreg.h" \
 11f6a85cfb70ca7edbbe3a41c395fbe525c1db822f881171c527de652de78cb9 "$oem/cam_csiphy_core.c" \
 efef1af717f54ad458a1db00c989fcaa4fdd775a8572d49ea8924cfad0ccee82 "$oem/cam_csiphy_dev.h" | sha256sum -c -
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^struct csiphy_lane_regs \{/ {copy=1} copy {print} copy && /^};/ {exit}' "$source" > "$work/entry-type.h"
for function in csiphy_settle_cnt_calc csiphy_gen2_config_lanes; do
 awk -v fn="$function" '$0 ~ "^static .* "fn"\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$source" >> "$work/native-before.h"
done
awk '
 /^struct csiphy_reg_t csiphy_(common_reg_2_2_1|reset_enter_reg_2_2_1|reset_exit_reg_2_2_1|2ph_v2_2_1_reg)\[\] = \{/ {copy=1}
 copy {print}
 copy && /^};/ {copy=0}
' "$oem/cam_csiphy_2_2_1_hwreg.h" | sed 's/\<CSIPHY_/OEM_CSIPHY_/g' > "$work/oem-data.h"
awk '/^#define CSIPHY_.*BIT\(/ {print}' "$oem/cam_csiphy_dev.h" | \
 sed 's/\<CSIPHY_/OEM_CSIPHY_/g' > "$work/oem-types.h"
awk '/^struct csiphy_reg_t \{/ {copy=1} copy {print} copy && /^};/ {exit}' \
 "$oem/cam_csiphy_dev.h" >> "$work/oem-types.h"
awk '/^static int __csiphy_prgm_common_data\(/ {copy=1} copy {print} copy && /^}/ {exit}' \
 "$oem/cam_csiphy_core.c" | sed 's/\<CSIPHY_/OEM_CSIPHY_/g' > "$work/oem-common.h"
awk '
 /xiaomi add DPHY log - end/ {ready=1; next}
 ready && /^\tfor \(i = 0; i < cfg_size; i\+\+\) \{/ {copy=1}
 copy {print}
 copy && /^\t}/ {exit}
' "$oem/cam_csiphy_core.c" | sed 's/\<CSIPHY_/OEM_CSIPHY_/g' > "$work/oem-lanes.h"
test -s "$work/oem-common.h"
test -s "$work/oem-lanes.h"
sed '/^#include /d' "$project/src/camera/camss/csiphy-sm7675.h" > "$work/phy.h"
read -ra flags <<< "${CAMSS_PHY_TEST_FLAGS:-}"
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" -I"$work" \
 "$project/tests/fixtures/camss-sm7675-phy-check.c" -o "$work/check"
ulimit -c 0
set +e
"$work/check" before > "$work/before.log" 2>&1
status=$?
set -e
[[ $status != 0 ]]
grep -F 'Original generic CSIPHY skipped the required zero skew writes' "$work/before.log"
grep -F 'Assertion' "$work/before.log"
printf 'Original generic CSIPHY zero-skew control reproduced (exit %s)\n' "$status"
"$work/check"
