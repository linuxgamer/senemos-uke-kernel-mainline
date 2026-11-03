#!/usr/bin/env bash
# Host metadata gate for the single public mainline source producer.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
spec=${1:-$root/packaging/senemos-uke-linux-kernel-mainline.spec}
command -v rpmspec >/dev/null
future=$(mktemp)
trap 'rm -f "$future"' EXIT
sed 's/^Version: .*/Version: 7.3.1/' "$spec" > "$future"
future_release=$(rpmspec -q --srpm --qf '%{RELEASE}' --target aarch64 "$future")
[[ $future_release == 1 || $future_release == 1.* ]]
expected=senemos-uke-linux-kernel-mainline-unstable
names=$(rpmspec -q --qf '%{NAME}\n' --target aarch64 "$spec")
[[ $names == "$expected"$'\n'"$expected-core"$'\n'"$expected-modules"$'\n'"$expected-dtbs"$'\n'"$expected-boot"$'\n'"$expected-singleboot" ]]
# Query expanded payload paths rather than retaining the old shared module ABI.
parsed=$(rpmspec --parse "$spec")
grep -Eq '^Provides: kernel-uname-r\(7\.3\.0-[1-9][0-9]*-unstable\)$' <<< "$parsed"
[[ $(grep -c '^Provides: installonlypkg(kernel)$' <<< "$parsed") == 4 ]]
grep -Fxq 'Requires: uke-kernel-update(kernel-touch-client-v1) >= 1' <<< "$parsed"
grep -Fxq 'Requires: uke-boot-integration(kernel-touch-dispatch-v1) >= 1' <<< "$parsed"
grep -Fxq 'Source9: senemos-uke-touch-runtime-1.tar.xz' <<< "$parsed"
if grep -E '^Obsoletes:|^Conflicts:|^%(pre|post|preun|postun|pretrans|posttrans|trigger[a-z]*)($|[[:space:]])' <<< "$parsed"; then
    echo 'Unstable packages must coexist without automatic activation' >&2
    exit 1
fi
grep -Fx 'Source4: senemos-native-profile-7.3.0.tar.xz' <<< "$parsed"
grep -F 'CONFIG_INITRAMFS_SOURCE=""' "$root/packaging/native/native.config"
bash "$root/tests/native-firewall-contract.sh"
if grep -Fq 'qcom_q6v5_pas' "$root/src/boot/early-modules.list"; then
    echo 'PAS must wait for OEM firmware on the real root' >&2
    exit 1
fi
grep -F 'git archive HEAD src/display src/boot src/usb src/audio src/power src/input patches/$(version) patches/display patches/boot tests' "$root/Makefile"
grep -Ex '(hdmi-only|speakers)' "$root/packaging/native/audio-profile"
grep -Fx 'native-v1' "$root/packaging/native/llcc-profile"
grep -F 'packaging/native/llcc-profile "$$assets/"' "$root/Makefile"
grep -Fx 'UKE_LLCC_PROFILE=$(cat "$profile/llcc-profile")' "$root/packaging/native/prepare.sh"
[[ ! -e $root/packaging/native/senemos-uke-linux-kernel-mainline-native.spec ]]
bash "$root/tests/unstable-boot-status-contract.sh"
build_guard=$(sed -n '/^\[\[ \$release =~ /p' "$root/src/boot/build-payload.sh")
base_guard=$(sed -n '/^\[\[ \$# == 2 && \$2 =~ /p' "$root/src/boot/make-initramfs-base.sh")
release=7.3.0-3-unstable jobs=2
eval "$build_guard"
(set -- fixture "$release"; eval "$base_guard")
release=7x3y0-3-unstable
if (eval "$build_guard") || (set -- fixture "$release"; eval "$base_guard"); then
    echo 'Producer release separators must be literal dots' >&2; exit 1
fi
prepare_guard=$(sed -n '/^case \$version in /p' "$root/src/boot/prepare-abl-source.sh")
version=7.3.0
eval "$prepare_guard"
version=7.4.0
if (eval "$prepare_guard"); then
    echo 'Unqualified source version accepted' >&2; exit 1
fi
echo 'Unstable namespace, isolated module ABI, matched boot and no activation passed'
