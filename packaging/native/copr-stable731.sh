#!/usr/bin/env bash
# COPR-only: move the reviewed release60 profile to signed upstream Linux 7.3.1.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-3
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11230581/senemos-uke-linux-kernel-mainline-7.3.0-60.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' b6352bcfd676eaeaa60c92577a3a53c5cb870a2310fb9dc8bbb58548a7987394 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' ecf44522bbfd183da3751aa48701c264fe4e51266caeb4f44c688a13175fc7f0 "$output/$spec" | sha256sum -c -
find "$output" -maxdepth 1 -type f \( -name linux-stable.asc -o -name SINGLEBOOT.md -o -name singleboot-LICENSE \) \
 -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-uke-adaptation-7.3.0.tar.xz senemos-native-profile-7.3.0.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" > "$stage/archive.entries"
    awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/archive.entries"
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
adaptation=$stage/unpacked/senemos-adaptation
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
find "$adaptation" -type f ! -name source-lock.json -print0 | sort -z | xargs -0 sha256sum > "$stage/patches.sha256"
printf '%s  %s\n' 17965b134c67009e79cf7ed8c0acfb63680e47ebec77d278bc7445fd5de559df "$adaptation/source-lock.json" | sha256sum -c -
install -m644 "$owner/manifests/native-linux-7.3.1.json" "$adaptation/source-lock.json"
jq -r '.patches[].path|split("/")|last' "$adaptation/source-lock.json" > "$stage/expected-series"
cmp "$stage/expected-series" "$adaptation/patches/series"
while IFS=$'\t' read -r path expected; do
    case $path in
        patches/*) staged="$adaptation/patches/${path##*/}";;
        configs/*) staged="$adaptation/configs/${path##*/}";;
        *) exit 1;;
    esac
    printf '%s  %s\n' "$expected" "$staged" | sha256sum -c -
done < <(jq -r '.patches[],.configs[]|[.path,.sha256]|@tsv' "$adaptation/source-lock.json")
sha256sum -c "$stage/patches.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent60.json"
overlays=(packaging/native/prepare.sh src/boot/prepare-abl-source.sh src/display/prepare-source.sh src/video/prepare-source.sh tests/mainline-package-contract.sh tests/msm-kms-alternate-build.sh tests/msm-kms-release-contract.sh)
for relative in "${overlays[@]}"; do
    destination=$relative
    [[ $relative != packaging/native/prepare.sh ]] || destination=prepare.sh
    install -Dm644 "$owner/$relative" "$profile/$destination"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$owner/manifests/boot-payload.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
    fi
done
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
 '{schema_version:1,source_mode:"signed-stable-upgrade-with-explicit-profile-overlay",source_commit:$commit,upstream_version:"7.3.1",upstream_commit:"79a907609d53d5cd645b42c11550d295d43abf99",upstream_sha256:"fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231",patch_series:"7.3.0",adaptation_patch_count:122,parent_copr_build:11230581,parent_srpm_sha256:"b6352bcfd676eaeaa60c92577a3a53c5cb870a2310fb9dc8bbb58548a7987394",parent_composition:"source-composition-parent60.json",adaptation_patches_unchanged:true,overlays:["prepare.sh","src/boot/prepare-abl-source.sh","src/display/prepare-source.sh","src/video/prepare-source.sh","tests/mainline-package-contract.sh","tests/msm-kms-alternate-build.sh","tests/msm-kms-release-contract.sh"],physical_acceptance:false}' > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in senemos-adaptation native-profile boot-recipe; do
    case $tree in
        senemos-adaptation) archive=senemos-uke-adaptation-7.3.1.tar.xz;;
        native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;
        boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;
    esac
    tar --sort=name --mtime=@1793362198 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
for suffix in tar.xz tar.sign; do
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
        "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.1.$suffix" -o "$output/linux-7.3.1.$suffix"
done
printf '%s  %s\n' fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231 "$output/linux-7.3.1.tar.xz" | sha256sum -c -
find "$output" -maxdepth 1 -type f \( -name 'linux-7.3.0.tar.*' -o -name 'senemos-uke-adaptation-7.3.0.tar.xz' -o -name 'senemos-native-profile-7.3.0.tar.xz' \) -delete
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-3
