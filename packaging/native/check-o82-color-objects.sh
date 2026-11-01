#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Remote source-stage ABI check; no Image, modules, firmware or device output.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(uname -m) == aarch64 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
scratch=$(mktemp -d)
trap 'find "$scratch" -depth -delete' EXIT
archive=$owner/referances/releases/linux-7.3.1.tar.xz
mkdir -p "${archive%/*}"
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.tar.xz -o "$archive"
printf '%s  %s\n' fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231 \
    "$archive" | sha256sum -c -
tar -xJf "$archive" -C "$scratch"
kernel=$scratch/linux-7.3.1
target=$kernel/drivers/gpu/drm/msm/disp/dpu1
for file in dpu_o82_profiles.c dpu_o82_profiles.h dpu_o82_regdma.c dpu_o82_regdma.h \
    o82-color-firmware.h o82-regdma.h uke-o82-hdr-format.h; do
    install -m644 "$owner/src/display/$file" "$target/$file"
done
# A direct object target needs a local Kbuild; production linkage remains separate.
cat > "$target/Makefile" <<'EOF'
ccflags-y += -I$(srctree)/drivers/gpu/drm/msm
obj-y += dpu_o82_profiles.o dpu_o82_regdma.o
EOF
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 defconfig
"$kernel/scripts/config" --file "$scratch/out/.config" -d RUST -d DEBUG_INFO_BTF
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 olddefconfig
make -s -C "$kernel" O="$scratch/out" ARCH=arm64 -j4 prepare
make -C "$kernel" O="$scratch/out" ARCH=arm64 KCFLAGS=-Werror -j4 \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_profiles.o \
    drivers/gpu/drm/msm/disp/dpu1/dpu_o82_regdma.o
printf '%s\n' 'O82 native profile loader and REGDMA transport compile against exact upstream Linux 7.3.1 AArch64 headers; production integration and hardware unverified'
