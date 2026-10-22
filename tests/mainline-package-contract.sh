#!/usr/bin/env bash
# Host metadata gate for the single public mainline source producer.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
spec=${1:-$root/packaging/senemos-uke-linux-kernel-mainline.spec}
command -v rpmspec >/dev/null
future=$(mktemp)
trap 'rm -f "$future"' EXIT
sed 's/^Version: .*/Version: 7.2.12/' "$spec" > "$future"
future_release=$(rpmspec -q --srpm --qf '%{RELEASE}' --target aarch64 "$future")
[[ $future_release == 1 || $future_release == 1.* ]]
expected=senemos-uke-linux-kernel-mainline
names=$(rpmspec -q --qf '%{NAME}\n' --target aarch64 "$spec")
[[ $names == "$expected"$'\n'"$expected-core"$'\n'"$expected-modules"$'\n'"$expected-dtbs"$'\n'"$expected-boot" ]]
# Query expanded payload paths rather than retaining the old shared module ABI.
parsed=$(rpmspec --parse "$spec")
grep -Eq '^Provides: kernel-uname-r\(7\.2\.11-[1-9][0-9]*\)$' <<< "$parsed"
[[ $(grep -c '^Provides: installonlypkg(kernel)$' <<< "$parsed") == 4 ]]
if grep -E '^Obsoletes:|^Conflicts:|^%post([[:space:]]|$)|^%pre([[:space:]]|$)|senemos-uke-linux-kernel-mainline-native' <<< "$parsed"; then
    echo 'Mainline source packages must preserve installed boot and fallback kernels' >&2
    exit 1
fi
[[ $(grep -c '^%posttrans boot -p /bin/sh$' "$spec") == 1 ]]
grep -Fx "if grep -Fxq 'automatic=1' /etc/senemos/kernel-update.conf 2>/dev/null; then" "$spec"
grep -Fx 'Source4: senemos-native-profile-7.2.11.tar.xz' <<< "$parsed"
grep -F 'CONFIG_INITRAMFS_SOURCE=""' "$root/packaging/native/native.config"
if grep -Fq 'qcom_q6v5_pas' "$root/src/boot/early-modules.list"; then
    echo 'PAS must wait for OEM firmware on the real root' >&2
    exit 1
fi
grep -F 'git archive HEAD src/display src/boot src/usb src/audio patches/$(version) patches/display patches/boot tests' "$root/Makefile"
grep -Fx 'disabled' "$root/packaging/native/audio-profile"
[[ ! -e $root/packaging/native/senemos-uke-linux-kernel-mainline-native.spec ]]
echo 'One mainline tuple, integer module ABI, matched boot and explicitly gated updater passed'
