#!/usr/bin/env bash
# COPR-only: retain exact58 kernel sources and fix the boot transaction metadata.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-59
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11230118/senemos-uke-linux-kernel-mainline-7.3.0-58.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 27038c74fa9e5e0e56cef8adc6885a650ab5f055806407f27405bde65f244788 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked" "$stage/baseline"
(cd "$output";cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name 'senemos-native-profile-*' \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
for archive in senemos-native-profile-7.3.0.tar.xz senemos-uke-boot-recipe.tar.xz;do
 tar -tJf "$output/$archive" > "$stage/archive.entries"
 awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
 tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile";sha256sum --check --strict --quiet SHA256SUMS)
cmp "$owner/packaging/native/prepare.sh" "$profile/prepare.sh"
jq -S '.source_assets' "$boot/lock.json" > "$stage/parent-assets.json"
jq -S '.source_assets' "$owner/manifests/boot-payload.json" > "$stage/current-assets.json"
cmp "$stage/parent-assets.json" "$stage/current-assets.json"
bash "$owner/packaging/native/replay-retirement58.sh" "$output" "$profile" "$stage/fixture" > "$stage/parent-files.sha256"
cmp "$stage/parent-files.sha256" "$owner/manifests/retirement58-parent-files.sha256"
while IFS= read -r relative;do install -Dm644 "$stage/fixture/$relative" "$stage/baseline/$relative";done < <(sed 's/^[0-9a-f]*  //' "$stage/parent-files.sha256")
git -C "$stage/fixture" apply --check "$owner/patches/display/0068-msm-scanout-retirement.patch"
git -C "$stage/fixture" apply "$owner/patches/display/0068-msm-scanout-retirement.patch"
CC=clang bash "$owner/tests/msm-retirement-contract.sh" "$stage/fixture" "$stage/baseline"
CC=clang bash "$owner/tests/msm-writeback-contract.sh" "$stage/fixture" "$stage/baseline"
CC=clang bash "$owner/tests/msm-retirement-proof-contract.sh" "$stage/fixture"
cp "$profile/source-composition.json" "$profile/source-composition-parent58.json"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
 '{schema_version:1,source_mode:"pinned-parent-with-package-metadata-correction",source_commit:$commit,parent_copr_build:11230118,parent_srpm_sha256:"27038c74fa9e5e0e56cef8adc6885a650ab5f055806407f27405bde65f244788",parent_binary_build_state:"canceled-before-binary-publication",parent_composition:"source-composition-parent58.json",kernel_source_assets_unchanged:true,package_corrections:["fresh59 ABI and signing identity","uke-kernel-update >=1.8.7 and transaction-v1","boot posttrans uses selected-profile transaction"],source_validation:"exact58 assets; actual-function source fixtures and strict archive/NVR guards in COPR; full native preparation repeats fixtures",physical_acceptance:false}' > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile";find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot";jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe;do
 case $tree in native-profile)archive=senemos-native-profile-7.3.0.tar.xz;;boot-recipe)archive=senemos-uke-boot-recipe.tar.xz;;esac
 tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-59
