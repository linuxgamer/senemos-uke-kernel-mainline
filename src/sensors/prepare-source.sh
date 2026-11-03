#!/usr/bin/env bash
# Host preparation only; do not run a donor or operate the sensor hardware.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
here=$(cd -- "$(dirname -- "$0")" && pwd)
target=$kernel/drivers/iio/common/uke-ssc
! grep -q 'uke-ssc/Kconfig' "$kernel/drivers/iio/common/Kconfig"
test ! -e "$target"
mkdir -p "$target"
install -m644 "$here/uke-ssc-iio.c" "$here/uke-ssc-protocol.c" "$here/uke-ssc-protocol.h" \
    "$here/Kconfig" "$here/Makefile" "$target/"
printf '\nsource "drivers/iio/common/uke-ssc/Kconfig"\n' >> "$kernel/drivers/iio/common/Kconfig"
printf '\nobj-y += uke-ssc/\n' >> "$kernel/drivers/iio/common/Makefile"
