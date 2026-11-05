#!/usr/bin/env bash
# COPR only: retain the qualified union SRPM and check the actual SSC correction.
set -Eeuo pipefail
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?Pass the remote source result directory}")
revision=${2:-1}
[[ $revision =~ ^[1-9][0-9]*$ ]]
manifest=manifests/ssc-transaction-source-20261105.json
(cd "$owner"; jq -r '.owned_inputs[]|.sha256+"  "+.path' "$manifest" | sha256sum -c --strict --quiet -)
bash "$owner/packaging/native/refuse-published-release.sh" uke-ssc-transaction-check "7.3.1-$revision"
[[ $(curl -q -fLsS --max-time 45 https://copr.fedorainfracloud.org/api_3/build/11261650 | jq -er .state) == succeeded ]]
[[ ! -e $output || (-d $output && -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit)) ]]
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -q -fLsS --retry 2 --max-time 600 --proto '=https' --proto-redir '=https' \
 "$(jq -er .parent.url "$owner/$manifest")" -o "$stage/parent.src.rpm"
printf '%s  %s\n' "$(jq -er .parent.sha256 "$owner/$manifest")" "$stage/parent.src.rpm" | sha256sum -c --strict -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/parent.src.rpm") == uke-coordinated-union-check-7.3.1-2.fc46 ]]
rpmkeys --checksig --nosignature --verbose "$stage/parent.src.rpm"
rpm2cpio "$stage/parent.src.rpm" > "$stage/parent.cpio"
cpio -t --quiet < "$stage/parent.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/parent.cpio")
parent=$output/uke-coordinated-union-check.spec
grep -Fxq 'Name: uke-coordinated-union-check' "$parent"
native_archive=senemos-native-profile-7.3.1.tar.xz
boot_archive=senemos-uke-boot-recipe.tar.xz
find "$output" -maxdepth 1 -type f ! -name "${parent##*/}" ! -name "$native_archive" \
 ! -name "$boot_archive" ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in "$native_archive" "$boot_archive"; do
    tar -tJf "$output/$archive" > "$stage/entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
cmp "$boot/lock.json" "$output/boot-payload.json"
seal_profile() { (cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS); }
snapshot()
{
    local tree
    for tree in "$profile" "$boot"; do
        (cd "$tree"; find . -type f -print0 | sort -z | xargs -0 sha256sum)
    done
}
overlay=$owner/packaging/native/overlay-ssc-transaction731.sh
# A repaired ledger must not admit an unreviewed production preimage.
cp "$profile/src/sensors/uke-ssc-iio.c" "$stage/original.c"
cp "$profile/SHA256SUMS" "$stage/original.ledger"
printf '\n/* Unreviewed source preimage. */\n' >> "$profile/src/sensors/uke-ssc-iio.c"
seal_profile
snapshot > "$stage/refusal.before"
if bash "$overlay" "$profile" "$boot" > "$stage/refusal.log" 2>&1; then
    printf 'SSC source layer admitted an unreviewed preimage\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/original.c" "$profile/src/sensors/uke-ssc-iio.c"
install -m644 "$stage/original.ledger" "$profile/SHA256SUMS"
bash "$overlay" "$profile" "$boot"
# An applied but false API acknowledgement must be refused without mutation.
cp "$profile/source-composition.json" "$stage/applied.composition"
cp "$profile/SHA256SUMS" "$stage/applied.ledger"
jq '.ssc_qmi_transaction_id_returns_id=false' "$stage/applied.composition" > "$profile/source-composition.json"
seal_profile
snapshot > "$stage/refusal.before"
if bash "$overlay" "$profile" "$boot" > "$stage/refusal.log" 2>&1; then
    printf 'SSC source layer admitted a false API acknowledgement\n' >&2; exit 1
fi
snapshot > "$stage/refusal.after"
cmp "$stage/refusal.before" "$stage/refusal.after"
install -m644 "$stage/applied.composition" "$profile/source-composition.json"
install -m644 "$stage/applied.ledger" "$profile/SHA256SUMS"
snapshot > "$stage/repeat.before"
bash "$overlay" "$profile" "$boot"
snapshot > "$stage/repeat.after"
cmp "$stage/repeat.before" "$stage/repeat.after"
printf 'SSC source layer: both required refusals preserve every file; exact repeat passed\n'
commit=$(git -C "$owner" rev-parse HEAD)
jq --arg package "uke-ssc-transaction-check-7.3.1-$revision" --arg commit "$commit" \
 '.source_check_package=$package | .ssc_transaction_layer_producer=$commit' \
 "$profile/source-composition.json" > "$stage/final.composition"
install -m644 "$stage/final.composition" "$profile/source-composition.json"
seal_profile
install -m644 "$boot/lock.json" "$output/boot-payload.json"
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
for tree in native-profile boot-recipe; do
    archive=$native_archive
    [[ $tree != boot-recipe ]] || archive=$boot_archive
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner \
      -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
printf '%s\n' "$commit" > "$output/ssc-transaction-source-commit.txt"
[[ $(grep -c '^Source11:' "$parent") == 0 ]]
spec=$output/uke-ssc-transaction-check.spec
awk -v revision="$revision" -v day="$(date -u --date="@$epoch" '+%a %b %d %Y')" '
 /^Name:/ {$0="Name: uke-ssc-transaction-check";name++}
 /^Release:/ {$0="Release: "revision"%{?dist}";release++}
 /^Summary:/ {$0="Summary: Correct SSC QMI transaction admission in the cumulative source union";summary++}
 /^%description$/ {
   print "Source11: ssc-transaction-source-commit.txt"
   print "\n%description\nCheck every allocated QMI transaction ID against the actual SSC callbacks,"
   print "retain the complete qualified source union and compile native AArch64 objects."
   print "Only text receipts and licenses are packaged; physical sensor acceptance is pending."
   skip=1;description++;next
 }
 /^%prep$/ {skip=0}
 skip {next}
 /^bash memory-addon\/packaging\/native\/check-coordinated-union731.sh / {
   sub(/memory-addon\/packaging\/native\/check-coordinated-union731.sh/,
       "native-profile/packaging/native/check-ssc-transaction731.sh");build++
 }
 /^install -m644 memory-addon\/source-commit / {
   sub(/memory-addon\/source-commit/,"%{SOURCE11}");identity++
 }
 /^%changelog$/ {
   print; print "* "day" Uke contributors - 7.3.1-"revision
   print "- Correct QMI transaction-ID admission and retain cumulative source checks.\n"
   next
 }
 {print}
 END {if(name!=1||release!=1||summary!=1||description!=1||build!=1||identity!=1)exit 1}
' "$parent" > "$spec"
sha256sum -c --strict --quiet "$stage/retained.sha256"
unlink "$parent"
[[ $(rpmspec --target aarch64 -q --srpm --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$spec") == uke-ssc-transaction-check-7.3.1-$revision.fc46 ]]
printf 'SSC transaction check source prepared from qualified union; production spec and unrelated sources retained; no full kernel revision\n'
