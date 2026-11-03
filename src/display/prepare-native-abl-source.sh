#!/usr/bin/env bash
# Host-only candidate entry; leaves the normal ABL source and build untouched.
set -Eeuo pipefail
[[ $# == 3 && -d $1 && -d $2 && $3 =~ ^(36|42|auto)$ ]] || exit 2
kernel=$(realpath "$1") output=$(realpath "$2") variant=$3
here=$(cd -- "$(dirname -- "$0")" && pwd)
[[ -s $kernel/drivers/gpu/drm/panel/panel-xiaomi-o82.c ]]
cmp "$here/../boot/uke-abl.c" "$kernel/arch/arm64/kernel/uke-abl.c"
patch=$here/../../patches/display/0002-arm64-uke-native-abl-entry.patch
git -C "$kernel" apply --check "$patch"
timing_patch=$here/../../patches/display/0005-native-dpu-dsc-active-width.patch
git -C "$kernel" apply --check "$timing_patch"
usb_cpp=()
[[ ${UKE_USB_PROFILE:-peripheral} != typec-v1 ]] || usb_cpp=(-DUKE_USB_TYPEC=1)
bash "$here/generate-native-panels.sh" "$kernel" "$output" \
    "$here/sm7675-uke-native-display.dtso" "$variant" "${usb_cpp[@]}"
install -m644 "$here/uke-abl-native.h" "$kernel/arch/arm64/kernel/uke-abl-native.h"
git -C "$kernel" apply "$patch"
git -C "$kernel" apply "$timing_patch"
sha256sum "$here/uke-abl-native.h" "$patch" "$output/display.dtbo" \
    "$timing_patch" "$kernel/arch/arm64/kernel/uke-abl.c" > "$output/native-entry-SHA256SUMS"
printf 'Isolated native entry prepared for O82 selection %s; only the initial 60 Hz mode is exposed\n' "$variant"
