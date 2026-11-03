#!/usr/bin/env bash
# COPR source worker only. Retain the53 hardening inputs and repair validation wiring.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.."; pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-54
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
# This target compiles host fixtures; it must run only on the remote worker.
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228820/senemos-uke-linux-kernel-mainline-7.3.0-53.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 06410380de4efda7e6a02f0416b1809a4263b2b76a8467f542edd308b9593f0b "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' 1c17a2ae58aefa2acb18af4223cfc4d6ed0779b6ed27907e0633c7a02631514c "$output/$spec" | sha256sum -c -
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name 'senemos-native-profile-*' \
    ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json \
    -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
for archive in senemos-native-profile-7.3.0.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
commit=$(git -C "$owner" rev-parse HEAD)
cp "$profile/source-composition.json" "$profile/source-composition-parent53.json"
install -m644 "$owner/packaging/native/prepare.sh" "$profile/prepare.sh"
install -m644 "$owner/packaging/native/prepare.sh" "$boot/packaging/native/prepare.sh"
install -m644 "$owner/tests/wlan-power-contract.sh" "$profile/tests/wlan-power-contract.sh"
install -m644 "$owner/tests/mainline-package-contract.sh" "$profile/tests/mainline-package-contract.sh"
install -m644 "$owner/tests/kernel-family-contract.sh" "$profile/tests/kernel-family-contract.sh"
install -m644 "$owner/tests/wlan-power-contract.sh" "$boot/tests/wlan-power-contract.sh"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
    '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11228820,parent_srpm_sha256:"06410380de4efda7e6a02f0416b1809a4263b2b76a8467f542edd308b9593f0b",parent_composition:"source-composition-parent53.json",overlays:["prepare.sh","tests/wlan-power-contract.sh","tests/mainline-package-contract.sh","tests/kernel-family-contract.sh"],source_validation:"make validate on COPR source worker",physical_acceptance:false}' \
    > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.0.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-54
