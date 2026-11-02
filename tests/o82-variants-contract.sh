#!/usr/bin/env bash
# Repeat actual-function checks after applying the supplier admission extension.
set -Eeuo pipefail
kernel=${1:?Pass the prepared kernel}
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
bash "$root/tests/o82-selector-contract.sh"
bash "$root/tests/o82-on-batch-contract.sh"
bash "$root/tests/o82-dfps-panel-contract.sh" "$root/src/display/panel-xiaomi-o82.c" \
    "$root/src/display/o82-data.h" "$root/src/display/o82-mode.h" "$root/src/display/qcom-uke-display.h"
for variant in 36 42; do
    O82_PANEL_VARIANT=$variant bash "$root/tests/o82-refresh-host-contract.sh" \
        "$kernel/drivers/gpu/drm/msm/dsi/dsi_host.c" "$root/src/display/o82-mode.h" "$root/src/display/o82-data.h"
    O82_PANEL_VARIANT=$variant bash "$root/tests/o82-mode-valid-contract.sh" \
        "$kernel/drivers/gpu/drm/msm/dsi/dsi_manager.c" "$root/src/display/o82-mode.h" "$root/src/display/o82-data.h"
done
