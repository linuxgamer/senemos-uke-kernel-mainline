#!/usr/bin/env bash
# COPR-only: compile changed legacy KMS units without relinking shipped modules.
set -Eeuo pipefail
kernel=$(realpath "${1:?Prepared source}")
output=$(realpath "${2:?Completed native output}")
root=$(realpath "${3:?Staged package root}")
release=${4:?Versioned kernel release}
[[ $release =~ ^7[.]3[.](0|1)-[1-9][0-9]*$ ]]
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
[[ ! -e $output/certs/signing_key.pem ]]
{
 find "$root/usr/lib/modules/$release" "$root/usr/lib/senemos/kernel-updates/$release" "$root/usr/share/senemos/uke/$release" -type f -print0
 printf '%s\0' "$output/.config" "$output/arch/arm64/boot/Image"
} | sort -z | xargs -0 sha256sum > "$work/before.sha256"
make -C "$kernel" O="$output" ARCH=arm64 LLVM=1 LLVM_IAS=1 LOCALVERSION="-${release##*-}" \
 KCONFIG_NOSILENTUPDATE=1 CONFIG_DRM_MSM_MDP4=y CONFIG_DRM_MSM_MDP5=y \
 KCFLAGS='-DCONFIG_DRM_MSM_MDP4=1 -DCONFIG_DRM_MSM_MDP5=1' \
 drivers/gpu/drm/msm/disp/mdp4/mdp4_kms.o drivers/gpu/drm/msm/disp/mdp5/mdp5_kms.o
[[ -s $output/drivers/gpu/drm/msm/disp/mdp4/mdp4_kms.o && -s $output/drivers/gpu/drm/msm/disp/mdp5/mdp5_kms.o ]]
[[ ! -e $output/certs/signing_key.pem ]]
sha256sum -c --quiet "$work/before.sha256"
printf 'Alternate MDP4/MDP5 KMS units compile; shipped modules, boot payloads, certificate, config and Image unchanged\n'
