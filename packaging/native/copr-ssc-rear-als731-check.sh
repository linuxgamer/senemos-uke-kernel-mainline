#!/usr/bin/env bash
# COPR source worker only: extend the retained front check and full12204 prep.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Remote source result directory}")
revision=${2:-3}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=$owner/manifests/ssc-sip1328-als-layer-20261105.json
(cd "$owner"; jq -r '.assets[],.check_inputs[],.inherited_inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/copr-ssc-als731-check.sh" "$output" "$revision"
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
mkdir -p "$stage/ssc-rear-addon"
mapfile -t assets < <(jq -r '.assets[].path,.check_inputs[].path,.inherited_inputs[].path' "$manifest"; printf '%s\n' manifests/ssc-sip1328-als-layer-20261105.json LICENSE LICENSES/GPL-2.0-only.txt)
git -C "$owner" archive HEAD "${assets[@]}" | tar -xf - -C "$stage/ssc-rear-addon"
git -C "$owner" rev-parse HEAD > "$stage/ssc-rear-addon/source-commit"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
    -cJf "$output/ssc-rear-addon.tar.xz" -C "$stage" ssc-rear-addon
cat > "$stage/rear-prep" <<'PREP'
tar -xJf %{SOURCE12}
(cd ssc-rear-addon; jq -r '.assets[],.check_inputs[],.inherited_inputs[]|.sha256+"  "+.path' manifests/ssc-sip1328-als-layer-20261105.json | sha256sum -c --strict --quiet -)
cmp ssc-als-addon/source-commit ssc-rear-addon/source-commit
find "$stage" -depth -delete
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
snapshot() { find native-profile boot-recipe -type f -print0 | sort -z | xargs -0 sha256sum; }
seal() { (cd native-profile; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }
cp native-profile/src/sensors/uke-ssc-iio.c "$stage/source.before"
cp native-profile/SHA256SUMS "$stage/ledger.before"
printf '\n/* Unreviewed rear source. */\n' >> native-profile/src/sensors/uke-ssc-iio.c
seal
snapshot > "$stage/refusal.before"
if bash ssc-rear-addon/packaging/native/overlay-ssc-rear-als731.sh native-profile boot-recipe > "$stage/refusal.log" 2>&1; then
    printf 'Rear ALS layer admitted an unreviewed source\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/source.before" native-profile/src/sensors/uke-ssc-iio.c
install -m644 "$stage/ledger.before" native-profile/SHA256SUMS
snapshot > "$stage/all.before"
bash ssc-rear-addon/packaging/native/overlay-ssc-rear-als731.sh native-profile boot-recipe
snapshot > "$stage/repeat.before"
bash ssc-rear-addon/packaging/native/overlay-ssc-rear-als731.sh native-profile boot-recipe
snapshot > "$stage/repeat.after"
cmp "$stage/repeat.before" "$stage/repeat.after"
while read -r digest path; do
    case "$path" in native-profile/src/sensors/uke-ssc-iio.c|boot-recipe/src/sensors/uke-ssc-iio.c|native-profile/source-composition.json|native-profile/SHA256SUMS|boot-recipe/lock.json) continue;; esac
    printf '%s  %s\n' "$digest" "$path" | sha256sum -c --strict --quiet -
done < "$stage/all.before"
install -m644 native-profile/src/sensors/uke-ssc-iio.c drivers/iio/common/uke-ssc/uke-ssc-iio.c
printf 'PASS: rear source refusal, exact repeat and complete unrelated-file preservation\n'
PREP
spec=$output/uke-ssc-als-check.spec
awk -v hook="$stage/rear-prep" '
 /^Source11:/ {print; print "Source12: ssc-rear-addon.tar.xz"; next}
 /^Summary:/ {$0="Summary: Uke front and logical rear ALS callbacks and native SSC object check"}
 /^%build$/ {while((getline line < hook)>0)print line; close(hook); injected++}
 /^bash ssc-als-addon\/packaging\/native\/check-ssc-als731.sh / {
   sub("ssc-als-addon/packaging/native/check-ssc-als731.sh", "ssc-rear-addon/packaging/native/check-ssc-rear-als731.sh"); replaced++
 }
 {print}
 END {if(injected!=1||replaced!=1)exit 1}
' "$spec" > "$stage/new.spec"
install -m644 "$stage/new.spec" "$spec"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-ssc-als-check-7.3.1-$revision* ]]
printf 'Logical rear ALS check prepared over qualified front/full12204; no full-kernel revision or target operation\n'
