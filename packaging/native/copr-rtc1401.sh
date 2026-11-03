#!/usr/bin/env bash
# COPR only: preserve the published 1301 cohort and add Uke secure RTC support.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-1401
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl -fLsS --retry 2 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11251200/senemos-uke-linux-kernel-mainline-7.3.1-1301.src.rpm -o "$stage/base.src.rpm"
[[ $(rpm -qp --qf '%{SHA256HEADER}' "$stage/base.src.rpm") == 028a702ee27f00cee694c69ce8b286bae4656808bb20ac172cc0664f25f1be1a ]]
[[ $(rpm -qp --qf '%{PAYLOADSHA256}' "$stage/base.src.rpm") == 5f8ed469d2052c3e63f2743ddd9e327510f4a18855787eb12c13d1482c4a8549 ]]
rpmkeys --checksig --nosignature --verbose "$stage/base.src.rpm"
parent=$(sha256sum "$stage/base.src.rpm");parent=${parent%% *}
printf 'RTC parent1301 SHA-256: %s\n' "$parent"
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=$output/senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "${spec##*/}" ! -name senemos-native-profile-7.3.1.tar.xz \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
 tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
 tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
[[ $(cat "$profile/source-commit") == 1c77e13fe0efd77053add9df9ebc7ae484fdbd48 ]]
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
cp "$profile/source-composition.json" "$profile/source-composition-before1401.json"
cat > "$stage/new-assets" <<'FILES'
src/rtc/uke-rtc-policy.h
src/rtc/prepare-secure-rtc.sh
src/boot/uke-rtc.h
patches/rtc/0001-uke-secure-rtc-offset.patch
tests/rtc-secure-contract.sh
tests/rtc-fdt-contract.sh
docs/RTC-SECURE-OFFSET.md
FILES
for tree in "$profile" "$boot"; do
 (cd "$tree"; find . -type f ! -name SHA256SUMS ! -name source-commit ! -name source-composition.json ! -name lock.json \
  ! -path './src/boot/uke-abl.c' ! -path './src/boot/prepare-abl-source.sh' -print0 | sort -z | xargs -0 sha256sum) > "$stage/unchanged.sha256"
 if [[ -f $tree/src/boot/uke-abl.c ]]; then
  git -C "$tree" apply --check "$owner/packaging/native/rtc-fdt-hook.patch"
  git -C "$tree" apply "$owner/packaging/native/rtc-fdt-hook.patch"
 else [[ $tree == "$boot" ]]; fi
 git -C "$tree" apply --check "$owner/packaging/native/rtc-prepare-hook.patch"
 git -C "$tree" apply "$owner/packaging/native/rtc-prepare-hook.patch"
 while read -r path; do test ! -e "$tree/$path";install -Dm644 "$owner/$path" "$tree/$path";done < "$stage/new-assets"
 (cd "$tree"; sha256sum -c --quiet "$stage/unchanged.sha256")
done
{
 cat "$stage/new-assets"
 printf '%s\n' src/boot/prepare-abl-source.sh
 [[ ! -f $boot/src/boot/uke-abl.c ]] || printf '%s\n' src/boot/uke-abl.c
} > "$stage/boot-overlays"
while read -r path; do
 digest=$(sha256sum "$boot/$path");digest=${digest%% *}
 jq --arg path "$path" --arg digest "$digest" \
  '.source_assets |= (map(select(.path!=$path)) + [{path:$path,sha256:$digest}])' "$boot/lock.json" > "$stage/lock.json"
 install -m644 "$stage/lock.json" "$boot/lock.json"
done < "$stage/boot-overlays"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq --arg commit "$commit" --arg parent "$parent" '. + {
 source_commit:$commit,source_mode:"retained1301-uke-secure-rtc",kernel_release:"7.3.1-1401",rpm_revision:"1401",
 overlays:["src/boot/uke-abl.c","src/boot/prepare-abl-source.sh","src/boot/uke-rtc.h",
  "src/rtc/uke-rtc-policy.h","src/rtc/prepare-secure-rtc.sh","patches/rtc/0001-uke-secure-rtc-offset.patch",
  "tests/rtc-secure-contract.sh","tests/rtc-fdt-contract.sh"],
 parent_copr_build:11251200,parent_srpm_sha256:$parent,parent_composition:"source-composition-before1401.json",
 rtc_backend:"qseecom-uefisecapp-RTCInfo",rtc_qseecom_version:"0x1402000",rtc_pmic_counter_writes:false,
 rtc_sdam_writes:false,rtc_initial_calendar_invalid:true,rtc_offset_write_readback:true,physical_acceptance:false}' \
 "$profile/source-composition-before1401.json" > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c --quiet -)
for tree in native-profile boot-recipe; do
 case $tree in native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;esac
 tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
[[ $(grep -Fxc '%global senemos_build_release 1301' "$spec") == 1 ]]
awk '
 /^%global senemos_build_release 1301$/ {$0="%global senemos_build_release 1401"}
 /^Provides: uke-kernel\(memlat-v1\) = 1$/ {print;print "Provides: uke-kernel(rtc-secure-offset-v1) = 1";next}
 /^Requires: uke-kernel-update >= 1[.]8[.]30$/ {$0="Requires: uke-kernel-update >= 1.8.38"}
 /^%package boot$/ {print;print "Requires: uke-installation-profile(rtc-secure-offset-v1) >= 1";next}
 /^%changelog$/ {print;print "* Tue Nov 03 2026 MCC45TR <75160848+MCC45TR@users.noreply.github.com> - 7.3.1-1401";print "- Add exact Uke firmware admission and verified secure RTC offset persistence.";print "- Refuse uninitialized RTC calendars without changing PMIC time or SDAM.";print "";next}
 {print}
' "$spec" > "$stage/next.spec"
install -m644 "$stage/next.spec" "$spec"
sha256sum -c "$stage/retained.sha256"
[[ $(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$spec") == 7.3.1-1401 ]]
