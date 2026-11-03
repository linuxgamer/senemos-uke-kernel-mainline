#!/usr/bin/env bash
# COPR source worker only; retain release54 and apply the reviewed framebuffer overlay.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.."; pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-55
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11228863/senemos-uke-linux-kernel-mainline-7.3.0-54.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked" "$stage/fixture"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
printf '%s  %s\n' 9aa6389b377756fb6c77b30758fc202b06744d9e862891a4c839fff931df74cc "$output/$spec" | sha256sum -c -
find "$output" -maxdepth 1 -type f ! -name "$spec" ! -name 'senemos-native-profile-*' \
    ! -name senemos-uke-boot-recipe.tar.xz ! -name boot-payload.json \
    -print0 | sort -z | xargs -0 sha256sum > "$stage/unchanged.sha256"
# Fast actual-function controls run remotely before any new kernel compilation.
files=(drivers/gpu/drm/msm/msm_fb.c drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c
    drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.h drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys.h
    drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_wb.c drivers/gpu/drm/msm/disp/dpu1/dpu_writeback.c)
paths=(); for file in "${files[@]}"; do paths+=("linux-7.3/$file"); done
tar -xJf "$output/linux-7.3.0.tar.xz" -C "$stage/fixture" --strip-components=1 "${paths[@]}"
cp "$stage/fixture/drivers/gpu/drm/msm/msm_fb.c" "$stage/baseline.c"
git -C "$stage/fixture" init -q
git -C "$stage/fixture" apply --check "$owner/patches/display/0065-msm-framebuffer-pin-state.patch"
git -C "$stage/fixture" apply "$owner/patches/display/0065-msm-framebuffer-pin-state.patch"
CC=clang bash "$owner/tests/msm-framebuffer-pin-contract.sh" "$stage/fixture" "$stage/baseline.c"
for archive in senemos-native-profile-7.3.0.tar.xz senemos-uke-boot-recipe.tar.xz; do
    tar -tJf "$output/$archive" | awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}'
    tar -xJf "$output/$archive" -C "$stage/unpacked"
done
profile=$stage/unpacked/native-profile
boot=$stage/unpacked/boot-recipe
(cd "$profile"; sha256sum --check --strict --quiet SHA256SUMS)
cp "$profile/source-composition.json" "$profile/source-composition-parent54.json"
for relative in packaging/native/prepare.sh tests/msm-framebuffer-pin-contract.sh patches/display/0065-msm-framebuffer-pin-state.patch; do
    install -Dm644 "$owner/$relative" "$boot/$relative"
    case $relative in packaging/native/prepare.sh) destination=prepare.sh;; *) destination=$relative;; esac
    install -Dm644 "$owner/$relative" "$profile/$destination"
done
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
    '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11228863,parent_srpm_sha256:"615b362bd44b15ec267c16532e986629df422966658769f6bb715004bfa7c1b0",parent_composition:"source-composition-parent54.json",overlays:["prepare.sh","tests/msm-framebuffer-pin-contract.sh","patches/display/0065-msm-framebuffer-pin-state.patch"],source_validation:"actual-function UBSan fixture and baseline controls in COPR; repeated after complete native preparation",physical_acceptance:false}' > "$profile/source-composition.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in native-profile) archive=senemos-native-profile-7.3.0.tar.xz;; boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;; esac
    tar --sort=name --mtime=@1791725270 --owner=0 --group=0 --numeric-owner \
        -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/unchanged.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-55
