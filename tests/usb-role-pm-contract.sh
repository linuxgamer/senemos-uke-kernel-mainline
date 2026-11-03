#!/usr/bin/env bash
# COPR-only model of the actual Qualcomm role and system-sleep functions.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
candidate=${1:?Pass candidate dwc3-qcom.c}
baseline=${2:?Pass retained baseline dwc3-qcom.c}
fixture=$(cd -- "$(dirname -- "$0")" && pwd)/usb-role-pm-fixture.c
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
for variant in baseline candidate; do
    source_file=$candidate
    expected=0
    if [[ $variant == baseline ]]; then source_file=$baseline; expected=1; fi
    : > "$work/actual.inc"
    for symbol in dwc3_qcom_set_role_notifier dwc3_qcom_pm_suspend dwc3_qcom_pm_resume; do
        awk -v symbol="$symbol" '
          $0 ~ ("^static (void|int) " symbol "\\(") {emit=1; found++}
          emit {print}
          emit && /^}/ {emit=0; exit}
          END {if (found != 1) exit 1}
        ' "$source_file" >> "$work/actual.inc"
    done
    "${CC:-cc}" -std=gnu11 -pthread -Wall -Wextra -Werror \
        -DEXPECT_BASELINE="$expected" -I "$work" "$fixture" -o "$work/$variant"
    "$work/$variant"
done
