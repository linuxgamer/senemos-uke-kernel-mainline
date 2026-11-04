#!/usr/bin/env bash
# COPR only. Actual stream caller before/after the checked PHY callback API.
set -Eeuo pipefail
[[ $# == 2 ]] || exit 2
before=$(realpath "$1")/drivers/media/platform/qcom/camss/camss-csiphy.c
after=$(realpath "$2")/drivers/media/platform/qcom/camss/camss-csiphy.c
project=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
for variant in before after; do
 source=${!variant}
 awk '/^static int csiphy_stream_on\(/ {copy=1} copy {print} copy && /^}/ {exit}' \
 "$source" > "$work/$variant-stream.h"
done
printf '%s  %s\n' \
 c12c1b70def19d97526873aca7e42cb8bc872a7a32554be56466ed8743ee0408 "$work/before-stream.h" \
 f48cb1ab6b60c98f6129a57a207769daf902248082ef93f544999fa9d794b58d "$work/after-stream.h" | sha256sum --check --strict
read -ra flags <<< "${CAMSS_STREAM_TEST_FLAGS:-}"
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -O1 -g "${flags[@]}" -I"$work" \
 "$project/tests/fixtures/camss-phy-stream-check.c" -o "$work/check"
ulimit -c 0
set +e
"$work/check" before > "$work/before.log" 2>&1
status=$?
set -e
[[ $status != 0 ]]
grep -F 'Original stream caller reported success after refused PHY setup' "$work/before.log"
grep -F 'Assertion' "$work/before.log"
printf 'Original PHY setup error control reproduced (exit %s)\n' "$status"
"$work/check"
