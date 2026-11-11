#!/usr/bin/env bash
# Host metadata gate for the single public mainline source producer.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
spec=${1:-$root/packaging/senemos-uke-linux-kernel-mainline.spec}
command -v rpmspec >/dev/null
future=$(mktemp)
trap 'rm -f "$future"' EXIT
sed 's/^Version: .*/Version: 7.3.2/' "$spec" > "$future"
future_release=$(rpmspec -q --srpm --qf '%{RELEASE}' --target aarch64 "$future")
[[ $future_release == 1 || $future_release == 1.* ]]
expected=senemos-uke-linux-kernel-mainline
names=$(rpmspec -q --qf '%{NAME}\n' --target aarch64 "$spec")
[[ $names == "$expected"$'\n'"$expected-core"$'\n'"$expected-modules"$'\n'"$expected-dtbs"$'\n'"$expected-boot"$'\n'"$expected-singleboot" ]]
# Query expanded payload paths rather than retaining the old shared module ABI.
parsed=$(rpmspec --parse "$spec")
grep -Eq '^Provides: kernel-uname-r\(7\.3\.1-[1-9][0-9]*\)$' <<< "$parsed"
[[ $(grep -c '^Provides: installonlypkg(kernel)$' <<< "$parsed") == 5 ]]
# Flags 12 are an ordinary >= dependency; scriptlet-only requirements expire.
requires=$(rpmspec -q --target aarch64 --qf '[%{=NAME}\t%{REQUIRENAME}\t%{REQUIREFLAGS}\t%{REQUIREVERSION}\n]' "$spec")
grep -Fxq "$expected-boot"$'\tuke-kernel-update\t12\t1.9.0' <<< "$requires"
grep -Fxq "$expected-boot"$'\tuke-kernel-update(guarded-automatic)\t12\t1' <<< "$requires"
grep -Fxq "$expected-boot"$'\tuke-kernel-update(transaction-v1)\t12\t1' <<< "$requires"
grep -Fxq "$expected-boot"$'\tuke-kernel-update(final-transaction-v2)\t12\t1' <<< "$requires"
grep -Fxq "$expected-boot"$'\tuke-kernel-update(boot-reset-v1)\t12\t1' <<< "$requires"
grep -Fxq "$expected-boot"$'\tuke-boot-integration(kernel-touch-input-v2)\t12\t1' <<< "$requires"
if grep -Eq 'kernel-touch-(client|dispatch)|^Source9:' <<< "$parsed"; then
    echo 'Native input must not require the userspace capture processor' >&2; exit 1
fi
if grep -E '^Obsoletes:|^Conflicts:|^%post([[:space:]]|$)|^%pre([[:space:]]|$)|senemos-uke-linux-kernel-mainline-native' <<< "$parsed"; then
    echo 'Mainline source packages must preserve installed boot and fallback kernels' >&2
    exit 1
fi
[[ $(grep -c '^%posttrans boot -p /bin/sh$' "$spec") == 1 ]]
grep -Fx '/usr/bin/uke-kernel-update transaction /usr/lib/senemos/kernel-updates/%{krel} || exit 1' "$spec"
! grep -Fq '/usr/bin/uke-kernel-update apply ' "$spec"
grep -Fx 'Source4: senemos-native-profile-7.3.1.tar.xz' <<< "$parsed"
grep -F 'CONFIG_INITRAMFS_SOURCE=""' "$root/packaging/native/native.config"
bash "$root/tests/native-firewall-contract.sh"
if grep -Fq 'qcom_q6v5_pas' "$root/src/boot/early-modules.list"; then
    echo 'PAS must wait for OEM firmware on the real root' >&2
    exit 1
fi
grep -F 'git archive HEAD src/performance src/nfc src/leds src/video patches/video manifests/video-linux73-candidate-20261025.json src/display src/boot src/usb src/audio src/power src/input src/rtc patches/$(patch_series) patches/display patches/boot patches/input patches/usb patches/rtc tests' "$root/Makefile"
grep -Ex '(hdmi-only|speakers|microphones)' "$root/packaging/native/audio-profile"
grep -Fx 'native-v1' "$root/packaging/native/llcc-profile"
grep -F 'packaging/native/llcc-profile "$$assets/"' "$root/Makefile"
grep -Fx 'UKE_LLCC_PROFILE=$(cat "$profile/llcc-profile")' "$root/packaging/native/prepare.sh"
[[ ! -e $root/packaging/native/senemos-uke-linux-kernel-mainline-native.spec ]]
echo 'One mainline tuple, integer module ABI, matched boot and explicitly gated updater passed'
