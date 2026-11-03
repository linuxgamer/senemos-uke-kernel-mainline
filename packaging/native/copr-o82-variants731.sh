#!/usr/bin/env bash
# COPR only: add supplier variants to the retained release1011 source recipe.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1101
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
parent_hash=84915ef98a26df47bc8f223e3751b160e40eba3c447f433fbe13b2097d6a7146
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11246385/senemos-uke-linux-kernel-mainline-7.3.1-1011.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' "$parent_hash" "$stage/base.src.rpm" | sha256sum -c -
[[ $(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}' "$stage/base.src.rpm") == senemos-uke-linux-kernel-mainline-7.3.1-1011 ]]
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" \
 ! -name senemos-native-profile-7.3.1.tar.xz ! -name senemos-uke-boot-recipe.tar.xz \
 ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$boot/lock.json" "$stage/parent-boot-lock.json"
cp "$profile/source-composition.json" "$profile/source-composition-before1101.json"
printf '%s  %s\n' cf0e81e7732a08f34b4b2666647e7a522034f1da1ebd58ddc7fdefb2af5493ec "$profile/prepare.sh" | sha256sum -c -
git -C "$profile" apply --check "$owner/packaging/native/o82-variants1011-prepare.patch"
git -C "$profile" apply "$owner/packaging/native/o82-variants1011-prepare.patch"
printf '%s  %s\n' 1c8b30589256c211c46752e106ddec1568a63d91dca71624e5342a00ba927ccf "$profile/prepare.sh" | sha256sum -c -
printf 'prepare.sh\n' > "$stage/overlays"
cat "$owner/packaging/native/o82-variants1011-overlays.txt" >> "$stage/overlays"
: > "$stage/boot-overlays"
while read -r relative; do
    [[ $relative =~ ^(src|patches|tests)/[a-zA-Z0-9_./-]+$ && $relative != *..* ]]
    install -Dm644 "$owner/$relative" "$profile/$relative"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$boot/lock.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
        printf '%s\n' "$relative" >> "$stage/boot-overlays"
        hash=$(sha256sum "$boot/$relative"); hash=${hash%% *}
        jq --arg path "$relative" --arg hash "$hash" \
            '(.source_assets[]|select(.path==$path).sha256)=$hash' \
            "$boot/lock.json" > "$boot/lock.json.new"
        mv "$boot/lock.json.new" "$boot/lock.json"
    fi
done < "$owner/packaging/native/o82-variants1011-overlays.txt"
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --quiet -
    fi
done < "$stage/parent-profile.sha256"
cmp <(jq -S 'del(.source_assets[].sha256)' "$stage/parent-boot-lock.json") \
    <(jq -S 'del(.source_assets[].sha256)' "$boot/lock.json")
while IFS=$'\t' read -r relative expected; do
    if ! grep -Fxq "$relative" "$stage/boot-overlays"; then
        printf '%s  %s\n' "$expected" "$boot/$relative" | sha256sum -c --quiet -
    fi
done < <(jq -r '.source_assets[]|[.path,.sha256]|@tsv' "$stage/parent-boot-lock.json")
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --arg parent_hash "$parent_hash" --slurpfile overlays "$stage/overlays.json" \
 'del(.kernel_driver_source_unchanged) + {source_mode:"retained1011-with-o82-touch-pmic-variants",
 source_commit:$commit,parent_copr_build:11246385,parent_srpm_sha256:$parent_hash,
 parent_composition:"source-composition-before1101.json",kernel_release:"7.3.1-1101",rpm_revision:"1101",
 overlays:$overlays[0],panel_variants:["o82_36_02_0a","o82_42_02_0b"],
 touch_variants:["tianma","csot"],pm8010_complete_inventory_check:true,
 firmware_payload_included:false,physical_acceptance:false}' \
 "$profile/source-composition-before1101.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
    case $tree in
        native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;
        boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;
    esac
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1011' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1011$/ {$0="%global senemos_build_release 1101"}
 /^%changelog$/ {
  print;print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1101"
  print "- Select either O82 native panel and its NT36532 supplier at early boot."
  print "- Validate the complete PMIC inventory before admitting PM8010."
  print "- Check both DSI suppliers and retain foreign-panel refusal coverage."
  print "";next
 }
 {print}
' "$spec" > "$stage/next.spec"
mv "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1101 ]]
