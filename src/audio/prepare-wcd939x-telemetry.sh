#!/usr/bin/env bash
# COPR only: change cached control metadata, never execute on the tablet.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
kernel=$(realpath "${1:?Prepared pinned Linux source directory}")
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
change=$owner/patches/boot/0061-wcd939x-read-only-telemetry.patch
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
git -C "$stage" init -q
apply=(git -C "$kernel" --git-dir "$stage/.git" --work-tree "$kernel" apply)
if "${apply[@]}" --check --reverse "$change" 2>/dev/null; then
 printf 'WCD939x telemetry metadata already matches the exact patch\n'
else
 sed -n '/^static int wcd939x_get_hph_type(/,/^static int wcd939x_mbhc_init(/p' \
  "$kernel/sound/soc/codecs/wcd939x.c" | sed '$d' | sed '${/^$/d;}' > "$stage/before.c"
 sed -n '/^static int wcd939x_get_hph_type(/,$p' \
  "$owner/tests/fixtures/wcd939x-before-telemetry.c" > "$stage/fixture.c"
 cmp "$stage/before.c" "$stage/fixture.c"
 "${apply[@]}" --check --whitespace=error-all "$change"
 "${apply[@]}" --whitespace=error-all "$change"
fi
