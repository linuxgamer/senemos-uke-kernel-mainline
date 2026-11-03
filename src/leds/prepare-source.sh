#!/usr/bin/env bash
set -Eeuo pipefail
kernel=$(realpath "${1:?prepared kernel}")
here=$(cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$kernel/native-generated"
cp "$kernel/drivers/leds/flash/leds-qcom-flash.c" "$kernel/native-generated/qcom-flash-before-safety.c"
git -C "$kernel" apply --check "$here/../../patches/boot/0043-qcom-flash-preserve-thermal-errors.patch"
git -C "$kernel" apply "$here/../../patches/boot/0043-qcom-flash-preserve-thermal-errors.patch"
bash "$here/../../tests/flash-thermal-errors.sh" "$kernel/drivers/leds/flash/leds-qcom-flash.c" "$kernel/native-generated/qcom-flash-before-safety.c"
install -m644 "$here/leds-uke-rgb.c" "$kernel/drivers/leds/"
install -m644 "$here/leds-uke-torch.c" "$here/uke-torch-uapi.h" "$kernel/drivers/leds/"
install -m644 "$here/uke-torch-uapi.h" "$kernel/include/uapi/linux/uke-torch.h"
install -m644 "$here/uke-rgb-policy.h" "$here/uke-rgb-uapi.h" "$kernel/drivers/leds/"
install -m644 "$here/uke-rgb-uapi.h" "$kernel/include/uapi/linux/uke-rgb.h"
install -m644 "$here/uke-rgb.h" "$kernel/include/linux/uke-rgb.h"
! grep -q '^config LEDS_UKE_RGB$' "$kernel/drivers/leds/Kconfig"
cat >> "$kernel/drivers/leds/Kconfig" <<'KCONFIG'

config LEDS_UKE_RGB
	tristate "Uke RGB notification policy"
	depends on LEDS_TRIGGERS && LEDS_CLASS_MULTICOLOR && POWER_SUPPLY && OF
	help
	  Exact-board notification LED ownership, battery warnings and a bounded
	  color test. Original QCOM LPG supplies the electrical implementation.
KCONFIG
cat >> "$kernel/drivers/leds/Kconfig" <<'KCONFIG'

config LEDS_UKE_TORCH
	tristate "Uke torch request ownership"
	depends on LEDS_CLASS && LEDS_TRIGGERS && OF
	help
	  Own the admitted QCOM torch LED, current-step requests and off on
	  writer close, system sleep and shutdown. No flash mode is exposed.
KCONFIG
printf '\nobj-$(CONFIG_LEDS_UKE_TORCH) += leds-uke-torch.o\n' >> "$kernel/drivers/leds/Makefile"
printf '\nobj-$(CONFIG_LEDS_UKE_RGB) += leds-uke-rgb.o\n' >> "$kernel/drivers/leds/Makefile"
git -C "$kernel" apply --check "$here/../../patches/boot/0012-led-multicolor-sysfs-disable.patch"
git -C "$kernel" apply "$here/../../patches/boot/0012-led-multicolor-sysfs-disable.patch"
bash "$here/../../tests/rgb-policy.sh"
bash "$here/../../tests/torch-lifetime.sh"
bash "$here/../../tests/torch-supplier.sh"
bash "$here/../../tests/rgb-supplier.sh"
bash "$here/../../tests/rgb-lifetime.sh"
bash "$here/../../tests/rgb-sysfs.sh" "$kernel"
