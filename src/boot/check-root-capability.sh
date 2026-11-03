#!/usr/bin/env bash
# Host-only check of the explicit little-endian ELF note in an Image or object.
set -Eeuo pipefail
[[ $# -ge 1 && $# -le 2 && -s $1 && -f $1 ]] || exit 2
image=$1
descriptor='root-selector-v2;userdata=f2fs,ext4,xfs,btrfs;slot=a,b;vrr-min=0,30'
type=0x554b4501
case ${2:-root} in
    root) ;;
    reset) descriptor='boot-reset-v1;watchdog=gunyah;open-timeout=180;runtime-timeout=30'; type=0x554b4502;;
    *) exit 2;;
esac
work=$(mktemp -d)
trap 'rm -r -- "$work"' EXIT
refuse() { echo 'Missing, duplicate or malformed Uke root-selector capability note' >&2; exit 1; }
le32() {
    local number=$1 octal
    printf -v octal '\\%03o\\%03o\\%03o\\%03o' "$((number & 255))" \
        "$((number >> 8 & 255))" "$((number >> 16 & 255))" "$((number >> 24 & 255))"
    printf '%b' "$octal"
}
length=$(printf '%s' "$descriptor" | wc -c)
{
    le32 4
    le32 "$((length + 1))"
    le32 "$((type))"
    printf 'UKE\0%s\0' "$descriptor"
    head -c "$(((4 - (length + 1) % 4) % 4))" /dev/zero
} > "$work/expected"
# Limit the result to two occurrences; one complete aligned note is required.
matches=$(LC_ALL=C grep -aFob -- "$descriptor" "$image" | head -n 2 || :)
[[ -n $matches && $matches != *$'\n'* ]] || refuse
offset=$(printf '%s\n' "$matches" | cut -d: -f1)
[[ $offset =~ ^[0-9]+$ ]] || refuse
((offset >= 16 && (offset - 16) % 4 == 0)) || refuse
size=$(wc -c < "$work/expected")
dd if="$image" bs=1 skip="$((offset - 16))" count="$size" status=none |
    cmp -s - "$work/expected" || refuse
printf 'Uke %s ELF capability note: passed (declaration only, no hardware qualification)\n' "${2:-root}"
