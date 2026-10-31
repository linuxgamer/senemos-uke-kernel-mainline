#!/usr/bin/env bash
# COPR-only: DT microphone gains and kernel audio data over qualified release102.
set -Eeuo pipefail
export LC_ALL=C
test ! -e /etc/senemos/kernel-update.conf
[[ $(rpm --eval '%{_host_cpu}') == aarch64 && $(rpm --eval '%{fedora}') == 46 ]]
owner=$(cd -- "$(dirname -- "$0")/../.." && pwd)
output=$(realpath -m "${1:?COPR result directory}")
bash "$owner/packaging/native/refuse-published-release.sh" senemos-uke-linux-kernel-mainline 7.3.1-108
CC=clang bash "$owner/tests/audio-eld-contract.sh"
CC=clang bash "$owner/tests/microphone-gain-contract.sh"
CXX=clang++ bash "$owner/tests/kernel-audio-policy-contract.sh"
make -C "$owner" validate
stage=$(mktemp -d)
trap 'find "$stage" -depth -delete' EXIT
curl --fail --location --silent --show-error --retry 3 --proto '=https' --proto-redir '=https' \
 https://download.copr.fedorainfracloud.org/results/mcc45tr/uke-linux-test:custom:microphone-20261030/srpm-builds/11235075/senemos-uke-linux-kernel-mainline-7.3.1-102.src.rpm -o "$stage/base.src.rpm"
printf '%s  %s\n' 42d6f7dde4e8d38356a9616abc5f4ce15c60b0eebcafbe740bc2d5e8fabaf84a "$stage/base.src.rpm" | sha256sum -c -
rpm2cpio "$stage/base.src.rpm" > "$stage/base.cpio"
cpio -t --quiet < "$stage/base.cpio" > "$stage/entries"
awk '/^\/|(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' "$stage/entries"
mkdir -p "$output" "$stage/unpacked"
(cd "$output"; cpio -idm --quiet --no-absolute-filenames < "$stage/base.cpio")
spec=senemos-uke-linux-kernel-mainline.spec
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-102
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
grep -Fx dcc59b39094d9875be91114cd838d85d9faa0002 "$profile/source-commit"
cp "$profile/SHA256SUMS" "$stage/parent-profile.sha256"
cp "$profile/source-composition.json" "$profile/source-composition-parent731102.json"
overlays=(
 packaging/native/prepare.sh packaging/native/audio-profile packaging/native/README.md
 src/boot/prepare-abl-source.sh src/audio/uke-audio-card.c
 src/audio/sm7675-uke-microphone-audio.dtsi src/audio/POCO-Pad-X1-Microphone-Capture.conf
 src/display/sm7675-uke-native-display-oem-modes.dtso
 patches/boot/0043-wcd939x-micbias-errors.patch patches/boot/0044-uke-microphone-bob-supply.patch
 patches/boot/0045-wcd939x-uke-supply-order.patch patches/boot/0046-wcd939x-chip-identification-errors.patch
 patches/boot/0047-wcd939x-uke-reset-required.patch patches/boot/0048-uke-soundwire-machine-dependency.patch
 patches/boot/0049-wcd939x-io-errors.patch patches/boot/0050-soundwire-resume-clock-error.patch
 patches/boot/0053-q6apm-uke-mono-capture.patch tests/microphone-pcm-limits-contract.sh
 patches/boot/0054-audioreach-read-completion-v2-layout.patch tests/audio-graph-response-contract.sh
 patches/boot/0055-lpass-tx-macro-multichannel-state.patch tests/lpass-tx-multichannel-contract.sh
 patches/boot/0056-q6apm-uke-raw-microphone-channel-map.patch tests/microphone-channel-map-contract.sh
 tests/audio-services-fdt-contract.sh tests/mainline-package-contract.sh
 tests/microphone-audio-card-contract.sh tests/microphone-audio-fdt-contract.sh
 tests/microphone-audio-topology-contract.sh tests/soundwire-resume-clock-contract.sh
 tests/speaker-audio-fdt-contract.sh tests/uke-rpmh-resource-contract.sh
 tests/wcd939x-chip-info-contract.sh tests/wcd939x-io-contract.sh
 tests/wcd939x-micbias-contract.sh tests/wcd939x-reset-consumer-contract.sh
 tests/wcd939x-supply-order-contract.sh
)
overlays+=(src/audio/uke-microphone-gain.h src/audio/xiaomi,uke-microphone-gain.yaml
 tests/microphone-gain-contract.sh tests/kernel-audio-policy-contract.sh tests/kernel-family-contract.sh
 src/audio/uke-dp-eld.h tests/audio-eld-contract.sh)
