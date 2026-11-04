#!/usr/bin/env bash
# COPR only: compare exact old/corrected production protocol, no touch device.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
before=$owner/tests/fixtures/nt36532-before-gesture-ack.c
printf '%s  %s\n' a6b7f99b8a226c54f36dea8c58ab0176bf44012086c6908e005e97ab1703e6e3 "$before" | sha256sum -c --strict
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
ulimit -c 0
for mode in oem-sequence getter-refusal; do
 marker='Gesture entry must follow the OEM ACK-only setting sequence'
 [[ $mode != getter-refusal ]] || marker='Gesture entry must not depend on extra diagnostic readback'
 set +e
 CC=gcc UKE_TOUCH_SANITIZE= UKE_TOUCH_GESTURE_ONLY=1 UKE_TOUCH_GESTURE_MODE=$mode UKE_TOUCH_PROTOCOL_SOURCE=$before \
  bash "$owner/tests/touch-protocol-contract.sh" > "$stage/$mode.log" 2>&1
 status=$?
 set -e
 if [[ $status != 134 ]] || ! grep -Fq "$marker" "$stage/$mode.log"; then
  cat "$stage/$mode.log"
  printf 'Old gesture %s control did not reach its required assertion134\n' "$mode" >&2
  exit 1
 fi
 printf 'Actual old touch gesture %s fails at required assertion134\n' "$mode"
done
CC=gcc UKE_TOUCH_SANITIZE= UKE_TOUCH_GESTURE_ONLY=1 UKE_TOUCH_GESTURE_MODE=values UKE_TOUCH_PROTOCOL_SOURCE=$before \
 bash "$owner/tests/touch-protocol-contract.sh"
for compiler in gcc clang; do
 CC=$compiler UKE_TOUCH_SANITIZE= UKE_TOUCH_GESTURE_ONLY=1 bash "$owner/tests/touch-protocol-contract.sh"
 CC=$compiler UKE_TOUCH_SANITIZE=1 UKE_TOUCH_GESTURE_ONLY=1 bash "$owner/tests/touch-protocol-contract.sh"
done
