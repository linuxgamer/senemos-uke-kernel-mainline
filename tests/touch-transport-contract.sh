#!/usr/bin/env bash
# Execute production transport/lifecycle functions with deterministic SPI faults.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
awk '
 /^static (bool nvt_active\(|void nvt_schedule_poll\(|int nvt_ready\(|int nvt_transfer\(|int nvt_spi_io\(|void nvt_irq_set\(|void nvt_quiesce\(|void nvt_fault\(|void nvt_boot_worker\(|int nvt_panel_changed\(|int nvt_suspend\(|int nvt_resume\(|void nvt_apply_charger\(|void nvt_charger_worker\(|int nvt_supply_changed\()/ { copying=1 }
 copying { print }
 copying && /^}/ { copying=0 }
' "$root/src/input/nt36532-uke-spi.c" > "$stage/production.h"
[[ $(grep -c '^static ' "$stage/production.h") == 15 ]]
sanitize=()
[[ -z ${UKE_TOUCH_SANITIZE:-} ]] || sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer)
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    "${sanitize[@]}" -pthread -I "$stage" "$root/tests/touch-transport.c" -o "$stage/check"
timeout 30s "$stage/check"
awk '
 /^static void o82_touch_state\(/ || /^int uke_o82_touch_register\(/ || /^void uke_o82_touch_unregister\(/ { copying=1 }
 copying { print }
 copying && /^}/ { copying=0 }
' "$root/src/display/panel-xiaomi-o82.c" > "$stage/panel-production.h"
[[ $(grep -c '^}' "$stage/panel-production.h") == 3 ]]
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    "${sanitize[@]}" -pthread -I "$stage" "$root/tests/touch-panel-notifier.c" -o "$stage/panel"
timeout 30s "$stage/panel"
mkdir -p "$stage/kernel/drivers/input/touchscreen" "$stage/kernel/include/linux"
printf '# fixture\n' > "$stage/kernel/drivers/input/touchscreen/Kconfig"
printf '# fixture\n' > "$stage/kernel/drivers/input/touchscreen/Makefile"
printf 'CONFIG_TOUCHSCREEN_NT36532_UKE is not set\n' > "$stage/kernel/.config"
before=$(sha256sum "$stage/kernel/.config")
bash "$root/src/input/prepare-source.sh" "$stage/kernel"
[[ $before == "$(sha256sum "$stage/kernel/.config")" ]]
cmp "$root/src/input/nt36532-uke-spi.c" "$stage/kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-spi.c"
cmp "$root/src/display/uke-o82-touch.h" "$stage/kernel/include/linux/uke-o82-touch.h"
if bash "$root/src/input/prepare-source.sh" "$stage/kernel"; then
    echo 'Duplicate staging unexpectedly accepted' >&2; exit 1
fi
profile=$root/packaging/native
[[ -f $profile/prepare.sh ]] || profile=$root
grep -Fx 'bash "$profile/src/input/prepare-source.sh" "$kernel"' "$profile/prepare.sh"
grep -Fx 'CONFIG_TOUCHSCREEN_NT36532_UKE=m' "$profile/native.config"
grep -Fx '#include "../input/sm7675-uke-thp.dtsi"' "$root/src/display/sm7675-uke-native-display-oem-modes.dtso"
printf 'Explicit staging and matched release selection: PASS\n'
