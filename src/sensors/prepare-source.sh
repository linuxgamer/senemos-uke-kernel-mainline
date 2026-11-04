#!/usr/bin/env bash
# Host preparation only; do not run a donor or operate the sensor hardware.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel source}
here=$(cd -- "$(dirname -- "$0")" && pwd)
target=$kernel/drivers/iio/common/uke-ssc
# The dispatcher follows this exact upstream transaction/decoder contract.
[[ $(git hash-object "$kernel/drivers/soc/qcom/qmi_interface.c") == 16e2e24b60968abad39065e77ca444a1562d65d1 ]]
[[ $(git hash-object "$kernel/drivers/soc/qcom/qmi_encdec.c") == 28ce6f130b6ac355820bb295c8c96f9c6a6e385f ]]
! grep -q 'uke-ssc/Kconfig' "$kernel/drivers/iio/common/Kconfig"
test ! -e "$target"
mkdir -p "$target"
install -m644 "$here/uke-ssc-iio.c" "$here/uke-ssc-protocol.c" "$here/uke-ssc-protocol.h" \
    "$here/Kconfig" "$here/Makefile" "$target/"
install -Dm644 "$here/sysfs-driver-uke-ssc" \
    "$kernel/Documentation/ABI/testing/sysfs-driver-uke-ssc"
printf '\nsource "drivers/iio/common/uke-ssc/Kconfig"\n' >> "$kernel/drivers/iio/common/Kconfig"
printf '\nobj-y += uke-ssc/\n' >> "$kernel/drivers/iio/common/Makefile"
