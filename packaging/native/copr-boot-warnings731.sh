#!/bin/bash
# COPR-only: retain release110 and overlay bounded startup warning fixes.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-115
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11239296/senemos-uke-linux-kernel-mainline-7.3.1-110.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 84a612c12c4b99ce29077273cdca6dce704fd94c364f4c7c50bcdeb9313af69c "$stage/base.src.rpm" | sha256sum -c -
test "$(rpm -qp --qf '%{SOURCEPACKAGE}' "$stage/base.src.rpm")" = 1
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/{bad=1} END{exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-110
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name senemos-native-profile-7.3.1.tar.xz \
 ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json -print0 | sort -z | xargs -0 sha256sum > "$stage/retained.sha256"
for archive in senemos-native-profile-7.3.1.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/{bad=1} END{exit bad}'
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
grep -Fxq 1ea50711f0acf2e5cb3aa1cb7c349ba065c3db33 "$profile/source-commit"
printf '%s  %s\n' 8cdef42c010304bd948cf1fa83015c12b8cce637f647bfcf166de6c49efc3db1 "$profile/prepare.sh" | sha256sum -c -
expected_linux=$(jq -er .source_sha256 "$owner/manifests/linux-7.3.1.json")
printf '%s  %s\n' "$expected_linux" "$output/linux-7.3.1.tar.xz" | sha256sum -c -
slice=$stage/source-check
mkdir -p "$slice"
for relative in drivers/soc/qcom/llcc-qcom.c include/linux/soc/qcom/llcc-qcom.h drivers/gpu/drm/msm/adreno/a6xx_gpu.c sound/soc/codecs/lpass-rx-macro.c sound/soc/codecs/lpass-wsa-macro.c usr/gen_init_cpio.c; do
    mkdir -p "$slice/$(dirname "$relative")"
    tar -xOf "$output/linux-7.3.1.tar.xz" "linux-7.3.1/$relative" > "$slice/$relative"
done
git -C "$slice" init -q
while IFS=$'\t' read -r relative expected; do
    printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c --status
    git -C "$slice" apply --include=drivers/soc/qcom/llcc-qcom.c --include=include/linux/soc/qcom/llcc-qcom.h \
        --include=drivers/gpu/drm/msm/adreno/a6xx_gpu.c --include=sound/soc/codecs/fs19xx.c \
        --include=sound/soc/codecs/lpass-rx-macro.c --include=sound/soc/codecs/lpass-wsa-macro.c \
        --include=usr/gen_init_cpio.c "$profile/$relative"
done < <(jq -r '.patches[] | [.path,.sha256] | @tsv' "$owner/manifests/native-linux-7.3.1.json")
for patch in 0057-llcc-optional-window.patch 0058-fs19xx-current-workqueue.patch 0059-lpass-sort-reg-defaults.patch; do
    git -C "$slice" apply "$owner/patches/boot/$patch"
done
CC=clang bash "$owner/tests/llcc-sm7675-contract.sh" "$slice"
CC=clang bash "$owner/tests/audio-fs19xx-lifecycle-contract.sh" "$slice"
# Match the selected Linux Makefile's common host C flags.
clang -Wall -Wmissing-prototypes -Wstrict-prototypes -O2 -fomit-frame-pointer -std=gnu11 \
    "$slice/usr/gen_init_cpio.c" -o "$slice/usr/gen_init_cpio"
bash "$owner/tests/initramfs-cpio-contract.sh" "$slice/usr/gen_init_cpio"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent731110.json"
overlays=(packaging/native/prepare.sh patches/boot/0057-llcc-optional-window.patch
 patches/boot/0058-fs19xx-current-workqueue.patch patches/boot/0059-lpass-sort-reg-defaults.patch tests/llcc-sm7675-contract.sh
 tests/audio-fs19xx-lifecycle-contract.sh src/boot/build-payload.sh src/boot/make-initramfs-cpio.sh
 tests/initramfs-cpio-contract.sh)
: > "$stage/overlays"
for relative in "${overlays[@]}"; do
    destination=$relative
    [[ $relative != packaging/native/prepare.sh ]] || destination=prepare.sh
    install -Dm644 "$owner/$relative" "$profile/$destination"
    printf '%s\n' "$destination" >> "$stage/overlays"
    install -Dm644 "$owner/$relative" "$boot/$relative"
done
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c -
    fi
done < "$stage/parent-profile.sha256"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --slurpfile overlays "$stage/overlays.json" \
 '. + {source_mode:"qualified-parent-with-bounded-boot-warning-fixes",source_commit:$commit,
 parent_copr_build:11239296,parent_srpm_sha256:"84a612c12c4b99ce29077273cdca6dce704fd94c364f4c7c50bcdeb9313af69c",
 parent_composition:"source-composition-parent731110.json",overlays:$overlays[0],
 adaptation_patches_unchanged:true,hardware_settings_unchanged:true,physical_acceptance:false}' \
 "$profile/source-composition-parent731110.json" > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.1.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime="@$epoch" --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-115
