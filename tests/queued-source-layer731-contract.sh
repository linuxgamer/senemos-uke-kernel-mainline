#!/usr/bin/env bash
# COPR only: exact source/lock/spec preservation, refusal and repeat application.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(realpath "${1:?Pass the owner}")
profile=$(realpath "${2:?Pass the native profile}")
boot=$(realpath "${3:?Pass the boot recipe}")
spec=$(realpath "${4:?Pass the production spec}")
helper=$owner/packaging/native/overlay-queued-kernel731.sh
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cp "$spec" "$work/spec"
cp "$profile/source-composition.json" "$work/composition"
cp "$profile/SHA256SUMS" "$work/sums"
seal() { (cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }
refuse()
{
    sha256sum "$profile/SHA256SUMS" "$boot/lock.json" "$spec" > "$work/before"
    if bash "$helper" "$profile" "$boot" "$spec" > "$work/refusal" 2>&1; then
        echo 'Required queued-source refusal was missed' >&2;exit 1
    fi
    sha256sum -c --strict --quiet "$work/before"
    (cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
    (cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --strict --quiet -)
}
late=patches/gpu/0075-gmu-hfi-irq-owned-status.patch
test ! -e "$profile/$late"
mkdir -p "$profile/patches/gpu"
printf 'Synthetic unreviewed late import\n' > "$profile/$late"
seal
refuse
unlink "$profile/$late"
install -m644 "$work/sums" "$profile/SHA256SUMS"
sed 's/^%build$/%build_removed/' "$work/spec" > "$spec"
refuse
install -m644 "$work/spec" "$spec"
bash "$helper" "$profile" "$boot" "$spec"
sha256sum "$profile/SHA256SUMS" "$boot/lock.json" "$spec" > "$work/applied"
bash "$helper" "$profile" "$boot" "$spec"
sha256sum -c --strict --quiet "$work/applied"
cp "$profile/source-composition.json" "$work/after-composition"
cp "$profile/SHA256SUMS" "$work/after-sums"
jq '.gmu_irq_owned_acknowledgement=false' "$work/after-composition" > "$profile/source-composition.json"
seal
refuse
install -m644 "$work/after-composition" "$profile/source-composition.json"
install -m644 "$work/after-sums" "$profile/SHA256SUMS"
owned=packaging/native/prepare-queued-kernel731.sh
cp "$profile/$owned" "$work/owned"
printf '\n# Synthetic applied-source mutation\n' >> "$profile/$owned"
seal
refuse
install -m644 "$work/owned" "$profile/$owned"
install -m644 "$work/after-sums" "$profile/SHA256SUMS"
sha256sum -c --strict --quiet "$work/applied"
printf 'Queued source layer: four required refusals, exact idempotence and retained profile/boot/spec inputs passed\n'
