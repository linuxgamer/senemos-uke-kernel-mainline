#!/usr/bin/env bash
# Exercise the selected kernel's actual GPI callback, not a rewritten callback.
set -Eeuo pipefail
source_file=${1:?Pass prepared drivers/spi/spi-geni-qcom.c}
here=$(cd -- "$(dirname -- "$0")" && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
awk '
 /^spi_gsi_callback_result\(/ { print "static void"; copying=1 }
 copying { print }
 copying && /^}/ { copying=0 }
' "$source_file" > "$stage/production.h"
[[ $(grep -c '^spi_gsi_callback_result(' "$stage/production.h") == 1 ]]
sanitize=()
[[ -z ${UKE_SPI_SANITIZE:-} ]] || sanitize=(-fsanitize=address,undefined -fno-omit-frame-pointer)
"${CC:-cc}" -std=gnu11 -O2 -g -Wall -Wextra -Werror "${sanitize[@]}" \
    -I "$stage" "$here/spi-geni-completion.c" -o "$stage/check"
timeout 10s "$stage/check"