while IFS= read -r relative; do overlays+=("$relative"); done < <(find "$owner/src/audio/desktop" -type f -printf '%P\n' | sed 's|^|src/audio/desktop/|' | LC_ALL=C sort)
: > "$stage/overlays"
for relative in "${overlays[@]}"; do
    destination=$relative
    case $relative in packaging/native/*) destination=${relative##*/};; esac
    install -Dm644 "$owner/$relative" "$profile/$destination"
    printf '%s\n' "$destination" >> "$stage/overlays"
    if jq -e --arg path "$relative" '.source_assets[]|select(.path==$path)' "$owner/manifests/boot-payload.json" >/dev/null; then
        install -Dm644 "$owner/$relative" "$boot/$relative"
    fi
done
# Every retained native-profile file outside this explicit overlay stays exact.
while read -r expected relative; do
    relative=${relative#./}
    case $relative in source-commit|source-composition.json) continue;; esac
    if ! grep -Fxq -- "$relative" "$stage/overlays"; then
        printf '%s  %s\n' "$expected" "$profile/$relative" | sha256sum -c -
    fi
done < "$stage/parent-profile.sha256"
commit=$(git -C "$owner" rev-parse HEAD)
printf '%s\n' "$commit" > "$profile/source-commit"
jq -Rn '[inputs]' < "$stage/overlays" > "$stage/overlays.json"
jq -n --arg commit "$commit" --slurpfile overlays "$stage/overlays.json" \
 '{schema_version:1,source_mode:"qualified-parent-with-bounded-startup-gain-and-kernel-audio-data",source_commit:$commit,upstream_version:"7.3.1",upstream_commit:"79a907609d53d5cd645b42c11550d295d43abf99",upstream_sha256:"fa595aad93734f829c963c2a90ef7c3673224fd7fdae7b49406e397cde2de231",patch_series:"7.3.0",adaptation_patch_count:122,parent_copr_build:11235075,parent_srpm_sha256:"42d6f7dde4e8d38356a9616abc5f4ce15c60b0eebcafbe740bc2d5e8fabaf84a",parent_composition:"source-composition-parent731102.json",adaptation_patches_unchanged:true,overlays:$overlays[0],audio_profile:"microphones",capture_channels:4,capture_channel_counts:[1,2,4],capture_analog_inputs:[1,3,4,5],input_qualification:"parent102_four_raw_paths_isolated_and_policy13_single_array_device_verified",analog_gain_indices:[8,8,8,8],digital_gain_db:[24,24,24,24],gain_applied_before_capture:true,desktop_data_owner:"kernel-core",physical_acceptance:false}' > "$profile/source-composition.json"
install -m644 "$owner/manifests/boot-payload.json" "$boot/lock.json"
(cd "$profile"; find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
(cd "$boot"; jq -r '.source_assets[]|.sha256+"  "+.path' lock.json | sha256sum -c -)
for tree in native-profile boot-recipe; do
    case $tree in
        native-profile) archive=senemos-native-profile-7.3.1.tar.xz;;
        boot-recipe) archive=senemos-uke-boot-recipe.tar.xz;;
    esac
    tar --sort=name --mtime=@1793394000 --owner=0 --group=0 --numeric-owner -cJf "$output/$archive" -C "$stage/unpacked" "$tree"
done
install -m644 "$boot/lock.json" "$output/boot-payload.json"
install -m644 "$owner/packaging/$spec" "$output/$spec"
sha256sum -c "$stage/retained.sha256"
test "$(rpmspec --target aarch64 --define 'dist %{nil}' -q --srpm --qf '%{VERSION}-%{RELEASE}' "$output/$spec")" = 7.3.1-108
