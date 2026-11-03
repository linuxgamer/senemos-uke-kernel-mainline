#!/usr/bin/env bash
# COPR-only: retain the verified 7.3.1-3 profile and add the PM8010 population gate.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-4
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11232738/senemos-uke-linux-kernel-mainline-7.3.1-3.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 6f25196564af0baf2535bd79b9904fa17d4d0ebf3cea83bd51d9b7aea0cd5cf2 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-3
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name senemos-native-profile-7.3.1.tar.xz \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fx a4570c876a940615b68efad45c7e7be7f643af99 "$profile/source-commit"
cp "$profile/source-composition.json" "$profile/source-composition-parent7313.json"
overlays=(src/boot/prepare-abl-source.sh src/power/uke-pm8010.h patches/boot/0043-uke-pm8010-firmware-population.patch tests/pm8010-population-contract.sh tests/mainline-package-contract.sh)
for relative in "${overlays[@]}"; do
    install -Dm644 "$owner/$relative" "$profile/$relative"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$owner/manifests/boot-payload.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
    fi
done
# Run the actual new helper against the signed upstream interface before SRPM emission.
fixture=$stage/fixture
mkdir -p "$fixture"
tar -xJf "$output/linux-7.3.1.tar.xz" --strip-components=1 -C "$fixture" \
 linux-7.3.1/include/linux/soc/qcom/socinfo.h linux-7.3.1/drivers/mfd/qcom-spmi-pmic.c
git -C "$fixture" apply "$owner/patches/boot/0043-uke-pm8010-firmware-population.patch"
install -m644 "$owner/src/power/uke-pm8010.h" "$fixture/drivers/mfd/uke-pm8010.h"
bash "$owner/tests/pm8010-population-contract.sh" "$fixture"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
 '{schema_version:1,source_mode:"verified-stable-profile-with-pmic-population-gate",source_commit:$commit,upstream_version:"7.3.1",upstream_commit:"79a907609d53d5cd645b42c11550d295d43abf99",upstream_sha256:"fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231",patch_series:"7.3.0",adaptation_patch_count:122,parent_copr_build:11232738,parent_srpm_sha256:"6f25196564af0baf2535bd79b9904fa17d4d0ebf3cea83bd51d9b7aea0cd5cf2",parent_composition:"source-composition-parent7313.json",adaptation_patches_unchanged:true,overlays:["src/boot/prepare-abl-source.sh","src/power/uke-pm8010.h","patches/boot/0043-uke-pm8010-firmware-population.patch","tests/pm8010-population-contract.sh","tests/mainline-package-contract.sh"],physical_acceptance:false}' > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in
        native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;
        boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;
    esac
    tar --sort=name --mtime=@1793362198 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-4
