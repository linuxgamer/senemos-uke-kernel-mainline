#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Inspect the actual compiled native providers; never open a device or send data.
set -Eeuo pipefail
objects=$(realpath "${1:?Pass the native kernel object tree}")
grep -Fx 'CONFIG_FM19511_UKE=m' "$objects/.config"
grep -Fx 'CONFIG_IR_SPI=m' "$objects/.config"
grep -Fx 'CONFIG_LIRC=y' "$objects/.config"
tag=$objects/drivers/misc/fm19511-uke.ko
ir=$objects/drivers/media/rc/ir-spi.ko
test -s "$tag" -a -s "$ir"
modinfo -F alias "$tag" | grep -Fx 'of:N*T*Cfm,fm19511C*'
modinfo -F alias "$ir" | grep -Fx 'of:N*T*Cir-spi-ledC*'
printf 'Native NFC/IR package ABI: configured providers, linked modules and exact DT autoload aliases passed\n'
