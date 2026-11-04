#!/usr/bin/env bash
# COPR only: exact cumulative source admission and mandatory rejection controls.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $# == 3 ]]
owner=$(realpath "$1")
profile=$(realpath "$2")
boot=$(realpath "$3")
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
helper=$owner/packaging/native/overlay-o82-memory731.sh
relative=src/display/o82-color-firmware.h
cp "$profile/$relative" "$work/header"
cp "$profile/source-composition.json" "$work/composition"
cp "$profile/SHA256SUMS" "$work/sums"
sha256sum "$boot/lock.json" > "$work/boot.sha256"
seal()
{
    (cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
}
refuse_unchanged()
{
    local result
    cp "$profile/SHA256SUMS" "$work/before.sha256"
    set +e
    bash "$helper" "$profile" "$boot" > "$work/refusal.log" 2>&1
    result=$?
    set -e
    [[ $result != 0 ]] || { printf 'Required source-layer rejection was missed\n' >&2; exit 1; }
    cmp "$work/before.sha256" "$profile/SHA256SUMS"
    (cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
    sha256sum -c --strict --quiet "$work/boot.sha256"
}
# Repairing the outer checksum must not admit an unreviewed late preimage.
printf '\n/* Synthetic preimage mutation. */\n' >> "$profile/$relative"
seal
refuse_unchanged
install -m644 "$work/header" "$profile/$relative"
install -m644 "$work/sums" "$profile/SHA256SUMS"
jq '.o82_color_initial_preset="synthetic_active"' "$work/composition" > "$profile/source-composition.json"
seal
refuse_unchanged
install -m644 "$work/composition" "$profile/source-composition.json"
install -m644 "$work/sums" "$profile/SHA256SUMS"
bash "$helper" "$profile" "$boot"
sha256sum "$profile/SHA256SUMS" "$profile/source-composition.json" "$boot/lock.json" > "$work/applied.sha256"
bash "$helper" "$profile" "$boot"
sha256sum -c --strict --quiet "$work/applied.sha256"
cp "$profile/$relative" "$work/after-header"
cp "$profile/source-composition.json" "$work/after-composition"
cp "$profile/SHA256SUMS" "$work/after-sums"
sha256sum "$boot/lock.json" > "$work/boot.sha256"
# The idempotence marker cannot hide changed code or unsupported metadata.
printf '\n/* Synthetic applied-source mutation. */\n' >> "$profile/$relative"
seal
refuse_unchanged
install -m644 "$work/after-header" "$profile/$relative"
install -m644 "$work/after-sums" "$profile/SHA256SUMS"
jq '.o82_memory_software_support=false' "$work/after-composition" > "$profile/source-composition.json"
seal
refuse_unchanged
install -m644 "$work/after-composition" "$profile/source-composition.json"
install -m644 "$work/after-sums" "$profile/SHA256SUMS"
sha256sum -c --strict --quiet "$work/applied.sha256"
printf 'Cumulative O82 source layer: exact idempotence, four required rejection controls and unchanged refusal inputs passed\n'
