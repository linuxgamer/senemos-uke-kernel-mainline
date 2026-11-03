#!/usr/bin/env bash
# COPR-only source preparation; no firmware call or device operation.
set -Eeuo pipefail
kernel=$(realpath "${1:?kernel source}")
output=$(realpath "${2:?source receipt directory}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
git -C "$kernel" apply --check "$owner/patches/rtc/0001-uke-secure-rtc-offset.patch"
git -C "$kernel" apply "$owner/patches/rtc/0001-uke-secure-rtc-offset.patch"
install -m644 "$owner/src/rtc/uke-rtc-policy.h" "$kernel/include/linux/uke-rtc-policy.h"
install -m644 "$owner/src/boot/uke-rtc.h" "$kernel/arch/arm64/kernel/uke-rtc.h"
bash "$owner/tests/rtc-secure-contract.sh" "$kernel"
sha256sum "$owner/patches/rtc/0001-uke-secure-rtc-offset.patch" \
 "$owner/src/rtc/uke-rtc-policy.h" "$owner/src/boot/uke-rtc.h" \
 "$kernel/drivers/rtc/rtc-pm8xxx.c" "$kernel/drivers/firmware/qcom/qcom_scm.c" > "$output/rtc-secure-SHA256SUMS"
