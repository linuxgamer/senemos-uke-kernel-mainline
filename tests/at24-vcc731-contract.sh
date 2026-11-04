#!/usr/bin/env bash
# COPR only. Actual before/after at24 reads, PM callbacks and voltage helper.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
before=$(realpath "$1")/drivers/nvmem/at24.c
after=$(realpath "$2")/drivers/nvmem/at24.c
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
printf '%s  %s\n' f37ed370a86b2b850625ecd7e5e4d810b5feeb65c10f719a9e505aa8db2795a0 "$before" | sha256sum -c --strict
extract() {
 awk -v name="$2" '$0 ~ "^static int( __maybe_unused)? " name "\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$1" > "$3"
}
extract "$before" at24_read "$work/before-read.h"
extract "$after" at24_read_data "$work/after-read-data.h"
for variant in before after; do
 source=${!variant}
 for function in suspend resume; do
  extract "$source" "at24_$function" "$work/$variant-$function.h"
 done
done
printf '%s\n' \
 '9881050f20f61f6f906b4f0882dcc139b03fceab2eb9f68f9d70e4971c1d0256  before-read.h' \
 '46e529ab0d53c399b73df7a54c6a9d1be1b23cf808b7e36b8f4ff323c2c3ef36  after-read-data.h' \
 '07ce3b42b90e5f2c160aa03e032f89dc22dd734e0aa0aeaea1ffc9b3a7e82abf  before-suspend.h' \
 'ef8a7d5c19ac9de2df146216e0b6cbd3c8929c544291dfee5d6752e9d4ddd66a  after-suspend.h' \
 '3a957e9b82aa4bb5203d5f889669afee4744c84d3262be51fd43db9c80a3c7d6  before-resume.h' \
 '6009e84251d5b1f4399f6799506e837dd87907b596825c07f94bdc5fc0411efa  after-resume.h' > "$work/functions.sha256"
(cd "$work"; sha256sum -c --strict functions.sha256)
cmp "$project/src/camera/eeprom/at24-vcc-readonly.h" "$(dirname "$after")/at24-vcc-readonly.h"
read -ra flags <<< "${AT24_VCC_TEST_FLAGS:-}"
"${CC:-clang}" -std=gnu11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
 "${flags[@]}" -pthread -I"$work" -I"$project/src/camera/eeprom" \
 "$project/tests/fixtures/at24-vcc-readonly-check.c" -o "$work/check"
ulimit -c 0
set +e
"$work/check" before > "$work/before.log" 2>&1
status=$?
set -e
[[ $status != 0 ]]
grep -F 'Original at24 reaches EEPROM read at the unrequested 1620000uV level' "$work/before.log"
grep -F 'Assertion' "$work/before.log"
printf 'Original at24 voltage control reproduced (exit %s)\n' "$status"
"$work/check"
grep -Fq 'devm_regulator_get_optional(dev, "vcc")' "$after"
grep -Fq 'nvmem_config.reg_write = at24->vcc_uV ? NULL : at24_write;' "$after"
grep -Fq 'full_power = !at24->vcc_uV && acpi_dev_state_d0(&client->dev);' "$after"
grep -Fq 'if (full_power || at24->vcc_uV) {' "$after"
printf 'Actual probe source retains optional real supply, read-only write-callback exclusion and first-read voltage path\n'
