#!/usr/bin/env bash
# Exercise the actual host compression command, including its error status.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
awk '/^find .*xargs.*zstd/ {print;count++} END {if(count!=1)exit 1}' "$root/src/boot/build-payload.sh" > "$work/compress.sh"
mkdir -p "$work/serial/sub" "$work/parallel"
for name in first 'space name' $'line\nbreak'; do cp /usr/bin/true "$work/serial/sub/$name.ko"; done
cp -a "$work/serial/." "$work/parallel/"
find "$work/serial" -type f -name '*.ko' -exec zstd -q -T1 --rm {} \;
source_modules="$work/parallel" jobs=4 bash -Eeuo pipefail "$work/compress.sh"
diff -qr "$work/serial" "$work/parallel"
[[ -z $(find "$work/parallel" -name '*.ko' -print -quit) ]]
source_modules="$work/parallel" jobs=4 bash -Eeuo pipefail "$work/compress.sh"
cp /usr/bin/true "$work/parallel/sub/first.ko"
if source_modules="$work/parallel" jobs=4 bash -Eeuo pipefail "$work/compress.sh" 2> "$work/expected-error"; then
    echo 'Compression unexpectedly overwrote an existing output' >&2;exit 1
fi
[[ -s $work/parallel/sub/first.ko ]]
diff -qr "$work/serial/sub" "$work/parallel/sub" > "$work/diff" && exit 1
printf 'Actual module compression: serial/parallel bytes, NUL paths, empty set and no-clobber failure propagation passed; host only\n'
