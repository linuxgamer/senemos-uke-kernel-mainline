#!/usr/bin/env bash
# COPR source worker only: retain release52 inputs and apply the explicit security overlay.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.."; pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-53
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228578/senemos-uke-linux-kernel-mainline-7.3.0-52.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 31a8aca3d1da77d3b7ee7e19a68e2739d5119391160892fe3298aee5c4dfe261 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' 908370e0c395eb9677c3da8473a08b4e94368be1939cc2bcaa2b2c62b69a6539 "$output/$spec" | sha256sum -c -
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
parent_commit=$(cat "$profile/source-commit")
commit=$(git -C "$owner" rev-parse HEAD)
install -m644 "$owner/packaging/native/native.config" "$profile/native.config"
install -m644 "$owner/tests/kernel-hardening-config-contract.sh" "$owner/tests/kernel-module-signatures-contract.sh" "$profile/tests/"
install -m644 "$owner/manifests/kernel53-hardening.json" "$profile/"
install -m644 "$owner/src/boot/build-payload.sh" "$profile/src/boot/build-payload.sh"
cat "$owner/packaging/native/hardening53.md" >> "$profile/README.md"
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" --arg parent "$parent_commit" \
    '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_embedded_commit:$parent,parent_copr_build:11228578,parent_srpm_sha256:"31a8aca3d1da77d3b7ee7e19a68e2739d5119391160892fe3298aee5c4dfe261",overlays:["native.config","tests/kernel-hardening-config-contract.sh","tests/kernel-module-signatures-contract.sh","kernel53-hardening.json","src/boot/build-payload.sh","README.md"],physical_acceptance:false}' \
    > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
install -m644 "$owner/packaging/native/native.config" "$boot/packaging/native/native.config"
install -m644 "$owner/src/boot/build-payload.sh" "$boot/src/boot/build-payload.sh"
install -m644 "$owner/tests/kernel-hardening-config-contract.sh" "$boot/tests/"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.0.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-53
