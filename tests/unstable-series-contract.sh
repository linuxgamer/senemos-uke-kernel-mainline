#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.."; pwd)
for version in 7.4-rc1 7.4-rc9 7.4-rc10; do
 bash "$root/scripts/require-unstable-series.sh" "$version"
done
for version in 7.3 7.3.0 7.3.1 7.4 7.4.0 7.5-rc1 7.4-rc0 7.4-rc01 7.4-rc1/foreign ''; do
 if bash "$root/scripts/require-unstable-series.sh" "$version" 2>/dev/null; then exit 1; fi
done
if bash "$root/scripts/require-unstable-series.sh" 2>/dev/null; then exit 1; fi
printf '%s\n' 'Only the Linux 7.4 release-candidate family is admitted.'
