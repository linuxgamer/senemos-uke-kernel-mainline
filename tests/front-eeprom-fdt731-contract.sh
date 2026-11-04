#!/usr/bin/env bash
# COPR only. Actual FDT helper, synthetic properties; never reads device EEPROM.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^static int UKE_INIT uke_scope_qup_buses\(/ {copy=1} copy {print} copy && /^}/ {exit}' \
 "$project/src/boot/uke-abl.c" > "$work/qup-scope.h"
printf '%s  %s\n' 5be650de0a721aa20c4e1a351a243e939648ba8a149805177a4e5c5f7764ad8b "$work/qup-scope.h" | sha256sum -c --strict
awk '/ret = uke_scope_qup_buses\(output\);/ {scope=NR;ns++}
 /ret = uke_front_eeprom_graph\(output\);/ {front=NR;nf++}
 END {exit !(ns==1 && nf==1 && scope<front)}' "$project/src/boot/uke-abl.c"
read -ra flags <<< "${FRONT_EEPROM_TEST_FLAGS:-}"
"${CC:-clang}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" \
 -I"$work" -I"$project/src/camera/eeprom" "$project/tests/fixtures/front-eeprom-fdt-check.c" \
 -lfdt -o "$work/check"
"$work/check"
