#!/usr/bin/env bash
# COPR source worker: retain55 and apply the reviewed DPU reservation overlay.
set -Eeuo pipefail
export LC_ALL=C
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.0-56
output=$(realpath -m "${1:?COPR result directory}")
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
    https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-unstable/srpm-builds/11229234/senemos-uke-linux-kernel-mainline-7.3.0-55.src.rpm \
    -o "$stage/base.src.rpm"
printf '%s  %s\n' 4ba244078f2419e3af731cfdb09dcb432c2031b594af95410dacb08ece918ef1 "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked" "$stage/fixture" "$stage/baseline"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
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
# Reproduce the three selected55 translation units before the full native build.
files=(drivers/gpu/drm/msm/msm_atomic.c drivers/gpu/drm/msm/disp/dpu1/dpu_crtc.c drivers/gpu/drm/msm/disp/dpu1/dpu_encoder.c)
paths=(); includes=(); for file in "${files[@]}"; do paths+=("linux-7.3/$file"); includes+=("--include=$file"); done
tar -xJf "$output/linux-7.3.0.tar.xz" -C "$stage/fixture" --strip-components=1 "${paths[@]}"
tar -xJf "$output/senemos-uke-adaptation-7.3.0.tar.xz" -C "$stage/fixture"
git -C "$stage/fixture" init -q
while IFS= read -r patch; do
    git -C "$stage/fixture" apply --allow-empty "${includes[@]}" "$stage/fixture/senemos-adaptation/patches/$patch"
done < "$stage/fixture/senemos-adaptation/patches/series"
git -C "$stage/fixture" apply "${includes[@]}" "$profile/patches/display/0065-msm-framebuffer-pin-state.patch"
for patch in 0020-uke-single-ctl-bonded-video-flush.patch \
    0034-uke-o82-live-refresh-timing.patch 0035-uke-o82-video-avr-experiment.patch \
    0036-uke-o82-all-mode-avr-experiment.patch 0037-uke-avr-vblank-timestamp.patch \
    0038-uke-avr-frame-watchdog.patch 0039-uke-o82-stop-source-before-video.patch \
    0040-uke-o82-experimental-vrr-capability.patch 0041-dpu-frame-watchdog-lifecycle.patch \
    0042-uke-o82-live-avr-retiming.patch 0043-uke-o82-live-avr-disable-modeset.patch \
    0044-uke-displayport-10bpc-output.patch 0047-uke-o82-retain-touch-cadence-floor.patch \
    0051-uke-sm7675-color-mixers.patch 0059-uke-displayport-rgb-dsc-fec.patch \
    0061-uke-dp-mst-and-negotiated-lanes.patch; do
    git -C "$stage/fixture" apply --allow-empty "${includes[@]}" "$profile/patches/display/$patch"
done
for file in "${files[@]}"; do install -Dm644 "$stage/fixture/$file" "$stage/baseline/$file"; done
git -C "$stage/fixture" apply --check "$owner/patches/display/0066-msm-dpu-reservation-ownership.patch"
git -C "$stage/fixture" apply "$owner/patches/display/0066-msm-dpu-reservation-ownership.patch"
CC=clang bash "$owner/tests/dpu-reservation-contract.sh" "$stage/fixture" "$stage/baseline"
cp "$profile/source-composition.json" "$profile/source-composition-parent55.json"
for relative in packaging/native/prepare.sh tests/dpu-reservation-contract.sh patches/display/0066-msm-dpu-reservation-ownership.patch; do
    install -Dm644 "$owner/$relative" "$boot/$relative"
    case $relative in packaging/native/prepare.sh) destination=prepare.sh;; *) destination=$relative;; esac
    install -Dm644 "$owner/$relative" "$profile/$destination"
done
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -n --arg commit "$commit" \
    '{schema_version:1,source_mode:"pinned-parent-with-explicit-overlay",source_commit:$commit,parent_copr_build:11229234,parent_srpm_sha256:"4ba244078f2419e3af731cfdb09dcb432c2031b594af95410dacb08ece918ef1",parent_composition:"source-composition-parent55.json",overlays:["prepare.sh","tests/dpu-reservation-contract.sh","patches/display/0066-msm-dpu-reservation-ownership.patch"],source_validation:"actual-function UBSan fixture and six unmodified-source controls in COPR; repeated after complete native preparation",physical_acceptance:false}' > "$profile/source-composition.json"
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
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.0-56
