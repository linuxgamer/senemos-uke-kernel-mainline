#!/usr/bin/env bash
# Source/COPR only: apply the qualified geometry and GMU paths once in prep.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Pass the prepared complete kernel source}")
profile=$(realpath "${2:?Pass the coordinated native profile}")
jq -e '.queued_kernel_layer==1 and .o82_memory_layer==1 and
 .qualified_touch_layer==1 and .o82_private_color_bundle_version==5 and
 .camera_geometry_source=="9398700a6375a309f572d588a9e448cdbc4b0736" and
 .gmu_irq_reference_source=="a85f0f660dd947d2737dca18ce043674ce55a45e" and
 .o82_color_initial_preset=="" and .native_hdr_advertised==false' \
 "$profile/source-composition.json" >/dev/null
geometry=src/camera/sensors/0005-ov08d10-selection731.patch
gmu=patches/gpu/0075-gmu-hfi-irq-owned-status.patch
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^static irqreturn_t a6xx_hfi_irq\(/ {emit=1} emit{print} emit&&/^}/{exit}' \
 "$kernel/drivers/gpu/drm/msm/adreno/a6xx_gmu.c" > "$work/irq.inc"
awk '/^static int a6xx_hfi_wait_for_msg_interrupt\(/ {emit=1} emit{print} emit&&/^}/{exit}' \
 "$kernel/drivers/gpu/drm/msm/adreno/a6xx_hfi.c" > "$work/wait.inc"
printf '%s  %s\n' 9ee70b3f49184e1aaceb03e18495023ccbbbc1f2674a3a70dd2a787ecbd5dff0 "$work/irq.inc" \
 89cd584b2e2f874b7afa8e1a036a07ac5ae77a0802a82aa5e964a150751b3741 "$work/wait.inc" | sha256sum -c --strict -
printf '%s  %s\n' 96aad491915796d54e2a8cd20c90a9a8c4e58515c64f7ad4d5faae39caa4d31c \
 "$kernel/drivers/media/i2c/ov08d10.c" | sha256sum -c --strict -
# Check both contexts before any prepared-source patch is applied.
git -C "$kernel" apply --check "$profile/$geometry"
git -C "$kernel" apply --check "$profile/$gmu"
before=$kernel/native-generated/queued-ov08d10-before.c
test ! -e "$before"
install -m644 "$kernel/drivers/media/i2c/ov08d10.c" "$before"
git -C "$kernel" apply "$profile/$geometry"
printf '%s  %s\n' df7ce54741d6a08c09ff607b86ce33c2057bb05c52b4d1a21d98b5be3395700e \
 "$kernel/drivers/media/i2c/ov08d10.c" | sha256sum -c --strict -
bash "$profile/tests/camera-geometry731-contract.sh" "$kernel" "$before"
# This qualified runner requires the actual original IRQ, proves assertion134,
# then applies the exact production patch and checks four compiler/modes.
bash "$profile/tests/gmu-hfi-irq-contract.sh" "$kernel"
printf 'Queued kernel prep: actual qualified geometry and GMU controls applied together; no hardware gate change\n'
