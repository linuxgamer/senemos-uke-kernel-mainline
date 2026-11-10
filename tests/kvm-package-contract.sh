#!/usr/bin/env bash
# shellcheck disable=SC2016
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
spec=$root/packaging/senemos-uke-linux-kernel-mainline.spec
family=$(sed -n 's/^Name: //p' "$spec")
if [[ $family == senemos-uke-linux-kernel-mainline ]]; then
    bash "$root/tests/el2-profile-contract.sh"
    bash "$root/tests/mainline-package-contract.sh"
    echo 'Main package identity retained; KVM sources are inactive and separately selected'
    exit 0
fi
expected=senemos-uke-linux-kernel-mainline-kvm
names=$(rpmspec -q --qf '%{NAME}\n' --target aarch64 "$spec")
[[ $names == "$expected"$'\n'"$expected-core"$'\n'"$expected-modules"$'\n'"$expected-dtbs"$'\n'"$expected-boot"$'\n'"$expected-singleboot" ]]
parsed=$(rpmspec --parse --target aarch64 "$spec")
grep -Eq '^Provides: kernel-uname-r\([0-9]+\.[0-9]+\.[0-9]+-[1-9][0-9]*-kvm\)$' <<< "$parsed"
if grep -E '^Obsoletes:|^Conflicts:|^%(post|pre|preun|postun|posttrans|pretrans|trigger)($|[[:space:]])' <<< "$parsed"; then
    echo 'KVM candidates must coexist without automatic activation' >&2; exit 1
fi
for requirement in CONFIG_KVM=y CONFIG_F2FS_FS=y CONFIG_F2FS_FS_SECURITY=y CONFIG_VIDEO_NT36532_UKE_THP=m; do
    grep -Fxq "$requirement" "$root/packaging/native/native.config"
done
grep -Fxq 'Requires: uke-kernel-update(kernel-touch-client-v1) >= 1' <<< "$parsed"
grep -Fxq 'Requires: uke-boot-integration(kernel-touch-dispatch-v1) >= 1' <<< "$parsed"
grep -Fxq 'Source9: senemos-uke-touch-runtime-1.tar.xz' <<< "$parsed"
grep -Fq 'git archive HEAD src/kvm KVM.md LICENSE' "$root/Makefile"
grep -Fq '"$out/userdata.img"' "$root/src/boot/build-payload.sh"
bash "$root/tests/native-firewall-contract.sh"
build_guard=$(sed -n '/^\[\[ \$release =~ /p' "$root/src/boot/build-payload.sh")
base_guard=$(sed -n '/^\[\[ \$# == 2 && \$2 =~ /p' "$root/src/boot/make-initramfs-base.sh")
# The extracted producer guard consumes jobs through eval.
# shellcheck disable=SC2034
release=7.2.12-3-kvm jobs=2
eval "$build_guard"
(set -- fixture "$release"; eval "$base_guard")
release=7x2y12-3-kvm
if (eval "$build_guard") || (set -- fixture "$release"; eval "$base_guard"); then
    echo 'Producer release separators must be literal dots' >&2; exit 1
fi
echo 'Current KVM namespace, distinct module ABI, both roots and no activation scriptlets passed'
