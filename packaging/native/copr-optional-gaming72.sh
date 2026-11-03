#!/usr/bin/env bash
# Run in COPR only; keep the installed hardware baseline and add two modules.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.."; pwd)
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228863/senemos-uke-linux-kernel-mainline-7.3.0-54.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' 9aa6389b377756fb6c77b30758fc202b06744d9e862891a4c839fff931df74cc "$output/$spec" | sha256sum -c -
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
cp "$profile/source-composition.json" "$profile/source-composition-parent54.json"
install -m644 "$owner/packaging/native/native.config" "$profile/native.config"
install -m644 "$owner/packaging/native/native.config" "$boot/packaging/native/native.config"
install -m644 "$owner/tests/optional-gaming-platform.sh" "$profile/tests/optional-gaming-platform.sh"
install -m644 "$owner/manifests/llcc-source-candidate-20261020.json" "$profile/manifests/llcc-source-candidate-20261020.json"
install -m644 "$owner/docs/OPTIONAL-GAMING.md" "$profile/OPTIONAL-GAMING.md"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
    '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11228863,parent_srpm_sha256:"615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0",parent_composition:"source-composition-parent54.json",overlays:["native.config","manifests/llcc-source-candidate-20261020.json","tests/optional-gaming-platform.sh","OPTIONAL-GAMING.md"],source_validation:"make validate on COPR source worker",physical_acceptance:false}' \
    > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[] | .sha256 + "  " + .path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.0.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
sed 's/%{?dist}/.fc46/g' "$owner/packaging/$spec" > "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
if rpmspec --parse --target aarch64 "$output/$spec" | grep -Ei '^(Requires|Recommends|Suggests|Supplements):.*\b(wine|proton|fex|box64|mangohud|gamescope|gamemode)\b'; then
    echo 'Unexpected gaming application dependency' >&2
    exit 1
fi
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-72.fc46
