#!/usr/bin/env bash
# Exercise the actual alternate-build admission with a shell-only make fixture.
set -Eeuo pipefail
here=$(cd -- "$(dirname -- "$0")" && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
mkdir -p "$work"/{kernel,output/arch/arm64/boot,root,bin}
printf 'fixture\n' > "$work/output/.config"
printf 'fixture\n' > "$work/output/arch/arm64/boot/Image"
export UKE_KMS_TEST_OUTPUT=$work/output UKE_KMS_TEST_CALLS=$work/calls
cat > "$work/bin/make" <<'MAKE'
#!/bin/bash
set -Eeuo pipefail
printf 'called\n' >> "$UKE_KMS_TEST_CALLS"
for unit in mdp4 mdp5; do
    mkdir -p "$UKE_KMS_TEST_OUTPUT/drivers/gpu/drm/msm/disp/$unit"
    printf 'fixture object\n' > "$UKE_KMS_TEST_OUTPUT/drivers/gpu/drm/msm/disp/$unit/${unit}_kms.o"
done
MAKE
chmod 755 "$work/bin/make"
for release in 7.3.0-60 7.3.1-3; do
    for tree in lib/modules lib/senemos/kernel-updates share/senemos/uke; do
        mkdir -p "$work/root/usr/$tree/$release"
        printf 'retained\n' > "$work/root/usr/$tree/$release/payload"
    done
    PATH="$work/bin:$PATH" bash "$here/msm-kms-alternate-build.sh" "$work/kernel" "$work/output" "$work/root" "$release" >/dev/null
done
[[ $(wc -l < "$work/calls") == 2 ]]
for release in 7.3.1-0 7.3.1-03 7.3.01-3 7.3.2-1 7.4.0-1 7.3.1-3-unstable; do
    if PATH="$work/bin:$PATH" bash "$here/msm-kms-alternate-build.sh" "$work/kernel" "$work/output" "$work/root" "$release" >/dev/null 2>&1; then
        printf 'Unexpected alternate-build release admission: %s\n' "$release" >&2; exit 1
    fi
done
[[ $(wc -l < "$work/calls") == 2 ]]
printf 'Actual alternate KMS build admits 7.3.0/7.3.1; malformed, foreign and unqualified releases refused before make\n'
