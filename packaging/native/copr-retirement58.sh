#!/usr/bin/env bash
# COPR source worker: exact57 parent plus independently checked retirement.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-58
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11229645/senemos-uke-linux-kernel-mainline-7.3.0-57.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 7d21da70f8f06410487f0f3c28f8bfa4147096eea3bebe538d6d83f4660e974d "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked" "$stage/baseline"
(cd "$output";cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name 'senemos-native-profile-*' \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
for archive in senemos-native-profile-7.3.0.tar.xz senemos-uke-boot-recipe.tar.xz;do
 tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
 tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile";sha256sum --check --strict --quiet SHA256SUMS)
bash "$owner/packaging/native/replay-retirement58.sh" "$output" "$profile" "$stage/fixture" > "$stage/parent-files.sha256"
cmp "$stage/parent-files.sha256" "$owner/manifests/retirement58-parent-files.sha256"
while IFS= read -r relative;do install -Dm644 "$stage/fixture/$relative" "$stage/baseline/$relative";done < <(sed 's/^[0-9a-f]*  //' "$stage/parent-files.sha256")
git -C "$stage/fixture" apply --check "$owner/patches/display/0068-msm-scanout-retirement.patch"
git -C "$stage/fixture" apply "$owner/patches/display/0068-msm-scanout-retirement.patch"
CC=clang bash "$owner/tests/msm-retirement-contract.sh" "$stage/fixture" "$stage/baseline"
CC=clang bash "$owner/tests/msm-writeback-contract.sh" "$stage/fixture" "$stage/baseline"
CC=clang bash "$owner/tests/msm-retirement-proof-contract.sh" "$stage/fixture"
cp "$profile/source-composition.json" "$profile/source-composition-parent57.json"
overlays=(packaging/native/prepare.sh patches/display/0068-msm-scanout-retirement.patch \
 tests/msm-retirement-contract.sh tests/msm-writeback-contract.sh tests/msm-retirement-proof-contract.sh manifests/retirement58-parent-files.sha256)
for relative in "${overlays[@]}";do
 install -Dm644 "$owner/$relative" "$boot/$relative"
 case $relative in packaging/native/prepare.sh) destination=prepare.sh;;manifests/retirement58-parent-files.sha256) destination=retirement58-parent-files.sha256;;*)destination=$relative;;esac
 install -Dm644 "$owner/$relative" "$profile/$destination"
done
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
 '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11229645,parent_srpm_sha256:"7d21da70f8f06410487f0f3c28f8bfa4147096eea3bebe538d6d83f4660e974d",parent_composition:"source-composition-parent57.json",overlays:["prepare.sh","patches/display/0068-msm-scanout-retirement.patch","tests/msm-retirement-contract.sh","tests/msm-writeback-contract.sh","tests/msm-retirement-proof-contract.sh","retirement58-parent-files.sha256"],source_validation:"actual-function UBSan timer/ownership/failure fixtures in COPR; exact parent bytes and fixtures repeated after complete native preparation",physical_acceptance:false}' > "$profile/source-composition.json"
(cd "$profile";find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot";jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe;do
 case $tree in native-profile)archive=senemos-native-profile-7.3.0.tar.xz;;boot-recipe)archive=senemos-uke-boot-recipe.tar.xz;;esac
 tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-58
