#!/usr/bin/env bash
# COPR only: require independent actual-old failures before corrected checks.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
kernel=${1:?Pinned prepared Linux source in COPR}
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
ulimit -c 0
for mode in access range; do
 marker='Cached jack telemetry must be read-only'
 [[ $mode != range ]] || marker='Cached jack telemetry must have a valid maximum'
 set +e
 CC=gcc SANITIZE=0 WCD_TELEMETRY_MODE=$mode \
  WCD_TELEMETRY_SOURCE="$owner/tests/fixtures/wcd939x-before-telemetry.c" \
  bash "$owner/tests/wcd939x-telemetry-contract.sh" "$kernel" > "$stage/$mode.log" 2>&1
 status=$?
 set -e
 if [[ $status != 134 ]] || ! grep -Fq "$marker" "$stage/$mode.log"; then
  cat "$stage/$mode.log"
  printf 'Actual old telemetry %s proof did not reach its required assertion134\n' "$mode" >&2
  exit 1
 fi
 printf 'Actual old WCD939x %s contract fails at required assertion134\n' "$mode"
done
CC=gcc SANITIZE=0 WCD_TELEMETRY_MODE=values \
 WCD_TELEMETRY_SOURCE="$owner/tests/fixtures/wcd939x-before-telemetry.c" \
 bash "$owner/tests/wcd939x-telemetry-contract.sh" "$kernel"
for compiler in gcc clang; do
 for sanitized in 0 1; do
  CC=$compiler SANITIZE=$sanitized bash "$owner/tests/wcd939x-telemetry-contract.sh" "$kernel"
 done
done
