#!/usr/bin/env bash
# COPR-only LMH correction; retain the exact release-116 composition.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
expected_release=7.3.1-1004
actual_release=$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$owner/packaging/senemos-uke-linux-kernel-mainline.spec")
[[ $actual_release == "$expected_release" ]] || {
    printf 'Producer expects %s; specification emits %s\n' "$expected_release" "$actual_release" >&2
    exit 1
}
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline "$expected_release"
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test:custom:power-20261031/srpm-builds/11239905/senemos-uke-linux-kernel-mainline-7.3.1-116.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c "$stage/base.src.rpm" | sha256sum -c -
test "$(rpm -qp --qf '%{SOURCEPACKAGE}' "$stage/base.src.rpm")" = 1
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-116
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
grep -Fx d9d48e916070c95d19518dda4aa8bcf11ed3d2b4 "$profile/source-commit"
grep -Fx microphones "$profile/audio-profile"
printf '%s  %s\n' 08d6d0b9320dd489231a41c057c22797f85108474a3ec7ddeaff56afc3c5e3d2 "$profile/native.config" | sha256sum -c -
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent731116.json"
overlays=(
 src/boot/prepare-abl-source.sh patches/boot/0060-cpufreq-lmh-ready-lifecycle.patch
 tests/cpufreq-lmh-lifecycle-contract.sh
)
: > "$stage/overlays"
for relative in "${overlays[@]}"; do
    destination=$relative
    [[ $relative != packaging/native/* ]] || destination=${relative##*/}
    install -Dm644 "$owner/$relative" "$profile/$destination"
    printf '%s\n' "$destination" >> "$stage/overlays"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$owner/manifests/boot-payload.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
    fi
done
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c -
    fi
done < "$stage/parent-profile.sha256"
cmp "$profile/prepare.sh" "$owner/packaging/native/prepare.sh"
cmp "$profile/patches/boot/0054-audioreach-read-completion-v2-layout.patch" \
    "$owner/patches/boot/0054-audioreach-read-completion-v2-layout.patch"
cmp "$profile/tests/audio-graph-response-contract.sh" "$owner/tests/audio-graph-response-contract.sh"
cmp "$profile/src/audio/sm7675-uke-microphone-audio.dtsi" "$owner/src/audio/sm7675-uke-microphone-audio.dtsi"
cmp "$profile/tests/microphone-audio-fdt-contract.sh" "$owner/tests/microphone-audio-fdt-contract.sh"
# Check the complete LMH callback sequence before SRPM emission.
mkdir -p "$stage/fixture"
tar -xJf "$output/linux-7.3.1.tar.xz" --strip-components=1 -C "$stage/fixture" \
 linux-7.3.1/drivers/cpufreq/qcom-cpufreq-hw.c
git -C "$stage/fixture" apply "$owner/patches/boot/0055-cpufreq-lmh-policy-lifecycle.patch"
git -C "$stage/fixture" apply "$owner/patches/boot/0060-cpufreq-lmh-ready-lifecycle.patch"
bash "$owner/tests/cpufreq-lmh-lifecycle-contract.sh" "$stage/fixture/drivers/cpufreq/qcom-cpufreq-hw.c"
commit=$(git -C "$owner" rev-parse HEAD)
epoch=$(git -C "$owner" show -s --format=%ct HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq --arg commit "$commit" --slurpfile overlays "$stage/overlays.json" \
 '. + {source_mode:"retained-release116-with-lmh-ready-fix",source_commit:$commit,
 parent_copr_build:11239905,parent_source_commit:"d9d48e916070c95d19518dda4aa8bcf11ed3d2b4",
 parent_srpm_sha256:"e376800a58f3d1b91e89b5f88b678da950e74157035db7944edbf306cc7f822c",
 parent_composition:"source-composition-parent731116.json",adaptation_patches_unchanged:true,
 overlays:$overlays[0],audio_hardware_settings_unchanged:true,hardware_settings_unchanged:false,
 lmh_policy_lifecycle_fix:true,lmh_policy_ready_fix:true,cpucp_observer:"manual-get-only",cpucp_version_negotiation:false,
 cpucp_required_version:"1.0",boost_default_changed:false,ignore_unused_removed:[],
 pm_debug_messages:true,physical_acceptance:false}' \
 "$profile/source-composition-parent731116.json" > "$profile/source-composition.json"
# Preserve the qualified audio fields rather than reconstructing an older profile.
jq -e --slurpfile parent "$profile/source-composition-parent731116.json" \
 '[.audio_profile,.capture_channels,.capture_channel_counts,.capture_analog_inputs,
   .input_qualification,.analog_gain_indices,.digital_gain_db,.gain_applied_before_capture,
   .desktop_data_owner] == ($parent[0] | [.audio_profile,.capture_channels,.capture_channel_counts,
   .capture_analog_inputs,.input_qualification,.analog_gain_indices,.digital_gain_db,
   .gain_applied_before_capture,.desktop_data_owner]) and .capture_channels==4 and
   .capture_channel_counts==[1,2,4] and .adaptation_patch_count==122' \
 "$profile/source-composition.json" >/dev/null
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
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = "$expected_release"
