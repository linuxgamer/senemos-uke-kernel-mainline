#!/usr/bin/env bash
# COPR only. Actual mode-admission source with MMIO/resource boundaries modeled.
set -Eeuo pipefail
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
sed '/^#include /d' "$project/src/camera/provider/camcc-sm7675-crm-guard.h" > "$work/crm-guard.h"
read -ra flags <<< "${CAMCC_CRM_TEST_FLAGS:-}"
"${CC:-clang}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" -I"$work" \
 "$project/tests/fixtures/camcc-crm-guard-check.c" -o "$work/check"
"$work/check"
