#!/usr/bin/env bash
# COPR only. Actual NVMEM access and mode gates, without device/calibration data.
set -Eeuo pipefail
kernel=$(realpath "${1:?prepared kernel source}")
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source=$kernel/drivers/nvmem/core.c
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
printf '%s  %s\n' 006b3a2074a3061bd2dadb4f309427fe44a72ee7b363b7c81d0903c6efe9e7c1 "$source" | sha256sum -c --strict
for function in __nvmem_reg_read __nvmem_reg_write nvmem_bin_attr_get_umode; do
 awk -v name="$function" '$0 ~ "^static (int|umode_t) " name "\\(" {copy=1} copy {print} copy && /^}/ {exit}' "$source" > "$work/$function.h"
done
printf '%s\n' \
 'b69f844241ff9b858992e618af74c8d1f79c33fa0495464c8cae460625a2acf2  __nvmem_reg_read.h' \
 '296d52ff1cb5ace08ab2a281bd43b5491818a2fcd6d66862a75050e1f5b84b03  __nvmem_reg_write.h' \
 '74b0acfb1aa1f2b41e1dc617b3ae220906a25013c51cedae26dd5ea908ea20a8  nvmem_bin_attr_get_umode.h' > "$work/functions.sha256"
(cd "$work"; sha256sum -c --strict functions.sha256)
read -ra flags <<< "${CAMERA_NVMEM_TEST_FLAGS:-}"
"${CC:-clang}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" -I"$work" \
 "$project/tests/fixtures/camera-nvmem-privacy-check.c" -o "$work/check"
"$work/check"
