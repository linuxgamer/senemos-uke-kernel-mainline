#!/usr/bin/env bash
# COPR only: actual complete kernel spec, mandatory refusals and exact retention.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(realpath "${1:?Pass the source owner}")
profile=$(realpath "${2:?Pass the memory/v5 profile}")
spec=$(realpath "${3:?Pass the original complete unstable spec}")
helper=$owner/packaging/native/overlay-o82-private-dnf731.sh
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
cp "$spec" "$work/original.spec"
cp "$profile/source-composition.json" "$work/composition"
cp "$profile/SHA256SUMS" "$work/sums"
refuse()
{
    sha256sum "$spec" > "$work/before"
    if bash "$helper" "$spec" "$profile" > "$work/refusal" 2>&1; then
        echo 'Required DNF source refusal was missed' >&2;exit 1
    fi
    sha256sum -c --quiet "$work/before"
}
jq '.o82_color_initial_preset="synthetic_active"' "$work/composition" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
refuse
install -m644 "$work/composition" "$profile/source-composition.json"
install -m644 "$work/sums" "$profile/SHA256SUMS"
sed 's/^%package boot$/%package omitted/' "$work/original.spec" > "$spec"
refuse
install -m644 "$work/original.spec" "$spec"
sha256sum "$profile/SHA256SUMS" "$profile/source-composition.json" "$profile/native.config" > "$work/profile.before"
bash "$helper" "$spec" "$profile"
sha256sum "$spec" > "$work/applied"
bash "$helper" "$spec" "$profile"
sha256sum -c --quiet "$work/applied"
cp "$spec" "$work/qualified.spec"
sed 's/uke-kernel-update(o82-private-color-v5) >= 1/uke-kernel-update(o82-private-color-v5) >= 2/' \
 "$work/qualified.spec" > "$spec"
refuse
install -m644 "$work/qualified.spec" "$spec"
sha256sum -c --quiet "$work/profile.before"
(cd "$profile"; sha256sum -c --strict --quiet SHA256SUMS)
rpmspec --parse "$spec" > "$work/parsed.spec"
grep -Fx 'Requires: uke-kernel-update(o82-private-color-v5) >= 1' "$work/parsed.spec"
grep -Fx 'Requires: uke-o82-color-profile >= 0.7.0-1' "$work/parsed.spec"
grep -Fx 'Requires: uke-kernel-update(final-transaction-v2) >= 1' "$work/parsed.spec"
! grep -q '^%posttrans' "$work/parsed.spec"
printf 'Actual complete12101/v5 DNF packaging: three mandatory refusals, exact idempotence, unchanged profile/config and retained final-transaction dependency without a new scriptlet passed; no kernel build\n'
