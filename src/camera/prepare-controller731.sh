#!/usr/bin/env bash
# COPR only. Install the reviewed permanent controller into actual Linux source.
set -Eeuo pipefail
kernel=$(realpath "${1:?prepared kernel}")
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
test ! -e "$kernel/drivers/clk/qcom/camcc-sm7675.c"
git -C "$kernel" apply --check "$here/provider/0005-clk-qcom-build-native-sm7675.patch"
git -C "$kernel" apply "$here/provider/0005-clk-qcom-build-native-sm7675.patch"
[[ $(grep -Fxc 'config SM_CAMCC_7675' "$kernel/drivers/clk/qcom/Kconfig") == 1 ]]
install -m644 "$here/camcc-sm7675.c" "$kernel/drivers/clk/qcom/camcc-sm7675.c"
install -m644 "$here/camcc-sm7675-data.h" "$kernel/drivers/clk/qcom/camcc-sm7675-data.h"
install -Dm644 "$here/include/dt-bindings/clock/qcom,sm7675-camcc.h" \
 "$kernel/include/dt-bindings/clock/qcom,sm7675-camcc.h"
for part in power owner clocks handoff registration crm-guard; do
 install -Dm644 "$here/provider/camcc-sm7675-$part.h" \
  "$kernel/drivers/clk/qcom/provider/camcc-sm7675-$part.h"
done
printf 'Permanent SM7675 CAMCC source installed; boolean linkage and actual boot admission remain checked separately\n'
