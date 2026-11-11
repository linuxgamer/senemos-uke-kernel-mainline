#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Remote source-stage ABI check; no Image, modules, firmware or device output.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
archive=$owner/source-cache/releases/linux-7.3.1.tar.xz
mkdir -p "${archive%/*}"
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.xz -o "$archive"
printf '%s  %s\n' fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231 \
    "$archive" | sha256sum -c -
tar -xJf "$archive" -C "$scratch"
kernel=$scratch/linux-7.3.1
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
for file in dpu_o82_profiles.c dpu_o82_profiles.h dpu_o82_regdma.c dpu_o82_regdma.h \
    dpu_o82_platform.c dpu_o82_platform.h \
    dpu_o82_lutbus.c dpu_o82_lutbus.h \
    o82-color-firmware.h o82-regdma.h uke-o82-hdr-format.h; do
    install -m644 "$owner/src/display/$file" "$target/$file"
done
# Only the new member is needed for this isolated object check. The retained
# production preparation applies the complete hook after its lifecycle patches.
git -C "$kernel" apply --check --include=drivers/gpu/drm/msm/disp/dpu1/dpu_kms.h \
    "$owner/patches/display/0072-o82-regdma-resource.patch"
git -C "$kernel" apply --include=drivers/gpu/drm/msm/disp/dpu1/dpu_kms.h \
    "$owner/patches/display/0072-o82-regdma-resource.patch"
# A direct object target needs a local Kbuild; production linkage remains separate.
cat > "$target/Makefile" <<'EOF'
ccflags-y += -I$(srctree)/drivers/gpu/drm/msm
ccflags-y += -I$(objtree)/drivers/gpu/drm/msm/generated
obj-y += dpu_o82_profiles.o dpu_o82_regdma.o dpu_o82_lutbus.o dpu_o82_platform.o
EOF
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 defconfig
"$kernel/scripts/config" --file "$scratch/out/.config" -d RUST -d DEBUG_INFO_BTF -d DRM_MSM_VALIDATE_XML
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 olddefconfig
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 -j4 prepare
printf '%s  %s\n' 81763fc03ea0ebf254ab7427af2113dc0c7c0d80dceab61232b6e371463d1f90 \
    "$kernel/drivers/gpu/drm/msm/registers/gen_header.py" | sha256sum -c -
# Same command as MSM's Kbuild; the top-level Makefile has no direct .h target.
mkdir -p "$scratch/out/drivers/gpu/drm/msm/generated"
python3 "$kernel/drivers/gpu/drm/msm/registers/gen_header.py" --no-validate \
    --rnn "$kernel/drivers/gpu/drm/msm/registers" \
    --xml "$kernel/drivers/gpu/drm/msm/registers/display/mdp_common.xml" c-defines \
    > "$scratch/out/drivers/gpu/drm/msm/generated/mdp_common.xml.h"
make -C "$kernel" O="$scratch/out" ARCH=arm64 KCFLAGS=-Werror -j4 \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_profiles.o \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_regdma.o \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_lutbus.o
make -C "$kernel" O="$scratch/out" ARCH=arm64 KCFLAGS=-Werror -j4 \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_platform.o
printf '%s\n' 'O82 native profile loader and REGDMA transport compile against exact upstream Linux 7.3.1 AArch64 headers; production integration and hardware unverified'
