#!/usr/bin/env bash
# Execute the production native-input payload guard without building Linux.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
tail -2 "$root/src/boot/build-payload.sh" > "$stage/production.sh"
export source_modules=$stage/modules
module=$source_modules/kernel/drivers/input/touchscreen/nt36532-uke/nt36532-uke-touch.ko.zst
mkdir -p "$(dirname "$module")"
printf 'native-input-module\n' > "$module"
bash -Eeuo pipefail "$stage/production.sh"
[[ ! -e $source_modules/uke ]]
rm "$module"
if bash -Eeuo pipefail "$stage/production.sh"; then
    echo 'Missing native input module admitted' >&2; exit 1
fi
printf 'native-input-module\n' > "$module"
mkdir -p "$source_modules/uke"
printf 'forbidden-client\n' > "$source_modules/uke/uke-touch-capture"
if bash -Eeuo pipefail "$stage/production.sh"; then
    echo 'Userspace touch dependency admitted' >&2; exit 1
fi
printf 'Native input payload requires its module and refuses a capture client: PASS\n'
