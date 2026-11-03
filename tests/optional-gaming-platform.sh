#!/usr/bin/env bash
# Verify the built platform rather than an application installation.
set -Eeuo pipefail
config=${1:?built kernel config}
modules=${2:?installed module tree}
release=${3:?kernel release}
output=${4:?kernel build directory}
for feature in ARM64_4K_PAGES FUTEX FUTEX_PI SYSVIPC NAMESPACES USER_NS \
               SECCOMP SECCOMP_FILTER MEMFD_CREATE INPUT_EVDEV HIDRAW DRM_MSM_GPU_STATE; do
    grep -Fx "CONFIG_$feature=y" "$config"
done
for feature in NTSYNC BINFMT_MISC INPUT_UINPUT DRM_MSM; do
    grep -Fx "CONFIG_$feature=m" "$config"
done
for path in drivers/misc/ntsync fs/binfmt_misc; do
    readelf -h "$output/$path.ko" | grep -q AArch64
    module="$modules/kernel/$path.ko.zst"
    test -s "$module"
    [[ $(modinfo -F vermagic "$module") == "$release "* ]]
    test -n "$(modinfo -F signer "$module")"
done
if grep -Eq '(^|/)(ntsync|binfmt_misc)([.]ko|[[:space:]]|$)' boot-recipe/src/boot/early-modules.list; then
    echo 'Optional Windows runtime modules entered early boot' >&2
    exit 1
fi
echo 'PASS: signed ARM64 runtime modules and existing graphics/input prerequisites; no Wine execution'
