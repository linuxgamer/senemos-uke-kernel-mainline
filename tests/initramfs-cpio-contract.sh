#!/usr/bin/env bash
# Native host archive checks; no extracted program or device node is run.
set -Eeuo pipefail
export LC_ALL=C
generator=$(realpath "${1:?Pass the selected Linux host gen_init_cpio}")
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
stage=$work/source\ tree
mkdir -p "$stage"/{dev,etc,usr/bin,usr/lib}
printf 'payload with TRAILER!!! and binary byte: \000\377\n' > "$stage/usr/bin/helper"
chmod 0751 "$stage/usr/bin/helper"
ln "$stage/usr/bin/helper" "$stage/usr/bin/helper-alias"
: > "$stage/etc/empty"
chmod 0600 "$stage/etc/empty"
ln "$stage/etc/empty" "$stage/etc/empty-alias"
ln -s ../usr/bin/helper "$stage/etc/relative-link"
ln -s /usr/bin/helper "$stage/etc/absolute-link"
epoch=1700000000
find "$stage" -exec touch -h -d "@$epoch" {} +
(cd "$stage"; find . -print0 | sort -z | cpio --null --quiet --reproducible --owner=0:0 -o -H newc) > "$work/before.cpio"
bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$work/after archive.gz" "$epoch"
bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$work/repeat.gz" "$epoch"
cmp "$work/after archive.gz" "$work/repeat.gz"
gzip -dc "$work/after archive.gz" > "$work/after.cpio"
cpio -itvn --quiet < "$work/after.cpio" > "$work/metadata"
awk '$1=="crw-------" && $2==1 && $3==0 && $4==0 && $5=="5," && $6==1 && $NF=="dev/console" {found++}
     $3!=0 || $4!=0 {bad=1}
     substr($1,1,1)!="-" && substr($1,1,1)!="d" && substr($1,1,1)!="l" {special++}
     END{exit bad || found!=1 || special!=1}' "$work/metadata"
mkdir "$work/before" "$work/after"
(cd "$work/before"; cpio -idm --quiet --no-absolute-filenames --no-preserve-owner < ../before.cpio)
(cd "$work/after"; cpio -idmf --quiet --no-absolute-filenames --no-preserve-owner 'dev/console' < ../after.cpio)
for tree in before after; do
    (cd "$work/$tree"; find . -printf '%P\t%y\t%m\t%T@\t%l\n' | sort) > "$work/$tree.metadata"
    (cd "$work/$tree"; find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$work/$tree.hashes"
    test "$(stat -c %i "$work/$tree/usr/bin/helper")" = "$(stat -c %i "$work/$tree/usr/bin/helper-alias")"
    test "$(stat -c %i "$work/$tree/etc/empty")" = "$(stat -c %i "$work/$tree/etc/empty-alias")"
done
cmp "$work/before.metadata" "$work/after.metadata"
cmp "$work/before.hashes" "$work/after.hashes"
reject() {
    if bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$work/refused.gz" "$epoch" > "$work/refusal.log" 2>&1; then exit 1; fi
    test ! -e "$work/refused.gz"
}
printf preserve > "$stage/dev/console"
reject
test "$(cat "$stage/dev/console")" = preserve
unlink "$stage/dev/console"
ln -s missing "$stage/dev/console"
reject
unlink "$stage/dev/console"
mkfifo "$stage/unsupported-fifo"
reject
unlink "$stage/unsupported-fifo"
: > "$stage/unsupported name"
reject
unlink "$stage/unsupported name"
: > "$stage/"'${FORBIDDEN}'
reject
unlink "$stage/"'${FORBIDDEN}'
ln -s $'unsupported\n' "$stage/etc/control-link"
reject
unlink "$stage/etc/control-link"
if bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$stage/inside.gz" "$epoch" > "$work/refusal.log" 2>&1; then exit 1; fi
test ! -e "$stage/inside.gz"
if bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$work/refused.gz" 4294967296 > "$work/refusal.log" 2>&1; then exit 1; fi
test ! -e "$work/refused.gz"
if bash "$root/src/boot/make-initramfs-cpio.sh" "$stage" "$generator" "$work/after archive.gz" "$epoch" > "$work/refusal.log" 2>&1; then exit 1; fi
cmp "$work/after archive.gz" "$work/repeat.gz"
printf 'Actual initramfs builder: one standard 5:1 console, unchanged data/modes/mtimes/links, retained empty/nonempty hardlinks, deterministic output and unsafe-input refusals passed; host archive only\n'
