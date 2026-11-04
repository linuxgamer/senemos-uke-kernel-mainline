#!/usr/bin/env bash
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Prepared kernel}
before=$kernel/native-generated/ath11k-regulatory-before
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
ulimit -c 0
for mode in legacy extended warning; do
 marker='WMI debug must describe the converted firmware event'
 [[ $mode != warning ]] || marker='Firmware refusal warning must expose the converted status'
 set +e
 CC=gcc SANITIZE=0 ATH11K_STATUS_MODE=$mode ATH11K_STATUS_SOURCE=$before \
  bash "$owner/tests/ath11k-regulatory-status-contract.sh" "$kernel" > "$stage/$mode.log" 2>&1
 status=$?
 set -e
 if [[ $status != 134 ]] || ! grep -Fq "$marker" "$stage/$mode.log"; then
  cat "$stage/$mode.log"
  printf 'Old ath11k %s diagnostic proof did not reach its required assertion134\n' "$mode" >&2
  exit 1
 fi
 printf 'Actual old ath11k %s diagnostics fail at required assertion134\n' "$mode"
done
CC=gcc SANITIZE=0 ATH11K_STATUS_MODE=values ATH11K_STATUS_SOURCE=$before \
 bash "$owner/tests/ath11k-regulatory-status-contract.sh" "$kernel"
for compiler in gcc clang; do
 for sanitized in 0 1; do
  CC=$compiler SANITIZE=$sanitized bash "$owner/tests/ath11k-regulatory-status-contract.sh" "$kernel"
 done
done
