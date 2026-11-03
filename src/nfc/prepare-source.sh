#!/usr/bin/env bash
# Install the reviewed POCO tag transport and retain upstream LIRC for Uke IR.
set -Eeuo pipefail
[[ $# == 1 && -f $1/drivers/misc/Kconfig ]] || exit 2
kernel=$(realpath "$1")
here=$(cd -- "$(dirname -- "$0")" && pwd)
install -m644 "$here/fm19511-uke.c" "$kernel/drivers/misc/fm19511-uke.c"
install -Dm644 "$here/fm,fm19511.yaml" "$kernel/Documentation/devicetree/bindings/nfc/fm,fm19511.yaml"
cat >> "$kernel/drivers/misc/Kconfig" <<'KCONFIG'

config FM19511_UKE
	tristate "POCO Pad X1 FM19511 NFC tag transport"
	depends on I2C && OF && REGULATOR && ARCH_QCOM
	help
	  Root-only transport for the FM19511 tag on the admitted POCO SKU.
	  This is a tag interface, not an NFC reader or card-emulation controller.
KCONFIG
printf '\nobj-$(CONFIG_FM19511_UKE) += fm19511-uke.o\n' >> "$kernel/drivers/misc/Makefile"
git -C "$kernel" apply --check "$here/../../patches/boot/0012-ir-spi-optional-power.patch"
git -C "$kernel" apply "$here/../../patches/boot/0012-ir-spi-optional-power.patch"
bash "$here/../../tests/ir-spi-contract.sh" "$kernel/drivers/media/rc/ir-spi.c"
