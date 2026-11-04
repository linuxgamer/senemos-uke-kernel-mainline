#!/usr/bin/env bash
# COPR only. Actual controller FDT conversion; no private retained FDT input.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
read -ra flags <<< "${CAMCC_FDT_TEST_FLAGS:-}"
"${CC:-clang}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" \
 -I"$project/src/camera/provider" "$project/tests/fixtures/camcc-controller-fdt-check.c" \
 -lfdt -o "$work/check"
"$work/check"
