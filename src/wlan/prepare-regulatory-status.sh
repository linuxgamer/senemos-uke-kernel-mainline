#!/usr/bin/env bash
# COPR only: repair diagnostics; preserve all regulatory state and decisions.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Prepared pinned Linux source}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
change=$owner/patches/boot/0062-ath11k-regulatory-status.patch
driver=drivers/net/wireless/ath/ath11k
before=$kernel/native-generated/ath11k-regulatory-before
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
git -C "$stage" init -q
apply=(git -C "$kernel" --git-dir "$stage/.git" --work-tree "$kernel" apply)
if "${apply[@]}" --check --reverse "$change" 2>/dev/null; then
 test -s "$before/$driver/wmi.c"
 test -s "$before/$driver/reg.c"
 printf 'ath11k country-status diagnostics already match the exact patch\n'
else
 printf '%s\n' \
  '9ab6c91245b95a0f69192d53b90cce41faf8f5e254edf340f9cf424de1a3cd8f  wmi.c' \
  'd81c3db8bf9cb98893d60004b4c0019339907a3a765c7f23c2aa985f63f8c634  reg.c' \
  '21bb62ac9b0b6d9816590b42eee648c297c6cecf9f3c656a53ce90cff0ddc5e9  wmi.h' \
  > "$stage/before.sha256"
 (cd "$kernel/$driver"; sha256sum -c --strict "$stage/before.sha256")
 for file in wmi.c reg.c; do
  install -Dm644 "$kernel/$driver/$file" "$before/$driver/$file"
 done
 "${apply[@]}" --check --whitespace=error-all "$change"
 "${apply[@]}" --whitespace=error-all "$change"
fi
printf '%s\n' \
 '9ab6c91245b95a0f69192d53b90cce41faf8f5e254edf340f9cf424de1a3cd8f  wmi.c' \
 'd81c3db8bf9cb98893d60004b4c0019339907a3a765c7f23c2aa985f63f8c634  reg.c' \
 > "$stage/saved-before.sha256"
(cd "$before/$driver"; sha256sum -c --strict "$stage/saved-before.sha256")
"${apply[@]}" --check --reverse "$change"
